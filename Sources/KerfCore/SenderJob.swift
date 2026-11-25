import Foundation

/// A finished job for the KerfSender apps (Windows 7/10 and macOS 10.12+), which only stream
/// files to a machine and cannot edit them.
///
/// The file is UTF-8 JSON with the `.kerfjob` extension. `data` holds the exact text to send:
/// G-code for GRBL lasers and CNC routers, HPGL or GP-GL for vinyl cutters. The `machine`
/// block carries the connection settings so the sender can pre-fill them. Senders must
/// ignore keys they do not know, and refuse a `version` newer than they understand.
public struct SenderJob: Codable, Equatable, Sendable {
    public static let fileExtension = "kerfjob"
    public static let currentVersion = 1

    public struct Machine: Codable, Equatable, Sendable {
        public var name: String
        /// "grblLaser", "cncRouter" or "vinylCutter".
        public var kind: String
        public var baudRate: Int
        /// "none", "hardware" (RTS/CTS) or "software" (XON/XOFF).
        public var flowControl: String
        /// GRBL receive buffer size in bytes (GRBL machines only).
        public var rxBufferSize: Int
        /// "serial" or "printerQueue" (vinyl cutters may print raw to a queue).
        public var output: String
        /// "gcode", "hpgl" or "gpgl".
        public var language: String
        /// Work area in mm, for display.
        public var bedWidth: Double
        public var bedHeight: Double
    }

    public var format = "kerfjob"
    public var version = SenderJob.currentVersion
    public var name: String
    /// ISO 8601 time the job was exported.
    public var created: String
    public var generator: String
    public var machine: Machine
    public var estimatedSeconds: Int
    /// Number of lines (G-code) or bytes (plotter) in `data`, for progress display.
    public var lineCount: Int
    public var data: String

    public init(name: String, created: Date = Date(), generator: String = "KerfKutter",
                profile: DeviceProfile, estimatedSeconds: Double, data: String) {
        self.name = name
        let f = ISO8601DateFormatter()
        self.created = f.string(from: created)
        self.generator = generator
        let language: String
        if profile.kind.usesGRBL {
            language = "gcode"
        } else {
            language = profile.language == .gpgl ? "gpgl" : "hpgl"
        }
        self.machine = Machine(name: profile.name, kind: profile.kind.rawValue, baudRate: profile.baudRate,
                               flowControl: profile.flowControl.rawValue, rxBufferSize: profile.rxBufferSize,
                               output: profile.kind.usesGRBL ? "serial" : profile.output.rawValue,
                               language: language, bedWidth: profile.bedWidth, bedHeight: profile.bedHeight)
        self.estimatedSeconds = Int(estimatedSeconds.rounded())
        self.lineCount = profile.kind.usesGRBL
            ? data.split(separator: "\n").filter { GRBLStreamer.clean(String($0)) != nil }.count
            : data.utf8.count
        self.data = data
    }

    /// Whether a sender can drive this profile (SVG-only cutters have no live connection).
    public static func supports(_ profile: DeviceProfile) -> Bool {
        profile.kind.usesGRBL || profile.language != .svgFile
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> SenderJob {
        try JSONDecoder().decode(SenderJob.self, from: data)
    }
}
