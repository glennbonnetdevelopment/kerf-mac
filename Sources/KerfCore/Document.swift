import Foundation

/// How a layer's shapes are processed.
public enum LayerMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Laser follows the outline (cutting or scoring).
    case line
    /// Laser engraves the inside of closed shapes with a scanline fill.
    case fill
    /// Laser engraves photos and bitmaps line by line.
    case image
    /// Vinyl cutter knife follows the outline.
    case cut
    /// CNC router mills along the outline to a depth.
    case mill
    /// Printed only (registration marks, print artwork); never sent to a machine.
    case print

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .line: return "Line"
        case .fill: return "Fill"
        case .image: return "Image"
        case .cut: return "Cut (vinyl)"
        case .mill: return "Mill (CNC)"
        case .print: return "Print only"
        }
    }
}

public enum DitherMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case threshold, floydSteinberg, atkinson, grayscale
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .threshold: return "Threshold"
        case .floydSteinberg: return "Floyd–Steinberg"
        case .atkinson: return "Atkinson"
        case .grayscale: return "Grayscale (variable power)"
        }
    }
}

public enum MillOffset: String, Codable, CaseIterable, Sendable, Identifiable {
    case onLine, outside, inside
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .onLine: return "On the line"
        case .outside: return "Outside"
        case .inside: return "Inside"
        }
    }
}

/// A colour-coded group of shapes sharing machine settings.
public struct Layer: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Colour as "#RRGGBB".
    public var colorHex: String
    public var mode: LayerMode
    public var enabled: Bool
    public var passes: Int

    // Laser settings
    /// Feed rate in mm/min (laser and CNC).
    public var speed: Double
    /// Laser power, 0–100 %.
    public var power: Double
    /// Lowest power for grayscale images, 0–100 %.
    public var powerMin: Double
    public var airAssist: Bool
    /// Fill / image line spacing in mm.
    public var fillInterval: Double
    /// Fill line angle in degrees.
    public var fillAngle: Double
    /// Engrave fill and image lines in both directions.
    public var fillBidirectional: Bool
    public var dither: DitherMode
    public var invertImage: Bool
    /// Extra travel past each image line so the head is at speed when it fires, mm.
    public var overscan: Double

    // Vinyl cutter settings
    /// Cutting speed in cm/s.
    public var cutSpeed: Int
    /// Knife force in grams (sent where the cutter supports it).
    public var cutForce: Int

    // CNC settings
    /// Final cut depth in mm.
    public var cutDepth: Double
    /// Depth per pass in mm.
    public var stepDown: Double
    public var toolDiameter: Double
    public var millOffset: MillOffset
    /// Plunge feed in mm/min.
    public var plungeRate: Double
    /// Spindle S value.
    public var spindleSpeed: Double

    public init(id: UUID = UUID(), name: String, colorHex: String, mode: LayerMode = .line,
                enabled: Bool = true, passes: Int = 1, speed: Double = 1000, power: Double = 50,
                powerMin: Double = 0, airAssist: Bool = false, fillInterval: Double = 0.1, fillAngle: Double = 0,
                fillBidirectional: Bool = true, dither: DitherMode = .floydSteinberg, invertImage: Bool = false,
                overscan: Double = 2.5, cutSpeed: Int = 20, cutForce: Int = 80, cutDepth: Double = 3,
                stepDown: Double = 1, toolDiameter: Double = 3.175, millOffset: MillOffset = .onLine,
                plungeRate: Double = 300, spindleSpeed: Double = 1000) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.mode = mode
        self.enabled = enabled
        self.passes = passes
        self.speed = speed
        self.power = power
        self.powerMin = powerMin
        self.airAssist = airAssist
        self.fillInterval = fillInterval
        self.fillAngle = fillAngle
        self.fillBidirectional = fillBidirectional
        self.dither = dither
        self.invertImage = invertImage
        self.overscan = overscan
        self.cutSpeed = cutSpeed
        self.cutForce = cutForce
        self.cutDepth = cutDepth
        self.stepDown = stepDown
        self.toolDiameter = toolDiameter
        self.millOffset = millOffset
        self.plungeRate = plungeRate
        self.spindleSpeed = spindleSpeed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, mode, enabled, passes, speed, power, powerMin, airAssist, fillInterval, fillAngle,
             fillBidirectional, dither, invertImage, overscan, cutSpeed, cutForce, cutDepth, stepDown, toolDiameter,
             millOffset, plungeRate, spindleSpeed
    }

    /// Missing keys fall back to defaults so older project files still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Layer(name: "", colorHex: "#000000")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#000000"
        mode = try c.decodeIfPresent(LayerMode.self, forKey: .mode) ?? .line
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 1
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        power = try c.decodeIfPresent(Double.self, forKey: .power) ?? d.power
        powerMin = try c.decodeIfPresent(Double.self, forKey: .powerMin) ?? d.powerMin
        airAssist = try c.decodeIfPresent(Bool.self, forKey: .airAssist) ?? d.airAssist
        fillInterval = try c.decodeIfPresent(Double.self, forKey: .fillInterval) ?? d.fillInterval
        fillAngle = try c.decodeIfPresent(Double.self, forKey: .fillAngle) ?? d.fillAngle
        fillBidirectional = try c.decodeIfPresent(Bool.self, forKey: .fillBidirectional) ?? d.fillBidirectional
        dither = try c.decodeIfPresent(DitherMode.self, forKey: .dither) ?? d.dither
        invertImage = try c.decodeIfPresent(Bool.self, forKey: .invertImage) ?? d.invertImage
        overscan = try c.decodeIfPresent(Double.self, forKey: .overscan) ?? d.overscan
        cutSpeed = try c.decodeIfPresent(Int.self, forKey: .cutSpeed) ?? d.cutSpeed
        cutForce = try c.decodeIfPresent(Int.self, forKey: .cutForce) ?? d.cutForce
        cutDepth = try c.decodeIfPresent(Double.self, forKey: .cutDepth) ?? d.cutDepth
        stepDown = try c.decodeIfPresent(Double.self, forKey: .stepDown) ?? d.stepDown
        toolDiameter = try c.decodeIfPresent(Double.self, forKey: .toolDiameter) ?? d.toolDiameter
        millOffset = try c.decodeIfPresent(MillOffset.self, forKey: .millOffset) ?? d.millOffset
        plungeRate = try c.decodeIfPresent(Double.self, forKey: .plungeRate) ?? d.plungeRate
        spindleSpeed = try c.decodeIfPresent(Double.self, forKey: .spindleSpeed) ?? d.spindleSpeed
    }

    /// Default layer colours, in the order new layers take them.
    public static let palette = [
        "#000000", "#0050FF", "#E5222D", "#16A34A", "#F59E0B", "#9333EA",
        "#0891B2", "#DB2777", "#65A30D", "#EA580C", "#4B5563", "#1D4ED8",
    ]
}

/// The source of a text shape, kept so the text stays editable.
public struct TextSpec: Codable, Hashable, Sendable {
    public var text: String
    public var fontName: String
    /// Capital-letter height in mm.
    public var height: Double

    public init(text: String, fontName: String, height: Double) {
        self.text = text
        self.fontName = fontName
        self.height = height
    }
}

/// A grayscale bitmap (0 = black, 255 = white), rows top to bottom.
public struct RasterImage: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Brightness 0…1 at normalised coordinates (u, v in 0…1), or nil outside the image.
    public func brightness(u: Double, v: Double) -> Double? {
        guard u >= 0, v >= 0, u < 1, v < 1, width > 0, height > 0 else { return nil }
        let x = min(width - 1, Int(u * Double(width)))
        let y = min(height - 1, Int(v * Double(height)))
        return Double(pixels[pixels.startIndex + y * width + x]) / 255
    }
}

/// A piece of artwork: flattened outlines plus an editing transform.
public struct Artwork: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var layerID: UUID
    public var name: String
    /// Outlines in the shape's own coordinates (mm, y down). For an image, its frame.
    public var paths: [Polyline]
    /// Placement on the bed.
    public var transform: Affine
    /// Set for text shapes, so the text can be edited later.
    public var text: TextSpec?
    /// Set for bitmap images; the image fills the bounds of `paths`.
    public var image: RasterImage?

    public init(id: UUID = UUID(), layerID: UUID, name: String, paths: [Polyline], transform: Affine = .identity,
                text: TextSpec? = nil, image: RasterImage? = nil) {
        self.id = id
        self.layerID = layerID
        self.name = name
        self.paths = paths
        self.transform = transform
        self.text = text
        self.image = image
    }

    /// Outlines in bed coordinates.
    public var placedPaths: [Polyline] {
        transform.isIdentity ? paths : paths.transformed(transform)
    }

    public var bounds: Rect2 { placedPaths.bounds }

    /// The image frame in the shape's own coordinates.
    public var localFrame: Rect2 { paths.bounds }
}

/// A design: layers and shapes on a workspace that matches the machine bed.
public struct KerfDocument: Codable, Hashable, Sendable {
    public var layers: [Layer]
    public var shapes: [Artwork]

    public init(layers: [Layer] = [], shapes: [Artwork] = []) {
        self.layers = layers
        self.shapes = shapes
    }

    public var bounds: Rect2 { shapes.reduce(Rect2.empty) { $0.union($1.bounds) } }

    public func layer(_ id: UUID) -> Layer? { layers.first { $0.id == id } }

    /// Returns the layer for `hex`, creating one if needed.
    @discardableResult
    public mutating func layer(forColor hex: String, defaultMode: LayerMode) -> UUID {
        let key = hex.uppercased()
        if let l = layers.first(where: { $0.colorHex.uppercased() == key && $0.mode == defaultMode }) { return l.id }
        let layer = Layer(name: "Layer \(layers.count + 1)", colorHex: key, mode: defaultMode)
        layers.append(layer)
        return layer.id
    }

    /// Returns the first layer with `mode`, creating one if needed.
    @discardableResult
    public mutating func layer(forMode mode: LayerMode, name: String, colorHex: String) -> UUID {
        if let l = layers.first(where: { $0.mode == mode }) { return l.id }
        var layer = Layer(name: name, colorHex: colorHex, mode: mode)
        if mode == .image { layer.speed = 3000; layer.power = 40 }
        layers.append(layer)
        return layer.id
    }

    /// Adds a layer using the next unused palette colour.
    @discardableResult
    public mutating func addLayer(mode: LayerMode) -> UUID {
        let used = Set(layers.map { $0.colorHex.uppercased() })
        let color = Layer.palette.first { !used.contains($0) } ?? Layer.palette[layers.count % Layer.palette.count]
        let layer = Layer(name: "Layer \(layers.count + 1)", colorHex: color, mode: mode)
        layers.append(layer)
        return layer.id
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Envelope(version: 2, document: self))
    }

    public static func decode(_ data: Data) throws -> KerfDocument {
        try JSONDecoder().decode(Envelope.self, from: data).document
    }

    private struct Envelope: Codable {
        var version: Int
        var document: KerfDocument
    }
}
