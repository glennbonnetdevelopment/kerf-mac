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

/// Which kinds of output a layer goes to.
public enum LayerOutput: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The current machine and embroidery export.
    case all
    /// Only embroidery export (never sent to a laser, cutter or CNC).
    case embroidery
    /// Only the laser, cutter or CNC (never sewn).
    case machines

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "Machine and embroidery"
        case .embroidery: return "Embroidery only"
        case .machines: return "Machine only (not sewn)"
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

/// What a CNC router does with a shape (like a part, a hole, or an engraved line).
public enum MillRole: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Closed shapes inside an odd number of other shapes are holes; the rest are parts. Open paths run on the line.
    case auto
    /// Cut around the outside so the part keeps its size.
    case part
    /// Cut on the inside so the hole keeps its size.
    case hole
    /// Tool centre follows the line (engraving, V-carving lines).
    case onLine
    /// Clear all material inside the shape to depth.
    case pocket
    /// Drill at the shape's centre.
    case drill

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Auto (part or hole)"
        case .part: return "Part (cut outside)"
        case .hole: return "Hole (cut inside)"
        case .onLine: return "On the line"
        case .pocket: return "Pocket (clear inside)"
        case .drill: return "Drill at centre"
        }
    }
}

public enum MillStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case climb, conventional
    public var id: String { rawValue }
    public var title: String { self == .climb ? "Climb" : "Conventional" }
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
    /// Blade offset in mm for this layer, for a different blade (a 60° blade for thick material);
    /// nil uses the machine's. Ignored on machines whose blade offset is 0 (they compensate themselves).
    public var bladeOffset: Double?

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
    /// Cut type for shapes that don't set their own.
    public var defaultMillRole: MillRole
    public var millStyle: MillStyle
    /// Pocket stepover as a fraction of the tool diameter.
    public var stepover: Double
    /// Holding tabs keep parts attached to the sheet: the laser skips short stretches of each part's
    /// outline, and a CNC router leaves a thin bridge. Also the master switch for tabs placed by hand.
    public var tabsEnabled: Bool
    /// Whether automatic tabs use a fixed count per part or a spacing along the outline.
    public var tabPlacement: TabPlacement
    /// Tabs per part (when placing by count).
    public var tabCount: Int
    /// Outline length between automatic tabs in mm (when placing by spacing).
    public var tabSpacing: Double
    /// CNC tab width in mm (the bridge left between cuts, not counting the tool).
    public var tabWidth: Double
    /// CNC tab height in mm, measured up from the bottom of the cut.
    public var tabHeight: Double
    /// Laser tab width in mm: the length of outline left uncut.
    public var laserTabWidth: Double
    /// Ramp into the cut along the path instead of plunging straight down (0 = plunge).
    public var rampLength: Double
    /// The material library entry these settings came from, if any.
    public var materialID: UUID?
    /// Embroidery machine settings; nil uses the defaults for the layer's mode (see `embroiderySettings`).
    public var embroidery: EmbroiderySettings?
    /// Which outputs use this layer: everything, only embroidery, or only the laser, cutter and CNC.
    public var output: LayerOutput = .all
    /// Embroidery: the machine stops before and after this layer, and it is never grouped with another layer
    /// of the same thread. For appliqué steps such as laying fabric on a placement line or trimming it.
    public var embroideryStop: Bool = false

    public init(id: UUID = UUID(), name: String, colorHex: String, mode: LayerMode = .line,
                enabled: Bool = true, passes: Int = 1, speed: Double = 1000, power: Double = 50,
                powerMin: Double = 0, airAssist: Bool = false, fillInterval: Double = 0.1, fillAngle: Double = 0,
                fillBidirectional: Bool = true, dither: DitherMode = .floydSteinberg, invertImage: Bool = false,
                overscan: Double = 2.5, cutSpeed: Int = 20, cutForce: Int = 80, cutDepth: Double = 3,
                stepDown: Double = 1, toolDiameter: Double = 3.175, millOffset: MillOffset = .onLine,
                plungeRate: Double = 300, spindleSpeed: Double = 1000, defaultMillRole: MillRole = .auto,
                millStyle: MillStyle = .climb, stepover: Double = 0.4, tabsEnabled: Bool = false,
                tabPlacement: TabPlacement = .count, tabCount: Int = 4, tabSpacing: Double = 100,
                tabWidth: Double = 5, tabHeight: Double = 1.5, laserTabWidth: Double = 0.5, rampLength: Double = 0,
                bladeOffset: Double? = nil) {
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
        self.defaultMillRole = defaultMillRole
        self.millStyle = millStyle
        self.stepover = stepover
        self.tabsEnabled = tabsEnabled
        self.tabPlacement = tabPlacement
        self.tabCount = tabCount
        self.tabSpacing = tabSpacing
        self.tabWidth = tabWidth
        self.tabHeight = tabHeight
        self.laserTabWidth = laserTabWidth
        self.rampLength = rampLength
        self.bladeOffset = bladeOffset
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, mode, enabled, passes, speed, power, powerMin, airAssist, fillInterval, fillAngle,
             fillBidirectional, dither, invertImage, overscan, cutSpeed, cutForce, cutDepth, stepDown, toolDiameter,
             millOffset, plungeRate, spindleSpeed, defaultMillRole, millStyle, stepover, tabsEnabled, tabPlacement, tabCount,
             tabSpacing, tabWidth, tabHeight, laserTabWidth, rampLength, materialID, embroidery, bladeOffset, output, embroideryStop
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
        defaultMillRole = try c.decodeIfPresent(MillRole.self, forKey: .defaultMillRole) ?? d.defaultMillRole
        millStyle = try c.decodeIfPresent(MillStyle.self, forKey: .millStyle) ?? d.millStyle
        stepover = try c.decodeIfPresent(Double.self, forKey: .stepover) ?? d.stepover
        tabsEnabled = try c.decodeIfPresent(Bool.self, forKey: .tabsEnabled) ?? d.tabsEnabled
        tabPlacement = try c.decodeIfPresent(TabPlacement.self, forKey: .tabPlacement) ?? d.tabPlacement
        tabCount = try c.decodeIfPresent(Int.self, forKey: .tabCount) ?? d.tabCount
        tabSpacing = try c.decodeIfPresent(Double.self, forKey: .tabSpacing) ?? d.tabSpacing
        tabWidth = try c.decodeIfPresent(Double.self, forKey: .tabWidth) ?? d.tabWidth
        tabHeight = try c.decodeIfPresent(Double.self, forKey: .tabHeight) ?? d.tabHeight
        laserTabWidth = try c.decodeIfPresent(Double.self, forKey: .laserTabWidth) ?? d.laserTabWidth
        rampLength = try c.decodeIfPresent(Double.self, forKey: .rampLength) ?? d.rampLength
        materialID = try c.decodeIfPresent(UUID.self, forKey: .materialID)
        embroidery = try c.decodeIfPresent(EmbroiderySettings.self, forKey: .embroidery)
        bladeOffset = try c.decodeIfPresent(Double.self, forKey: .bladeOffset)
        output = try c.decodeIfPresent(LayerOutput.self, forKey: .output) ?? .all
        embroideryStop = try c.decodeIfPresent(Bool.self, forKey: .embroideryStop) ?? false
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
    /// Bend in degrees: positive arches the text upward, negative bends it into a bowl. Nil or 0 is straight.
    public var curve: Double?

    public init(text: String, fontName: String, height: Double, curve: Double? = nil) {
        self.text = text
        self.fontName = fontName
        self.height = height
        self.curve = curve
    }

    /// True when the text is bent by a noticeable amount.
    public var isCurved: Bool { abs(curve ?? 0) >= 0.5 }
}

/// Text laid along a guide path. The guide is in the shape's own coordinates, so it moves with the text.
public struct PathTextSpec: Codable, Hashable, Sendable {
    /// Points of the guide, in travel order. Letters stand on the left of the direction of travel
    /// (above the path when it runs left to right).
    public var guide: [Vec2]
    public var closed: Bool
    /// Arc length along the guide where the text starts.
    public var offset: Double
    /// Gap between the guide and the text baseline, in mm (negative moves the text across the line).
    public var gap: Double

    public init(guide: [Vec2], closed: Bool, offset: Double = 0, gap: Double = 1) {
        self.guide = guide
        self.closed = closed
        self.offset = offset
        self.gap = gap
    }

    public var length: Double {
        var total = 0.0
        for i in guide.indices.dropFirst() { total += guide[i].distance(to: guide[i - 1]) }
        return total
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
    /// CNC cut type for this shape; nil uses the layer's default.
    public var millRole: MillRole?
    /// Set when `text` is laid along a path, so the text and its position stay editable.
    public var pathText: PathTextSpec?
    /// Line width in mm when the source file drew this shape as a stroke with no fill (nil when filled or unknown).
    /// Auto embroidery sews such shapes along the line instead of filling them.
    public var strokeWidth: Double?
    /// Embroidery settings for this shape alone; nil uses its layer's.
    public var embroidery: EmbroiderySettings?
    /// Hand-edited stitches in the shape's own coordinates. When set they are sewn exactly as they are
    /// instead of digitizing the outline.
    public var stitches: [[Vec2]]?
    /// Stroke, fill and offset styles, each made on its own layer as a child of this shape.
    public var style: ArtworkStyle?
    /// Holding tabs placed by hand, as points near the outline in the shape's own coordinates (each one
    /// snaps to the nearest outline when the job is planned). Nil places tabs automatically from the
    /// layer's settings; empty means no tabs on this shape.
    public var tabs: [Vec2]?

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
/// The piece of material the job goes on: CNC stock or a cutter mat. Shown on the canvas inside the bed.
public struct Workpiece: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case stock, mat, sheet, hoop
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .stock: return "Material stock"
            case .mat: return "Cutting mat"
            case .sheet: return "Sheet or vinyl"
            case .hoop: return "Embroidery hoop"
            }
        }
    }

    public var kind: Kind
    public var name: String
    /// Top-left corner on the bed, in mm.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Material thickness in mm (used by the CNC preview).
    public var thickness: Double
    /// The material's colour on the canvas ("#RRGGBB"): fabric, vinyl, wood. Nil draws the kind's usual tint.
    public var colorHex: String?

    public init(kind: Kind = .stock, name: String = "Workpiece", x: Double = 0, y: Double = 0,
                width: Double, height: Double, thickness: Double = 18, colorHex: String? = nil) {
        self.kind = kind
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.thickness = thickness
        self.colorHex = colorHex
    }

    public var rect: Rect2 { Rect2(minX: x, minY: y, maxX: x + width, maxY: y + height) }

    /// The same piece with its size, kind, thickness and colour from `preset`, keeping its place on the bed.
    public func resized(like preset: Workpiece) -> Workpiece {
        var n = preset
        n.x = x
        n.y = y
        return n
    }

    /// Common material colours to pick from, with names.
    public static let colorSwatches: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"), ("Natural cotton", "#F1E9D8"), ("Black", "#1C1C1E"), ("Charcoal", "#4A4A4F"),
        ("Heather grey", "#A7A9AC"), ("Navy", "#1F2A44"), ("Royal blue", "#2B4DB0"), ("Denim", "#4F6D8F"),
        ("Red", "#B3202A"), ("Pink", "#F2B5C4"), ("Forest green", "#2E5B3A"), ("Khaki", "#C3B091"),
        ("Yellow", "#F3D34A"), ("Birch plywood", "#E3C99A"), ("Walnut", "#6B4A32"), ("Clear acrylic", "#E6F2F5"),
    ]

    public static let presets: [Workpiece] = [
        Workpiece(kind: .mat, name: "12 × 12 in mat", width: 304.8, height: 304.8, thickness: 0.3),
        Workpiece(kind: .mat, name: "12 × 24 in mat", width: 304.8, height: 609.6, thickness: 0.3),
        Workpiece(kind: .mat, name: "ScanNCut 12 × 12 mat", width: 305, height: 305, thickness: 0.3),
        Workpiece(kind: .sheet, name: "Letter sheet", width: 215.9, height: 279.4, thickness: 0.1),
        Workpiece(kind: .sheet, name: "A4 sheet", width: 210, height: 297, thickness: 0.1),
        Workpiece(kind: .stock, name: "Plywood 300 × 300 × 18", width: 300, height: 300, thickness: 18),
        Workpiece(kind: .stock, name: "Plywood 400 × 400 × 12", width: 400, height: 400, thickness: 12),
        Workpiece(kind: .stock, name: "Board 600 × 150 × 19", width: 600, height: 150, thickness: 19),
        Workpiece(kind: .stock, name: "Acrylic 300 × 200 × 3", width: 300, height: 200, thickness: 3),
    ] + EmbroideryHoop.all.map { Workpiece(kind: .hoop, name: $0.name, width: $0.width, height: $0.height, thickness: 1) }
}

/// Workpieces the user saved with their own sizes and colours, offered next to the built-in presets.
public struct WorkpieceLibrary: Codable, Hashable, Sendable {
    public var items: [Workpiece]

    public init(items: [Workpiece] = []) {
        self.items = items
    }

    /// Saves `piece` under `name`, replacing a saved piece with the same name. The place on the bed isn't kept.
    /// Returns false when the name is blank.
    @discardableResult
    public mutating func save(_ piece: Workpiece, as name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var w = piece
        w.name = trimmed
        w.x = 0
        w.y = 0
        if let i = items.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            items[i] = w
        } else {
            items.append(w)
        }
        return true
    }

    public mutating func remove(named name: String) {
        items.removeAll { $0.name == name }
    }

    public func contains(named name: String) -> Bool {
        items.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct KerfDocument: Codable, Hashable, Sendable {
    public var layers: [Layer]
    public var shapes: [Artwork]
    /// Optional material piece shown on the bed.
    public var workpiece: Workpiece?

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
