import Foundation

/// How a layer's shapes are processed.
public enum LayerMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Laser follows the outline (cutting or scoring).
    case line
    /// Laser engraves the inside of closed shapes with a scanline fill.
    case fill
    /// Vinyl cutter knife follows the outline.
    case cut

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .line: return "Line"
        case .fill: return "Fill"
        case .cut: return "Cut (vinyl)"
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
    /// Feed rate in mm/min.
    public var speed: Double
    /// Laser power, 0–100 %.
    public var power: Double
    public var airAssist: Bool
    /// Fill line spacing in mm.
    public var fillInterval: Double
    /// Fill line angle in degrees.
    public var fillAngle: Double
    /// Engrave fill lines in both directions.
    public var fillBidirectional: Bool

    // Vinyl cutter settings
    /// Cutting speed in cm/s.
    public var cutSpeed: Int
    /// Knife force in grams (sent where the cutter supports it).
    public var cutForce: Int

    public init(id: UUID = UUID(), name: String, colorHex: String, mode: LayerMode = .line,
                enabled: Bool = true, passes: Int = 1, speed: Double = 1000, power: Double = 50,
                airAssist: Bool = false, fillInterval: Double = 0.1, fillAngle: Double = 0,
                fillBidirectional: Bool = true, cutSpeed: Int = 20, cutForce: Int = 80) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.mode = mode
        self.enabled = enabled
        self.passes = passes
        self.speed = speed
        self.power = power
        self.airAssist = airAssist
        self.fillInterval = fillInterval
        self.fillAngle = fillAngle
        self.fillBidirectional = fillBidirectional
        self.cutSpeed = cutSpeed
        self.cutForce = cutForce
    }

    /// Default layer colours, in the order new layers take them.
    public static let palette = [
        "#000000", "#0050FF", "#E5222D", "#16A34A", "#F59E0B", "#9333EA",
        "#0891B2", "#DB2777", "#65A30D", "#EA580C", "#4B5563", "#1D4ED8",
    ]
}

/// A piece of artwork: flattened outlines plus an editing transform.
public struct Artwork: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var layerID: UUID
    public var name: String
    /// Outlines in the shape's own coordinates (mm, y down).
    public var paths: [Polyline]
    /// Placement on the bed.
    public var transform: Affine

    public init(id: UUID = UUID(), layerID: UUID, name: String, paths: [Polyline], transform: Affine = .identity) {
        self.id = id
        self.layerID = layerID
        self.name = name
        self.paths = paths
        self.transform = transform
    }

    /// Outlines in bed coordinates.
    public var placedPaths: [Polyline] {
        transform.isIdentity ? paths : paths.transformed(transform)
    }

    public var bounds: Rect2 { placedPaths.bounds }
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
        if let l = layers.first(where: { $0.colorHex.uppercased() == key }) { return l.id }
        let layer = Layer(name: "Layer \(layers.count + 1)", colorHex: key, mode: defaultMode)
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
        return try enc.encode(Envelope(version: 1, document: self))
    }

    public static func decode(_ data: Data) throws -> KerfDocument {
        try JSONDecoder().decode(Envelope.self, from: data).document
    }

    private struct Envelope: Codable {
        var version: Int
        var document: KerfDocument
    }
}
