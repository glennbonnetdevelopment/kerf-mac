import Foundation

// MARK: - Fill patterns

/// The design sewn inside a filled shape.
public enum FillPattern: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Plain tatami: straight rows with needle holes in a brick pattern.
    case tatami
    /// Dense rows that ripple in smooth waves.
    case waves
    /// Dense rows bent into sharp zig-zags.
    case zigzag
    /// Open parallel lines of running stitch; the fabric shows between them.
    case lines
    /// Open lines in two directions at right angles.
    case crosshatch
    /// Open lines in two directions 60° apart, making a diamond lattice.
    case lattice
    /// Rows of small stars, outlined in running stitch.
    case stars
    case hearts
    case diamonds
    case circles
    case flowers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tatami: return "Plain (tatami)"
        case .waves: return "Waves"
        case .zigzag: return "Zig-zag"
        case .lines: return "Open lines"
        case .crosshatch: return "Crosshatch"
        case .lattice: return "Diamond lattice"
        case .stars: return "Stars"
        case .hearts: return "Hearts"
        case .diamonds: return "Diamonds"
        case .circles: return "Circles"
        case .flowers: return "Flowers"
        }
    }

    /// Dense patterns cover the fabric like tatami; the others are open, decorative fills.
    public var isDense: Bool { self == .tatami || self == .waves || self == .zigzag }

    /// Patterns of repeated small shapes.
    public var isMotif: Bool { motif != nil }

    /// The motif's outline, about 1 across, centred on zero (y down, so the top is negative).
    public var motif: [Vec2]? {
        func ring(_ n: Int, _ radius: (Double) -> Double) -> [Vec2] {
            (0..<n).map { i in
                let t = Double(i) / Double(n) * 2 * .pi - .pi / 2
                return Vec2(cos(t), sin(t)) * radius(t)
            }
        }
        switch self {
        case .stars:
            return (0..<10).map { i in
                let t = Double(i) * .pi / 5 - .pi / 2
                return Vec2(cos(t), sin(t)) * (i % 2 == 0 ? 0.5 : 0.2)
            }
        case .hearts:
            return (0..<40).map { i in
                let t = Double(i) / 40 * 2 * .pi
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                return Vec2(x / 32, -(y + 2.5) / 32)
            }
        case .diamonds:
            return [Vec2(0, -0.5), Vec2(0.33, 0), Vec2(0, 0.5), Vec2(-0.33, 0)]
        case .circles:
            return ring(24) { _ in 0.5 }
        case .flowers:
            return ring(60) { t in 0.5 * (0.62 + 0.38 * cos(5 * (t + .pi / 2))) }
        default:
            return nil
        }
    }
}

// MARK: - Line styles

/// A decorative style for lines (running, triple and satin stitch, and lines in automatic digitizing).
public enum LineStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The stitch type's own line.
    case plain
    /// Satin stitches slanted steeply so they look like twisted rope.
    case rope
    /// An open zig-zag across the line.
    case zigzag
    /// A smooth wavy (scalloped) line.
    case wave
    /// A row of linked loops.
    case chain
    /// A straight line with teeth on one side (blanket or E stitch, for appliqué edges).
    case blanket
    /// A row of crosses.
    case crossStitch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plain: return "Plain"
        case .rope: return "Rope"
        case .zigzag: return "Zig-zag"
        case .wave: return "Wave"
        case .chain: return "Chain"
        case .blanket: return "Blanket (E stitch)"
        case .crossStitch: return "Cross stitch"
        }
    }
}

// MARK: - Stitching

extension EmbroideryPlanner {
    /// A patterned fill of closed outlines (even-odd, so holes stay open).
    public static func patternFill(_ polys: [Polyline], settings s: EmbroiderySettings, from start: Vec2) -> [[Vec2]] {
        var runs: [[Vec2]] = []
        var cursor = start
        func add(_ r: [[Vec2]]) {
            runs += r
            if let last = r.last?.last { cursor = last }
        }
        let size = s.patternSize
        func underlay() {
            if s.underlay {
                add(fill(polys, angle: s.fillAngle + 90, spacing: max(1.5, s.density * 5), stitchLength: 3.5,
                         extend: -0.6, from: cursor))
            }
        }
        switch s.fillType {
        case .satin:
            underlay()
            add(fill(polys, angle: s.fillAngle, spacing: s.density, stitchLength: s.satinSplitLength,
                     extend: s.pullCompensation / 2, from: cursor, satinSplit: s.satinSplitLength))
            return runs.filter { $0.count >= 2 }
        case .embossed:
            underlay()
            add(fill(polys, angle: s.fillAngle, spacing: s.density, stitchLength: s.fillStitchLength,
                     extend: s.pullCompensation / 2, from: cursor, offset: s.tatamiOffset,
                     emboss: (s.embossPattern, size)))
            return runs.filter { $0.count >= 2 }
        case .tatami, .motif:
            break
        }
        switch s.fillPattern {
        case .tatami, .waves, .zigzag:
            underlay()
            let warp: (Double) -> Double
            let length: Double
            switch s.fillPattern {
            case .zigzag:
                // A triangle wave; holes on a quarter-wave grid land on every point.
                let amp = size / 8
                warp = { x in
                    let f = (x / size).truncatingRemainder(dividingBy: 1)
                    let u = f < 0 ? f + 1 : f
                    return amp * (u < 0.25 ? 4 * u : u < 0.75 ? 2 - 4 * u : 4 * u - 4)
                }
                length = size / 4 / (size / 4 / s.fillStitchLength).rounded(.up)
            case .waves:
                let amp = size / 8
                warp = { x in amp * sin(2 * .pi * x / size) }
                length = min(s.fillStitchLength, size / 6)
            default:
                warp = { _ in 0 }
                length = s.fillStitchLength
            }
            add(fill(polys, angle: s.fillAngle, spacing: s.density, stitchLength: length,
                     extend: s.pullCompensation / 2, from: cursor,
                     warp: s.fillPattern == .tatami ? nil : warp, stagger: s.fillPattern != .zigzag,
                     offset: s.tatamiOffset))
        case .lines, .crosshatch, .lattice:
            let angles: [Double]
            switch s.fillPattern {
            case .crosshatch: angles = [s.fillAngle, s.fillAngle + 90]
            case .lattice: angles = [s.fillAngle + 30, s.fillAngle - 30]
            default: angles = [s.fillAngle]
            }
            for a in angles {
                add(fill(polys, angle: a, spacing: s.patternSpacing, stitchLength: s.stitchLength, extend: 0,
                         from: cursor, stagger: false))
            }
        default:
            if let motif = s.fillPattern.motif {
                let sewn = motifFill(polys, motif: motif, size: size, gap: s.patternSpacing, angle: s.fillAngle,
                                     stitchLength: min(s.stitchLength, max(0.8, size / 4)), from: cursor)
                // Too small for even one motif: outline the shape so it isn't lost.
                add(sewn.isEmpty ? Planner.order(polys, from: cursor, innerFirst: true).map { running($0, length: s.stitchLength) } : sewn)
            }
        }
        return runs.filter { $0.count >= 2 }
    }

    /// Whole motifs that fit inside the outlines, in staggered rows at `angle`, each outlined in running stitch.
    /// The motifs stay upright on the design. Neighbouring motifs are joined by a short stitch so a row sews
    /// without trims; each motif is entered on one side and left on the other, so its shorter half is sewn twice.
    public static func motifFill(_ polys: [Polyline], motif: [Vec2], size: Double, gap: Double, angle: Double,
                                 stitchLength: Double, from start: Vec2) -> [[Vec2]] {
        guard motif.count >= 3, size > 0.5 else { return [] }
        let rad = angle * .pi / 180
        let rotated = polys.map { Polyline($0.points.map { $0.rotated(by: -rad) }, closed: true) }
        let b = rotated.bounds
        guard !b.isEmpty else { return [] }
        func inside(_ p: Vec2) -> Bool { rotated.filter { Planner.contains($0, p) }.count % 2 == 1 }

        // The motif in the rows' frame, with extra points so the inside test catches edges that poke out.
        var shape: [Vec2] = []
        let placed = motif.map { ($0 * size).rotated(by: -rad) }
        for i in placed.indices {
            shape += split(from: placed[i], to: placed[(i + 1) % placed.count], max: max(0.3, size / 16)).dropLast()
        }
        let pitch = size + max(0, gap)
        let rowPitch = pitch * 0.866
        var rows: [[Vec2]] = []
        var y = b.minY + size / 2
        var r = 0
        while y <= b.maxY - size / 2 + 1e-9 {
            var centres: [Vec2] = []
            var x = b.minX + size / 2 + (r % 2 == 1 ? pitch / 2 : 0)
            while x <= b.maxX - size / 2 + 1e-9 {
                let c = Vec2(x, y)
                if shape.allSatisfy({ inside($0 + c) }) { centres.append(c) }
                x += pitch
            }
            if !centres.isEmpty { rows.append(centres) }
            y += rowPitch
            r += 1
        }
        guard !rows.isEmpty else { return [] }

        // Start from the top or bottom row, whichever is nearer.
        let pos = start.rotated(by: -rad)
        if let lastRow = rows.last, let firstRow = rows.first,
           min(lastRow[0].distance(to: pos), lastRow[lastRow.count - 1].distance(to: pos))
            < min(firstRow[0].distance(to: pos), firstRow[firstRow.count - 1].distance(to: pos)) {
            rows.reverse()
        }
        var leftToRight = firstRowStartsLeft(rows[0], pos)

        var runs: [[Vec2]] = []
        var run: [Vec2] = []
        for row in rows {
            let centres = leftToRight ? row : row.reversed()
            for c in centres {
                let path = motifPath(placed, centre: c, leftToRight: leftToRight, stitchLength: stitchLength)
                guard let first = path.first else { continue }
                if let last = run.last {
                    let link = [0.2, 0.4, 0.6, 0.8].map { last + (first - last) * $0 }
                    if link.allSatisfy(inside) && last.distance(to: first) <= pitch * 2.5 {
                        run += split(from: last, to: first, max: stitchLength).dropFirst()
                        run += path.dropFirst()
                        continue
                    }
                    runs.append(run)
                }
                run = path
            }
            leftToRight.toggle()
        }
        if !run.isEmpty { runs.append(run) }
        return runs.map { $0.map { $0.rotated(by: rad) } }
    }

    private static func firstRowStartsLeft(_ row: [Vec2], _ pos: Vec2) -> Bool {
        row[0].distance(to: pos) <= row[row.count - 1].distance(to: pos)
    }

    /// One motif's stitches: in at its left (or right) end, round the outline, then back over the shorter half
    /// so it leaves at the other end.
    static func motifPath(_ outline: [Vec2], centre: Vec2, leftToRight: Bool, stitchLength: Double) -> [Vec2] {
        let pts = outline.map { $0 + centre }
        let n = pts.count
        let lo = pts.indices.min { pts[$0].x < pts[$1].x }!, hi = pts.indices.max { pts[$0].x < pts[$1].x }!
        let entry = leftToRight ? lo : hi, exit = leftToRight ? hi : lo
        func arc(_ from: Int, _ to: Int) -> [Vec2] {
            var out = [pts[from]]
            var i = from
            while i != to {
                i = (i + 1) % n
                out.append(pts[i])
            }
            return out
        }
        // `go` runs entry → exit along the shorter half, `back` exit → entry along the longer one.
        var go = arc(entry, exit), back = arc(exit, entry)
        if arcLength(go) > arcLength(back) {
            let shorter = Array(back.reversed())
            back = Array(go.reversed())
            go = shorter
        }
        let path = go + back.dropFirst() + go.dropFirst()
        return running(path, length: stitchLength)
    }

    /// One line sewn in a decorative style, `width` across.
    public static func styledLine(_ pts: [Vec2], style: LineStyle, width: Double, settings s: EmbroiderySettings,
                                  triple: Bool = false) -> [[Vec2]] {
        guard pts.count >= 2 else { return [] }
        let total = arcLength(pts)
        guard total > 1e-6 else { return [] }
        let w = max(0.5, width)
        let half = w / 2
        /// A point on the line and the normal to its left there.
        func side(_ d: Double, _ offset: Double) -> Vec2 {
            let (p, n) = frame(pts, total, d)
            return p + n * offset
        }
        var out: [Vec2] = []
        switch style {
        case .plain:
            out = running(pts, length: s.stitchLength)
        case .rope:
            // Satin with the far side a stitch-width ahead: every stitch lies at a steep slant.
            var under: [Vec2] = []
            var path = pts
            if s.underlay {
                under = running(pts, length: 2)
                path = pts.reversed()
            }
            let slant = w * 0.9
            let n = max(2, Int((total / max(0.2, s.density)).rounded()))
            var column: [Vec2] = []
            for k in 0...n {
                let d = total * Double(k) / Double(n)
                if k % 2 == 0 {
                    let (p, nn) = frame(path, total, d)
                    column.append(p + nn * half)
                } else {
                    let (p, nn) = frame(path, total, min(total, d + slant))
                    column.append(p - nn * half)
                }
            }
            return [under + column]
        case .zigzag:
            let step = max(0.6, s.stitchLength / 2)
            let n = max(2, Int((total / step).rounded()))
            out = (0...n).map { k in side(total * Double(k) / Double(n), k % 2 == 0 ? half : -half) }
        case .wave:
            let lambda = max(2, w * 2.5)
            let waves = max(1, Int((total / lambda).rounded()))
            let step = min(s.stitchLength, lambda / 8)
            let n = max(2, Int((total / step).rounded(.up)))
            out = (0...n).map { k in
                let d = total * Double(k) / Double(n)
                return side(d, half * sin(2 * .pi * Double(waves) * d / total))
            }
        case .chain:
            let links = max(1, Int((total / max(1.5, w * 1.3)).rounded()))
            let length = total / Double(links)
            out = [side(0, 0)]
            for k in 0..<links {
                let d0 = Double(k) * length
                let ts = [0.25, 0.5, 0.75, 1.0]
                // Round the top, back round the bottom, then along the bottom again to the next link.
                out += ts.map { side(d0 + $0 * length, half * sin(.pi * $0)) }
                out += ts.reversed().dropFirst().map { side(d0 + $0 * length, -half * sin(.pi * $0)) } + [side(d0, 0)]
                out += ts.map { side(d0 + $0 * length, -half * sin(.pi * $0)) }
            }
        case .blanket:
            let teeth = max(1, Int((total / max(1, s.stitchLength)).rounded()))
            out = [side(0, 0)]
            for k in 0...teeth {
                let d = total * Double(k) / Double(teeth)
                if k > 0 { out.append(side(d, 0)) }
                out += [side(d, w), side(d, 0)]
            }
        case .crossStitch:
            let cells = max(1, Int((total / w).rounded()))
            let length = total / Double(cells)
            out = [side(0, half)]
            for k in 0..<cells {
                let d0 = Double(k) * length, d1 = d0 + length
                out += [side(d1, -half), side(d0, -half), side(d1, half)]
            }
        }
        // Long moves (a stitch across a wide style) are split so no stitch is longer than the machine allows.
        var sewn = [out[0]]
        for p in out.dropFirst() { sewn += split(from: sewn[sewn.count - 1], to: p, max: 7).dropFirst() }
        return [triple ? bean(sewn) : sewn]
    }

    /// A point `d` along a path of length `total`, and the normal to its left there.
    private static func frame(_ pts: [Vec2], _ total: Double, _ dIn: Double) -> (Vec2, Vec2) {
        let d = min(max(0, dIn), total)
        let p = point(on: pts, at: d)
        let ahead = point(on: pts, at: min(total, d + 0.4)), behind = point(on: pts, at: max(0, d - 0.4))
        var t = (ahead - behind).normalized
        if t.length < 0.5 { t = (pts[pts.count - 1] - pts[0]).normalized }
        return (p, Vec2(-t.y, t.x))
    }
}
