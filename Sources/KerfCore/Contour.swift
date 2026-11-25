import Foundation

/// Builds an outline around artwork at a distance ("contour" or "shadow" cut for print and cut).
/// Works on a grid: the artwork is drawn into a mask, grown by the offset, its holes are filled,
/// and the outer edge is traced and smoothed.
public enum Contour {
    /// A coverage grid in design millimetres.
    public struct Mask: Sendable {
        public var width: Int
        public var height: Int
        /// Design position of the grid's top-left corner and the size of one cell, in mm.
        public var origin: Vec2
        public var cell: Double
        public var cells: [Bool]

        public init(width: Int, height: Int, origin: Vec2, cell: Double, cells: [Bool]? = nil) {
            self.width = width
            self.height = height
            self.origin = origin
            self.cell = cell
            self.cells = cells ?? [Bool](repeating: false, count: width * height)
        }

        public subscript(x: Int, y: Int) -> Bool {
            get { x >= 0 && y >= 0 && x < width && y < height && cells[y * width + x] }
            set { if x >= 0, y >= 0, x < width, y < height { cells[y * width + x] = newValue } }
        }
    }

    /// Picks a grid for `bounds` grown by `margin`, at most `maxCells` on the long side.
    public static func grid(for bounds: Rect2, margin: Double, maxCells: Int = 1600, finest: Double = 0.1) -> Mask {
        let r = bounds.insetBy(-(margin + 1))
        let cell = max(finest, max(r.width, r.height) / Double(maxCells))
        return Mask(width: max(1, Int((r.width / cell).rounded(.up))), height: max(1, Int((r.height / cell).rounded(.up))),
                    origin: Vec2(r.minX, r.minY), cell: cell)
    }

    /// The outer outline(s) of `mask` grown by `offset` mm, smoothed.
    public static func outline(_ mask: Mask, offset: Double, smoothing: Int = 2) -> [Polyline] {
        var m = dilate(mask, by: offset)
        fillHoles(&m)
        return trace(m).map { smooth($0, iterations: smoothing) }
            .map { simplify($0, tolerance: m.cell * 0.4) }
            .filter { $0.points.count > 2 }
    }

    /// Grows the mask by `distance` mm using a two-pass chamfer distance (close to round corners).
    public static func dilate(_ mask: Mask, by distance: Double) -> Mask {
        guard distance > 0 else { return mask }
        let w = mask.width, h = mask.height
        let big = Double.greatestFiniteMagnitude / 4
        var d = mask.cells.map { $0 ? 0.0 : big }
        let a = 1.0, b = 2.0.squareRoot()
        for y in 0..<h {
            for x in 0..<w {
                var v = d[y * w + x]
                if x > 0 { v = min(v, d[y * w + x - 1] + a) }
                if y > 0 {
                    v = min(v, d[(y - 1) * w + x] + a)
                    if x > 0 { v = min(v, d[(y - 1) * w + x - 1] + b) }
                    if x < w - 1 { v = min(v, d[(y - 1) * w + x + 1] + b) }
                }
                d[y * w + x] = v
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                var v = d[y * w + x]
                if x < w - 1 { v = min(v, d[y * w + x + 1] + a) }
                if y < h - 1 {
                    v = min(v, d[(y + 1) * w + x] + a)
                    if x < w - 1 { v = min(v, d[(y + 1) * w + x + 1] + b) }
                    if x > 0 { v = min(v, d[(y + 1) * w + x - 1] + b) }
                }
                d[y * w + x] = v
            }
        }
        let limit = distance / mask.cell
        var out = mask
        out.cells = d.map { $0 <= limit }
        return out
    }

    /// Fills every empty area that can't be reached from the grid's edge.
    public static func fillHoles(_ m: inout Mask) {
        let w = m.width, h = m.height
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func push(_ x: Int, _ y: Int) {
            let i = y * w + x
            if !m.cells[i], !outside[i] { outside[i] = true; stack.append(i) }
        }
        for x in 0..<w { push(x, 0); push(x, h - 1) }
        for y in 0..<h { push(0, y); push(w - 1, y) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { push(x - 1, y) }
            if x < w - 1 { push(x + 1, y) }
            if y > 0 { push(x, y - 1) }
            if y < h - 1 { push(x, y + 1) }
        }
        for i in m.cells.indices where !outside[i] { m.cells[i] = true }
    }

    /// Traces the boundaries between filled and empty cells into closed loops (design mm).
    public static func trace(_ m: Mask) -> [Polyline] {
        // Directed unit edges with the filled cell on the right (y down), keyed by start corner.
        struct P: Hashable { var x: Int; var y: Int }
        var next: [P: [P]] = [:]
        func edge(_ a: P, _ b: P) { next[a, default: []].append(b) }
        for y in 0..<m.height {
            for x in 0..<m.width where m[x, y] {
                if !m[x, y - 1] { edge(P(x: x, y: y), P(x: x + 1, y: y)) }
                if !m[x + 1, y] { edge(P(x: x + 1, y: y), P(x: x + 1, y: y + 1)) }
                if !m[x, y + 1] { edge(P(x: x + 1, y: y + 1), P(x: x, y: y + 1)) }
                if !m[x - 1, y] { edge(P(x: x, y: y + 1), P(x: x, y: y)) }
            }
        }
        var loops: [Polyline] = []
        while let start = next.keys.first {
            var pts: [P] = [start]
            var cur = start
            while let list = next[cur], let n = list.first {
                if list.count == 1 { next[cur] = nil } else { next[cur] = Array(list.dropFirst()) }
                if n == start { break }
                pts.append(n)
                cur = n
            }
            if next[start]?.isEmpty == true { next[start] = nil }
            // Drop the corners in the middle of straight runs.
            var kept: [P] = []
            for (i, p) in pts.enumerated() {
                let prev = pts[(i - 1 + pts.count) % pts.count], nxt = pts[(i + 1) % pts.count]
                if (prev.x == p.x && p.x == nxt.x) || (prev.y == p.y && p.y == nxt.y) { continue }
                kept.append(p)
            }
            if kept.count > 2 {
                loops.append(Polyline(kept.map { Vec2(m.origin.x + Double($0.x) * m.cell, m.origin.y + Double($0.y) * m.cell) }, closed: true))
            }
        }
        return loops
    }

    /// Chaikin corner cutting, which rounds the grid's stair steps.
    public static func smooth(_ p: Polyline, iterations: Int) -> Polyline {
        var pts = p.points
        guard pts.count > 2 else { return p }
        for _ in 0..<max(0, iterations) {
            var out: [Vec2] = []
            out.reserveCapacity(pts.count * 2)
            for i in pts.indices {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                out.append(a * 0.75 + b * 0.25)
                out.append(a * 0.25 + b * 0.75)
            }
            pts = out
        }
        return Polyline(pts, closed: true)
    }

    /// Douglas–Peucker simplification of a closed outline.
    public static func simplify(_ p: Polyline, tolerance: Double) -> Polyline {
        let pts = p.points
        guard pts.count > 4 else { return p }
        // Split the loop at its farthest point from the start so both halves are open runs.
        let far = pts.indices.max { pts[$0].distance(to: pts[0]) < pts[$1].distance(to: pts[0]) } ?? pts.count / 2
        guard far > 0 else { return p }
        let first = rdp(Array(pts[0...far]), tolerance: tolerance)
        let second = rdp(Array(pts[far...]) + [pts[0]], tolerance: tolerance)
        return Polyline(first + second.dropFirst().dropLast(), closed: true)
    }

    /// Douglas–Peucker on an open run; keeps both ends.
    static func rdp(_ pts: [Vec2], tolerance: Double) -> [Vec2] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while case let (s, e)? = stack.popLast() {
            guard e > s + 1 else { continue }
            let a = pts[s], ab = pts[e] - a, len = ab.length
            var best = -1.0, idx = s
            for i in (s + 1)..<e {
                let v = pts[i] - a
                let d = len > 1e-12 ? abs(v.cross(ab)) / len : v.length
                if d > best { best = d; idx = i }
            }
            if best > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }
}
