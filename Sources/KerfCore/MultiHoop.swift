import Foundation

// MARK: - Multi-hooping

/// Which way the hoop sits on the design when it is split into hoopings.
public enum HoopOrientation: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whichever way needs fewer hoopings (upright when it's a tie).
    case auto
    case upright
    /// The hoop turned 90°.
    case turned

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Fewest hoopings"
        case .upright: return "Upright"
        case .turned: return "Turned 90°"
        }
    }
}

/// How a design too big for one hoop is split into several hoopings.
public struct MultiHoopOptions: Codable, Hashable, Sendable {
    /// Width shared by neighbouring hoopings, in mm. The seam between them runs down its middle, and the
    /// alignment marks sit in it.
    public var overlap: Double
    /// Space kept clear inside the hoop's sewing area, in mm, so stitches stay off the hoop edge.
    public var margin: Double
    public var orientation: HoopOrientation
    /// Sew small crosses in each overlap, in their own colour, to line the next hooping up with.
    public var alignmentMarks: Bool
    /// Length of each arm of an alignment cross, in mm.
    public var markSize: Double
    /// Sew a long running-stitch box around each hooping's area first, to hold the fabric to the stabiliser.
    public var basting: Bool

    public init(overlap: Double = 10, margin: Double = 5, orientation: HoopOrientation = .auto,
                alignmentMarks: Bool = true, markSize: Double = 8, basting: Bool = false) {
        self.overlap = overlap
        self.margin = margin
        self.orientation = orientation
        self.alignmentMarks = alignmentMarks
        self.markSize = markSize
        self.basting = basting
    }

    /// The options kept to values that make a layout possible in a hoop of this size.
    public func sanitized(hoopWidth: Double, hoopHeight: Double) -> MultiHoopOptions {
        var o = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : lo }
        let small = min(hoopWidth, hoopHeight)
        o.margin = clamp(margin, 0, small * 0.2)
        let usable = small - 2 * o.margin
        o.overlap = clamp(overlap, 0, usable * 0.4)
        o.markSize = clamp(markSize, 2, 30)
        return o
    }
}

/// One hooping of a split design: where the hoop sits on the design and what it sews.
public struct Hooping: Hashable, Sendable, Identifiable {
    /// 0-based, in sewing order (rows top to bottom, left to right).
    public var index: Int
    public var row: Int
    public var column: Int
    /// The part of the design the hoop can sew (the hoop's area less the margin), in design mm.
    public var area: Rect2
    /// The part of the design this hooping is responsible for: its area cut at the middle of each overlap.
    public var owned: Rect2
    /// Stitches in design mm, starting with the basting and alignment-mark blocks when they are on.
    public var plan: EmbroideryPlan
    /// Centres of the alignment crosses this hooping sews, in design mm.
    public var marks: [Vec2]

    public var id: Int { index }

    /// The hoop's centre on the design. Each hooping's file is centred here, so the machine sews it at the
    /// middle of the hoop.
    public var center: Vec2 { area.center }

    /// True when only the alignment marks and basting would be sewn.
    public var isEmpty: Bool {
        plan.blocks.allSatisfy { $0.name == MultiHoop.marksBlockName || $0.name == MultiHoop.bastingBlockName || $0.runs.isEmpty }
    }
}

/// A design split into hoopings.
public struct MultiHoopLayout: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    /// The hoop's sewing area as it sits on the design (swapped when the hoop is turned), in mm.
    public var hoopWidth: Double
    public var hoopHeight: Double
    public var turned: Bool
    public var hoopings: [Hooping]
    /// The design's stitches before splitting, in design mm.
    public var designBounds: Rect2

    public var count: Int { hoopings.count }

    /// Hoopings that have stitches of the design in them; empty ones (in a corner the design misses) are left
    /// out of the export.
    public var sewnHoopings: [Hooping] { hoopings.filter { !$0.isEmpty } }
}

public enum MultiHoop {
    public static let marksBlockName = "Alignment marks"
    public static let bastingBlockName = "Basting"
    public static let markColor = ThreadColor(hex: "#E11D48")
    public static let bastingColor = ThreadColor(hex: "#9CA3AF")

    /// Number of hoopings needed along one side: hoop length `usable`, sharing `overlap` with each neighbour.
    public static func count(length: Double, usable: Double, overlap: Double) -> Int {
        guard length > usable + 1e-6 else { return 1 }
        let step = usable - overlap
        guard step > 0.5 else { return 1 }
        return Int(((length - overlap) / step - 1e-9).rounded(.up))
    }

    /// Splits a plan (design mm) into hoopings of this hoop.
    public static func split(_ plan: EmbroideryPlan, hoop: EmbroideryHoop, options raw: MultiHoopOptions) -> MultiHoopLayout {
        let o = raw.sanitized(hoopWidth: hoop.width, hoopHeight: hoop.height)
        let bounds = plan.bounds.isEmpty ? Rect2(minX: 0, minY: 0, maxX: 0, maxY: 0) : plan.bounds

        func grid(_ w: Double, _ h: Double) -> (cols: Int, rows: Int) {
            (count(length: bounds.width, usable: w - 2 * o.margin, overlap: o.overlap),
             count(length: bounds.height, usable: h - 2 * o.margin, overlap: o.overlap))
        }
        let upright = grid(hoop.width, hoop.height), turnedGrid = grid(hoop.height, hoop.width)
        let turned: Bool
        switch o.orientation {
        case .upright: turned = false
        case .turned: turned = true
        case .auto: turned = turnedGrid.cols * turnedGrid.rows < upright.cols * upright.rows
        }
        let hw = turned ? hoop.height : hoop.width, hh = turned ? hoop.width : hoop.height
        let (cols, rows) = turned ? turnedGrid : upright
        let uw = hw - 2 * o.margin, uh = hh - 2 * o.margin

        // The hoopings' areas, centred on the design.
        let stepX = uw - o.overlap, stepY = uh - o.overlap
        let spanX = Double(cols) * uw - Double(cols - 1) * o.overlap
        let spanY = Double(rows) * uh - Double(rows - 1) * o.overlap
        let x0 = bounds.center.x - spanX / 2, y0 = bounds.center.y - spanY / 2
        // Seams down the middle of each overlap; the outer hoopings own everything beyond their edge.
        func seamX(_ i: Int) -> Double { x0 + Double(i) * stepX + o.overlap / 2 }
        func seamY(_ j: Int) -> Double { y0 + Double(j) * stepY + o.overlap / 2 }

        var hoopings: [Hooping] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let area = Rect2(minX: x0 + Double(c) * stepX, minY: y0 + Double(r) * stepY,
                                 maxX: x0 + Double(c) * stepX + uw, maxY: y0 + Double(r) * stepY + uh)
                let owned = Rect2(minX: c == 0 ? -.infinity : seamX(c), minY: r == 0 ? -.infinity : seamY(r),
                                  maxX: c == cols - 1 ? .infinity : seamX(c + 1), maxY: r == rows - 1 ? .infinity : seamY(r + 1))
                hoopings.append(Hooping(index: hoopings.count, row: r, column: c, area: area, owned: owned,
                                        plan: EmbroideryPlan(), marks: []))
            }
        }

        func tile(at p: Vec2) -> Int {
            var c = 0, r = 0
            while c < cols - 1 && p.x >= seamX(c + 1) { c += 1 }
            while r < rows - 1 && p.y >= seamY(r + 1) { r += 1 }
            return r * cols + c
        }

        // Each colour block's runs go to the hooping that can sew them whole, when one can; runs too big for
        // any one hooping are cut at the seams, each piece reaching a stitch past the seam so they meet.
        var blocks = Array(repeating: [StitchBlock](), count: hoopings.count)
        for block in plan.blocks {
            var runs = Array(repeating: [[Vec2]](), count: hoopings.count)
            for run in block.runs where run.count >= 2 {
                var rb = Rect2.empty
                for p in run { rb.include(p) }
                let home = tile(at: rb.center)
                if hoopings[home].area.contains(rb, tolerance: 1e-6) {
                    runs[home].append(run)
                    continue
                }
                if let other = hoopings.first(where: { $0.area.contains(rb, tolerance: 1e-6) }) {
                    runs[other.index].append(run)
                    continue
                }
                for (t, piece) in cut(run, owner: tile, areas: hoopings.map(\.area)) {
                    runs[t].append(piece)
                }
            }
            for t in runs.indices where !runs[t].isEmpty {
                blocks[t].append(StitchBlock(color: block.color, name: block.name, runs: runs[t]))
            }
        }

        // Alignment crosses in the overlap each pair of neighbours shares, two per shared edge.
        var marks = Array(repeating: [Vec2](), count: hoopings.count)
        if o.alignmentMarks && hoopings.count > 1 {
            for h in hoopings {
                for n in [h.column + 1 < cols ? h.index + 1 : nil, h.row + 1 < rows ? h.index + cols : nil].compactMap({ $0 }) {
                    let a = h.area, b = hoopings[n].area
                    let shared = Rect2(minX: max(a.minX, b.minX), minY: max(a.minY, b.minY),
                                       maxX: min(a.maxX, b.maxX), maxY: min(a.maxY, b.maxY))
                    guard !shared.isEmpty else { continue }
                    let along = n == h.index + 1 ? Vec2(0, 1) : Vec2(1, 0)
                    let length = along.x == 0 ? shared.height : shared.width
                    for f in [0.25, 0.75] {
                        let p = along.x == 0
                            ? Vec2(shared.center.x, shared.minY + length * f)
                            : Vec2(shared.minX + length * f, shared.center.y)
                        marks[h.index].append(p)
                        marks[n].append(p)
                    }
                }
            }
        }
        let arm = min(o.markSize, max(2, o.overlap)) / 2

        for i in hoopings.indices {
            var out: [StitchBlock] = []
            if o.basting {
                let a = hoopings[i].area
                let box = [Vec2(a.minX, a.minY), Vec2(a.maxX, a.minY), Vec2(a.maxX, a.maxY), Vec2(a.minX, a.maxY), Vec2(a.minX, a.minY)]
                out.append(StitchBlock(color: bastingColor, name: bastingBlockName,
                                       runs: [EmbroideryPlanner.running(box, length: 5, cornerDegrees: 25)]))
            }
            if !marks[i].isEmpty {
                out.append(StitchBlock(color: markColor, name: marksBlockName, runs: marks[i].map { cross(at: $0, arm: arm) }))
            }
            hoopings[i].plan = EmbroideryPlan(blocks: out + blocks[i])
            hoopings[i].marks = marks[i]
        }
        return MultiHoopLayout(columns: cols, rows: rows, hoopWidth: hw, hoopHeight: hh, turned: turned,
                               hoopings: hoopings, designBounds: bounds)
    }

    /// An alignment cross: across, back to the middle, then up and down, as one running-stitch run.
    public static func cross(at c: Vec2, arm: Double) -> [Vec2] {
        let pts = [Vec2(c.x - arm, c.y), Vec2(c.x + arm, c.y), c, Vec2(c.x, c.y - arm), Vec2(c.x, c.y + arm)]
        return EmbroideryPlanner.running(pts, length: 1.5, cornerDegrees: 25)
    }

    /// Cuts a run into pieces by which hooping owns each stitch. Each piece takes in the stitch on either side
    /// of it (shortened to the hooping's area if it reaches beyond), so pieces from neighbouring hoopings meet.
    static func cut(_ run: [Vec2], owner: (Vec2) -> Int, areas: [Rect2]) -> [(Int, [Vec2])] {
        var out: [(Int, [Vec2])] = []
        var i = 0
        while i < run.count {
            let t = owner(run[i])
            var j = i
            while j + 1 < run.count && owner(run[j + 1]) == t { j += 1 }
            var piece = Array(run[i...j])
            if i > 0 { piece.insert(clip(from: run[i], to: run[i - 1], in: areas[t]), at: 0) }
            if j + 1 < run.count { piece.append(clip(from: run[j], to: run[j + 1], in: areas[t])) }
            if piece.count >= 2 { out.append((t, piece)) }
            i = j + 1
        }
        return out
    }

    /// The point `b`, or where the line from `a` (inside `r`) toward it leaves `r`.
    static func clip(from a: Vec2, to b: Vec2, in r: Rect2) -> Vec2 {
        if r.contains(b) { return b }
        var t = 1.0
        let d = b - a
        if d.x > 0, b.x > r.maxX { t = min(t, (r.maxX - a.x) / d.x) }
        if d.x < 0, b.x < r.minX { t = min(t, (r.minX - a.x) / d.x) }
        if d.y > 0, b.y > r.maxY { t = min(t, (r.maxY - a.y) / d.y) }
        if d.y < 0, b.y < r.minY { t = min(t, (r.minY - a.y) / d.y) }
        return a + d * max(0, t)
    }

    /// The machine file for one hooping, centred on the hoop.
    public static func pattern(_ h: Hooping, name: String) -> StitchPattern {
        StitchPattern(plan: h.plan, name: name, center: h.center)
    }

    /// A short written guide for hooping and sewing the parts in order.
    public static func guide(_ layout: MultiHoopLayout, name: String, fileNames: [Int: String], hoop: EmbroideryHoop,
                             options: MultiHoopOptions) -> String {
        let sewn = layout.sewnHoopings
        let b = layout.designBounds
        var s = "\(name): multi-hooping guide\n\n"
        s += String(format: "Design: %.1f × %.1f mm, split into %d hooping%@ (%d × %d) of %@%@.\n",
                    b.width, b.height, sewn.count, sewn.count == 1 ? "" : "s", layout.columns, layout.rows, hoop.name,
                    layout.turned ? ", hoop turned 90°" : "")
        s += String(format: "Neighbouring hoopings overlap by %.0f mm; the seam runs down the middle of each overlap.\n\n", options.overlap)
        s += "Positions are the hoop centre measured from the design's centre (right and down are positive).\n\n"
        for (k, h) in sewn.enumerated() {
            let dx = h.center.x - b.center.x, dy = h.center.y - b.center.y
            s += String(format: "%d. %@  row %d, column %d  centre %+.1f, %+.1f mm\n", k + 1,
                        fileNames[h.index] ?? "", h.row + 1, h.column + 1, dx, dy)
        }
        s += "\nSewing\n"
        s += "- Mark the design centre and the hoop centres on the fabric (or print the design at full size as a template).\n"
        s += "- Hoop the fabric for part 1 and sew it.\n"
        if options.alignmentMarks {
            s += "- Each part starts with its alignment crosses in their own colour. Re-hoop for the next part so the crosses it shares with the parts already sewn lie in the hoop, then move the needle over each cross (with the machine's layout or jog keys) and nudge the design until it lands on them. Sew the crosses again or skip that colour.\n"
            s += "- Pick the crosses out when everything is sewn.\n"
        } else {
            s += "- Re-hoop for each part so its centre lands where the list above says, using the stitches already sewn in the overlap to line it up.\n"
        }
        return s
    }
}
