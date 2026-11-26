import Foundation

// MARK: - Settings

/// How a layer's shapes are sewn on an embroidery machine.
public enum StitchType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A single line of stitches along the outline.
    case running
    /// Each stitch sewn three times (forward, back, forward) for a bold line.
    case bean
    /// A zig-zag column of a set width along the outline.
    case satin
    /// Rows of stitches filling the inside of closed shapes (tatami).
    case fill

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .running: return "Running stitch"
        case .bean: return "Triple (bean) stitch"
        case .satin: return "Satin border"
        case .fill: return "Fill (tatami)"
        }
    }
}

/// A layer's embroidery settings. All lengths are in mm.
public struct EmbroiderySettings: Codable, Hashable, Sendable {
    public var stitchType: StitchType
    /// Running and bean stitch length.
    public var stitchLength: Double
    /// Satin column width.
    public var satinWidth: Double
    /// Gap between satin zig-zags and between fill rows.
    public var density: Double
    /// Fill row angle in degrees.
    public var fillAngle: Double
    /// Longest stitch along a fill row.
    public var fillStitchLength: Double
    /// Sew a light foundation first (a centre run under satin, a sparse cross fill under fill).
    public var underlay: Bool
    /// Extra width added to satin columns and fill rows, because thread pulls the fabric in.
    public var pullCompensation: Double

    public init(stitchType: StitchType = .running, stitchLength: Double = 2.5, satinWidth: Double = 3,
                density: Double = 0.4, fillAngle: Double = 45, fillStitchLength: Double = 3.5,
                underlay: Bool = true, pullCompensation: Double = 0.2) {
        self.stitchType = stitchType
        self.stitchLength = stitchLength
        self.satinWidth = satinWidth
        self.density = density
        self.fillAngle = fillAngle
        self.fillStitchLength = fillStitchLength
        self.underlay = underlay
        self.pullCompensation = pullCompensation
    }

    private enum CodingKeys: String, CodingKey {
        case stitchType, stitchLength, satinWidth, density, fillAngle, fillStitchLength, underlay, pullCompensation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EmbroiderySettings()
        stitchType = try c.decodeIfPresent(StitchType.self, forKey: .stitchType) ?? d.stitchType
        stitchLength = try c.decodeIfPresent(Double.self, forKey: .stitchLength) ?? d.stitchLength
        satinWidth = try c.decodeIfPresent(Double.self, forKey: .satinWidth) ?? d.satinWidth
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? d.density
        fillAngle = try c.decodeIfPresent(Double.self, forKey: .fillAngle) ?? d.fillAngle
        fillStitchLength = try c.decodeIfPresent(Double.self, forKey: .fillStitchLength) ?? d.fillStitchLength
        underlay = try c.decodeIfPresent(Bool.self, forKey: .underlay) ?? d.underlay
        pullCompensation = try c.decodeIfPresent(Double.self, forKey: .pullCompensation) ?? d.pullCompensation
    }

    /// Settings a layer starts with: fill layers fill, everything else follows the outline.
    public static func defaults(for mode: LayerMode) -> EmbroiderySettings {
        EmbroiderySettings(stitchType: mode == .fill ? .fill : .running)
    }

    /// The settings with every value kept to a range a machine can sew.
    public var sanitized: EmbroiderySettings {
        var s = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite ? Swift.min(hi, Swift.max(lo, v)) : fallback
        }
        s.stitchLength = clamp(stitchLength, 0.5, 12, 2.5)
        s.satinWidth = clamp(satinWidth, 0.5, 12, 3)
        s.density = clamp(density, 0.15, 5, 0.4)
        s.fillAngle = fillAngle.isFinite ? fillAngle : 45
        s.fillStitchLength = clamp(fillStitchLength, 1, 7, 3.5)
        s.pullCompensation = clamp(pullCompensation, 0, 2, 0.2)
        return s
    }
}

public extension Layer {
    /// This layer's embroidery settings, or the defaults for its mode.
    var embroiderySettings: EmbroiderySettings {
        get { embroidery ?? .defaults(for: mode) }
        set { embroidery = newValue }
    }

    /// Whether the layer is sewn when exporting embroidery (print-only and image layers are not).
    var isEmbroidered: Bool { enabled && mode != .print && mode != .image }
}

// MARK: - Plan

/// A thread colour.
public struct ThreadColor: Hashable, Codable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(rgb: UInt32) {
        self.init(red: UInt8((rgb >> 16) & 0xFF), green: UInt8((rgb >> 8) & 0xFF), blue: UInt8(rgb & 0xFF))
    }

    /// From "#RRGGBB"; black if it can't be read.
    public init(hex: String) {
        self.init(rgb: UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0)
    }

    public var rgb: UInt32 { UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue) }
    public var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
}

/// Stitches sewn in one thread colour. Each run is sewn without lifting; the machine trims and jumps between runs.
public struct StitchBlock: Hashable, Sendable {
    public var color: ThreadColor
    public var name: String
    /// Needle positions in mm on the design (y down).
    public var runs: [[Vec2]]

    public init(color: ThreadColor, name: String, runs: [[Vec2]]) {
        self.color = color
        self.name = name
        self.runs = runs
    }
}

/// The whole design as stitches, in sewing order.
public struct EmbroideryPlan: Hashable, Sendable {
    public var blocks: [StitchBlock]

    public init(blocks: [StitchBlock] = []) {
        self.blocks = blocks
    }

    public var isEmpty: Bool { blocks.allSatisfy { $0.runs.allSatisfy(\.isEmpty) } }

    public var bounds: Rect2 {
        var r = Rect2.empty
        for b in blocks { for run in b.runs { for p in run { r.include(p) } } }
        return r
    }
}

/// Turns a design's vector shapes into stitches.
public enum EmbroideryPlanner {
    /// Stitches for every enabled, sewable layer, in layer order. Layers next to each other with the same colour share a thread.
    public static func plan(_ doc: KerfDocument, shapeIDs: Set<UUID>? = nil) -> EmbroideryPlan {
        var blocks: [StitchBlock] = []
        var cursor = Vec2.zero
        var started = false
        for layer in doc.layers where layer.isEmbroidered {
            let shapes = doc.shapes.filter {
                $0.layerID == layer.id && $0.image == nil && (shapeIDs?.contains($0.id) ?? true)
            }
            guard !shapes.isEmpty else { continue }
            if !started, let first = shapes.first?.bounds, !first.isEmpty {
                cursor = Vec2(first.minX, first.minY)
                started = true
            }
            let runs = layerRuns(shapes, settings: layer.embroiderySettings.sanitized, cursor: &cursor)
            guard !runs.isEmpty else { continue }
            let color = ThreadColor(hex: layer.colorHex)
            if let last = blocks.last, last.color == color {
                blocks[blocks.count - 1].runs += runs
            } else {
                blocks.append(StitchBlock(color: color, name: layer.name, runs: runs))
            }
        }
        return EmbroideryPlan(blocks: blocks)
    }

    static func layerRuns(_ shapes: [Artwork], settings s: EmbroiderySettings, cursor: inout Vec2) -> [[Vec2]] {
        var runs: [[Vec2]] = []
        switch s.stitchType {
        case .running, .bean, .satin:
            let polys = shapes.flatMap(\.placedPaths).map { $0.deduplicated() }.filter { $0.points.count >= 2 }
            for path in Planner.order(polys, from: cursor, innerFirst: true) {
                switch s.stitchType {
                case .bean:
                    runs.append(bean(running(path, length: s.stitchLength)))
                case .satin:
                    runs.append(contentsOf: satin(path, settings: s))
                default:
                    runs.append(running(path, length: s.stitchLength))
                }
                if let last = runs.last?.last { cursor = last }
            }
        case .fill:
            var remaining = shapes.map { $0.placedPaths.map { $0.deduplicated() }.filter { $0.closed && $0.points.count >= 3 } }
                .filter { !$0.isEmpty }
            while !remaining.isEmpty {
                // Next shape: the one whose box is nearest.
                let pos = cursor
                let k = remaining.indices.min { distance(pos, to: remaining[$0].bounds) < distance(pos, to: remaining[$1].bounds) }!
                let polys = remaining.remove(at: k)
                if s.underlay {
                    let under = fill(polys, angle: s.fillAngle + 90, spacing: max(1.5, s.density * 5),
                                     stitchLength: 3.5, extend: -0.6, from: cursor)
                    runs += under
                    if let last = under.last?.last { cursor = last }
                }
                let top = fill(polys, angle: s.fillAngle, spacing: s.density, stitchLength: s.fillStitchLength,
                               extend: s.pullCompensation / 2, from: cursor)
                runs += top
                if let last = top.last?.last { cursor = last }
            }
        }
        return runs.filter { $0.count >= 2 }
    }

    static func distance(_ p: Vec2, to b: Rect2) -> Double {
        let dx = max(b.minX - p.x, 0, p.x - b.maxX), dy = max(b.minY - p.y, 0, p.y - b.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Running and bean

    /// Even stitches of about `length` along a path, keeping sharp corners.
    public static func running(_ pts: [Vec2], length: Double, cornerDegrees: Double = 25) -> [Vec2] {
        guard pts.count >= 2, length > 0 else { return pts }
        let cosLimit = cos(cornerDegrees * .pi / 180)
        // Split at corners, then space stitches evenly along each piece.
        var pieces: [[Vec2]] = []
        var current = [pts[0]]
        for i in 1..<pts.count {
            current.append(pts[i])
            if i < pts.count - 1 {
                let a = (pts[i] - pts[i - 1]).normalized, b = (pts[i + 1] - pts[i]).normalized
                if a.dot(b) < cosLimit {
                    pieces.append(current)
                    current = [pts[i]]
                }
            }
        }
        pieces.append(current)
        var out = [pts[0]]
        for piece in pieces {
            let total = arcLength(piece)
            guard total > 1e-9 else { continue }
            let n = max(1, Int((total / length).rounded()))
            for k in 1...n {
                out.append(point(on: piece, at: total * Double(k) / Double(n)))
            }
        }
        return out
    }

    /// Sews each stitch three times: forward, back, forward.
    public static func bean(_ pts: [Vec2]) -> [Vec2] {
        guard pts.count >= 2 else { return pts }
        var out = [pts[0]]
        for i in 1..<pts.count {
            out += [pts[i], pts[i - 1], pts[i]]
        }
        return out
    }

    // MARK: Satin

    /// A zig-zag column along the path. With underlay, a centre run is sewn first and the satin comes back over it.
    public static func satin(_ pts: [Vec2], settings s: EmbroiderySettings) -> [[Vec2]] {
        guard pts.count >= 2 else { return [] }
        let total = arcLength(pts)
        guard total > 1e-6 else { return [] }
        var path = pts
        var runs: [[Vec2]] = []
        var under: [Vec2] = []
        if s.underlay {
            under = running(path, length: 2)
            path = path.reversed()
        }
        let half = (s.satinWidth + s.pullCompensation) / 2
        // Each zig and each zag moves `density` along the path.
        let n = max(2, Int((total / s.density).rounded()))
        var column: [Vec2] = []
        column.reserveCapacity(n + 1)
        for k in 0...n {
            let d = total * Double(k) / Double(n)
            let p = point(on: path, at: d)
            let ahead = point(on: path, at: min(total, d + 0.5)), behind = point(on: path, at: max(0, d - 0.5))
            var t = (ahead - behind).normalized
            if t.length < 0.5 { t = (path[path.count - 1] - path[0]).normalized }
            let normal = Vec2(-t.y, t.x)
            column.append(p + normal * (k % 2 == 0 ? half : -half))
        }
        if !under.isEmpty {
            // Step from the end of the underlay to the first side of the column.
            runs.append(under + column)
        } else {
            runs.append(column)
        }
        return runs
    }

    // MARK: Fill

    /// One row of fill: a scanline segment in the rotated frame.
    struct FillRow {
        var row: Int
        var y: Double
        var x0: Double
        var x1: Double
    }

    /// Tatami fill of closed outlines (even-odd, so holes stay open). Rows are `spacing` apart at `angle`
    /// degrees, sewn back and forth with staggered stitches. `extend` lengthens (or with a negative value
    /// shortens) every row at both ends.
    public static func fill(_ polys: [Polyline], angle: Double, spacing: Double, stitchLength: Double,
                            extend: Double, from start: Vec2) -> [[Vec2]] {
        guard spacing > 0.05, stitchLength > 0.2 else { return [] }
        let rad = angle * .pi / 180
        let rotated = polys.map { Polyline($0.points.map { $0.rotated(by: -rad) }, closed: true) }
        let b = rotated.bounds
        guard !b.isEmpty else { return [] }

        // Scanline intersections.
        var edges: [(Vec2, Vec2)] = []
        for p in rotated where p.points.count > 2 {
            for i in 0..<p.points.count {
                let a = p.points[i], c = p.points[(i + 1) % p.points.count]
                if a.y != c.y { edges.append((a, c)) }
            }
        }
        var rows: [[FillRow]] = []
        var y = b.minY + spacing / 2
        var r = 0
        while y < b.maxY {
            var xs: [Double] = []
            for (a, c) in edges {
                let lo = min(a.y, c.y), hi = max(a.y, c.y)
                if y >= lo && y < hi { xs.append(a.x + (y - a.y) * (c.x - a.x) / (c.y - a.y)) }
            }
            xs.sort()
            var segs: [FillRow] = []
            var i = 0
            while i + 1 < xs.count {
                let x0 = xs[i] - extend, x1 = xs[i + 1] + extend
                if x1 - x0 > 0.3 { segs.append(FillRow(row: r, y: y, x0: x0, x1: x1)) }
                i += 2
            }
            rows.append(segs)
            y += spacing
            r += 1
        }

        // Chain overlapping segments on neighbouring rows into regions that can be sewn back and forth.
        var used = rows.map { [Bool](repeating: false, count: $0.count) }
        var regions: [[FillRow]] = []
        for ri in rows.indices {
            for si in rows[ri].indices where !used[ri][si] {
                used[ri][si] = true
                var chain = [rows[ri][si]]
                var cur = rows[ri][si]
                var next = ri + 1
                while next < rows.count {
                    guard let k = rows[next].indices.first(where: { !used[next][$0] && rows[next][$0].x0 < cur.x1 && rows[next][$0].x1 > cur.x0 })
                    else { break }
                    used[next][k] = true
                    cur = rows[next][k]
                    chain.append(cur)
                    next += 1
                }
                regions.append(chain)
            }
        }

        func inside(_ p: Vec2) -> Bool { rotated.filter { Planner.contains($0, p) }.count % 2 == 1 }

        // Sew regions nearest-first, entering each at whichever corner is closest.
        var runs: [[Vec2]] = []
        var pos = start.rotated(by: -rad)
        while !regions.isEmpty {
            var best = (index: 0, reverse: false, leftFirst: true, dist: Double.infinity)
            for (i, reg) in regions.enumerated() {
                for reverse in [false, true] {
                    let row = reverse ? reg[reg.count - 1] : reg[0]
                    let dl = Vec2(row.x0, row.y).distance(to: pos), dr = Vec2(row.x1, row.y).distance(to: pos)
                    if dl < best.dist { best = (i, reverse, true, dl) }
                    if dr < best.dist { best = (i, reverse, false, dr) }
                }
            }
            var reg = regions.remove(at: best.index)
            if best.reverse { reg.reverse() }
            var run: [Vec2] = []
            var leftToRight = best.leftFirst
            for row in reg {
                let from = leftToRight ? row.x0 : row.x1, to = leftToRight ? row.x1 : row.x0
                let pts = tatamiRow(from: from, to: to, y: row.y, row: row.row, length: stitchLength)
                if let last = run.last, let first = pts.first {
                    // Connect along the edge when the link stays inside the shape; otherwise start a new run.
                    let link = [0.25, 0.5, 0.75].map { last + (first - last) * $0 }
                    if last.distance(to: first) <= spacing * 1.5 || link.allSatisfy(inside) {
                        run += split(from: last, to: first, max: stitchLength).dropFirst()
                        run += pts.dropFirst()
                    } else {
                        runs.append(run)
                        run = pts
                    }
                } else {
                    run += pts
                }
                leftToRight.toggle()
            }
            if !run.isEmpty { runs.append(run) }
            pos = runs.last?.last ?? pos
        }
        return runs.map { $0.map { $0.rotated(by: rad) } }
    }

    /// Stitch points along one fill row. Stitches fall on a grid shifted by a third each row, so the needle
    /// holes make a brick pattern instead of lines.
    static func tatamiRow(from: Double, to: Double, y: Double, row: Int, length: Double) -> [Vec2] {
        let dir: Double = to >= from ? 1 : -1
        var pts = [Vec2(from, y)]
        let shift = Double(((row % 3) + 3) % 3) / 3 * length
        let lo = min(from, to), hi = max(from, to)
        var grid: [Double] = []
        var g = (floor((lo - shift) / length) + 1) * length + shift
        while g < hi {
            if g - lo > length * 0.3 && hi - g > length * 0.3 { grid.append(g) }
            g += length
        }
        if dir < 0 { grid.reverse() }
        pts += grid.map { Vec2($0, y) }
        pts.append(Vec2(to, y))
        // Skipping a grid point next to an end can leave a long stitch; split it.
        var out = [pts[0]]
        for p in pts.dropFirst() { out += split(from: out[out.count - 1], to: p, max: length).dropFirst() }
        return out
    }

    /// Points from `a` to `b` (both included) no more than `max` apart.
    static func split(from a: Vec2, to b: Vec2, max: Double) -> [Vec2] {
        let d = a.distance(to: b)
        let n = Swift.max(1, Int((d / max).rounded(.up)))
        return (0...n).map { a + (b - a) * (Double($0) / Double(n)) }
    }

    // MARK: Path helpers

    static func arcLength(_ pts: [Vec2]) -> Double {
        var total = 0.0
        for i in pts.indices.dropFirst() { total += pts[i].distance(to: pts[i - 1]) }
        return total
    }

    static func point(on pts: [Vec2], at distance: Double) -> Vec2 {
        guard var prev = pts.first else { return .zero }
        var left = distance
        for p in pts.dropFirst() {
            let seg = p.distance(to: prev)
            if left <= seg, seg > 0 { return prev + (p - prev) * (left / seg) }
            left -= seg
            prev = p
        }
        return pts[pts.count - 1]
    }
}

// MARK: - Hoops

/// An embroidery hoop's sewing area.
public struct EmbroideryHoop: Hashable, Sendable, Identifiable {
    public var name: String
    public var brand: String
    /// Sewing area in mm.
    public var width: Double
    public var height: Double

    public var id: String { name }

    public init(_ name: String, brand: String, width: Double, height: Double) {
        self.name = name
        self.brand = brand
        self.width = width
        self.height = height
    }

    /// True when a design of this size fits, as it is or turned 90°.
    public func fits(width w: Double, height h: Double) -> Bool {
        (w <= width + 1e-6 && h <= height + 1e-6) || (w <= height + 1e-6 && h <= width + 1e-6)
    }

    /// True only when the design fits without turning it.
    public func fitsUpright(width w: Double, height h: Double) -> Bool {
        w <= width + 1e-6 && h <= height + 1e-6
    }

    public static let brother: [EmbroideryHoop] = [
        EmbroideryHoop("Brother 4 × 4 in (100 × 100 mm)", brand: "Brother", width: 100, height: 100),
        EmbroideryHoop("Brother 5 × 7 in (130 × 180 mm)", brand: "Brother", width: 130, height: 180),
        EmbroideryHoop("Brother 6 × 10 in (160 × 260 mm)", brand: "Brother", width: 160, height: 260),
        EmbroideryHoop("Brother 8 × 12 in (200 × 300 mm)", brand: "Brother", width: 200, height: 300),
    ]

    public static let janome: [EmbroideryHoop] = [
        EmbroideryHoop("Janome C (50 × 50 mm)", brand: "Janome", width: 50, height: 50),
        EmbroideryHoop("Janome A (126 × 110 mm)", brand: "Janome", width: 126, height: 110),
        EmbroideryHoop("Janome SQ14 (140 × 140 mm)", brand: "Janome", width: 140, height: 140),
        EmbroideryHoop("Janome B (140 × 200 mm)", brand: "Janome", width: 140, height: 200),
        EmbroideryHoop("Janome RE20 (170 × 200 mm)", brand: "Janome", width: 170, height: 200),
        EmbroideryHoop("Janome SQ20 (200 × 200 mm)", brand: "Janome", width: 200, height: 200),
        EmbroideryHoop("Janome RE28 (200 × 280 mm)", brand: "Janome", width: 200, height: 280),
    ]

    public static let all: [EmbroideryHoop] = brother + janome
}
