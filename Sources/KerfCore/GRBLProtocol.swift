import Foundation

/// A parsed GRBL status report, e.g. `<Idle|MPos:0.000,0.000,0.000|FS:0,0|WCO:0.000,0.000,0.000>`.
public struct GRBLStatus: Equatable, Sendable {
    public var state: String
    public var machinePosition: Vec2?
    public var workPosition: Vec2?
    public var workOffset: Vec2?
    public var feed: Double?
    public var spindle: Double?

    public init(state: String) {
        self.state = state
    }

    public static func parse(_ line: String) -> GRBLStatus? {
        guard line.hasPrefix("<"), line.hasSuffix(">") else { return nil }
        let body = line.dropFirst().dropLast()
        let fields = body.split(separator: "|")
        guard let first = fields.first else { return nil }
        var status = GRBLStatus(state: String(first.split(separator: ":").first ?? first))
        func vec(_ s: Substring) -> Vec2? {
            let n = s.split(separator: ",").compactMap { Double($0) }
            return n.count >= 2 ? Vec2(n[0], n[1]) : nil
        }
        for f in fields.dropFirst() {
            let kv = f.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "MPos": status.machinePosition = vec(kv[1])
            case "WPos": status.workPosition = vec(kv[1])
            case "WCO": status.workOffset = vec(kv[1])
            case "FS", "F":
                let n = kv[1].split(separator: ",").compactMap { Double($0) }
                status.feed = n.first
                status.spindle = n.count > 1 ? n[1] : nil
            default: break
            }
        }
        return status
    }
}

/// GRBL response lines.
public enum GRBLResponse: Equatable, Sendable {
    case ok
    case error(Int)
    case alarm(Int)
    case status(GRBLStatus)
    case welcome(String)
    case message(String)
    case other(String)

    public static func parse(_ raw: String) -> GRBLResponse {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "ok" { return .ok }
        if line.hasPrefix("error:") { return .error(Int(line.dropFirst(6)) ?? -1) }
        if line.hasPrefix("ALARM:") { return .alarm(Int(line.dropFirst(6)) ?? -1) }
        if let s = GRBLStatus.parse(line) { return .status(s) }
        if line.hasPrefix("Grbl ") || line.hasPrefix("GrblHAL") { return .welcome(line) }
        if line.hasPrefix("[") { return .message(line) }
        return .other(line)
    }

    public static func errorText(_ code: Int) -> String {
        switch code {
        case 1: return "G-code word missing a letter"
        case 2: return "Numeric value format is not valid"
        case 3: return "'$' command not recognised"
        case 8: return "Command needs the machine to be idle"
        case 9: return "G-code locked out during alarm or jog; unlock first"
        case 15: return "Jog target exceeds machine travel"
        case 20: return "Unsupported G-code command"
        case 22: return "Feed rate has not been set"
        default: return "GRBL error \(code)"
        }
    }

    public static func alarmText(_ code: Int) -> String {
        switch code {
        case 1: return "Hard limit triggered; re-home the machine"
        case 2: return "Motion target exceeds machine travel"
        case 3: return "Reset while in motion; re-home recommended"
        case 6, 7, 8, 9: return "Homing failed"
        default: return "GRBL alarm \(code)"
        }
    }
}

/// GRBL real-time commands (sent as single bytes, never buffered).
public enum GRBLRealtime: UInt8, Sendable {
    case statusQuery = 0x3F // ?
    case feedHold = 0x21 // !
    case cycleStart = 0x7E // ~
    case softReset = 0x18
    case jogCancel = 0x85
}

/// Character-counting streaming protocol: keeps GRBL's receive buffer as full as
/// possible without overflowing it. Transport-independent so it can be unit-tested.
public struct GRBLStreamer: Sendable {
    public let bufferSize: Int
    private var queue: [String] = []
    private var nextIndex = 0
    private var inFlight: [Int] = []
    public private(set) var acknowledged = 0
    public private(set) var errors: [(line: String, code: Int)] = []
    private var sentLines: [String] = []

    public init(bufferSize: Int = 127) {
        self.bufferSize = bufferSize
    }

    /// Strips comments and whitespace; returns nil for lines with nothing to send.
    public static func clean(_ line: String) -> String? {
        var s = line
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            s.removeSubrange(open...close)
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    public mutating func enqueue(_ lines: [String]) {
        queue.append(contentsOf: lines.compactMap(GRBLStreamer.clean))
    }

    public var total: Int { queue.count }
    public var pendingCount: Int { queue.count - nextIndex }
    public var inFlightCount: Int { inFlight.count }
    public var isIdle: Bool { nextIndex >= queue.count && inFlight.isEmpty }
    public var bufferUsed: Int { inFlight.reduce(0, +) }

    /// Lines that fit in the controller buffer now. They are counted as in flight.
    public mutating func takeSendable() -> [String] {
        var out: [String] = []
        var used = bufferUsed
        while nextIndex < queue.count {
            let line = queue[nextIndex]
            let len = line.utf8.count + 1 // newline
            // An over-long line is still sent once the buffer is empty.
            if used + len > bufferSize && !(inFlight.isEmpty && out.isEmpty) { break }
            out.append(line)
            inFlight.append(len)
            sentLines.append(line)
            used += len
            nextIndex += 1
        }
        return out
    }

    /// Records an `ok` or `error` reply. Returns false if nothing was in flight.
    @discardableResult
    public mutating func acknowledge(errorCode: Int? = nil) -> Bool {
        guard !inFlight.isEmpty else { return false }
        inFlight.removeFirst()
        let line = sentLines.removeFirst()
        acknowledged += 1
        if let code = errorCode { errors.append((line, code)) }
        return true
    }

    /// Drops everything queued and in flight (after a soft reset).
    public mutating func reset() {
        queue.removeAll()
        nextIndex = 0
        inFlight.removeAll()
        sentLines.removeAll()
        acknowledged = 0
        errors.removeAll()
    }
}
