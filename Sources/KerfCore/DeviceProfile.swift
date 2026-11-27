import Foundation

public enum DeviceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case grblLaser
    case vinylCutter
    case cncRouter

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .grblLaser: return "GRBL laser"
        case .vinylCutter: return "Vinyl cutter"
        case .cncRouter: return "GRBL CNC router"
        }
    }

    /// GRBL lasers and CNC routers share the same controller protocol.
    public var usesGRBL: Bool { self != .vinylCutter }

    /// The layer mode new artwork gets on this kind of machine.
    public var defaultMode: LayerMode {
        switch self {
        case .grblLaser: return .line
        case .vinylCutter: return .cut
        case .cncRouter: return .mill
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

public enum RotaryType: String, Codable, CaseIterable, Sendable, Identifiable {
    case roller, chuck
    public var id: String { rawValue }
    public var title: String { self == .roller ? "Roller" : "Chuck" }
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

    // CNC router
    /// Clearance height for rapid moves, mm above the work zero.
    public var safeZ: Double

    // Rotary attachment on the Y axis
    public var rotaryEnabled: Bool
    public var rotaryType: RotaryType
    /// Y travel (as configured in the controller) that turns the rotary motor one full revolution, mm.
    public var rotaryMMPerRotation: Double
    /// Diameter of the roller wheel that drives the object (roller type), mm.
    public var rotaryRollerDiameter: Double
    /// Diameter of the object being engraved (chuck type), mm.
    public var rotaryObjectDiameter: Double

    public init(id: UUID = UUID(), name: String, kind: DeviceKind, bedWidth: Double, bedHeight: Double,
                origin: OriginCorner, swapAxes: Bool = false, baudRate: Int, flowControl: FlowControl = .none,
                sMax: Double = 1000, rapidSpeed: Double = 3000, rxBufferSize: Int = 127,
                language: CutterLanguage = .hpgl, unitsPerMM: Double = 40, bladeOffset: Double = 0.25,
                overcut: Double = 1, output: CutterOutput = .serial, printerQueue: String = "",
                sendSpeedAndForce: Bool = true, safeZ: Double = 5,
                rotaryEnabled: Bool = false, rotaryType: RotaryType = .roller, rotaryMMPerRotation: Double = 360,
                rotaryRollerDiameter: Double = 25, rotaryObjectDiameter: Double = 80) {
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
        self.safeZ = safeZ
        self.rotaryEnabled = rotaryEnabled
        self.rotaryType = rotaryType
        self.rotaryMMPerRotation = rotaryMMPerRotation
        self.rotaryRollerDiameter = rotaryRollerDiameter
        self.rotaryObjectDiameter = rotaryObjectDiameter
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, bedWidth, bedHeight, origin, swapAxes, baudRate, flowControl, sMax, rapidSpeed,
             rxBufferSize, language, unitsPerMM, bladeOffset, overcut, output, printerQueue, sendSpeedAndForce, safeZ,
             rotaryEnabled, rotaryType, rotaryMMPerRotation, rotaryRollerDiameter, rotaryObjectDiameter
    }

    /// Missing keys fall back to defaults so saved profiles survive upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  kind: try c.decode(DeviceKind.self, forKey: .kind),
                  bedWidth: try c.decode(Double.self, forKey: .bedWidth),
                  bedHeight: try c.decode(Double.self, forKey: .bedHeight),
                  origin: try c.decode(OriginCorner.self, forKey: .origin),
                  swapAxes: try c.decodeIfPresent(Bool.self, forKey: .swapAxes) ?? false,
                  baudRate: try c.decode(Int.self, forKey: .baudRate),
                  flowControl: try c.decodeIfPresent(FlowControl.self, forKey: .flowControl) ?? .none,
                  sMax: try c.decodeIfPresent(Double.self, forKey: .sMax) ?? 1000,
                  rapidSpeed: try c.decodeIfPresent(Double.self, forKey: .rapidSpeed) ?? 3000,
                  rxBufferSize: try c.decodeIfPresent(Int.self, forKey: .rxBufferSize) ?? 127,
                  language: try c.decodeIfPresent(CutterLanguage.self, forKey: .language) ?? .hpgl,
                  unitsPerMM: try c.decodeIfPresent(Double.self, forKey: .unitsPerMM) ?? 40,
                  bladeOffset: try c.decodeIfPresent(Double.self, forKey: .bladeOffset) ?? 0.25,
                  overcut: try c.decodeIfPresent(Double.self, forKey: .overcut) ?? 1,
                  output: try c.decodeIfPresent(CutterOutput.self, forKey: .output) ?? .serial,
                  printerQueue: try c.decodeIfPresent(String.self, forKey: .printerQueue) ?? "",
                  sendSpeedAndForce: try c.decodeIfPresent(Bool.self, forKey: .sendSpeedAndForce) ?? true,
                  safeZ: try c.decodeIfPresent(Double.self, forKey: .safeZ) ?? 5,
                  rotaryEnabled: try c.decodeIfPresent(Bool.self, forKey: .rotaryEnabled) ?? false,
                  rotaryType: try c.decodeIfPresent(RotaryType.self, forKey: .rotaryType) ?? .roller,
                  rotaryMMPerRotation: try c.decodeIfPresent(Double.self, forKey: .rotaryMMPerRotation) ?? 360,
                  rotaryRollerDiameter: try c.decodeIfPresent(Double.self, forKey: .rotaryRollerDiameter) ?? 25,
                  rotaryObjectDiameter: try c.decodeIfPresent(Double.self, forKey: .rotaryObjectDiameter) ?? 80)
    }

    /// The blade offset to use for a layer: the layer's own when it has one, else the machine's.
    /// A machine set to 0 (no compensation, or one that compensates itself) stays at 0.
    public func bladeOffset(for layer: Layer) -> Double {
        guard bladeOffset > 0 else { return 0 }
        return max(0, layer.bladeOffset ?? bladeOffset)
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
        // Creality Falcon2: 400×415 mm work area, GRBL over USB serial. Check which corner yours homes to.
        DeviceProfile(name: "Creality Falcon2 12 W", kind: .grblLaser, bedWidth: 400, bedHeight: 415,
                      origin: .bottomLeft, baudRate: 115200, sMax: 1000, rapidSpeed: 6000),
        DeviceProfile(name: "Creality Falcon2 40 W", kind: .grblLaser, bedWidth: 400, bedHeight: 415,
                      origin: .bottomLeft, baudRate: 115200, sMax: 1000, rapidSpeed: 6000),
        // K40-style 40 W CO2 laser converted to a GRBL controller. Most home at the back left.
        DeviceProfile(name: "40 W CO2 laser (GRBL, K40-style 300×200)", kind: .grblLaser, bedWidth: 300, bedHeight: 200,
                      origin: .topLeft, baudRate: 115200, sMax: 1000, rapidSpeed: 6000),
        DeviceProfile(name: "SainSmart Genmitsu 4040 Pro (CNC)", kind: .cncRouter, bedWidth: 400, bedHeight: 400,
                      origin: .bottomLeft, baudRate: 115200, sMax: 1000, rapidSpeed: 2500, safeZ: 5),
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

    /// Machine Y units per mm of surface travel on the rotary (1 when the rotary is off).
    public var rotaryYScale: Double {
        guard rotaryEnabled, kind.usesGRBL else { return 1 }
        let d = rotaryType == .roller ? rotaryRollerDiameter : rotaryObjectDiameter
        guard d > 0, rotaryMMPerRotation > 0 else { return 1 }
        return rotaryMMPerRotation / (Double.pi * d)
    }

    /// The design height that wraps once around the object (chuck) — useful as the work area height.
    public var rotaryCircumference: Double { Double.pi * rotaryObjectDiameter }

    /// Converts a point from design space (mm, origin top-left, y down) to machine coordinates.
    public func toMachine(_ p: Vec2) -> Vec2 {
        let m = toMachineFlat(p)
        let k = rotaryYScale
        return k == 1 ? m : Vec2(m.x, m.y * k)
    }

    private func toMachineFlat(_ p: Vec2) -> Vec2 {
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
    public func fromMachine(_ machine: Vec2) -> Vec2 {
        let k = rotaryYScale
        let m = k == 1 ? machine : Vec2(machine.x, machine.y / k)
        let q = swapAxes ? Vec2(m.y, m.x) : m
        switch origin {
        case .topLeft: return q
        case .bottomLeft: return Vec2(q.x, bedHeight - q.y)
        case .topRight: return Vec2(bedWidth - q.x, q.y)
        case .bottomRight: return Vec2(bedWidth - q.x, bedHeight - q.y)
        }
    }
}
