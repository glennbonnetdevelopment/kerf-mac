import Foundation

// MARK: - Vinyl weeding aids

/// Where weeding boxes go.
public enum WeedBoxStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// No box.
    case none
    /// One box around the whole job.
    case job
    /// A box around each separate design on the sheet (shapes whose margins touch share a box).
    case eachDesign

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None"
        case .job: return "Around everything"
        case .eachDesign: return "Around each design"
        }
    }
}

/// Which way weeding lines run.
public enum WeedLineStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, horizontal, vertical, grid

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .grid: return "Both (grid)"
        }
    }
}

/// Settings for the weeding box and weeding lines cut around a vinyl job.
public struct WeedingOptions: Codable, Hashable, Sendable {
    public var box: WeedBoxStyle
    /// Gap between the design and its box, in mm.
    public var margin: Double
    public var lines: WeedLineStyle
    /// Largest distance between weeding lines, in mm. Lines are spread evenly so no strip is wider than this.
    public var spacing: Double
    /// How far weeding lines stop short of the design, in mm, so the blade never nicks it.
    public var clearance: Double

    public init(box: WeedBoxStyle = .none, margin: Double = 3, lines: WeedLineStyle = .none,
                spacing: Double = 20, clearance: Double = 0.5) {
        self.box = box
        self.margin = margin
        self.lines = lines
        self.spacing = spacing
        self.clearance = clearance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WeedingOptions()
        box = try c.decodeIfPresent(WeedBoxStyle.self, forKey: .box) ?? d.box
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? d.margin
        lines = try c.decodeIfPresent(WeedLineStyle.self, forKey: .lines) ?? d.lines
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? d.spacing
        clearance = try c.decodeIfPresent(Double.self, forKey: .clearance) ?? d.clearance
    }

    public var isActive: Bool { box != .none || lines != .none }
}

/// The extra cuts for weeding: boxes and the lines that split the waste inside them.
public struct WeedingCuts: Hashable, Sendable {
    public var boxes: [[Vec2]]
    public var lines: [[Vec2]]

    public init(boxes: [[Vec2]] = [], lines: [[Vec2]] = []) {
        self.boxes = boxes
        self.lines = lines
    }

    public var isEmpty: Bool { boxes.isEmpty && lines.isEmpty }
    /// Lines first, then boxes, so the sheet stays in one piece until the end.
    public var allPaths: [[Vec2]] { lines + boxes }
}

public enum Weeding {
    /// Weeding cuts for the vector cut layers of a toolpath (fill and image layers don't cut vinyl).
    public static func cuts(for tp: Toolpath, options: WeedingOptions) -> WeedingCuts {
        let paths = tp.layers.filter { $0.layer.mode != .fill && $0.layer.mode != .image }.flatMap(\.paths)
        return cuts(for: paths, options: options)
    }

    /// Weeding cuts around `paths` (design coordinates, closed paths repeat their first point).
    public static func cuts(for paths: [[Vec2]], options: WeedingOptions) -> WeedingCuts {
        let paths = paths.filter { $0.count > 1 }
        guard options.isActive, !paths.isEmpty else { return WeedingCuts() }
        let margin = max(0, options.margin)
        let regions = options.box == .eachDesign
            ? designRegions(paths, margin: margin)
            : [bounds(of: paths).insetBy(-margin)]

        var lines: [[Vec2]] = []
        if options.lines != .none, options.spacing > 0 {
            let clearance = max(0, options.clearance)
            for r in regions {
                if options.lines == .horizontal || options.lines == .grid {
                    lines += weedLines(in: r, paths: paths, spacing: options.spacing, clearance: clearance, vertical: false)
                }
                if options.lines == .vertical || options.lines == .grid {
                    lines += weedLines(in: r, paths: paths, spacing: options.spacing, clearance: clearance, vertical: true)
                }
            }
        }
        let boxes = options.box == .none ? [] : regions.map(rectanglePath)
        return WeedingCuts(boxes: boxes, lines: lines)
    }

    /// One rectangle per separate design: each path's bounds grown by `margin`,
    /// merged with any other that overlaps it, sorted top to bottom then left to right.
    public static func designRegions(_ paths: [[Vec2]], margin: Double) -> [Rect2] {
        var rects = paths.map { bounds(of: [$0]).insetBy(-margin) }.filter { !$0.isEmpty }
        rects.sort { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        var merged = true
        while merged {
            merged = false
            var out: [Rect2] = []
            for r in rects {
                var cur = r
                // Fold in every kept rectangle this one overlaps.
                var i = 0
                while i < out.count {
                    if out[i].intersects(cur) {
                        cur = cur.union(out[i])
                        out.remove(at: i)
                        merged = true
                        i = 0
                    } else {
                        i += 1
                    }
                }
                out.append(cur)
            }
            rects = out
        }
        return rects.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// Weeding lines across `region`, spread evenly no more than `spacing` apart,
    /// broken wherever they would come within `clearance` of the design or cross into it.
    /// Lines alternate direction so the blade doesn't travel back between them.
    static func weedLines(in region: Rect2, paths: [[Vec2]], spacing: Double, clearance: Double, vertical: Bool) -> [[Vec2]] {
        // Work in a frame where the lines are horizontal.
        func flip(_ p: Vec2) -> Vec2 { vertical ? Vec2(p.y, p.x) : p }
        let r = vertical ? Rect2(minX: region.minY, minY: region.minX, maxX: region.maxY, maxY: region.maxX) : region
        guard !r.isEmpty, r.height > 0 else { return [] }
        let local = vertical ? paths.map { $0.map(flip) } : paths
        let segments = local.flatMap { p in (1..<p.count).map { (p[$0 - 1], p[$0]) } }
        let closedPaths = local.filter { $0.count > 2 && $0[0].distance(to: $0[$0.count - 1]) < 1e-6 }
        let radius = max(clearance, 1e-6)
        let minPiece = max(1.0, clearance * 2)

        let count = max(0, Int((r.height / spacing).rounded(.up)) - 1)
        var out: [[Vec2]] = []
        for k in 0..<count {
            let y = r.minY + r.height * Double(k + 1) / Double(count + 1)
            var blocked: [(Double, Double)] = []
            // Inside any closed shape (so lines never cross a letter's body; counters stay whole too).
            for p in closedPaths {
                var xs: [Double] = []
                for i in 1..<p.count {
                    let a = p[i - 1], b = p[i]
                    if (a.y > y) != (b.y > y) {
                        xs.append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
                    }
                }
                xs.sort()
                var i = 0
                while i + 1 < xs.count {
                    blocked.append((xs[i], xs[i + 1]))
                    i += 2
                }
            }
            // Too close to any cut line.
            for (a, b) in segments where min(a.y, b.y) - radius < y && max(a.y, b.y) + radius > y {
                if let span = capsuleSpan(a, b, y: y, radius: radius) { blocked.append(span) }
            }
            blocked.sort { $0.0 < $1.0 }

            var pieces: [(Double, Double)] = []
            var cursor = r.minX
            for (lo, hi) in blocked {
                if lo > cursor { pieces.append((cursor, min(lo, r.maxX))) }
                cursor = max(cursor, hi)
                if cursor >= r.maxX { break }
            }
            if cursor < r.maxX { pieces.append((cursor, r.maxX)) }
            pieces = pieces.filter { $0.1 - $0.0 >= minPiece }

            let reverse = k % 2 == 1
            for (lo, hi) in reverse ? pieces.reversed() : pieces {
                let line = reverse ? [Vec2(hi, y), Vec2(lo, y)] : [Vec2(lo, y), Vec2(hi, y)]
                out.append(line.map(flip))
            }
        }
        return out
    }

    /// Where the horizontal line at `y` is closer than `radius` to segment a–b, as an x range.
    static func capsuleSpan(_ a: Vec2, _ b: Vec2, y: Double, radius c: Double) -> (Double, Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for p in [a, b] {
            let dy = y - p.y
            if abs(dy) < c {
                let w = (c * c - dy * dy).squareRoot()
                lo = min(lo, p.x - w)
                hi = max(hi, p.x + w)
            }
        }
        let d = b - a
        let length = d.length
        if length > 1e-12 {
            let u = d / length, n = Vec2(-u.y, u.x)
            var xlo = -Double.infinity, xhi = Double.infinity, ok = true
            // Keep x where minV <= k*x + k0 <= maxV.
            func limit(_ k: Double, _ k0: Double, _ minV: Double, _ maxV: Double) {
                if abs(k) < 1e-12 {
                    if k0 < minV || k0 > maxV { ok = false }
                    return
                }
                var x1 = (minV - k0) / k, x2 = (maxV - k0) / k
                if x1 > x2 { swap(&x1, &x2) }
                xlo = max(xlo, x1)
                xhi = min(xhi, x2)
            }
            limit(u.x, u.y * (y - a.y) - u.x * a.x, 0, length)
            limit(n.x, n.y * (y - a.y) - n.x * a.x, -c, c)
            if ok, xlo <= xhi {
                lo = min(lo, xlo)
                hi = max(hi, xhi)
            }
        }
        return lo <= hi ? (lo, hi) : nil
    }

    static func bounds(of paths: [[Vec2]]) -> Rect2 {
        var r = Rect2.empty
        for p in paths { for v in p { r.include(v) } }
        return r
    }

    static func rectanglePath(_ r: Rect2) -> [Vec2] {
        [Vec2(r.minX, r.minY), Vec2(r.maxX, r.minY), Vec2(r.maxX, r.maxY), Vec2(r.minX, r.maxY), Vec2(r.minX, r.minY)]
    }
}
