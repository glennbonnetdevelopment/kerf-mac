import Foundation

// MARK: - Options

/// The outline of an embroidered patch.
public enum PatchShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case circle, oval, roundedRectangle, rectangle, shield, hexagon
    /// Follows the outline of the design at a distance, like a die-cut sticker.
    case contour

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .circle: return "Circle"
        case .oval: return "Oval"
        case .roundedRectangle: return "Rounded rectangle"
        case .rectangle: return "Rectangle"
        case .shield: return "Shield"
        case .hexagon: return "Hexagon"
        case .contour: return "Follow the design"
        }
    }

    /// An SF Symbol for the shape picker.
    public var symbol: String {
        switch self {
        case .circle: return "circle"
        case .oval: return "oval"
        case .roundedRectangle: return "app"
        case .rectangle: return "rectangle"
        case .shield: return "shield"
        case .hexagon: return "hexagon"
        case .contour: return "lasso"
        }
    }
}

/// How the patch's edge is finished.
public enum PatchBorder: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A wide satin column around the edge, like a merrowed edge.
    case satin
    /// A bold triple stitch line, for patches whose edge is cut and sealed.
    case triple
    /// No border.
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .satin: return "Satin (merrowed look)"
        case .triple: return "Triple stitch line"
        case .none: return "None"
        }
    }
}

/// What makes the patch's background.
public enum PatchBacking: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A piece of fabric (usually twill) sewn on as appliqué: a placement line, a stop to lay the fabric,
    /// a tackdown, and a stop to trim it, before the design.
    case fabric
    /// Fill stitches cover the whole background.
    case fill
    /// Nothing: the hooped fabric shows through.
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fabric: return "Fabric (twill appliqué)"
        case .fill: return "Stitched fill"
        case .none: return "None (hooped fabric)"
        }
    }
}

/// Settings for making a patch. Lengths are in mm.
public struct PatchOptions: Codable, Hashable, Sendable {
    public var shape: PatchShape
    /// Size the patch around the selected design; otherwise use `width` × `height`.
    public var sizeToDesign: Bool
    /// Gap between the design and the inside of the border.
    public var margin: Double
    /// Finished size of the patch (outer edge) when not sized to the design.
    public var width: Double
    public var height: Double
    public var cornerRadius: Double

    public var border: PatchBorder
    /// Satin border width.
    public var borderWidth: Double
    /// Gap between satin stitches.
    public var borderDensity: Double
    public var borderColorHex: String

    public var backing: PatchBacking
    /// Fabric colour, or the thread colour of the fill.
    public var backgroundColorHex: String
    /// With fabric: sew a placement line first, so you can see where to lay the fabric.
    public var placementLine: Bool
    public var fillAngle: Double
    /// Gap between fill rows.
    public var fillDensity: Double

    /// Add a laser or cutter line for the fabric piece, cut to shape before it is laid on the placement line.
    public var cutFabricPiece: Bool
    /// Add a laser or cutter line around the finished patch, to cut it out after sewing.
    public var cutOutPatch: Bool
    /// Gap between the finished edge and the cut-out line.
    public var cutOffset: Double
    /// When a cut line is added, set the design's layers to embroidery only, so the laser or cutter
    /// cuts just the patch lines.
    public var designSewnOnly: Bool

    public init(shape: PatchShape = .circle, sizeToDesign: Bool = true, margin: Double = 3, width: Double = 76.2,
                height: Double = 76.2, cornerRadius: Double = 8, border: PatchBorder = .satin, borderWidth: Double = 4,
                borderDensity: Double = 0.35, borderColorHex: String = "#1F2937", backing: PatchBacking = .fabric,
                backgroundColorHex: String = "#1D4ED8", placementLine: Bool = true, fillAngle: Double = 45,
                fillDensity: Double = 0.42, cutFabricPiece: Bool = false, cutOutPatch: Bool = false,
                cutOffset: Double = 0.5, designSewnOnly: Bool = true) {
        self.shape = shape
        self.sizeToDesign = sizeToDesign
        self.margin = margin
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.border = border
        self.borderWidth = borderWidth
        self.borderDensity = borderDensity
        self.borderColorHex = borderColorHex
        self.backing = backing
        self.backgroundColorHex = backgroundColorHex
        self.placementLine = placementLine
        self.fillAngle = fillAngle
        self.fillDensity = fillDensity
        self.cutFabricPiece = cutFabricPiece
        self.cutOutPatch = cutOutPatch
        self.cutOffset = cutOffset
        self.designSewnOnly = designSewnOnly
    }

    private enum CodingKeys: String, CodingKey {
        case shape, sizeToDesign, margin, width, height, cornerRadius, border, borderWidth, borderDensity, borderColorHex,
             backing, backgroundColorHex, placementLine, fillAngle, fillDensity, cutFabricPiece, cutOutPatch, cutOffset, designSewnOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PatchOptions()
        shape = try c.decodeIfPresent(PatchShape.self, forKey: .shape) ?? d.shape
        sizeToDesign = try c.decodeIfPresent(Bool.self, forKey: .sizeToDesign) ?? d.sizeToDesign
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? d.margin
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        border = try c.decodeIfPresent(PatchBorder.self, forKey: .border) ?? d.border
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? d.borderWidth
        borderDensity = try c.decodeIfPresent(Double.self, forKey: .borderDensity) ?? d.borderDensity
        borderColorHex = try c.decodeIfPresent(String.self, forKey: .borderColorHex) ?? d.borderColorHex
        backing = try c.decodeIfPresent(PatchBacking.self, forKey: .backing) ?? d.backing
        backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? d.backgroundColorHex
        placementLine = try c.decodeIfPresent(Bool.self, forKey: .placementLine) ?? d.placementLine
        fillAngle = try c.decodeIfPresent(Double.self, forKey: .fillAngle) ?? d.fillAngle
        fillDensity = try c.decodeIfPresent(Double.self, forKey: .fillDensity) ?? d.fillDensity
        cutFabricPiece = try c.decodeIfPresent(Bool.self, forKey: .cutFabricPiece) ?? d.cutFabricPiece
        cutOutPatch = try c.decodeIfPresent(Bool.self, forKey: .cutOutPatch) ?? d.cutOutPatch
        cutOffset = try c.decodeIfPresent(Double.self, forKey: .cutOffset) ?? d.cutOffset
        designSewnOnly = try c.decodeIfPresent(Bool.self, forKey: .designSewnOnly) ?? d.designSewnOnly
    }

    /// The options with every number kept to a range that makes a sewable patch.
    public var sanitized: PatchOptions {
        var o = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite ? Swift.min(hi, Swift.max(lo, v)) : fallback
        }
        o.margin = clamp(margin, 0, 50, 3)
        o.width = clamp(width, 15, 400, 76.2)
        o.height = clamp(height, 15, 400, 76.2)
        o.cornerRadius = clamp(cornerRadius, 0, 100, 8)
        o.borderWidth = clamp(borderWidth, 1.5, 10, 4)
        o.borderDensity = clamp(borderDensity, 0.2, 1, 0.35)
        o.fillAngle = fillAngle.isFinite ? fillAngle : 45
        o.fillDensity = clamp(fillDensity, 0.25, 1.5, 0.42)
        o.cutOffset = clamp(cutOffset, 0, 5, 0.5)
        return o
    }

    /// True when the patch adds a laser or cutter line.
    public var hasCutLine: Bool { cutOutPatch || (cutFabricPiece && backing == .fabric) }

    /// How far in from the outer edge the border reaches.
    public var borderReach: Double {
        switch border {
        case .satin: return borderWidth
        case .triple: return 1.5
        case .none: return 0
        }
    }
}

// MARK: - Parts

/// One piece of a patch, made as a layer of its own.
public enum PatchPartKind: String, CaseIterable, Sendable {
    case placement, tackdown, backingFill, border, fabricCut, outerCut

    public var title: String {
        switch self {
        case .placement: return "Placement line"
        case .tackdown: return "Tackdown"
        case .backingFill: return "Background fill"
        case .border: return "Border"
        case .fabricCut: return "Fabric piece cut"
        case .outerCut: return "Cut-out line"
        }
    }

    /// True for parts sewn before the design (the rest are sewn after it, or cut).
    public var sewsBeforeDesign: Bool { self == .placement || self == .tackdown || self == .backingFill }

    public var isCut: Bool { self == .fabricCut || self == .outerCut }
}

public struct PatchPart: Hashable, Sendable {
    public var kind: PatchPartKind
    public var layer: Layer
    public var paths: [Polyline]
}

/// Builds standalone embroidered patches (to sew on later): an outline shape, a satin or triple border,
/// a fabric or fill background with placement and tackdown runs, and optional laser or cutter lines for
/// the fabric piece and for cutting the finished patch out.
public enum Patch {
    /// The finished outer edge of a `shape` filling `rect` (not used for `.contour`).
    public static func edge(_ shape: PatchShape, in rect: Rect2, cornerRadius: Double) -> Polyline {
        let c = rect.center, rx = rect.width / 2, ry = rect.height / 2
        switch shape {
        case .circle:
            let r = min(rx, ry)
            return Flatten.ellipse(center: c, rx: r, ry: r, step: 0.2)
        case .oval:
            return Flatten.ellipse(center: c, rx: rx, ry: ry, step: 0.2)
        case .roundedRectangle:
            return ShapeLibrary.roundedRect(rect, radius: max(0.5, cornerRadius))
        case .rectangle, .contour:
            return ShapeLibrary.roundedRect(rect, radius: 0)
        case .hexagon:
            let pts = (0..<6).map { i -> Vec2 in
                let a = -Double.pi / 2 + Double.pi / 3 * Double(i)
                return Vec2(c.x + cos(a) * rx, c.y + sin(a) * ry)
            }
            return Polyline(pts, closed: true)
        case .shield:
            func u(_ x: Double, _ y: Double) -> Vec2 { Vec2(rect.minX + x * rect.width, rect.minY + y * rect.height) }
            func quad(_ a: Vec2, _ ctrl: Vec2, _ b: Vec2, steps: Int) -> [Vec2] {
                (1...steps).map { k in
                    let t = Double(k) / Double(steps), m = 1 - t
                    return a * (m * m) + ctrl * (2 * m * t) + b * (t * t)
                }
            }
            var pts = [u(0, 0), u(1, 0), u(1, 0.5)]
            pts += quad(u(1, 0.5), u(1, 0.86), u(0.5, 1), steps: 40)
            pts += quad(u(0.5, 1), u(0, 0.86), u(0, 0.5), steps: 40)
            return Polyline(pts, closed: true)
        }
    }

    /// The outer edge of a `shape` patch just big enough that `design`, with `options.margin` around it,
    /// sits inside the border.
    public static func edge(_ shape: PatchShape, around design: Rect2, options o: PatchOptions) -> Polyline {
        let reach = o.borderReach
        let content = design.insetBy(-o.margin)
        var base = content.insetBy(-reach)
        if shape == .circle {
            let side = max(base.width, base.height)
            base = Rect2(minX: base.center.x - side / 2, minY: base.center.y - side / 2,
                         maxX: base.center.x + side / 2, maxY: base.center.y + side / 2)
        }
        // A shield is narrow at the bottom, so the design sits a little above its middle.
        let drop = shape == .shield ? 0.12 : 0
        func candidate(_ s: Double) -> Polyline {
            let w = base.width * s, h = base.height * s
            let c = base.center + Vec2(0, h * drop)
            let r = Rect2(minX: c.x - w / 2, minY: c.y - h / 2, maxX: c.x + w / 2, maxY: c.y + h / 2)
            return edge(shape, in: r, cornerRadius: o.cornerRadius)
        }
        let corners = [Vec2(content.minX, content.minY), Vec2(content.maxX, content.minY),
                       Vec2(content.maxX, content.maxY), Vec2(content.minX, content.maxY), content.center]
        func fits(_ s: Double) -> Bool {
            let inner = reach > 0 ? PathOffset.offset(candidate(s), by: -reach) : candidate(s)
            return corners.allSatisfy { Planner.contains(inner, $0) }
        }
        // Smallest scale that holds the design: grow until it fits, then narrow it down.
        var lo = 1.0, hi = 1.0
        while !fits(hi) && hi < 8 { hi *= 1.25 }
        if fits(lo) { return candidate(lo) }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if fits(mid) { hi = mid } else { lo = mid }
        }
        return candidate(hi)
    }

    /// The largest loop of a traced contour, used as the edge of a `.contour` patch.
    public static func contourEdge(_ loops: [Polyline]) -> Polyline? {
        loops.filter { $0.closed && $0.points.count > 2 }.max { abs($0.signedArea) < abs($1.signedArea) }
    }

    /// The patch's parts for an outer `edge`, in sewing order, then the cut lines. Cut lines go on layers of
    /// `cutMode` (the current machine's), sewn parts on embroidery-only layers.
    public static func parts(edge rawEdge: Polyline, options: PatchOptions, cutMode: LayerMode, name: String = "Patch") -> [PatchPart] {
        let o = options.sanitized
        var edge = rawEdge.deduplicated()
        if edge.points.count > 3, let f = edge.points.first, let l = edge.points.last, f.distance(to: l) < 1e-6 {
            edge.points.removeLast()
        }
        edge.closed = true
        guard edge.points.count > 2 else { return [] }
        let bw = o.borderReach
        // The middle of the border: placement, tackdown and the satin column all follow it.
        let centre = bw > 0 ? PathOffset.offset(edge, by: -bw / 2) : edge
        var out: [PatchPart] = []

        func sewn(_ kind: PatchPartKind, colour: String, settings: EmbroiderySettings, stop: Bool, paths: [Polyline]) {
            var layer = Layer(name: "\(name) \(kind.title.lowercased())", colorHex: colour.uppercased(), mode: .line)
            layer.output = .embroidery
            layer.embroideryStop = stop
            layer.embroidery = settings
            out.append(PatchPart(kind: kind, layer: layer, paths: paths))
        }
        func cut(_ kind: PatchPartKind, colour: String, paths: [Polyline]) {
            var layer = Layer(name: "\(name) \(kind.title.lowercased())", colorHex: colour, mode: cutMode)
            layer.output = .machines
            if cutMode == .line {
                layer.speed = 1200
                layer.power = 40
            }
            out.append(PatchPart(kind: kind, layer: layer, paths: paths))
        }

        switch o.backing {
        case .fabric:
            if o.placementLine {
                sewn(.placement, colour: o.backgroundColorHex,
                     settings: EmbroiderySettings(stitchType: .running, stitchLength: 2.5), stop: true, paths: [centre])
            }
            // A light zig-zag just inside the middle of the border, so the satin covers it and the trimmed edge.
            let zig = bw > 0 ? min(1.5, max(0.8, bw * 0.4)) : 1.2
            let tack = bw > 0 ? PathOffset.offset(centre, by: -zig / 2) : PathOffset.offset(edge, by: -zig / 2)
            sewn(.tackdown, colour: o.backgroundColorHex,
                 settings: EmbroiderySettings(stitchType: .satin, satinWidth: zig, density: 1.2, underlay: true, pullCompensation: 0),
                 stop: true, paths: [tack])
        case .fill:
            // The fill runs under the inner half of the border so no gap shows between them.
            let reach = bw > 0 ? max(0, bw / 2 - 1) : 0.3
            let area = PathOffset.offset(centre, by: -reach)
            sewn(.backingFill, colour: o.backgroundColorHex,
                 settings: EmbroiderySettings(stitchType: .fill, density: o.fillDensity, fillAngle: o.fillAngle,
                                              fillStitchLength: 3.5, underlay: true, pullCompensation: 0.2),
                 stop: false, paths: [area])
        case .none:
            break
        }

        switch o.border {
        case .satin:
            sewn(.border, colour: o.borderColorHex,
                 settings: EmbroiderySettings(stitchType: .satin, satinWidth: o.borderWidth, density: o.borderDensity,
                                              underlay: true, pullCompensation: 0.3),
                 stop: false, paths: [centre])
        case .triple:
            sewn(.border, colour: o.borderColorHex,
                 settings: EmbroiderySettings(stitchType: .bean, stitchLength: 2), stop: false, paths: [centre])
        case .none:
            break
        }

        if o.cutFabricPiece && o.backing == .fabric {
            // Bigger than the tackdown, but well inside the satin so the raw edge is covered.
            let grow = o.border == .satin ? o.borderWidth / 4 : 0.5
            cut(.fabricCut, colour: "#F97316", paths: [PathOffset.offset(centre, by: grow)])
        }
        if o.cutOutPatch {
            cut(.outerCut, colour: "#DC2626", paths: [o.cutOffset > 0 ? PathOffset.offset(edge, by: o.cutOffset) : edge])
        }
        return out
    }

    /// Adds a patch's layers and shapes to `doc`: parts sewn before the design go at the top of the layer list
    /// (layers sew top to bottom), the border and cut lines at the bottom. Returns the added shapes' ids.
    @discardableResult
    public static func apply(_ parts: [PatchPart], to doc: inout KerfDocument) -> [UUID] {
        var ids: [UUID] = []
        var top = 0
        for part in parts {
            if part.kind.sewsBeforeDesign {
                doc.layers.insert(part.layer, at: top)
                top += 1
            } else {
                doc.layers.append(part.layer)
            }
            let shape = Artwork(layerID: part.layer.id, name: part.layer.name, paths: part.paths)
            doc.shapes.append(shape)
            ids.append(shape.id)
        }
        return ids
    }
}
