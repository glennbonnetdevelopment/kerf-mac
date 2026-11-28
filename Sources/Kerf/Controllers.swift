import Foundation
import KerfCore

struct LogLine: Identifiable {
    enum Kind { case sent, received, info, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// Talks to a GRBL controller over USB serial, or to an xTool D1 / D1 Pro over Wi-Fi.
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

    // Wi-Fi (xTool D1 / D1 Pro)
    /// Connected over Wi-Fi: no position, jogging or homing, and jobs run from the machine's own copy.
    @Published private(set) var isWiFi = false
    @Published private(set) var wifiFirmware: XToolFirmware?
    /// A job is being uploaded.
    @Published private(set) var isUploading = false
    /// A job was uploaded and waits for the machine's button.
    @Published private(set) var awaitingButton = false
    private var wifi: XToolWiFiClient?
    private var wifiAutoStart = false
    private var wifiPoll: Task<Void, Never>?

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

    /// The laser answers pause, resume and stop over Wi-Fi (firmware 40.30.010.01 and newer).
    var wifiJobControl: Bool { wifiFirmware?.hasJobControl == true }

    func connect(profile: DeviceProfile) {
        if profile.usesWiFi {
            connectWiFi(profile)
            return
        }
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
        if isWiFi {
            wifiPoll?.cancel()
            wifiPoll = nil
            wifi = nil
            isWiFi = false
            wifiFirmware = nil
            isUploading = false
            awaitingButton = false
        }
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
        if isWiFi {
            sendWiFi(line)
            return
        }
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

    func jogZ(_ dz: Double, feed: Double) {
        send(String(format: "$J=G91 G21 Z%.3f F%d", dz, Int(feed)))
    }

    func setWorkZeroZ() { send("G10 L20 P1 Z0") }

    func cancelJog() { realtime(.jogCancel) }

    func frame(lines: [String]) {
        guard isConnected, !isRunning else { return }
        if isWiFi {
            let job = XToolWiFi.frameJob(lines)
            guard !job.isEmpty else { return }
            uploadWiFi(job, label: "Frame", autoStart: false)
            return
        }
        append(.info, "Framing job outline")
        streamer.enqueue(lines)
        pump()
    }

    func run(lines: [String]) {
        guard isConnected, !isRunning else { return }
        if isWiFi {
            uploadWiFi(lines, label: "Job", autoStart: wifiAutoStart)
            return
        }
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
        if isWiFi {
            wifiAction(.pause)
            return
        }
        realtime(.feedHold)
        isPaused = true
    }

    func resume() {
        if isWiFi {
            wifiAction(.resume)
            return
        }
        realtime(.cycleStart)
        isPaused = false
    }

    /// Stops immediately: feed hold, then a soft reset (which also turns the laser off).
    func stop() {
        if isWiFi {
            wifiAction(.stop)
            return
        }
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

    // MARK: - Wi-Fi (xTool D1 / D1 Pro)

    private func connectWiFi(_ profile: DeviceProfile) {
        guard !isConnected else { return }
        guard let base = XToolWiFi.baseURL(host: profile.networkHost, port: profile.networkPort) else {
            append(.error, "Enter the laser's IP address in the device settings (gear button).")
            return
        }
        let client = XToolWiFiClient(base: base)
        wifi = client
        wifiAutoStart = profile.wifiAutoStart
        isWiFi = true
        isConnected = true
        isRunning = false
        isPaused = false
        awaitingButton = false
        workPosition = nil
        status = GRBLStatus(state: "Connecting")
        append(.info, "Connecting to \(base.absoluteString) over Wi-Fi")
        Task { [weak self] in
            do {
                try await client.ping()
            } catch {
                guard let self, self.wifi?.base == base else { return }
                self.append(.error, error.localizedDescription)
                self.append(.info, "Check the IP address, that the laser is on, and that this Mac is on the same network.")
                self.handleDisconnect(reason: "Not connected.")
                return
            }
            let fw = await client.firmware()
            guard let self, self.wifi?.base == base else { return }
            self.wifiFirmware = fw
            self.status = GRBLStatus(state: "Idle")
            self.append(.info, "Connected over Wi-Fi" + (fw.map { ", firmware \($0)" } ?? ""))
            if fw?.hasJobControl != true {
                self.append(.info, "This firmware can't pause or stop over Wi-Fi. Use the laser's button, or update its firmware to 40.30.010.01 or newer.")
            }
            self.startWiFiPolling()
        }
    }

    private func startWiFiPolling() {
        wifiPoll?.cancel()
        wifiPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollWiFi()
                let seconds: UInt64 = self.wifiJobControl ? 1 : 5
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    private func pollWiFi() async {
        guard let client = wifi else { return }
        if let start = jobStarted, isRunning { elapsed = Date().timeIntervalSince(start) }
        do {
            if wifiJobControl {
                let state = try await client.workingState()
                guard wifi?.base == client.base else { return }
                if state.isBusy {
                    if !isRunning {
                        isRunning = true
                        awaitingButton = false
                        jobStarted = Date()
                        elapsed = 0
                        append(.info, "The laser started the job.")
                    }
                    status = GRBLStatus(state: isPaused ? "Hold" : "Run")
                } else {
                    if isRunning {
                        let secs = Int(Date().timeIntervalSince(jobStarted ?? Date()))
                        append(.info, "Job finished in \(secs / 60)m \(secs % 60)s.")
                    }
                    isRunning = false
                    isPaused = false
                    status = GRBLStatus(state: awaitingButton ? "Ready" : "Idle")
                }
            } else {
                try await client.ping()
                guard wifi?.base == client.base else { return }
                status = GRBLStatus(state: awaitingButton ? "Ready" : "Idle")
            }
        } catch {
            guard wifi?.base == client.base else { return }
            if status.state != "No answer" { append(.error, error.localizedDescription) }
            status = GRBLStatus(state: "No answer")
        }
    }

    /// Uploads a job or frame. The machine keeps one stored job, so an upload replaces the last one.
    private func uploadWiFi(_ lines: [String], label: String, autoStart: Bool) {
        guard let client = wifi, !isUploading else { return }
        isUploading = true
        let text = XToolWiFi.jobFile(lines)
        let checkBusy = wifiJobControl
        Task { [weak self] in
            defer { self?.isUploading = false }
            do {
                // An upload replaces the stored job, which cancels one that is running or paused.
                if checkBusy, try await client.workingState().isBusy {
                    self?.append(.error, "The laser is running or has paused a job. Stop it first. Nothing was uploaded.")
                    return
                }
                self?.append(.info, "Uploading \(label.lowercased()) (\(lines.count) lines)…")
                try await client.upload(text)
                // The button only starts a stored job once the laser has had $I (it forgets after a button stop).
                try? await client.command("$I")
                guard let self else { return }
                if autoStart {
                    try await client.start()
                    self.awaitingButton = false
                    self.jobStarted = Date()
                    self.elapsed = 0
                    self.append(.info, "\(label) uploaded and started.")
                } else {
                    self.awaitingButton = true
                    self.status = GRBLStatus(state: "Ready")
                    self.append(.info, "\(label) uploaded. Press the button on the laser to start it.")
                }
            } catch {
                self?.append(.error, error.localizedDescription)
            }
        }
    }

    private func wifiAction(_ action: XToolWiFi.JobAction) {
        guard let client = wifi else { return }
        guard wifiJobControl else {
            switch action {
            case .stop: append(.error, "This laser's firmware can't stop over Wi-Fi. Press its button, or switch it off.")
            default: append(.error, "This laser's firmware can't pause over Wi-Fi. Press its button.")
            }
            return
        }
        Task { [weak self] in
            do {
                let ok = try await client.action(action)
                guard let self else { return }
                switch action {
                case .pause:
                    if ok { self.isPaused = true; self.status = GRBLStatus(state: "Hold") }
                case .resume:
                    if ok { self.isPaused = false; self.status = GRBLStatus(state: "Run") }
                case .stop:
                    // What the laser does with its beam after a stop isn't documented, so switch it off too.
                    try? await client.command("M5")
                    self.isPaused = false
                    self.awaitingButton = false
                    if ok {
                        self.isRunning = false
                        self.append(.info, "Stop sent. The laser now treats the head's position as X0 Y0, so put the head where the next job should start.")
                    }
                }
                if !ok { self.append(.error, "The laser refused \(action.rawValue).") }
            } catch {
                self?.append(.error, error.localizedDescription)
            }
        }
    }

    private func sendWiFi(_ line: String) {
        guard let client = wifi else { return }
        // Console lines join the laser's job queue, so they'd run inside a running or paused job.
        guard !isRunning else {
            append(.error, "Not sent: the laser is running a job.")
            return
        }
        append(.sent, line)
        Task { [weak self] in
            do {
                try await client.command(line)
                self?.append(.received, "ok")
            } catch {
                self?.append(.error, error.localizedDescription)
            }
        }
    }
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
    /// A head move asked for while something was still sending; only the latest is kept.
    private var pendingMove: (text: String, profile: DeviceProfile)?

    init() {
        refreshPorts()
    }

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if !ports.contains(selectedPort) {
            selectedPort = ports.first { $0.contains("usb") || $0.contains("wch") || $0.contains("SLAB") } ?? ports.first ?? ""
        }
    }

    /// Sends a short command such as a head move. Moves are absolute, so while a send is still going only the
    /// newest is kept and goes when it finishes; quick clicks on the jog arrows end at the right place.
    func sendMove(_ text: String, profile: DeviceProfile) {
        if isSending {
            pendingMove = (text, profile)
        } else {
            send(text, profile: profile)
        }
    }

    private func sendPendingMove() {
        guard let next = pendingMove else { return }
        pendingMove = nil
        send(next.text, profile: next.profile)
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
        pendingMove = nil
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
                    self.sendPendingMove()
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
                    self.sendPendingMove()
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
