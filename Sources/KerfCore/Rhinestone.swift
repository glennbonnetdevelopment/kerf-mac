import Foundation

// Rhinestone layout: stones placed along outlines and filling areas, cut as holes in template material
// (flock, sticky flex or rubber) on a vinyl cutter or laser. Stones are brushed into the holes, picked up
// with transfer tape and pressed onto the garment, so the template reads the same way as the finished design.

/// A rhinestone size: the jewellery "SS" (stone size) number and a typical diameter for flat-back hotfix stones.
public struct StoneSize: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    /// Stone diameter in mm.
    public var diameter: Double

    public init(name: String, diameter: Double) {
        self.name = name
        self.diameter = diameter
    }

    public var id: String { name }
    public var radius: Double { diameter / 2 }
    /// "SS10 (2.8 mm)".
    public var title: String { "\(name) (\(String(format: "%.1f", diameter)) mm)" }

    public static let ss6 = StoneSize(name: "SS6", diameter: 2.0)
    public static let ss8 = StoneSize(name: "SS8", diameter: 2.4)
    public static let ss10 = StoneSize(name: "SS10", diameter: 2.8)
    public static let ss12 = StoneSize(name: "SS12", diameter: 3.1)
    public static let ss16 = StoneSize(name: "SS16", diameter: 3.9)
    public static let ss20 = StoneSize(name: "SS20", diameter: 4.7)

    /// The sizes offered, smallest first.
    public static let all: [StoneSize] = [.ss6, .ss8, .ss10, .ss12, .ss16, .ss20]
}

/// A stone colour. Each colour and size becomes its own layer, so each can be cut as a separate template.
public struct StoneColor: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    /// Colour shown on the canvas and given to the stone's layer, "#RRGGBB".
    public var hex: String

    public init(name: String, hex: String) {
        self.name = name
        self.hex = hex
    }

    public var id: String { name }

    public static let crystal = StoneColor(name: "Crystal", hex: "#7FA7C9")
    public static let jet = StoneColor(name: "Jet", hex: "#262626")

    public static let palette: [StoneColor] = [
        .crystal,
        StoneColor(name: "Crystal AB", hex: "#A98FD6"),
        .jet,
        StoneColor(name: "Siam (red)", hex: "#C8102E"),
        StoneColor(name: "Rose (pink)", hex: "#E26A9C"),
        StoneColor(name: "Topaz (amber)", hex: "#D08A2B"),
        StoneColor(name: "Gold", hex: "#B8951E"),
        StoneColor(name: "Peridot (green)", hex: "#7FB43A"),
        StoneColor(name: "Emerald", hex: "#138A4F"),
        StoneColor(name: "Aquamarine", hex: "#3FB5CF"),
        StoneColor(name: "Sapphire", hex: "#1F4E9C"),
        StoneColor(name: "Amethyst", hex: "#8350A8"),
    ]
}

/// How the inside of closed shapes is filled with stones.
public enum RhinestoneFill: String, Codable, CaseIterable, Sendable, Identifiable {
    /// No fill: only the outline rows.
    case none
    /// Staggered rows, each stone touching six neighbours: the densest, most even fill.
    case honeycomb
    /// Square rows and columns.
    case grid
    /// Rows that follow the outline inwards, like rings.
    case contour

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None (outline only)"
        case .honeycomb: return "Honeycomb (staggered rows)"
        case .grid: return "Grid (square rows)"
        case .contour: return "Contour (rows follow the outline)"
        }
    }
}

/// Where the outline stones sit.
public enum RhinestoneOutlinePosition: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Just inside the outline, so the stones stay within the shape.
    case inside
    /// Centred on the outline (also used for open lines).
    case onLine

    public var id: String { rawValue }
    public var title: String { self == .inside ? "Inside the outline" : "Centred on the outline" }
}

/// What happens to the shapes the stones were laid out on.
public enum RhinestoneOriginal: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Moved to a Print-only guide layer, shown on the canvas but never cut.
    case guide
    /// Left where they are (they are cut with their layer).
    case keep
    /// Removed.
    case delete

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .guide: return "Move to a guide layer (not cut)"
        case .keep: return "Keep on its layer"
        case .delete: return "Delete"
        }
    }
}

/// Settings for a rhinestone layout.
public struct RhinestoneOptions: Codable, Hashable, Sendable {
    public var outline: Bool
    public var outlineSize: StoneSize
    public var outlineColor: StoneColor
    /// Rows of outline stones, 1 or more, each one further in.
    public var outlineRows: Int
    public var outlinePosition: RhinestoneOutlinePosition

    public var fill: RhinestoneFill
    public var fillSize: StoneSize
    public var fillColor: StoneColor
    /// Angle of honeycomb and grid rows, degrees.
    public var fillAngle: Double

    /// After the fill, put smaller stones in the gaps left near edges and corners.
    public var gapFill: Bool
    public var gapFillSize: StoneSize
    public var gapFillColor: StoneColor

    /// Space between neighbouring stones, edge to edge, in mm.
    public var spacing: Double
    /// How much bigger than the stone each template hole is cut, in mm (on the diameter).
    public var holeClearance: Double
    public var original: RhinestoneOriginal

    public init(outline: Bool = true, outlineSize: StoneSize = .ss10, outlineColor: StoneColor = .crystal,
                outlineRows: Int = 1, outlinePosition: RhinestoneOutlinePosition = .inside,
                fill: RhinestoneFill = .honeycomb, fillSize: StoneSize = .ss10, fillColor: StoneColor = .crystal,
                fillAngle: Double = 0, gapFill: Bool = false, gapFillSize: StoneSize = .ss6,
                gapFillColor: StoneColor = .crystal, spacing: Double = 1.0, holeClearance: Double = 0.2,
                original: RhinestoneOriginal = .guide) {
        self.outline = outline
        self.outlineSize = outlineSize
        self.outlineColor = outlineColor
        self.outlineRows = outlineRows
        self.outlinePosition = outlinePosition
        self.fill = fill
        self.fillSize = fillSize
        self.fillColor = fillColor
        self.fillAngle = fillAngle
        self.gapFill = gapFill
        self.gapFillSize = gapFillSize
        self.gapFillColor = gapFillColor
        self.spacing = spacing
        self.holeClearance = holeClearance
        self.original = original
    }

    private enum CodingKeys: String, CodingKey {
        case outline, outlineSize, outlineColor, outlineRows, outlinePosition, fill, fillSize, fillColor, fillAngle,
             gapFill, gapFillSize, gapFillColor, spacing, holeClearance, original
    }

    /// Missing keys fall back to defaults so saved settings survive new options.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RhinestoneOptions()
        outline = try c.decodeIfPresent(Bool.self, forKey: .outline) ?? d.outline
        outlineSize = try c.decodeIfPresent(StoneSize.self, forKey: .outlineSize) ?? d.outlineSize
        outlineColor = try c.decodeIfPresent(StoneColor.self, forKey: .outlineColor) ?? d.outlineColor
        outlineRows = try c.decodeIfPresent(Int.self, forKey: .outlineRows) ?? d.outlineRows
        outlinePosition = try c.decodeIfPresent(RhinestoneOutlinePosition.self, forKey: .outlinePosition) ?? d.outlinePosition
        fill = try c.decodeIfPresent(RhinestoneFill.self, forKey: .fill) ?? d.fill
        fillSize = try c.decodeIfPresent(StoneSize.self, forKey: .fillSize) ?? d.fillSize
        fillColor = try c.decodeIfPresent(StoneColor.self, forKey: .fillColor) ?? d.fillColor
        fillAngle = try c.decodeIfPresent(Double.self, forKey: .fillAngle) ?? d.fillAngle
        gapFill = try c.decodeIfPresent(Bool.self, forKey: .gapFill) ?? d.gapFill
        gapFillSize = try c.decodeIfPresent(StoneSize.self, forKey: .gapFillSize) ?? d.gapFillSize
        gapFillColor = try c.decodeIfPresent(StoneColor.self, forKey: .gapFillColor) ?? d.gapFillColor
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? d.spacing
        holeClearance = try c.decodeIfPresent(Double.self, forKey: .holeClearance) ?? d.holeClearance
        original = try c.decodeIfPresent(RhinestoneOriginal.self, forKey: .original) ?? d.original
    }

    /// Template material left between two holes at the closest spacing the layout allows, in mm.
    public var narrowestWeb: Double { max(0, spacing) * Rhinestone.minimumGapFraction - holeClearance }
}

/// Which part of the layout a stone belongs to.
public enum StoneRole: Int, Hashable, Sendable {
    case outline, fill, gap
}

/// One placed stone, in bed millimetres.
public struct Stone: Hashable, Sendable {
    public var center: Vec2
    public var size: StoneSize
    public var color: StoneColor
    public var role: StoneRole

    public init(center: Vec2, size: StoneSize, color: StoneColor, role: StoneRole) {
        self.center = center
        self.size = size
        self.color = color
        self.role = role
    }

    public var radius: Double { size.radius }
}

/// Stones of one size and colour: one template layer.
public struct StoneGroup: Hashable, Sendable, Identifiable {
    public var size: StoneSize
    public var color: StoneColor
    public var stones: [Stone]

    public var id: String { "\(size.name) \(color.name)" }
    public var title: String { "\(size.name) \(color.name)" }
}

public enum Rhinestone {
    /// Neighbouring stones may come this close, as a fraction of the spacing (corners and curves bunch them up).
    public static let minimumGapFraction = 0.6
    /// The most stones one layout makes.
    public static let maxStones = 30000

    /// Lays out stones on `paths` (bed coordinates). Closed paths are areas (even-odd, so letter counters stay
    /// empty); open paths only get a row of stones along them.
    public static func layout(_ input: [Polyline], options o: RhinestoneOptions) -> [Stone] {
        let paths = input.map { $0.deduplicated() }.filter { $0.points.count >= 2 && $0.length > 1e-6 }
        guard !paths.isEmpty else { return [] }
        let closed = paths.filter { $0.closed && $0.points.count >= 3 }
        let open = paths.filter { !($0.closed && $0.points.count >= 3) }
        let gap = max(0, o.spacing)
        let sizes = [o.outlineSize, o.fillSize, o.gapFillSize]
        let biggest = sizes.map(\.diameter).max() ?? 3
        let bounds = paths.bounds
        var placer = Placer(cell: biggest + gap + 0.01, minGap: gap * minimumGapFraction)
        let edges = EdgeIndex(paths, cell: max(biggest + gap, max(bounds.width, bounds.height) / 400))

        // How far in from the outline the next row of stones starts (centre line), and the stone before it.
        var nextInset: Double? = nil

        // Outline rows.
        if o.outline {
            let s = o.outlineSize
            let pitch = s.diameter + gap
            let start = o.outlinePosition == .inside ? s.radius : 0
            for row in 0..<max(1, min(50, o.outlineRows)) {
                let inset = start + Double(row) * pitch
                // An exact inset keeps sharp corners (so corners get stones) and the true length of each side.
                let curves = inset < 1e-6 ? closed : closed.compactMap { insetLoop($0, by: inset, edges: edges) }
                let before = placer.stones.count
                // Open lines can't be inset: they get one row centred on the line.
                if row == 0 {
                    for c in open {
                        placeAlong(c, pitch: pitch, size: s, color: o.outlineColor, role: .outline, edges: nil, placer: &placer)
                    }
                }
                if curves.isEmpty { break }
                for c in curves {
                    placeAlong(c, pitch: pitch, size: s, color: o.outlineColor, role: .outline,
                               edges: inset > 1e-6 ? edges : nil, placer: &placer)
                }
                if row > 0 && placer.stones.count == before { break }
                nextInset = inset + s.radius + gap
            }
        }

        // Fill.
        if o.fill != .none, !closed.isEmpty {
            let s = o.fillSize
            let pitch = s.diameter + gap
            switch o.fill {
            case .none:
                break
            case .contour:
                var inset = (nextInset ?? 0) + s.radius
                var rows = 0
                while rows < 500, placer.stones.count < maxStones {
                    let curves = StyleGeometry.offset(closed, by: -inset)
                    if curves.isEmpty { break }
                    for c in curves {
                        placeAlong(c, pitch: pitch, size: s, color: o.fillColor, role: .fill, edges: edges, placer: &placer)
                    }
                    inset += pitch
                    rows += 1
                }
            case .honeycomb, .grid:
                latticeFill(bounds: bounds, pitch: pitch, rowStep: o.fill == .honeycomb ? pitch * 3.0.squareRoot() / 2 : pitch,
                            stagger: o.fill == .honeycomb, angle: o.fillAngle * .pi / 180, size: s, color: o.fillColor,
                            role: .fill, edges: edges, placer: &placer)
            }

            // Smaller stones in the gaps.
            if o.gapFill {
                let g = o.gapFillSize
                let step = max(0.3, g.radius * 0.6)
                latticeFill(bounds: bounds, pitch: step, rowStep: step, stagger: false, angle: 0, size: g,
                            color: o.gapFillColor, role: .gap, edges: edges, placer: &placer)
            }
        }
        return placer.stones
    }

    /// `layout`, remembering the last result so a live preview can redraw every frame.
    public static func cachedLayout(_ paths: [Polyline], options: RhinestoneOptions) -> [Stone] {
        cache.get(paths, options) ?? {
            let stones = layout(paths, options: options)
            cache.set(paths, options, stones)
            return stones
        }()
    }

    /// Stones grouped by size and colour, in the order each group first appears (outline before fill).
    public static func groups(_ stones: [Stone]) -> [StoneGroup] {
        var out: [StoneGroup] = []
        var index: [String: Int] = [:]
        for s in stones {
            let key = "\(s.size.name)|\(s.size.diameter)|\(s.color.name)"
            if let i = index[key] {
                out[i].stones.append(s)
            } else {
                index[key] = out.count
                out.append(StoneGroup(size: s.size, color: s.color, stones: [s]))
            }
        }
        return out
    }

    /// One closed circle per stone: the template hole, `clearance` mm wider than the stone.
    public static func holes(_ stones: [Stone], clearance: Double) -> [Polyline] {
        stones.map { circle($0.center, radius: max(0.05, ($0.size.diameter + clearance) / 2)) }
    }

    static func circle(_ c: Vec2, radius r: Double) -> Polyline {
        let n = max(16, min(64, Int((2 * .pi * r / 0.25).rounded(.up))))
        return Polyline((0..<n).map { k in
            let a = 2 * Double.pi * Double(k) / Double(n)
            return Vec2(c.x + r * cos(a), c.y + r * sin(a))
        }, closed: true)
    }

    // MARK: - Placement

    /// Evenly spaced stones along a curve. Closed loops start at their sharpest corner so corners get a stone;
    /// loops too small for three stones get one stone in the middle (the dot of an i).
    static func placeAlong(_ curve: Polyline, pitch: Double, size: StoneSize, color: StoneColor, role: StoneRole,
                           edges: EdgeIndex?, placer: inout Placer) {
        let length = curve.length
        guard length > 1e-6, pitch > 1e-6 else { return }
        func tryPlace(_ p: Vec2) {
            if let edges, !edges.inside(p) || edges.distance(p, limit: size.radius) < size.radius * 0.7 { return }
            _ = placer.place(Stone(center: p, size: size, color: color, role: role))
        }
        if curve.closed {
            if length < pitch * 3 {
                let b = curve.bounds
                tryPlace(b.center)
                return
            }
            let loop = curve.rotatedStart(to: sharpestCorner(curve))
            let n = max(3, Int((length / pitch).rounded(.down)))
            let step = length / Double(n)
            let points = pointsAlong(loop.drawnPoints, every: step, count: n)
            for p in points { tryPlace(p) }
        } else {
            if length < pitch {
                tryPlace(point(on: curve.points, at: length / 2))
                return
            }
            let n = max(1, Int((length / pitch).rounded(.down)))
            let step = length / Double(n)
            for p in pointsAlong(curve.points, every: step, count: n + 1) { tryPlace(p) }
        }
    }

    /// `loop` moved `d` mm into the area (even-odd, so a hole's loop moves out into the material), corner by
    /// corner with mitred joins. Very sharp corners are capped. Parts that fold over where the shape is narrower
    /// than `2d` are left to the edge and inside checks when stones are placed.
    static func insetLoop(_ loop: Polyline, by d: Double, edges: EdgeIndex) -> Polyline? {
        let pts = loop.deduplicated().points
        let n = pts.count
        guard n >= 3 else { return nil }
        // Which side is inside: test just off the middle of the longest edge.
        var longest = 0
        for i in 0..<n where pts[i].distance(to: pts[(i + 1) % n]) > pts[longest].distance(to: pts[(longest + 1) % n]) {
            longest = i
        }
        let a = pts[longest], b = pts[(longest + 1) % n]
        let left = Vec2(-(b - a).y, (b - a).x).normalized
        let probe = min(0.05, a.distance(to: b) * 0.01, d * 0.5)
        let sign: Double = edges.inside((a + b) / 2 + left * probe) ? 1 : -1
        var out: [Vec2] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let prev = pts[(i - 1 + n) % n], cur = pts[i], next = pts[(i + 1) % n]
            let e1 = (cur - prev).normalized, e2 = (next - cur).normalized
            let n1 = Vec2(-e1.y, e1.x) * sign, n2 = Vec2(-e2.y, e2.x) * sign
            let sum = n1 + n2
            let len = sum.length
            guard len > 1e-9 else {
                out.append(cur + n1 * d)
                continue
            }
            let bis = sum / len
            let cosHalf = max(1e-9, bis.dot(n1))
            let miter = d / cosHalf
            if miter <= d * 3 {
                out.append(cur + bis * miter)
            } else {
                // Too sharp to mitre: two points, one off each side.
                out.append(cur + n1 * d)
                out.append(cur + n2 * d)
            }
        }
        return Polyline(out, closed: true)
    }

    /// Index of the point where a closed loop turns the most.
    static func sharpestCorner(_ p: Polyline) -> Int {
        let pts = p.points
        let n = pts.count
        guard n >= 3 else { return 0 }
        var best = 0, bestTurn = 0.0
        for i in 0..<n {
            let a = pts[(i - 1 + n) % n], b = pts[i], c = pts[(i + 1) % n]
            let u = (b - a).normalized, v = (c - b).normalized
            let turn = acos(max(-1, min(1, u.dot(v))))
            if turn > bestTurn {
                bestTurn = turn
                best = i
            }
        }
        // Gentle curves have no real corner; any start looks the same.
        return bestTurn > 0.5 ? best : 0
    }

    /// `count` points along `pts`, `step` apart by arc length, starting at the first point.
    static func pointsAlong(_ pts: [Vec2], every step: Double, count: Int) -> [Vec2] {
        guard let first = pts.first, count > 0 else { return [] }
        var out = [first]
        var target = step
        var walked = 0.0
        var i = 1
        while out.count < count, i < pts.count {
            let a = pts[i - 1], b = pts[i]
            let seg = a.distance(to: b)
            if seg > 1e-12, walked + seg >= target - 1e-9 {
                let t = min(1, max(0, (target - walked) / seg))
                out.append(a + (b - a) * t)
                target += step
                continue
            }
            walked += seg
            i += 1
        }
        if out.count < count, let last = pts.last, out.last.map({ $0.distance(to: last) > step * 0.5 }) ?? true {
            out.append(last)
        }
        return out
    }

    static func point(on pts: [Vec2], at s: Double) -> Vec2 {
        pointsAlong(pts, every: max(1e-9, s), count: 2).last ?? pts.first ?? .zero
    }

    /// Stones on a lattice (rotated by `angle` about the middle of `bounds`), wherever one fits inside the area.
    static func latticeFill(bounds: Rect2, pitch: Double, rowStep: Double, stagger: Bool, angle: Double,
                            size: StoneSize, color: StoneColor, role: StoneRole, edges: EdgeIndex, placer: inout Placer) {
        guard pitch > 1e-6, rowStep > 1e-6, !bounds.isEmpty else { return }
        let centre = bounds.center
        let reach = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() / 2 + pitch
        let rows = Int((reach / rowStep).rounded(.up)), cols = Int((reach / pitch).rounded(.up)) + 1
        let grown = bounds.insetBy(-pitch)
        let r = size.radius
        for j in -rows...rows {
            let shift = stagger && (j & 1) != 0 ? pitch / 2 : 0
            for i in -cols...cols {
                if placer.stones.count >= maxStones { return }
                let q = Vec2(Double(i) * pitch + shift, Double(j) * rowStep)
                let p = centre + (angle == 0 ? q : q.rotated(by: angle))
                guard grown.contains(p) else { continue }
                let stone = Stone(center: p, size: size, color: color, role: role)
                guard placer.fits(stone), edges.inside(p), edges.distance(p, limit: r) >= r - 1e-6 else { continue }
                placer.place(stone)
            }
        }
    }

    /// Placed stones, with a spatial hash so each new stone is checked against its neighbours only.
    struct Placer {
        let cell: Double
        let minGap: Double
        var stones: [Stone] = []
        var buckets: [Key: [Int]] = [:]

        struct Key: Hashable {
            var x: Int
            var y: Int
        }

        init(cell: Double, minGap: Double) {
            self.cell = max(0.1, cell)
            self.minGap = minGap
        }

        func key(_ p: Vec2) -> Key { Key(x: Int((p.x / cell).rounded(.down)), y: Int((p.y / cell).rounded(.down))) }

        func fits(_ s: Stone) -> Bool {
            let k = key(s.center)
            for dy in -1...1 {
                for dx in -1...1 {
                    guard let list = buckets[Key(x: k.x + dx, y: k.y + dy)] else { continue }
                    for i in list {
                        let o = stones[i]
                        if o.center.distance(to: s.center) < o.radius + s.radius + minGap - 1e-6 { return false }
                    }
                }
            }
            return true
        }

        @discardableResult
        mutating func place(_ s: Stone) -> Bool {
            guard stones.count < Rhinestone.maxStones, fits(s) else { return false }
            buckets[key(s.center), default: []].append(stones.count)
            stones.append(s)
            return true
        }
    }

    /// Outline segments on a grid for quick "how far to the nearest edge" and "is this inside" questions.
    struct EdgeIndex {
        var segments: [(Vec2, Vec2)] = []
        var closedSegments: [(Vec2, Vec2)] = []
        let origin: Vec2
        let cell: Double
        let cols: Int
        let rows: Int
        /// Segment indices per grid cell.
        var cells: [[Int]]
        /// Closed-outline segment indices per row band, for the even-odd inside test.
        var bands: [[Int]]

        init(_ paths: [Polyline], cell wanted: Double) {
            let b = paths.bounds.insetBy(-1)
            let size = max(b.width, b.height, 1)
            let c = max(wanted, size / 512, 0.05)
            origin = Vec2(b.minX, b.minY)
            cell = c
            cols = max(1, Int((b.width / c).rounded(.up)))
            rows = max(1, Int((b.height / c).rounded(.up)))
            cells = Array(repeating: [], count: cols * rows)
            bands = Array(repeating: [], count: rows)
            for p in paths {
                let pts = p.drawnPoints
                let isClosed = p.closed && p.points.count >= 3
                for i in pts.indices.dropFirst() {
                    let a = pts[i - 1], z = pts[i]
                    let idx = segments.count
                    segments.append((a, z))
                    let x0 = col(min(a.x, z.x)), x1 = col(max(a.x, z.x))
                    let y0 = row(min(a.y, z.y)), y1 = row(max(a.y, z.y))
                    for y in y0...y1 {
                        for x in x0...x1 { cells[y * cols + x].append(idx) }
                    }
                    if isClosed {
                        let ci = closedSegments.count
                        closedSegments.append((a, z))
                        for y in y0...y1 { bands[y].append(ci) }
                    }
                }
            }
        }

        func col(_ x: Double) -> Int { max(0, min(cols - 1, Int(((x - origin.x) / cell).rounded(.down)))) }
        func row(_ y: Double) -> Int { max(0, min(rows - 1, Int(((y - origin.y) / cell).rounded(.down)))) }

        /// Distance from `p` to the nearest outline, or `limit` when nothing is that close.
        func distance(_ p: Vec2, limit: Double) -> Double {
            var best = limit
            let x0 = col(p.x - limit), x1 = col(p.x + limit), y0 = row(p.y - limit), y1 = row(p.y + limit)
            for y in y0...y1 {
                for x in x0...x1 {
                    for i in cells[y * cols + x] {
                        let (a, b) = segments[i]
                        best = min(best, EdgeIndex.segmentDistance(p, a, b))
                    }
                }
            }
            return best
        }

        /// Even-odd: inside an odd number of closed outlines.
        func inside(_ p: Vec2) -> Bool {
            let y = Int(((p.y - origin.y) / cell).rounded(.down))
            guard y >= 0, y < rows else { return false }
            var crossings = 0
            for i in bands[y] {
                let (a, b) = closedSegments[i]
                guard (a.y <= p.y) != (b.y <= p.y) else { continue }
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if x > p.x { crossings += 1 }
            }
            return crossings % 2 == 1
        }

        static func segmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            let ab = b - a
            let len2 = ab.dot(ab)
            guard len2 > 1e-18 else { return p.distance(to: a) }
            let t = max(0, min(1, (p - a).dot(ab) / len2))
            return p.distance(to: a + ab * t)
        }
    }

    // MARK: - Cache

    final class Cache: @unchecked Sendable {
        private var key: ([Polyline], RhinestoneOptions)?
        private var value: [Stone] = []
        private let lock = NSLock()

        func get(_ paths: [Polyline], _ options: RhinestoneOptions) -> [Stone]? {
            lock.lock(); defer { lock.unlock() }
            guard let key, key.1 == options, key.0 == paths else { return nil }
            return value
        }

        func set(_ paths: [Polyline], _ options: RhinestoneOptions, _ stones: [Stone]) {
            lock.lock(); defer { lock.unlock() }
            key = (paths, options)
            value = stones
        }
    }

    static let cache = Cache()
}
