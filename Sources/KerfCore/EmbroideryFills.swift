import Foundation

// MARK: - Fill types

/// The kind of stitching that covers a filled area.
public enum FillType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Rows of stitches with the needle holes staggered like brickwork: a stable, matte cover for large shapes
    /// and backgrounds (also called complex fill).
    case tatami
    /// Long stitches straight across the shape for a glossy, smooth surface. Stitches longer than the split
    /// length are split, with the splits staggered, so wide areas don't snag.
    case satin
    /// Tatami with a texture pressed in: short stitches line up along a pattern, leaving fine grooves.
    case embossed
    /// Small shapes or running-stitch lines repeated across the area.
    case motif

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tatami: return "Tatami (complex fill)"
        case .satin: return "Satin fill"
        case .embossed: return "Embossed"
        case .motif: return "Motif"
        }
    }

    public var shortTitle: String {
        switch self {
        case .tatami: return "Tatami"
        case .satin: return "Satin"
        case .embossed: return "Embossed"
        case .motif: return "Motif"
        }
    }

    public var detail: String {
        switch self {
        case .tatami:
            return "Staggered, brick-like rows for a stable, matte finish. Best for large shapes and backgrounds."
        case .satin:
            return "A glossy, smooth surface for narrow shapes, borders and lettering. Stitches longer than the split length are split, with the splits staggered, so wide areas don't snag."
        case .embossed:
            return "Tatami with a texture: short stitches line up along a pattern and leave fine grooves in the fill."
        case .motif:
            return "Small shapes or running-stitch lines repeated across the area. The fabric shows between them."
        }
    }

    /// The patterns this fill type sews (motifs and open lines for a motif fill, row shapes for tatami).
    public var patterns: [FillPattern] {
        switch self {
        case .tatami: return FillPattern.allCases.filter(\.isDense)
        case .motif: return FillPattern.allCases.filter { !$0.isDense }
        case .satin, .embossed: return [.tatami]
        }
    }

    /// The fill type a pattern from before fill types existed belongs to.
    public static func legacy(_ pattern: FillPattern) -> FillType { pattern.isDense ? .tatami : .motif }
}

/// How far each tatami row's needle holes are shifted from the row before, as a part of the stitch length.
public enum TatamiOffset: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Every other row shifted by half: a classic brick pattern.
    case half
    /// A third per row: gentle steps (the usual tatami).
    case third
    /// A quarter per row: holes line up in fine diagonals.
    case quarter
    /// A fifth per row: long, shallow diagonals.
    case fifth
    /// A different shift on every row, so no line shows.
    case random

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .half: return "Brick (½ offset)"
        case .third: return "Steps (⅓ offset)"
        case .quarter: return "Diagonal (¼ offset)"
        case .fifth: return "Shallow diagonal (⅕ offset)"
        case .random: return "Random"
        }
    }

    /// The shift of row `row`, from 0 up to (not including) 1.
    public func fraction(_ row: Int) -> Double {
        func cycle(_ n: Int) -> Double { Double(((row % n) + n) % n) / Double(n) }
        switch self {
        case .half: return cycle(2)
        case .third: return cycle(3)
        case .quarter: return cycle(4)
        case .fifth: return cycle(5)
        case .random:
            // A fixed hash of the row, so the same design always sews the same way.
            var z = UInt64(bitPattern: Int64(row)) &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return 0.1 + 0.8 * Double(z % 10_000) / 10_000
        }
    }
}

/// The texture pressed into an embossed fill.
public enum EmbossPattern: String, Codable, CaseIterable, Sendable, Identifiable {
    case stripes
    case diamonds
    case squares
    case waves
    case rings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stripes: return "Diagonal stripes"
        case .diamonds: return "Diamonds"
        case .squares: return "Squares"
        case .waves: return "Waves"
        case .rings: return "Rings"
        }
    }
}

// MARK: - Textures

/// Where an embossed texture's grooves cross the fill rows, in the rows' own frame (rows run along x).
struct FillTexture {
    let pattern: EmbossPattern
    /// Distance between grooves.
    let size: Double
    /// The texture's centre (rings are centred here).
    let centre: Vec2
    /// Fill row spacing, to find rows that lie along a groove.
    let spacing: Double

    /// The pattern as level functions: grooves lie where a function passes a whole number.
    private func levels(_ p: Vec2) -> [Double] {
        let q = p - centre
        let diag = size * 2.0.squareRoot()
        switch pattern {
        case .stripes: return [(q.x + q.y) / diag]
        case .diamonds: return [(q.x + q.y) / diag, (q.x - q.y) / diag]
        case .squares: return [q.x / size]
        case .waves: return [(q.x + size * 0.3 * sin(2 * .pi * q.y / (size * 2))) / size]
        case .rings: return [q.length / size]
        }
    }

    /// True for rows that run along a groove (the rows of the squares pattern): they are sewn in short stitches.
    func isGroove(_ y: Double) -> Bool {
        guard pattern == .squares else { return false }
        let v = (y - centre.y) / size
        return abs(v - v.rounded()) * size < spacing / 2
    }

    /// The x positions between `lo` and `hi` where the row at `y` crosses a groove.
    func crossings(y: Double, lo: Double, hi: Double) -> [Double] {
        guard hi > lo, size > 0 else { return [] }
        let step = 0.2
        var out: [Double] = []
        var x0 = lo
        var f0 = levels(Vec2(lo, y))
        while x0 < hi {
            let x1 = min(hi, x0 + step)
            let f1 = levels(Vec2(x1, y))
            for i in f0.indices where floor(f0[i]) != floor(f1[i]) {
                let target = max(floor(f0[i]), floor(f1[i]))
                let t = (f1[i] - f0[i]).magnitude > 1e-12 ? (target - f0[i]) / (f1[i] - f0[i]) : 0.5
                out.append(x0 + (x1 - x0) * min(1, max(0, t)))
            }
            x0 = x1
            f0 = f1
        }
        return out.sorted()
    }
}

// MARK: - Rows

extension EmbroideryPlanner {
    /// Stitch points along one satin-fill row: one stitch edge to edge, or, when that is longer than `split`,
    /// even pieces with the split points shifted a third each row so they never line up.
    static func satinRow(from: Double, to: Double, y: Double, row: Int, split maxLength: Double) -> [Vec2] {
        let lo = min(from, to), hi = max(from, to)
        let length = hi - lo
        let n = Int((length / maxLength).rounded(.up))
        guard n > 1 else { return [Vec2(from, y), Vec2(to, y)] }
        let piece = length / Double(n)
        let shift = Double(((row % 3) + 3) % 3) / 3
        var cuts: [Double] = []
        for k in 0...n {
            let x = lo + (Double(k) + shift) * piece
            if x - lo > piece * 0.25 && hi - x > piece * 0.25 { cuts.append(x) }
        }
        if to < from { cuts.reverse() }
        let pts = [Vec2(from, y)] + cuts.map { Vec2($0, y) } + [Vec2(to, y)]
        var out = [pts[0]]
        for p in pts.dropFirst() { out += split(from: out[out.count - 1], to: p, max: maxLength).dropFirst() }
        return out
    }
}

// MARK: - Summary

public extension EmbroiderySettings {
    /// A short description, such as "Fill · Tatami, steps (⅓ offset)" or "Running stitch · Rope".
    var summary: String {
        let s = sanitized
        let border = s.border.map { " + " + ($0.stitch == .satin ? "satin" : $0.stitch == .bean ? "triple" : "running") + " border" } ?? ""
        return mainSummary(s) + border
    }

    private func mainSummary(_ s: EmbroiderySettings) -> String {
        switch s.stitchType {
        case .fill:
            switch s.fillType {
            case .tatami:
                let rows = s.fillPattern == .tatami ? "" : ", \(s.fillPattern.title.lowercased())"
                return "Tatami fill\(rows)"
            case .satin: return "Satin fill"
            case .embossed: return "Embossed fill, \(s.embossPattern.title.lowercased())"
            case .motif: return "Motif fill, \(s.fillPattern.title.lowercased())"
            }
        default:
            return s.stitchType.title + (s.lineStyle == .plain || s.stitchType == .satinColumns ? "" : " · \(s.lineStyle.title)")
        }
    }
}
