import Foundation

/// Settings for cutting a sign that is bigger than the cutter as overlapping panels (tiling).
public struct PanelOptions: Codable, Hashable, Sendable {
    /// Split the job into panels when it doesn't fit the machine.
    public var enabled: Bool
    /// Largest panel width across the media (design X), mm. 0 uses the machine's bed width.
    /// Never more than the bed width.
    public var maxWidth: Double
    /// Largest panel length along the media (design Y), mm. 0 uses the machine's bed height.
    public var maxHeight: Double
    /// How far neighbouring panels overlap, mm, so the pieces can be laid with no gap.
    public var overlap: Double
    /// Cut small crosshair alignment marks in the overlaps, at the same spot on both panels.
    public var marks: Bool
    /// Width of each alignment crosshair, mm.
    public var markSize: Double

    public init(enabled: Bool = false, maxWidth: Double = 0, maxHeight: Double = 0, overlap: Double = 12,
                marks: Bool = true, markSize: Double = 10) {
        self.enabled = enabled
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.overlap = overlap
        self.marks = marks
        self.markSize = markSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PanelOptions()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth) ?? d.maxWidth
        maxHeight = try c.decodeIfPresent(Double.self, forKey: .maxHeight) ?? d.maxHeight
        overlap = try c.decodeIfPresent(Double.self, forKey: .overlap) ?? d.overlap
        marks = try c.decodeIfPresent(Bool.self, forKey: .marks) ?? d.marks
        markSize = try c.decodeIfPresent(Double.self, forKey: .markSize) ?? d.markSize
    }

    /// The panel width actually used on `profile`.
    public func panelWidth(for profile: DeviceProfile) -> Double {
        maxWidth > 0 ? min(maxWidth, profile.bedWidth) : profile.bedWidth
    }

    /// The panel length actually used on `profile`. It may be longer than the bed on roll-fed cutters.
    public func panelHeight(for profile: DeviceProfile) -> Double {
        maxHeight > 0 ? maxHeight : profile.bedHeight
    }
}

/// One piece of a tiled job.
public struct Panel: Hashable, Sendable, Identifiable {
    /// Position in cutting order (row by row, left to right).
    public var index: Int
    /// Row from the top (0 = A) and column from the left (0 = 1).
    public var row: Int
    public var column: Int
    /// The part of the design this panel cuts, overlaps included, in design space.
    public var rect: Rect2

    public var id: Int { index }

    /// "A1" for the top-left panel, "A2" to its right, "B1" below it.
    public var name: String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let rowName = row < letters.count ? String(letters[row]) : "R\(row + 1)-"
        return "\(rowName)\(column + 1)"
    }
}

/// How a job is split into panels.
public struct PanelLayout: Hashable, Sendable {
    public var panels: [Panel]
    public var rows: Int
    public var columns: Int
    /// The area the panels cover.
    public var area: Rect2
    /// Centres of the alignment crosshairs, in design space.
    public var marks: [Vec2]
    public var markSize: Double
    /// Seams where no alignment mark could be placed clear of the artwork.
    public var unmarkedSeams: Int

    public init(panels: [Panel] = [], rows: Int = 0, columns: Int = 0, area: Rect2 = .empty, marks: [Vec2] = [],
                markSize: Double = 0, unmarkedSeams: Int = 0) {
        self.panels = panels
        self.rows = rows
        self.columns = columns
        self.area = area
        self.marks = marks
        self.markSize = markSize
        self.unmarkedSeams = unmarkedSeams
    }

    /// True when the job is cut in more than one piece.
    public var isSplit: Bool { panels.count > 1 }

    /// Alignment marks that fall on `panel` (each mark sits in an overlap, so it is on two or more panels).
    public func marks(in panel: Panel) -> [Vec2] {
        let r = panel.rect.insetBy(-1e-6)
        return marks.filter { r.contains($0) }
    }
}

public enum Panels {
    /// Splits the cut layers of `tp` into equal overlapping panels no bigger than the options allow.
    /// A job that already fits gives one panel and no marks.
    public static func layout(for tp: Toolpath, profile: DeviceProfile, options: PanelOptions) -> PanelLayout {
        let paths = cutPaths(tp)
        var bounds = Rect2.empty
        for p in paths { for v in p { bounds.include(v) } }
        guard !bounds.isEmpty else { return PanelLayout() }
        let limitW = max(1, options.panelWidth(for: profile))
        let limitH = max(1, options.panelHeight(for: profile))
        if bounds.width <= limitW + 1e-9 && bounds.height <= limitH + 1e-9 {
            return PanelLayout(panels: [Panel(index: 0, row: 0, column: 0, rect: bounds)], rows: 1, columns: 1, area: bounds)
        }
        let size = max(1, options.markSize)
        // Room around the artwork so the marks at the ends of each seam sit clear of it.
        let pad = options.marks ? markEndInset(size) + markClearance(size) + 0.5 : 0
        let area = bounds.insetBy(-pad)
        let overlap = min(max(0, options.overlap), min(limitW, limitH) / 2)
        let (cols, panelW) = split(area.width, limit: limitW, overlap: overlap)
        let (rows, panelH) = split(area.height, limit: limitH, overlap: overlap)
        var panels: [Panel] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = area.minX + Double(c) * (panelW - overlap)
                let y0 = area.minY + Double(r) * (panelH - overlap)
                // The last panel ends exactly on the area's edge, whatever rounding did.
                let x1 = c == cols - 1 ? area.maxX : x0 + panelW
                let y1 = r == rows - 1 ? area.maxY : y0 + panelH
                panels.append(Panel(index: panels.count, row: r, column: c,
                                    rect: Rect2(minX: x0, minY: y0, maxX: x1, maxY: y1)))
            }
        }
        var layout = PanelLayout(panels: panels, rows: rows, columns: cols, area: area, markSize: size)
        if options.marks {
            (layout.marks, layout.unmarkedSeams) = alignmentMarks(panels: panels, rows: rows, columns: cols,
                                                                 size: size, avoiding: paths)
        }
        return layout
    }

    /// Number of equal panels along a length, and each panel's size with the overlap.
    static func split(_ length: Double, limit: Double, overlap: Double) -> (Int, Double) {
        guard length > limit + 1e-9 else { return (1, length) }
        let n = Int(((length - overlap) / (limit - overlap)).rounded(.up))
        return (max(1, n), (length - overlap) / Double(max(1, n)) + overlap)
    }

    /// Crosshairs along every seam, in the middle of the overlap: near both ends of the seam and then
    /// about every 300 mm, each kept only where it can't touch the artwork or sit inside a shape.
    static func alignmentMarks(panels: [Panel], rows: Int, columns: Int, size: Double,
                               avoiding paths: [[Vec2]]) -> ([Vec2], Int) {
        func panel(_ r: Int, _ c: Int) -> Panel { panels[r * columns + c] }
        var seams: [(Rect2, Bool)] = []
        for r in 0..<rows {
            for c in 0..<max(0, columns - 1) {
                let a = panel(r, c).rect, b = panel(r, c + 1).rect
                seams.append((Rect2(minX: b.minX, minY: a.minY, maxX: a.maxX, maxY: a.maxY), true))
            }
        }
        for r in 0..<max(0, rows - 1) {
            for c in 0..<columns {
                let a = panel(r, c).rect, b = panel(r + 1, c).rect
                seams.append((Rect2(minX: a.minX, minY: b.minY, maxX: a.maxX, maxY: a.maxY), false))
            }
        }
        let clearance = markClearance(size)
        let segments = paths.flatMap { p in p.count < 2 ? [] : (1..<p.count).map { (p[$0 - 1], p[$0]) } }
        // A mark inside any closed shape could cut into a letter or panel of the sign, so those spots are out.
        let closed = paths.filter { $0.count > 3 && $0[0].distance(to: $0[$0.count - 1]) < 1e-6 }
            .map { Polyline(Array($0.dropLast()), closed: true) }
        let closedBounds = closed.map(\.bounds)
        var marks: [Vec2] = []
        var unmarked = 0
        for (seam, vertical) in seams {
            let length = vertical ? seam.height : seam.width
            let end = markEndInset(size)
            guard length > 2 * end else { unmarked += 1; continue }
            let span = length - 2 * end
            let count = max(2, Int((span / 300).rounded(.up)) + 1)
            var placed = false
            for k in 0..<count {
                let t = end + span * Double(k) / Double(count - 1)
                let p = vertical ? Vec2(seam.center.x, seam.minY + t) : Vec2(seam.minX + t, seam.center.y)
                guard isClear(p, of: segments, by: clearance),
                      !closed.indices.contains(where: { closedBounds[$0].contains(p) && Planner.contains(closed[$0], p) })
                else { continue }
                placed = true
                if !marks.contains(where: { $0.distance(to: p) < size }) { marks.append(p) }
            }
            if !placed { unmarked += 1 }
        }
        return (marks, unmarked)
    }

    /// How far the first and last marks sit from the ends of a seam.
    static func markEndInset(_ size: Double) -> Double { size / 2 + 1 }

    /// Smallest distance from a mark's centre to the artwork: the crosshair's reach plus a little.
    static func markClearance(_ size: Double) -> Double { size / 2 * 2.0.squareRoot() + 1.5 }

    static func isClear(_ p: Vec2, of segments: [(Vec2, Vec2)], by distance: Double) -> Bool {
        for (a, b) in segments {
            if min(a.x, b.x) - distance > p.x || max(a.x, b.x) + distance < p.x ||
                min(a.y, b.y) - distance > p.y || max(a.y, b.y) + distance < p.y { continue }
            if pointSegmentDistance(p, a, b) < distance { return false }
        }
        return true
    }

    static func pointSegmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 0 else { return p.distance(to: a) }
        let t = min(1, max(0, (p - a).dot(ab) / len2))
        return p.distance(to: a + ab * t)
    }

    /// A crosshair: two open cuts through `center`.
    public static func crosshair(at center: Vec2, size: Double) -> [[Vec2]] {
        let h = size / 2
        return [[Vec2(center.x - h, center.y), Vec2(center.x + h, center.y)],
                [Vec2(center.x, center.y - h), Vec2(center.x, center.y + h)]]
    }

    /// The job for one panel: the cut layers clipped to the panel, with its alignment marks cut last
    /// using the last layer's settings, optionally mirrored, and moved so the panel starts at the
    /// machine's origin (`inset` mm in from it, for example to leave room for a weeding box).
    public static func toolpath(_ tp: Toolpath, panel: Panel, layout: PanelLayout, profile: DeviceProfile,
                                mirror: OutputMirror = .none, inset: Double = 0) -> Toolpath {
        let rect = panel.rect
        var layers: [ToolpathLayer] = []
        for tl in tp.layers where tl.layer.mode != .fill && tl.layer.mode != .image {
            let clipped = tl.paths.flatMap { clip($0, to: rect) }
            guard !clipped.isEmpty else { continue }
            layers.append(ToolpathLayer(layer: tl.layer, paths: clipped))
        }
        let marks = layout.marks(in: panel)
        if !marks.isEmpty, var markLayer = layers.last?.layer ?? tp.layers.last?.layer {
            markLayer.name = "Panel marks"
            markLayer.passes = 1
            layers.append(ToolpathLayer(layer: markLayer, paths: marks.flatMap { crosshair(at: $0, size: layout.markSize) }.flatMap { clip($0, to: rect) }))
        }
        var move = mirror.transform(about: rect.center)
        // The panel corner nearest the machine origin goes to that origin.
        let origin = profile.fromMachine(.zero)
        let right = origin.x > profile.bedWidth / 2, bottom = origin.y > profile.bedHeight / 2
        let corner = Vec2(right ? rect.maxX : rect.minX, bottom ? rect.maxY : rect.minY)
        let target = Vec2(origin.x + (right ? -inset : inset), origin.y + (bottom ? -inset : inset))
        move = move.then(.translation(target.x - corner.x, target.y - corner.y))
        for i in layers.indices {
            layers[i].paths = layers[i].paths.map { $0.map(move.apply) }
        }
        return Toolpath(layers: layers)
    }

    /// Vector cut paths (what a cutter cuts) of a toolpath.
    static func cutPaths(_ tp: Toolpath) -> [[Vec2]] {
        tp.layers.filter { $0.layer.mode != .fill && $0.layer.mode != .image }.flatMap(\.paths)
    }

    // MARK: - Clipping

    /// The parts of a path inside `rect`. A closed path that crosses the edge comes back as open pieces,
    /// with the piece through its start joined up so the cut isn't broken there.
    public static func clip(_ path: [Vec2], to rect: Rect2) -> [[Vec2]] {
        guard path.count > 1 else { return [] }
        var pieces: [[Vec2]] = []
        var current: [Vec2] = []
        func flush() {
            if current.count > 1, length(current) > 1e-6 { pieces.append(current) }
            current = []
        }
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            guard let range = clipSegment(a, b, to: rect) else {
                flush()
                continue
            }
            let (t0, t1) = range
            let p0 = t0 == 0 ? a : a + (b - a) * t0
            let p1 = t1 == 1 ? b : a + (b - a) * t1
            if current.isEmpty || t0 > 0 {
                flush()
                current = [p0]
            }
            current.append(p1)
            if t1 < 1 { flush() }
        }
        flush()
        let closed = path.count > 2 && path[0].distance(to: path[path.count - 1]) < 1e-6
        if closed, pieces.count > 1, let first = pieces.first, let last = pieces.last,
           first[0] == path[0], let tail = last.last, tail.distance(to: path[path.count - 1]) < 1e-9 {
            pieces[0] = last + first.dropFirst()
            pieces.removeLast()
        }
        return pieces
    }

    /// Liang–Barsky: the parameter range of segment a→b inside `r`, or nil when it misses.
    static func clipSegment(_ a: Vec2, _ b: Vec2, to r: Rect2) -> (Double, Double)? {
        var t0 = 0.0, t1 = 1.0
        let dx = b.x - a.x, dy = b.y - a.y
        let checks: [(Double, Double)] = [(-dx, a.x - r.minX), (dx, r.maxX - a.x), (-dy, a.y - r.minY), (dy, r.maxY - a.y)]
        for (p, q) in checks {
            if p == 0 {
                if q < 0 { return nil }
                continue
            }
            let t = q / p
            if p < 0 {
                if t > t1 { return nil }
                if t > t0 { t0 = t }
            } else {
                if t < t0 { return nil }
                if t < t1 { t1 = t }
            }
        }
        return t0 <= t1 ? (t0, t1) : nil
    }

    static func length(_ p: [Vec2]) -> Double {
        p.count < 2 ? 0 : (1..<p.count).reduce(0) { $0 + p[$1].distance(to: p[$1 - 1]) }
    }
}
