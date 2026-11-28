import Foundation

/// How the app reaches a GRBL laser.
public enum LaserLink: String, Codable, CaseIterable, Sendable, Identifiable {
    /// GRBL streamed line by line over a USB serial port.
    case usbSerial
    /// xTool D1 / D1 Pro over Wi-Fi: the job is uploaded to the machine, which runs it itself.
    case xToolWiFi

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .usbSerial: return "USB serial"
        case .xToolWiFi: return "xTool Wi-Fi (D1 / D1 Pro)"
        }
    }
}

/// An xTool D1 firmware version, such as `40.30.010.01 B2`.
public struct XToolFirmware: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var parts: [Int]
    public var tag: String

    public init(_ a: Int, _ b: Int, _ c: Int, _ d: Int, tag: String = "") {
        parts = [a, b, c, d]
        self.tag = tag
    }

    /// The first `a.b.c.d [Bn]` version in `text`, or nil.
    public static func parse(_ text: String) -> XToolFirmware? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)\.(\d+)(?:\s*([Bb]\d+))?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        let n = (1...4).compactMap { group($0).flatMap(Int.init) }
        guard n.count == 4 else { return nil }
        return XToolFirmware(n[0], n[1], n[2], n[3], tag: group(5)?.uppercased() ?? "")
    }

    public static func < (a: XToolFirmware, b: XToolFirmware) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public static func == (a: XToolFirmware, b: XToolFirmware) -> Bool { a.parts == b.parts }
    public func hash(into h: inout Hasher) { h.combine(parts) }

    public var description: String {
        let text = String(format: "%d.%d.%03d.%02d", parts[0], parts[1], parts[2], parts[3])
        return tag.isEmpty ? text : "\(text) \(tag)"
    }

    /// First firmware known to answer pause / resume / stop and job status over Wi-Fi.
    public static let jobControlSince = XToolFirmware(40, 30, 10, 1)

    public var hasJobControl: Bool { self >= Self.jobControlSince }
}

/// What the D1 says it is doing (`GET /system?action=get_working_sta`).
public enum XToolWorkingState: Equatable, Sendable {
    case idle
    /// Running a job started over Wi-Fi.
    case runningFromApp
    /// Running (or paused in) a job started with the machine's button.
    case runningFromButton
    case other(Int)

    public init(code: Int) {
        switch code {
        case 0: self = .idle
        case 1: self = .runningFromApp
        case 2: self = .runningFromButton
        default: self = .other(code)
        }
    }

    public var isBusy: Bool { self != .idle }
}

/// The xTool D1 / D1 Pro Wi-Fi API.
///
/// xTool doesn't document it. This follows what the community has worked out (rayforge-xtool-d1,
/// xTool-Connect, ha-xtool): an HTTP server on port 8080 that stores one G-code file and runs it
/// with the machine's own streamer.
///
/// - `GET /ping` answers `{"result":"ok"}`.
/// - `GET /system?action=version` answers `{"sn":"…","version":"V40.30.010.01 B2"}`.
/// - `POST /cnc/data?filetype=1` with a multipart `file` field replaces the stored job (`/tmp.gcode`).
/// - The stored job is started with the machine's button. `GET /read?file=/tmp.gcode` has been seen to
///   start it from software, but nobody documents it, so it is opt-in.
/// - `GET /cmd?cmd=<line>` runs one G-code line. Replies never carry GRBL text, only ok or fail.
/// - Firmware 40.30.010.01 and newer: `GET /cnc/data?action=pause|resume|stop` and
///   `GET /system?action=get_working_sta` (`{"working":"0"}`: 0 idle, 1 started over Wi-Fi, 2 started with the button).
///
/// The machine reports no position over Wi-Fi, and can't jog or home there.
public enum XToolWiFi {
    public static let defaultPort = 8080
    /// Where the machine keeps the uploaded job.
    public static let storedFile = "/tmp.gcode"

    /// `http://host:port`, accepting a bare IP, `host:port`, or a pasted URL.
    public static func baseURL(host: String, port: Int) -> URL? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard var c = URLComponents(string: text), let h = c.host, !h.isEmpty else { return nil }
        c.scheme = "http"
        if c.port == nil { c.port = port }
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    public static func pingURL(_ base: URL) -> URL { url(base, "/ping") }
    public static func versionURL(_ base: URL) -> URL { url(base, "/system", [("action", "version")]) }
    public static func workingStateURL(_ base: URL) -> URL { url(base, "/system", [("action", "get_working_sta")]) }
    public static func uploadURL(_ base: URL) -> URL { url(base, "/cnc/data", [("filetype", "1")]) }
    public static func startURL(_ base: URL) -> URL { url(base, "/read", [("file", storedFile)]) }

    public enum JobAction: String, Sendable { case pause, resume, stop }
    public static func actionURL(_ base: URL, _ action: JobAction) -> URL {
        url(base, "/cnc/data", [("action", action.rawValue)])
    }

    /// One G-code line, with everything after `;` dropped.
    public static func commandURL(_ base: URL, line: String) -> URL? {
        let code = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !code.isEmpty else { return nil }
        return url(base, "/cmd", [("cmd", code)])
    }

    private static func url(_ base: URL, _ path: String, _ query: [(String, String)] = []) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = path
        if !query.isEmpty {
            // Encode everything outside the unreserved set so G-code like "G0 X1+2" or "$I" survives.
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
            c.percentEncodedQuery = query.map { k, v in
                "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
            }.joined(separator: "&")
        }
        return c.url!
    }

    /// True when the reply is the machine's `{"result":"ok"}`.
    public static func isOK(_ reply: String) -> Bool {
        guard let json = object(reply) else { return reply.contains("\"ok\"") }
        return (json["result"] as? String)?.lowercased() == "ok"
    }

    /// The firmware from a `/system?action=version` reply.
    public static func firmware(fromVersionReply reply: String) -> XToolFirmware? {
        if let json = object(reply), let v = json["version"] as? String { return XToolFirmware.parse(v) }
        return XToolFirmware.parse(reply)
    }

    /// The state from a `get_working_sta` reply (the number may come as a string or a number).
    public static func workingState(_ reply: String) -> XToolWorkingState? {
        guard let json = object(reply), let w = json["working"] else { return nil }
        if let n = w as? Int { return XToolWorkingState(code: n) }
        if let s = w as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { return XToolWorkingState(code: n) }
        if let d = w as? Double { return XToolWorkingState(code: Int(d)) }
        return nil
    }

    private static func object(_ reply: String) -> [String: Any]? {
        guard let data = reply.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return any as? [String: Any]
    }

    /// The job file to upload. The D1 needs its steppers switched on (`M17 S1`) at the start of a stored
    /// job; it switches them off by itself when the job ends.
    public static func jobFile(_ lines: [String]) -> String {
        var out = lines
        let hasEnable = lines.contains { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("M17") }
        if !hasEnable {
            let at = out.firstIndex { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(";") } ?? out.count
            out.insert("M17 S1", at: at)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A framing job built from the app's frame jog lines (`$J=G90 G21 X… Y… F…`): the same corners as
    /// laser-off moves, with the D1's crosshair light (`M106`) on while it traces them.
    public static func frameJob(_ jogLines: [String]) -> [String] {
        let moves: [String] = jogLines.compactMap { line in
            var code = line.trimmingCharacters(in: .whitespaces)
            if code.uppercased().hasPrefix("$J=") { code.removeFirst(3) }
            let words = code.split(separator: " ").filter { w in
                let u = w.uppercased()
                return u.hasPrefix("X") || u.hasPrefix("Y") || u.hasPrefix("F")
            }
            guard words.contains(where: { $0.uppercased().hasPrefix("X") || $0.uppercased().hasPrefix("Y") }) else { return nil }
            return "G0 " + words.joined(separator: " ")
        }
        guard !moves.isEmpty else { return [] }
        return ["; Kerf frame", "G90", "G21", "M5", "M106 S1"] + moves + ["M106 S0"]
    }

    /// A multipart/form-data body carrying `text` as the `file` field.
    public static func multipartBody(_ text: String, boundary: String, filename: String = "kerf.gcode") -> Data {
        var d = Data()
        d.append("--\(boundary)\r\n".data(using: .utf8)!)
        d.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        d.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        d.append(text.data(using: .utf8)!)
        d.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return d
    }
}
