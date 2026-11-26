import Foundation

// MARK: - Satin columns for lettering

extension EmbroideryPlanner {
    /// Stroke directions tried at each point (every 15°).
    static let columnDirections = 12

    /// Satin columns across the strokes of closed shapes, for lettering.
    ///
    /// The shape is sampled on a grid. At each point the stroke's width is the shortest chord through it, and the
    /// satin stitches run along that chord, so they turn with the stroke around curves. Neighbouring points with the
    /// same direction become one column. Parts wider than the maximum column width are tatami filled instead.
    public static func satinColumns(_ polys: [Polyline], settings s: EmbroiderySettings, from start: Vec2) -> [[Vec2]] {
        let closed = polys.filter { $0.closed && $0.points.count >= 3 }
        // The direction grid only needs the outline roughly; fewer points keep it quick.
        let grid = ColumnGrid(closed.map { Contour.simplify($0, tolerance: 0.05) }, maxWidth: s.maxColumnWidth)
        guard grid.componentCount > 0 else { return [] }

        // Rows for each column, in that column's own rotated frame.
        struct Piece {
            var rows: [FillRow]
            var radians: Double
            var isFill: Bool
        }
        var pieces: [Piece] = []
        for ci in 0..<grid.componentCount {
            let label = grid.componentLabel[ci]
            let isFill = label == grid.fillLabel
            let degrees = isFill ? s.fillAngle : Double(label) * 180 / Double(columnDirections)
            let rad = degrees * .pi / 180
            let rows = clippedRows(closed, radians: rad, spacing: s.density, step: grid.cell / 2,
                                   extend: s.pullCompensation / 2) { grid.component(at: $0) == ci }
            for chain in chainRows(rows) where !chain.isEmpty {
                pieces.append(Piece(rows: chain, radians: rad, isFill: isFill))
            }
        }

        // Sew nearest first, entering each piece at its closest corner.
        var runs: [[Vec2]] = []
        var pos = start
        while !pieces.isEmpty {
            var best = (index: 0, reverse: false, leftFirst: true, dist: Double.infinity)
            for (i, piece) in pieces.enumerated() {
                for reverse in [false, true] {
                    let r = reverse ? piece.rows[piece.rows.count - 1] : piece.rows[0]
                    let dl = Vec2(r.x0, r.y).rotated(by: piece.radians).distance(to: pos)
                    let dr = Vec2(r.x1, r.y).rotated(by: piece.radians).distance(to: pos)
                    if dl < best.dist { best = (i, reverse, true, dl) }
                    if dr < best.dist { best = (i, reverse, false, dr) }
                }
            }
            let piece = pieces.remove(at: best.index)
            var rows = piece.rows
            if best.reverse { rows.reverse() }
            var run: [Vec2] = []
            if piece.isFill {
                var leftToRight = best.leftFirst
                for row in rows {
                    let pts = tatamiRow(from: leftToRight ? row.x0 : row.x1, to: leftToRight ? row.x1 : row.x0,
                                        y: row.y, row: row.row, length: s.fillStitchLength)
                    if let last = run.last, let first = pts.first {
                        run += split(from: last, to: first, max: s.fillStitchLength).dropFirst()
                        run += pts.dropFirst()
                    } else {
                        run += pts
                    }
                    leftToRight.toggle()
                }
            } else {
                var satinRows = rows
                if s.underlay && rows.count >= 3 {
                    // A run down the middle of the column holds the fabric, then the satin comes back over it.
                    let mids = rows.map { Vec2(($0.x0 + $0.x1) / 2, $0.y) }
                    run = running(mids, length: 2)
                    satinRows.reverse()
                }
                // Zig-zag: each stitch crosses the column to the far side of the next row.
                var left = best.leftFirst
                if !run.isEmpty, let last = run.last, let r = satinRows.first {
                    left = Vec2(r.x0, r.y).distance(to: last) <= Vec2(r.x1, r.y).distance(to: last)
                }
                for r in satinRows {
                    run.append(left ? Vec2(r.x0, r.y) : Vec2(r.x1, r.y))
                    left.toggle()
                }
            }
            let placed = run.map { $0.rotated(by: piece.radians) }
            if placed.count >= 2 {
                runs.append(placed)
                pos = placed[placed.count - 1]
            }
        }
        return runs
    }

    /// Scanline rows at `radians` through the shapes (even-odd), cut down to where `member` is true.
    /// Rows are in the frame rotated by `-radians`. Row ends on the shape's outline are lengthened by `extend`.
    static func clippedRows(_ polys: [Polyline], radians: Double, spacing: Double, step: Double, extend: Double,
                            member: (Vec2) -> Bool) -> [[FillRow]] {
        let rotated = polys.map { Polyline($0.points.map { $0.rotated(by: -radians) }, closed: true) }
        let b = rotated.bounds
        guard !b.isEmpty, spacing > 0.05, step > 0 else { return [] }
        var edges: [(Vec2, Vec2)] = []
        for p in rotated {
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
                let x0 = xs[i], x1 = xs[i + 1]
                i += 2
                guard x1 - x0 > 0.05 else { continue }
                // Walk the row and keep the stretches inside this column.
                let n = max(1, Int(((x1 - x0) / step).rounded(.up)))
                let dx = (x1 - x0) / Double(n)
                var runStart: Int?
                for k in 0...n {
                    let isIn = k < n && member(Vec2(x0 + (Double(k) + 0.5) * dx, y).rotated(by: radians))
                    if isIn, runStart == nil { runStart = k }
                    if !isIn, let s0 = runStart {
                        var a = x0 + Double(s0) * dx, z = x0 + Double(k) * dx
                        if s0 == 0 { a -= extend }
                        if k == n { z += extend }
                        if z - a > 0.2 { segs.append(FillRow(row: r, y: y, x0: a, x1: z)) }
                        runStart = nil
                    }
                }
            }
            rows.append(segs)
            y += spacing
            r += 1
        }
        return rows
    }

    /// Chains segments that overlap on neighbouring rows into pieces sewn row after row.
    static func chainRows(_ rows: [[FillRow]]) -> [[FillRow]] {
        var used = rows.map { [Bool](repeating: false, count: $0.count) }
        var chains: [[FillRow]] = []
        for ri in rows.indices {
            for si in rows[ri].indices where !used[ri][si] {
                used[ri][si] = true
                var chain = [rows[ri][si]]
                var cur = rows[ri][si]
                var next = ri + 1
                while next < rows.count {
                    guard let k = rows[next].indices.first(where: {
                        !used[next][$0] && rows[next][$0].x0 < cur.x1 && rows[next][$0].x1 > cur.x0
                    }) else { break }
                    used[next][k] = true
                    cur = rows[next][k]
                    chain.append(cur)
                    next += 1
                }
                chains.append(chain)
            }
        }
        return chains
    }
}

/// A grid over a shape giving each inside point a stroke direction (or "fill" where the stroke is too wide),
/// grouped into connected columns.
struct ColumnGrid {
    let minX: Double
    let minY: Double
    let cell: Double
    let nx: Int
    let ny: Int
    /// Per cell: -1 outside, 0..<directions a stroke direction, `fillLabel` too wide for satin.
    private(set) var label: [Int]
    /// Per cell: the column it belongs to, or -1.
    private(set) var component: [Int]
    private(set) var componentLabel: [Int] = []
    let fillLabel = EmbroideryPlanner.columnDirections

    var componentCount: Int { componentLabel.count }

    init(_ polys: [Polyline], maxWidth: Double) {
        let b = polys.bounds
        guard !b.isEmpty, b.width > 0.1, b.height > 0.1 else {
            minX = 0; minY = 0; cell = 1; nx = 0; ny = 0; label = []; component = []
            return
        }
        var c = 0.4
        while (b.width / c) * (b.height / c) > 30_000 { c *= 1.25 }
        cell = c
        minX = b.minX
        minY = b.minY
        nx = max(1, Int((b.width / c).rounded(.up)))
        ny = max(1, Int((b.height / c).rounded(.up)))
        label = [Int](repeating: -1, count: nx * ny)
        component = [Int](repeating: -1, count: nx * ny)

        var edges: [(Vec2, Vec2)] = []
        for p in polys {
            for i in 0..<p.points.count { edges.append((p.points[i], p.points[(i + 1) % p.points.count])) }
        }
        let dirs = (0..<EmbroideryPlanner.columnDirections).map { k -> Vec2 in
            let a = Double(k) * .pi / Double(EmbroideryPlanner.columnDirections)
            return Vec2(cos(a), sin(a))
        }
        // Distance from each inside cell to the outline.
        var dist = [Double](repeating: -1, count: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                let p = Vec2(minX + (Double(i) + 0.5) * c, minY + (Double(j) + 0.5) * c)
                var inside = false
                var d2 = Double.infinity
                for (a, e) in edges {
                    if (a.y > p.y) != (e.y > p.y), p.x < (e.x - a.x) * (p.y - a.y) / (e.y - a.y) + a.x { inside.toggle() }
                    d2 = min(d2, Self.segmentDistance2(p, a, e))
                }
                if inside { dist[j * nx + i] = d2.squareRoot() }
            }
        }
        // Local stroke half-width: the deepest point within reach of a widest column.
        let reach = max(1, Int((maxWidth / 2 / c).rounded(.up)))
        let half = Self.windowMax(dist, nx: nx, ny: ny, radius: reach)
        let pending = -2
        for k in dist.indices where dist[k] >= 0 {
            if 2 * half[k] > maxWidth {
                label[k] = fillLabel
            } else if dist[k] >= min(0.5, half[k] / 2) {
                // Away from the edge the shortest chord is across the stroke (near a curved edge it can run along it).
                let p = Vec2(minX + (Double(k % nx) + 0.5) * c, minY + (Double(k / nx) + 0.5) * c)
                var bestK = 0, bestChord = Double.infinity
                for (n, d) in dirs.enumerated() {
                    let ch = Self.chord(p, d, edges)
                    if ch < bestChord { bestChord = ch; bestK = n }
                }
                label[k] = bestK
            } else {
                label[k] = pending
            }
        }
        // Edge cells take the direction of the stroke beside them.
        var changed = true
        while changed {
            changed = false
            var next = label
            for k in label.indices where label[k] == pending {
                let i = k % nx, j = k / nx
                var counts: [Int: Int] = [:]
                for dj in -1...1 {
                    for di in -1...1 {
                        let x = i + di, y = j + dj
                        guard x >= 0, y >= 0, x < nx, y < ny else { continue }
                        let l = label[y * nx + x]
                        if l >= 0 { counts[l, default: 0] += 1 }
                    }
                }
                if let top = counts.max(by: { $0.value < $1.value }) {
                    next[k] = top.key
                    changed = true
                }
            }
            label = next
        }
        for k in label.indices where label[k] == pending { label[k] = 0 }
        smooth()
        smooth()
        findComponents()
        mergeSmallComponents(minCells: max(4, Int((1.2 / c) * (1.2 / c))))
        mergeSmallComponents(minCells: max(4, Int((1.2 / c) * (1.2 / c))))
    }

    static func segmentDistance2(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a, ap = p - a
        let len2 = ab.dot(ab)
        let t = len2 > 0 ? max(0, min(1, ap.dot(ab) / len2)) : 0
        let q = a + ab * t
        return (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
    }

    /// Largest value within `radius` cells (a square window), ignoring cells below zero.
    static func windowMax(_ v: [Double], nx: Int, ny: Int, radius r: Int) -> [Double] {
        var rows = [Double](repeating: -1, count: v.count)
        for j in 0..<ny {
            for i in 0..<nx {
                var m = -1.0
                for x in max(0, i - r)...min(nx - 1, i + r) { m = max(m, v[j * nx + x]) }
                rows[j * nx + i] = m
            }
        }
        var out = [Double](repeating: -1, count: v.count)
        for j in 0..<ny {
            for i in 0..<nx {
                var m = -1.0
                for y in max(0, j - r)...min(ny - 1, j + r) { m = max(m, rows[y * nx + i]) }
                out[j * nx + i] = m
            }
        }
        return out
    }

    /// Length of the line through `p` along `d` between the nearest outline crossings on each side.
    static func chord(_ p: Vec2, _ d: Vec2, _ edges: [(Vec2, Vec2)]) -> Double {
        var tPos = Double.infinity, tNeg = -Double.infinity
        for (a, e) in edges {
            let ae = e - a
            let den = d.cross(ae)
            guard abs(den) > 1e-12 else { continue }
            let ap = a - p
            let u = ap.cross(d) / den
            guard u >= 0, u < 1 else { continue }
            let t = ap.cross(ae) / den
            if t > 0 { tPos = min(tPos, t) } else { tNeg = max(tNeg, t) }
        }
        return tPos - tNeg
    }

    func index(_ p: Vec2) -> Int? {
        let i = Int(floor((p.x - minX) / cell)), j = Int(floor((p.y - minY) / cell))
        guard i >= 0, j >= 0, i < nx, j < ny else { return nil }
        return j * nx + i
    }

    func component(at p: Vec2) -> Int {
        guard let k = index(p) else { return -1 }
        return component[k]
    }

    /// Replaces each label with the most common one around it, to remove speckle.
    private mutating func smooth() {
        var out = label
        for j in 0..<ny {
            for i in 0..<nx where label[j * nx + i] >= 0 {
                var counts: [Int: Int] = [:]
                for dj in -1...1 {
                    for di in -1...1 {
                        let x = i + di, y = j + dj
                        guard x >= 0, y >= 0, x < nx, y < ny else { continue }
                        let l = label[y * nx + x]
                        if l >= 0 { counts[l, default: 0] += 1 }
                    }
                }
                let own = label[j * nx + i]
                if let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $1.key == own) }),
                   top.value > counts[own, default: 0] {
                    out[j * nx + i] = top.key
                }
            }
        }
        label = out
    }

    private mutating func findComponents() {
        component = [Int](repeating: -1, count: nx * ny)
        componentLabel = []
        for start in label.indices where label[start] >= 0 && component[start] < 0 {
            let id = componentLabel.count
            let l = label[start]
            componentLabel.append(l)
            var stack = [start]
            component[start] = id
            while let k = stack.popLast() {
                let i = k % nx, j = k / nx
                for (x, y) in [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)] {
                    guard x >= 0, y >= 0, x < nx, y < ny else { continue }
                    let n = y * nx + x
                    if component[n] < 0 && label[n] == l {
                        component[n] = id
                        stack.append(n)
                    }
                }
            }
        }
    }

    /// Folds columns too small to sew well into the neighbour they share most edge with.
    private mutating func mergeSmallComponents(minCells: Int) {
        var size = [Int](repeating: 0, count: componentCount)
        for c in component where c >= 0 { size[c] += 1 }
        var changed = false
        var newLabel = label
        for k in label.indices where component[k] >= 0 && size[component[k]] < minCells {
            let i = k % nx, j = k / nx
            var counts: [Int: Int] = [:]
            for (x, y) in [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1), (i - 1, j - 1), (i + 1, j + 1), (i - 1, j + 1), (i + 1, j - 1)] {
                guard x >= 0, y >= 0, x < nx, y < ny else { continue }
                let n = y * nx + x
                if component[n] >= 0, component[n] != component[k], size[component[n]] >= minCells {
                    counts[label[n], default: 0] += 1
                }
            }
            if let top = counts.max(by: { $0.value < $1.value }) {
                newLabel[k] = top.key
                changed = true
            }
        }
        if changed {
            label = newLabel
            findComponents()
        }
    }
}
