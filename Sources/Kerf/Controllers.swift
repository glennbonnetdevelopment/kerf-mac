import Foundation
import KerfCore

struct LogLine: Identifiable {
    enum Kind { case sent, received, info, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// Talks to a GRBL controller over USB serial.
@MainActor
final class LaserController: ObservableObject {
    @Published var ports: [String] = []
    @Published var selectedPort = ""
    @Published private(set) var isConnected = false
    @Published private(set) var status = GRBLStatus(state: "Disconnected")
    @Published private(set) var workPosition: Vec2?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var progress = 0.0
    @Published private(set) var elapsed: TimeInterval = 0

    private var port: SerialPort?
    private var streamer = GRBLStreamer()
    private var rxBuffer = ""
    private var statusTimer: Timer?
    private var workOffset = Vec2.zero
    private var jobFirstAck = 0
    private var jobLineCount = 0
    private var jobStarted: Date?

    init() {
        refreshPorts()
    }

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if !ports.contains(selectedPort) {
            selectedPort = ports.first { $0.contains("usb") || $0.contains("wch") || $0.contains("SLAB") } ?? ports.first ?? ""
        }
    }

    func connect(profile: DeviceProfile) {
        guard !isConnected, !selectedPort.isEmpty else { return }
        let p = SerialPort(path: selectedPort)
        p.onData = { [weak self] data in
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.receive(text) }
        }
        p.onClose = { [weak self] in
            Task { @MainActor in self?.handleDisconnect(reason: "The laser was disconnected.") }
        }
        do {
            try p.open(baudRate: profile.baudRate, flowControl: .none)
        } catch {
            append(.error, error.localizedDescription)
            return
        }
        port = p
        streamer = GRBLStreamer(bufferSize: profile.rxBufferSize)
        rxBuffer = ""
        isConnected = true
        status = GRBLStatus(state: "Connecting")
        append(.info, "Opened \(selectedPort) at \(profile.baudRate) baud")
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.realtime(.statusQuery)
                if let start = self.jobStarted, self.isRunning { self.elapsed = Date().timeIntervalSince(start) }
            }
        }
        // Ask for build info so the console shows what we are talking to.
        send("$I")
    }

    func disconnect() {
        handleDisconnect(reason: "Disconnected.")
    }

    private func handleDisconnect(reason: String) {
        guard isConnected else { return }
        statusTimer?.invalidate()
        statusTimer = nil
        port?.close()
        port = nil
        isConnected = false
        isRunning = false
        isPaused = false
        streamer.reset()
        status = GRBLStatus(state: "Disconnected")
        workPosition = nil
        append(.info, reason)
    }

    // MARK: - Receiving

    private func receive(_ text: String) {
        rxBuffer += text
        while let nl = rxBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(rxBuffer[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            rxBuffer.removeSubrange(...nl)
            if !line.isEmpty { handle(line) }
        }
    }

    private func handle(_ line: String) {
        switch GRBLResponse.parse(line) {
        case .ok:
            streamer.acknowledge()
            if !isRunning { append(.received, "ok") }
            pump()
        case .error(let code):
            streamer.acknowledge(errorCode: code)
            append(.error, "error:\(code) \(GRBLResponse.errorText(code))")
            pump()
        case .alarm(let code):
            append(.error, "ALARM:\(code) \(GRBLResponse.alarmText(code))")
            if isRunning {
                isRunning = false
                isPaused = false
                streamer.reset()
                append(.error, "Job stopped by alarm.")
            }
        case .status(let s):
            if let wco = s.workOffset { workOffset = wco }
            if let w = s.workPosition {
                workPosition = w
            } else if let m = s.machinePosition {
                workPosition = m - workOffset
            }
            status = s
        case .welcome(let text):
            append(.received, text)
            streamer.reset()
            isRunning = false
            isPaused = false
        case .message(let text), .other(let text):
            append(.received, text)
        }
        if isRunning {
            let done = streamer.acknowledged - jobFirstAck
            progress = jobLineCount > 0 ? min(1, Double(done) / Double(jobLineCount)) : 1
            if streamer.isIdle {
                isRunning = false
                let secs = Int(Date().timeIntervalSince(jobStarted ?? Date()))
                append(.info, "Job finished in \(secs / 60)m \(secs % 60)s with \(streamer.errors.count) error(s).")
            }
        }
    }

    // MARK: - Sending

    private func pump() {
        guard let port else { return }
        let lines = streamer.takeSendable()
        guard !lines.isEmpty else { return }
        if !isRunning { for l in lines { append(.sent, l) } }
        port.write(lines.joined(separator: "\n") + "\n") { [weak self] error in
            if let error {
                Task { @MainActor in self?.append(.error, error.localizedDescription) }
            }
        }
    }

    func send(_ line: String) {
        guard isConnected else { return }
        streamer.enqueue([line])
        pump()
    }

    func realtime(_ command: GRBLRealtime) {
        port?.write(Data([command.rawValue]))
    }

    func home() { send("$H") }
    func unlock() { send("$X") }
    func setWorkOrigin() { send("G10 L20 P1 X0 Y0") }

    func goToOrigin(feed: Double) {
        send("$J=G90 G21 X0 Y0 F\(Int(feed))")
    }

    func jog(dx: Double, dy: Double, feed: Double) {
        send(String(format: "$J=G91 G21 X%.3f Y%.3f F%d", dx, dy, Int(feed)))
    }

    func cancelJog() { realtime(.jogCancel) }

    func frame(lines: [String]) {
        guard isConnected, !isRunning else { return }
        append(.info, "Framing job outline")
        streamer.enqueue(lines)
        pump()
    }

    func run(lines: [String]) {
        guard isConnected, !isRunning else { return }
        let before = streamer.total
        streamer.enqueue(lines)
        jobLineCount = streamer.total - before
        // Lines already queued before the job are acknowledged first.
        jobFirstAck = streamer.acknowledged + (streamer.pendingCount - jobLineCount) + streamer.inFlightCount
        jobStarted = Date()
        elapsed = 0
        progress = 0
        isRunning = true
        isPaused = false
        append(.info, "Job started: \(jobLineCount) lines")
        pump()
    }

    func pause() {
        realtime(.feedHold)
        isPaused = true
    }

    func resume() {
        realtime(.cycleStart)
        isPaused = false
    }

    /// Stops immediately: feed hold, then a soft reset (which also turns the laser off).
    func stop() {
        realtime(.feedHold)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.realtime(.softReset)
        }
        streamer.reset()
        if isRunning { append(.info, "Job stopped. Re-home or re-check the origin before the next job.") }
        isRunning = false
        isPaused = false
    }

    private func append(_ kind: LogLine.Kind, _ text: String) {
        log.append(LogLine(kind: kind, text: text))
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    func clearLog() { log.removeAll() }
}

/// Thread-safe cancel flag for background sends.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Sends HPGL / GP-GL to a vinyl cutter over USB serial or a raw printer queue.
@MainActor
final class CutterSender: ObservableObject {
    @Published var ports: [String] = []
    @Published var selectedPort = ""
    @Published private(set) var isSending = false
    @Published private(set) var progress = 0.0
    @Published private(set) var message = ""

    private var cancelFlag: CancelFlag?

    init() {
        refreshPorts()
    }

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if !ports.contains(selectedPort) {
            selectedPort = ports.first { $0.contains("usb") || $0.contains("wch") || $0.contains("SLAB") } ?? ports.first ?? ""
        }
    }

    static func printerQueues() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
        p.arguments = ["-e"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return []
        }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func cancel() {
        cancelFlag?.set()
        message = "Stopping…"
    }

    func send(_ text: String, profile: DeviceProfile) {
        guard !isSending else { return }
        let data = Data(text.utf8)
        isSending = true
        progress = 0
        let flag = CancelFlag()
        cancelFlag = flag

        switch profile.output {
        case .printerQueue:
            let queue = profile.printerQueue
            message = "Sending to printer queue \(queue)…"
            Task.detached {
                let result = Self.sendToQueue(data, queue: queue)
                await MainActor.run {
                    self.isSending = false
                    self.progress = result == nil ? 1 : 0
                    self.message = result ?? "Sent to \(queue)."
                }
            }
        case .serial:
            let path = selectedPort
            message = "Sending to \(path)…"
            let baud = profile.baudRate, flow = profile.flowControl
            Task.detached {
                let port = SerialPort(path: path)
                var outcome = "Sent \(data.count) bytes."
                do {
                    try port.open(baudRate: baud, flowControl: flow)
                    var offset = 0
                    while offset < data.count {
                        if flag.isSet {
                            outcome = "Stopped. The cutter may finish commands already in its buffer."
                            break
                        }
                        let end = min(offset + 256, data.count)
                        try port.writeAll(data.subdata(in: offset..<end))
                        port.drainOutput()
                        offset = end
                        let fraction = Double(offset) / Double(data.count)
                        await MainActor.run { self.progress = fraction }
                    }
                    port.close()
                } catch {
                    port.close()
                    outcome = error.localizedDescription
                }
                let finalMessage = outcome
                await MainActor.run {
                    self.isSending = false
                    self.message = finalMessage
                }
            }
        }
    }

    /// Returns an error message, or nil on success.
    nonisolated static func sendToQueue(_ data: Data, queue: String) -> String? {
        guard !queue.isEmpty else { return "Choose a printer queue first." }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kerf-\(UUID().uuidString).plt")
        do {
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
            p.arguments = ["-d", queue, "-o", "raw", tmp.path]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return "lp failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
