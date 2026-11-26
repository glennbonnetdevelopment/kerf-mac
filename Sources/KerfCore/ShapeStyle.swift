import Foundation

/// A style that can be added to a shape. Each one turned on becomes a child of the shape on a layer of its own,
/// so it can be engraved, cut, printed or sewn separately from the shape's outline.
public enum StylePartKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A line of a set width along the outline.
    case stroke
    /// The inside of the shape's closed outlines.
    case fill
    /// A copy of the outline grown (or shrunk) by a set distance.
    case offset

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stroke: return "Stroke"
        case .fill: return "Fill"
        case .offset: return "Offset outline"
        }
    }

    /// Label for the part's number, or nil when it has none.
    public var amountTitle: String? {
        switch self {
        case .stroke: return "Width (mm)"
        case .fill: return nil
        case .offset: return "Distance (mm)"
        }
    }

    public var defaultAmount: Double {
        switch self {
        case .stroke: return 1
        case .fill: return 0
        case .offset: return 2
        }
    }

    /// The mode a new layer for this part gets on a machine of `kind`.
    public func defaultMode(for kind: DeviceKind) -> LayerMode {
        switch (self, kind) {
        case (.stroke, .grblLaser), (.fill, .grblLaser): return .fill
        case (.fill, .vinylCutter): return .print
        default: return kind.defaultMode
        }
    }
}

/// One style on a shape and the layer it goes on. The part's colour is its layer's colour.
public struct StylePart: Codable, Hashable, Sendable, Identifiable {
    public var kind: StylePartKind
    public var enabled: Bool
    public var layerID: UUID
    /// Stroke: line width in mm. Offset: distance in mm, positive grows the outline, negative shrinks it.
    /// Unused for a fill.
    public var amount: Double

    public var id: StylePartKind { kind }

    public init(kind: StylePartKind, enabled: Bool = true, layerID: UUID, amount: Double? = nil) {
        self.kind = kind
        self.enabled = enabled
        self.layerID = layerID
        self.amount = amount ?? kind.defaultAmount
    }
}

/// Styles added to a shape.
public struct ArtworkStyle: Codable, Hashable, Sendable {
    public var parts: [StylePart]
    /// False leaves the shape's own outline out of jobs and exports, so only its style parts are made.
    public var outlineEnabled: Bool

    public init(parts: [StylePart] = [], outlineEnabled: Bool = true) {
        self.parts = parts
        self.outlineEnabled = outlineEnabled
    }

    public func part(_ kind: StylePartKind) -> StylePart? { parts.first { $0.kind == kind } }

    public var enabledParts: [StylePart] { parts.filter(\.enabled) }

    public var isEmpty: Bool { parts.isEmpty && outlineEnabled }
}

public extension Artwork {
    /// True when the shape's own outline is made (it has no style, or its style keeps the outline).
    var outlineEnabled: Bool { style?.outlineEnabled ?? true }

    /// Stable id for the child shape a style part makes.
    static func partID(_ parent: UUID, _ kind: StylePartKind) -> UUID {
        var bytes = parent.uuid
        let k = UInt8(StylePartKind.allCases.firstIndex(of: kind)! + 1)
        bytes.15 ^= k
        bytes.14 ^= 0xA5
        return UUID(uuid: bytes)
    }

    /// The enabled style parts as shapes of their own, on the parts' layers, placed like this shape.
    /// For embroidery a stroke stays a line with a width (sewn along it); for machines it becomes the outline
    /// of the band it covers, so a fill layer engraves it and a cut layer cuts around it.
    func styleShapes(embroidery: Bool = false) -> [Artwork] {
        guard let style, image == nil else { return [] }
        let scale = max(1e-9, transform.meanScale)
        var out: [Artwork] = []
        for part in style.enabledParts {
            var child = Artwork(id: Self.partID(id, part.kind), layerID: part.layerID,
                                name: "\(name) · \(part.kind.title)", paths: [], transform: transform)
            switch part.kind {
            case .stroke:
                let w = max(0.01, part.amount) / scale
                if embroidery {
                    child.paths = paths
                    child.strokeWidth = w
                } else {
                    child.paths = StyleGeometry.cached(.stroke, paths, w)
                }
            case .fill:
                child.paths = paths.filter { $0.closed && $0.points.count >= 3 }
                child.millRole = .pocket
            case .offset:
                child.paths = StyleGeometry.cached(.offset, paths, part.amount / scale)
                child.millRole = millRole
            }
            if !child.paths.isEmpty { out.append(child) }
        }
        return out
    }
}

public extension KerfDocument {
    /// Shapes as machines and exports see them: each shape (unless its outline is turned off), followed by
    /// its style parts as shapes of their own on the parts' layers.
    func machineShapes(embroidery: Bool = false) -> [Artwork] {
        var out: [Artwork] = []
        out.reserveCapacity(shapes.count)
        for shape in shapes {
            if shape.outlineEnabled { out.append(shape) }
            if shape.style != nil {
                out += shape.styleShapes(embroidery: embroidery).filter { layer($0.layerID) != nil }
            }
        }
        return out
    }

    /// How many shapes and style parts are on a layer (without building any geometry).
    func itemCount(onLayer id: UUID) -> Int {
        shapes.reduce(0) { n, s in
            n + (s.layerID == id && s.outlineEnabled ? 1 : 0)
                + (s.style?.enabledParts.filter { $0.layerID == id }.count ?? 0)
        }
    }

    /// The shape and style a layer was made for, when it holds a shape's style part.
    func styleOwner(ofLayer id: UUID) -> (shape: Artwork, kind: StylePartKind)? {
        for s in shapes {
            if let p = s.style?.parts.first(where: { $0.layerID == id }) { return (s, p.kind) }
        }
        return nil
    }

    /// Drops style parts whose layer no longer exists.
    mutating func pruneStyleParts() {
        let ids = Set(layers.map(\.id))
        for i in shapes.indices where shapes[i].style != nil {
            shapes[i].style?.parts.removeAll { !ids.contains($0.layerID) }
            if shapes[i].style?.isEmpty == true { shapes[i].style = nil }
        }
    }
}

/// Outline geometry for strokes and offsets. Works on a grid like `Contour`, so any outline (open, closed,
/// self-crossing, with holes) gives clean closed loops with round corners.
public enum StyleGeometry {
    public enum Op: Hashable, Sendable { case stroke, offset }

    /// Outlines of the band `width` wide centred on `paths`.
    public static func stroke(_ paths: [Polyline], width: Double) -> [Polyline] {
        let r = abs(width) / 2
        guard r > 0, !paths.isEmpty else { return [] }
        var mask = grid(paths, margin: r, feature: r)
        markLines(paths, into: &mask)
        return loops(Contour.dilate(mask, by: r))
    }

    /// The outline grown by `distance` (negative shrinks it). Closed outlines are treated as areas (even-odd,
    /// so holes stay holes); open paths can only be grown.
    public static func offset(_ paths: [Polyline], by distance: Double) -> [Polyline] {
        guard !paths.isEmpty else { return [] }
        let d = abs(distance)
        guard d > 1e-9 else { return paths.filter { $0.closed } }
        var mask = grid(paths, margin: d, feature: d)
        fillAreas(paths, into: &mask)
        if distance > 0 {
            markLines(paths, into: &mask)
            return loops(Contour.dilate(mask, by: d))
        }
        // Shrink: grow the empty space instead.
        var inv = mask
        inv.cells = mask.cells.map { !$0 }
        var grown = Contour.dilate(inv, by: d)
        grown.cells = grown.cells.map { !$0 }
        return loops(grown)
    }

    /// `stroke` or `offset`, remembering recent results so the canvas can redraw every frame.
    public static func cached(_ op: Op, _ paths: [Polyline], _ amount: Double) -> [Polyline] {
        let key = CacheKey(op: op, paths: paths, amount: amount)
        if let hit = cache.get(key) { return hit }
        let result = op == .stroke ? stroke(paths, width: amount) : offset(paths, by: amount)
        cache.set(key, result)
        return result
    }

    // MARK: - Grid

    static func grid(_ paths: [Polyline], margin: Double, feature: Double) -> Contour.Mask {
        let b = paths.bounds
        let long = max(b.width, b.height, margin * 2, 1e-3)
        // Fine enough to show the feature, coarse enough to stay quick.
        let cell = max(long / 2400, min(feature / 3, long / 500))
        let r = b.insetBy(-(margin + cell * 3))
        return Contour.Mask(width: max(1, Int((r.width / cell).rounded(.up))),
                            height: max(1, Int((r.height / cell).rounded(.up))),
                            origin: Vec2(r.minX, r.minY), cell: cell)
    }

    /// Marks every cell a path passes through.
    static func markLines(_ paths: [Polyline], into m: inout Contour.Mask) {
        for p in paths {
            let pts = p.drawnPoints
            if pts.count == 1 { mark(pts[0], &m) }
            for i in pts.indices.dropFirst() {
                let a = pts[i - 1], b = pts[i]
                let steps = max(1, Int((a.distance(to: b) / (m.cell * 0.5)).rounded(.up)))
                for s in 0...steps { mark(a + (b - a) * (Double(s) / Double(steps)), &m) }
            }
        }
    }

    static func mark(_ p: Vec2, _ m: inout Contour.Mask) {
        let x = Int(((p.x - m.origin.x) / m.cell).rounded(.down)), y = Int(((p.y - m.origin.y) / m.cell).rounded(.down))
        m[x, y] = true
    }

    /// Fills the inside of closed outlines, even-odd, by cell centres.
    static func fillAreas(_ paths: [Polyline], into m: inout Contour.Mask) {
        var edges: [(Vec2, Vec2)] = []
        for p in paths where p.closed && p.points.count >= 3 {
            for i in p.points.indices { edges.append((p.points[i], p.points[(i + 1) % p.points.count])) }
        }
        guard !edges.isEmpty else { return }
        for y in 0..<m.height {
            let cy = m.origin.y + (Double(y) + 0.5) * m.cell
            var xs: [Double] = []
            for (a, b) in edges where (a.y <= cy) != (b.y <= cy) {
                xs.append(a.x + (cy - a.y) / (b.y - a.y) * (b.x - a.x))
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let x0 = Int(((xs[k] - m.origin.x) / m.cell - 0.5).rounded(.up))
                let x1 = Int(((xs[k + 1] - m.origin.x) / m.cell - 0.5).rounded(.down))
                let lo = max(0, x0), hi = min(m.width - 1, x1)
                if lo <= hi { for x in lo...hi { m[x, y] = true } }
                k += 2
            }
        }
    }

    static func loops(_ m: Contour.Mask) -> [Polyline] {
        Contour.trace(m)
            .map { Contour.smooth($0, iterations: 2) }
            .map { Contour.simplify($0, tolerance: m.cell * 0.4) }
            .filter { $0.points.count > 2 }
    }

    // MARK: - Cache

    struct CacheKey: Hashable {
        var op: Op
        var paths: [Polyline]
        var amount: Double
    }

    final class Cache: @unchecked Sendable {
        private var store: [CacheKey: [Polyline]] = [:]
        private let lock = NSLock()

        func get(_ k: CacheKey) -> [Polyline]? {
            lock.lock(); defer { lock.unlock() }
            return store[k]
        }

        func set(_ k: CacheKey, _ v: [Polyline]) {
            lock.lock(); defer { lock.unlock() }
            if store.count > 200 { store.removeAll() }
            store[k] = v
        }
    }

    static let cache = Cache()
}
