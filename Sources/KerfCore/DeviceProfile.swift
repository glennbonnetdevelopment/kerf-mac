import Foundation

public enum DeviceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case grblLaser
    case vinylCutter

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .grblLaser: return "GRBL laser"
        case .vinylCutter: return "Vinyl cutter"
        }
    }
}

/// Where the machine's (0, 0) sits on the bed, as seen from above.
public enum OriginCorner: String, Codable, CaseIterable, Sendable, Identifiable {
    case bottomLeft, topLeft, topRight, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bottomLeft: return "Front left"
        case .topLeft: return "Rear left"
        case .topRight: return "Rear right"
        case .bottomRight: return "Front right"
        }
    }
}

public enum CutterLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case hpgl, gpgl
    /// No live connection: export an SVG cut file (e.g. for Brother ScanNCut via USB stick or CanvasWorkspace).
    case svgFile
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .hpgl: return "HPGL"
        case .gpgl: return "GP-GL"
        case .svgFile: return "SVG file only"
        }
    }
    public var fileExtension: String { self == .svgFile ? "svg" : "plt" }
}

public enum CutterOutput: String, Codable, CaseIterable, Sendable, Identifiable {
    case serial, printerQueue
    public var id: String { rawValue }
    public var title: String { self == .serial ? "USB serial port" : "Printer queue (raw)" }
}

public enum FlowControl: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, hardware, software
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None"
        case .hardware: return "RTS/CTS"
        case .software: return "XON/XOFF"
        }
    }
}

/// A machine the app can drive.
public struct DeviceProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: DeviceKind
    /// Work area in mm.
    public var bedWidth: Double
    public var bedHeight: Double
    public var origin: OriginCorner
    /// Swap X and Y when sending (some cutters feed along X).
    public var swapAxes: Bool
    public var baudRate: Int
    public var flowControl: FlowControl

    // GRBL laser
    /// GRBL $30 (maximum spindle / laser S value).
    public var sMax: Double
    /// Rapid travel speed used for time estimates and framing, mm/min.
    public var rapidSpeed: Double
    /// GRBL serial receive buffer size in bytes.
    public var rxBufferSize: Int

    // Vinyl cutter
    public var language: CutterLanguage
    /// Plotter units per mm (HPGL is usually 40; GP-GL 10 or 20).
    public var unitsPerMM: Double
    /// Drag-knife blade offset in mm (0 disables compensation).
    public var bladeOffset: Double
    /// Extra cut past the start of closed shapes, mm.
    public var overcut: Double
    public var output: CutterOutput
    /// CUPS queue name when output is a printer queue.
    public var printerQueue: String
    /// Send per-layer speed and force commands.
    public var sendSpeedAndForce: Bool

    public init(id: UUID = UUID(), name: String, kind: DeviceKind, bedWidth: Double, bedHeight: Double,
                origin: OriginCorner, swapAxes: Bool = false, baudRate: Int, flowControl: FlowControl = .none,
                sMax: Double = 1000, rapidSpeed: Double = 3000, rxBufferSize: Int = 127,
                language: CutterLanguage = .hpgl, unitsPerMM: Double = 40, bladeOffset: Double = 0.25,
                overcut: Double = 1, output: CutterOutput = .serial, printerQueue: String = "",
                sendSpeedAndForce: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bedWidth = bedWidth
        self.bedHeight = bedHeight
        self.origin = origin
        self.swapAxes = swapAxes
        self.baudRate = baudRate
        self.flowControl = flowControl
        self.sMax = sMax
        self.rapidSpeed = rapidSpeed
        self.rxBufferSize = rxBufferSize
        self.language = language
        self.unitsPerMM = unitsPerMM
        self.bladeOffset = bladeOffset
        self.overcut = overcut
        self.output = output
        self.printerQueue = printerQueue
        self.sendSpeedAndForce = sendSpeedAndForce
    }

    public static let defaultLaser = DeviceProfile(name: "GRBL laser 400×400", kind: .grblLaser,
                                                   bedWidth: 400, bedHeight: 400, origin: .bottomLeft, baudRate: 115200)

    public static let defaultCutter = DeviceProfile(name: "Vinyl cutter 600 mm", kind: .vinylCutter,
                                                    bedWidth: 600, bedHeight: 1000, origin: .bottomLeft,
                                                    baudRate: 9600, flowControl: .software,
                                                    language: .hpgl, unitsPerMM: 40)

    /// Starting points for common machines. Bed sizes and origins should be checked against the machine.
    public static let presets: [DeviceProfile] = [
        DeviceProfile(name: "xTool D1 Pro", kind: .grblLaser, bedWidth: 432, bedHeight: 406,
                      origin: .topLeft, baudRate: 115200),
        DeviceProfile(name: "xTool D1 Pro + extension kit", kind: .grblLaser, bedWidth: 432, bedHeight: 940,
                      origin: .topLeft, baudRate: 115200),
        DeviceProfile(name: "Generic GRBL laser", kind: .grblLaser, bedWidth: 400, bedHeight: 400,
                      origin: .bottomLeft, baudRate: 115200),
        DeviceProfile(name: "GCC Expert 24", kind: .vinylCutter, bedWidth: 600, bedHeight: 1000,
                      origin: .bottomRight, baudRate: 9600, flowControl: .hardware,
                      language: .hpgl, unitsPerMM: 40, bladeOffset: 0.25, output: .printerQueue),
        DeviceProfile(name: "Redsail cutter (RS series)", kind: .vinylCutter, bedWidth: 630, bedHeight: 1000,
                      origin: .bottomRight, baudRate: 9600, flowControl: .software,
                      language: .hpgl, unitsPerMM: 40, bladeOffset: 0.25),
        DeviceProfile(name: "EasyCut-class cutter (USB serial)", kind: .vinylCutter, bedWidth: 720, bedHeight: 1000,
                      origin: .bottomRight, baudRate: 9600, flowControl: .software,
                      language: .hpgl, unitsPerMM: 40, bladeOffset: 0.25),
        DeviceProfile(name: "Janome Artistic Edge 15 (experimental)", kind: .vinylCutter, bedWidth: 381, bedHeight: 610,
                      origin: .topLeft, baudRate: 9600, flowControl: .none,
                      language: .hpgl, unitsPerMM: 40, bladeOffset: 0.25),
        DeviceProfile(name: "Brother ScanNCut 12×12 mat (SVG export)", kind: .vinylCutter, bedWidth: 296, bedHeight: 296,
                      origin: .topLeft, baudRate: 9600, language: .svgFile, unitsPerMM: 1, bladeOffset: 0, overcut: 0,
                      sendSpeedAndForce: false),
        DeviceProfile(name: "Brother ScanNCut 12×24 mat (SVG export)", kind: .vinylCutter, bedWidth: 296, bedHeight: 600,
                      origin: .topLeft, baudRate: 9600, language: .svgFile, unitsPerMM: 1, bladeOffset: 0, overcut: 0,
                      sendSpeedAndForce: false),
    ]

    /// Converts a point from design space (mm, origin top-left, y down) to machine coordinates.
    public func toMachine(_ p: Vec2) -> Vec2 {
        var q: Vec2
        switch origin {
        case .topLeft: q = p
        case .bottomLeft: q = Vec2(p.x, bedHeight - p.y)
        case .topRight: q = Vec2(bedWidth - p.x, p.y)
        case .bottomRight: q = Vec2(bedWidth - p.x, bedHeight - p.y)
        }
        if swapAxes { q = Vec2(q.y, q.x) }
        return q
    }

    /// Inverse of `toMachine`.
    public func fromMachine(_ m: Vec2) -> Vec2 {
        let q = swapAxes ? Vec2(m.y, m.x) : m
        switch origin {
        case .topLeft: return q
        case .bottomLeft: return Vec2(q.x, bedHeight - q.y)
        case .topRight: return Vec2(bedWidth - q.x, q.y)
        case .bottomRight: return Vec2(bedWidth - q.x, bedHeight - q.y)
        }
    }
}
