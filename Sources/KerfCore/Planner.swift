import Foundation

/// A resolved CNC path type.
public enum MillCut: Sendable, Equatable {
    case part, hole, onLine, pocketClear, drill
}

/// The moves for one layer, in design space. Each path is an explicit point list
/// (closed outlines repeat their first point at the end).
public struct ToolpathLayer: Sendable {
    public var layer: Layer
    public var paths: [[Vec2]]
    /// Image engraving lines (image layers only).
    public var rasters: [RasterRow]
    /// For CNC layers: what each path is (same order as `paths`).
    public var cuts: [MillCut]
    /// For CNC layers: arc-length ranges of each path where the tool lifts to leave a holding tab
    /// (same order as `paths`). Laser tabs are already left out of `paths`.
    public var tabs: [[ClosedRange<Double>]]
    /// Every holding tab on the layer, for the canvas.
    public var tabMarks: [TabMark]

    public init(layer: Layer, paths: [[Vec2]], rasters: [RasterRow] = [], cuts: [MillCut] = [],
                tabs: [[ClosedRange<Double>]] = [], tabMarks: [TabMark] = []) {
        self.layer = layer
        self.paths = paths
        self.rasters = rasters
        self.cuts = cuts
        self.tabs = tabs
        self.tabMarks = tabMarks
    }

    public func tabs(at i: Int) -> [ClosedRange<Double>] { i < tabs.count ? tabs[i] : [] }

    public func cut(at i: Int) -> MillCut { i < cuts.count ? cuts[i] : .onLine }

    public var cutLength: Double {
        let vector = paths.reduce(0) { total, p in
            var l = 0.0
            if p.count > 1 { for i in 1..<p.count { l += p[i].distance(to: p[i - 1]) } }
            return total + l
        }
        let raster = rasters.reduce(0) { $0 + ($1.x1 - $1.x0) + 2 * layer.overscan }
        return vector + raster
    }

    /// Number of depth passes for CNC milling.
    public var depthPasses: Int {
        guard layer.mode == .mill else { return 1 }
        return max(1, Int((layer.cutDepth / max(0.05, layer.stepDown)).rounded(.up)))
    }
}

public struct Toolpath: Sendable {
    public var layers: [ToolpathLayer]

    public var isEmpty: Bool { layers.allSatisfy { $0.paths.isEmpty } }

    /// Every holding tab in the job.
    public var tabMarks: [TabMark] { layers.flatMap(\.tabMarks) }

    public var bounds: Rect2 {
        var r = Rect2.empty
        for l in layers {
            for p in l.paths { for v in p { r.include(v) } }
            for row in l.rasters {
                r.include(Vec2(row.x0, row.y))
                r.include(Vec2(row.x1, row.y))
            }
        }
        return r
    }

    /// Travel (pen up / laser off) moves, for previews.
    public var travelMoves: [(Vec2, Vec2)] {
        var out: [(Vec2, Vec2)] = []
        var pos = Vec2.zero
        var first = true
        for l in layers {
            for _ in 0..<(max(1, l.layer.passes) * l.depthPasses) {
                for p in l.paths {
                    guard let s = p.first, let e = p.last else { continue }
                    if !first { out.append((pos, s)) }
                    first = false
                    pos = e
                }
            }
        }
        return out
    }

    /// Rough job duration in seconds.
    public func estimatedSeconds(profile: DeviceProfile) -> Double {
        var t = 0.0
        let travel = travelMoves.reduce(0) { $0 + $1.0.distance(to: $1.1) }
        for l in layers {
            let speedMMs: Double
            if l.layer.mode == .cut || profile.kind == .vinylCutter {
                speedMMs = Double(max(1, l.layer.cutSpeed)) * 10
            } else {
                speedMMs = max(1, l.layer.speed) / 60
            }
            t += l.cutLength * Double(max(1, l.layer.passes) * l.depthPasses) / speedMMs
        }
        t += travel / max(1, profile.rapidSpeed / 60)
        return t
    }
}

public enum Planner {
    /// Builds the toolpath for all enabled layers that have shapes. Fill layers run
    /// before line layers so engraving happens before parts are cut free.
    /// Whether a layer of `mode` produces moves on a machine of `kind`.
    public static func supports(_ mode: LayerMode, on kind: DeviceKind) -> Bool {
        switch (mode, kind) {
        case (.print, _): return false
        case (.line, _): return true
        case (.fill, .grblLaser), (.image, .grblLaser): return true
        case (.cut, .vinylCutter), (.cut, .grblLaser): return true
        case (.mill, .cncRouter), (.cut, .cncRouter): return true
        default: return false
        }
    }

    public static func plan(_ doc: KerfDocument, for kind: DeviceKind) -> Toolpath {
        var layers: [ToolpathLayer] = []
        var pos = Vec2.zero
        // Engrave before cutting so parts don't move once they are cut free.
        let rank: (LayerMode) -> Int = { $0 == .image ? 0 : ($0 == .fill ? 1 : 2) }
        let ordered = doc.layers.enumerated().sorted { (rank($0.element.mode), $0.offset) < (rank($1.element.mode), $1.offset) }.map(\.element)
        let all = doc.machineShapes()
        for var layer in ordered where layer.enabled && supports(layer.mode, on: kind) {
            if kind == .cncRouter { layer.mode = .mill }
            let shapes = all.filter { $0.layerID == layer.id }
            if layer.mode == .image {
                let rows = shapes.flatMap { Raster.rows(for: $0, layer: layer) }
                guard !rows.isEmpty else { continue }
                layers.append(ToolpathLayer(layer: layer, paths: [], rasters: rows))
                continue
            }
            if layer.mode == .mill {
                let (paths, cuts, owners) = millPaths(shapes.filter { $0.image == nil }, layer: layer, from: pos)
                guard !paths.isEmpty else { continue }
                pos = paths.last?.last ?? pos
                // Tabs on parts (and by hand on holes). The tool eats into the bridge from both sides,
                // so the lifted stretch is the tab width plus the tool diameter.
                let width = max(0, layer.tabWidth) + max(0, layer.toolDiameter)
                let placed = HoldingTabs.place(paths: paths, owners: owners, autoEligible: cuts.map { $0 == .part },
                                               manualEligible: cuts.map { $0 == .part || $0 == .hole },
                                               layer: layer, width: width)
                let tabs = zip(paths, placed).map { path, p in
                    HoldingTabs.intervals(centers: p.map(\.s), width: width, total: HoldingTabs.cumulative(path).last ?? 0)
                }
                let marks = paths.indices.flatMap {
                    HoldingTabs.marks(on: paths[$0], placed: placed[$0], owner: owners[$0].id, width: width)
                }
                layers.append(ToolpathLayer(layer: layer, paths: paths, cuts: cuts, tabs: tabs, tabMarks: marks))
                continue
            }
            var polys: [Polyline] = []
            var owners: [Artwork] = []
            for shape in shapes where shape.image == nil {
                for p in shape.placedPaths where p.points.count > 1 {
                    polys.append(p)
                    owners.append(shape)
                }
            }
            guard !polys.isEmpty else { continue }
            var paths: [[Vec2]]
            var marks: [TabMark] = []
            if layer.mode == .fill {
                paths = hatch(polys.filter { $0.closed }, interval: layer.fillInterval, angleDegrees: layer.fillAngle,
                              bidirectional: layer.fillBidirectional)
            } else if kind == .grblLaser, layer.tabsEnabled {
                (paths, marks) = laserPathsWithTabs(polys, owners: owners, layer: layer, from: pos)
            } else {
                paths = order(polys, from: pos, innerFirst: true)
            }
            guard !paths.isEmpty else { continue }
            pos = paths.last?.last ?? pos
            layers.append(ToolpathLayer(layer: layer, paths: paths, tabMarks: marks))
        }
        return Toolpath(layers: layers)
    }

    /// Laser outlines in cutting order with holding tabs left uncut: automatic tabs on parts (closed
    /// outlines that aren't holes in another), and hand-placed tabs on any closed outline of their shape.
    static func laserPathsWithTabs(_ polys: [Polyline], owners: [Artwork], layer: Layer,
                                   from start: Vec2) -> ([[Vec2]], [TabMark]) {
        let depth = layerNestingDepth(polys, owners: owners)
        let ordered = orderIndexed(polys, from: start, innerFirst: true)
        let paths = ordered.map(\.1)
        let pathOwners = ordered.map { owners[$0.0] }
        let width = max(0.01, layer.laserTabWidth)
        let placed = HoldingTabs.place(paths: paths, owners: pathOwners,
                                       autoEligible: ordered.map { polys[$0.0].closed && depth[$0.0] % 2 == 0 },
                                       manualEligible: ordered.map { polys[$0.0].closed },
                                       layer: layer, width: width)
        var out: [[Vec2]] = []
        var marks: [TabMark] = []
        for (i, path) in paths.enumerated() {
            guard !placed[i].isEmpty else {
                out.append(path)
                continue
            }
            let total = HoldingTabs.cumulative(path).last ?? 0
            let ranges = HoldingTabs.intervals(centers: placed[i].map(\.s), width: width, total: total)
            out += HoldingTabs.split(path, tabs: ranges)
            marks += HoldingTabs.marks(on: path, placed: placed[i], owner: pathOwners[i].id, width: width)
        }
        return (out, marks)
    }

    /// Nesting depth of each outline within its layer, with text nested only within itself
    /// (so lettering behaves the same wherever it sits). Even depths are parts, odd ones holes.
    static func layerNestingDepth(_ polys: [Polyline], owners: [Artwork]) -> [Int] {
        var depth = [Int](repeating: 0, count: polys.count)
        var groups: [UUID?: [Int]] = [:]
        for i in polys.indices { groups[owners[i].text == nil ? nil : owners[i].id, default: []].append(i) }
        for (_, members) in groups {
            for (k, d) in nestingDepth(members.map { polys[$0] }).enumerated() { depth[members[k]] = d }
        }
        return depth
    }

    // MARK: - Ordering

    /// Orders outlines to reduce travel. With `innerFirst`, shapes nested inside other
    /// shapes are cut first (so letter counters and holes are cut before the outline frees the part).
    public static func order(_ polys: [Polyline], from start: Vec2, innerFirst: Bool) -> [[Vec2]] {
        orderIndexed(polys, from: start, innerFirst: innerFirst).map(\.1)
    }

    /// Like `order`, also returning each path's index in `polys`.
    public static func orderIndexed(_ polys: [Polyline], from start: Vec2, innerFirst: Bool) -> [(Int, [Vec2])] {
        let bounds = polys.map(\.bounds)
        var depth = [Int](repeating: 0, count: polys.count)
        if innerFirst {
            for i in polys.indices where polys[i].closed {
                for j in polys.indices where j != i && polys[j].closed {
                    let bi = bounds[i], bj = bounds[j]
                    if bj.contains(bi) && (bj.width * bj.height) > (bi.width * bi.height) + 1e-9 { depth[i] += 1 }
                }
            }
        }
        var out: [(Int, [Vec2])] = []
        var pos = start
        let levels = Set(depth).sorted(by: >)
        for level in levels {
            var remaining = polys.indices.filter { depth[$0] == level }
            while !remaining.isEmpty {
                var bestK = 0, bestDist = Double.infinity, bestVertex = 0, bestReverse = false
                for (k, idx) in remaining.enumerated() {
                    let b = bounds[idx]
                    let dx = max(b.minX - pos.x, 0, pos.x - b.maxX), dy = max(b.minY - pos.y, 0, pos.y - b.maxY)
                    if (dx * dx + dy * dy).squareRoot() >= bestDist { continue }
                    let p = polys[idx]
                    if p.closed {
                        for (vi, v) in p.points.enumerated() {
                            let dd = v.distance(to: pos)
                            if dd < bestDist { bestDist = dd; bestK = k; bestVertex = vi; bestReverse = false }
                        }
                    } else {
                        let ds = p.points.first!.distance(to: pos), de = p.points.last!.distance(to: pos)
                        if ds < bestDist { bestDist = ds; bestK = k; bestReverse = false }
                        if de < bestDist { bestDist = de; bestK = k; bestReverse = true }
                    }
                }
                let idx = remaining.remove(at: bestK)
                var p = polys[idx]
                if p.closed { p = p.rotatedStart(to: bestVertex) } else if bestReverse { p = p.reversed }
                let pts = p.drawnPoints
                out.append((idx, pts))
                pos = pts.last ?? pos
            }
        }
        return out
    }

    // MARK: - CNC

    /// Nesting depth of each closed polyline among `polys` (how many others contain it).
    static func nestingDepth(_ polys: [Polyline]) -> [Int] {
        polys.indices.map { i in
            guard polys[i].closed, !polys[i].points.isEmpty else { return 0 }
            // A shape only counts as inside another when it is wholly inside, so a letter that
            // crosses a circle's line isn't treated as a hole in it.
            let pts = polys[i].points
            let stride = max(1, pts.count / 24)
            let probes = Swift.stride(from: 0, to: pts.count, by: stride).map { pts[$0] }
            let bi = polys[i].bounds
            return polys.indices.filter { j in
                guard j != i, polys[j].closed, polys[j].bounds.contains(bi, tolerance: 1e-6) else { return false }
                return probes.allSatisfy { contains(polys[j], $0) }
            }.count
        }
    }

    /// Even-odd point-in-polygon test.
    public static func contains(_ poly: Polyline, _ p: Vec2) -> Bool {
        let pts = poly.points
        guard pts.count > 2 else { return false }
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Builds CNC paths: tool-offset contours for parts and holes, centre-line paths, pocket clearing and drill points.
    /// Also returns the shape each path came from.
    static func millPaths(_ shapes: [Artwork], layer: Layer, from start: Vec2) -> ([[Vec2]], [MillCut], [Artwork]) {
        let r = max(0, layer.toolDiameter / 2)
        // Auto roles come from nesting across the whole layer, so a hole drawn as a separate shape still counts.
        // Text is self-contained: its letters and counters nest only within the text itself, so the
        // same lettering cuts the same way whether or not it sits inside another outline.
        var depthLookup: [Polyline: Int] = [:]
        var groups: [[Polyline]] = [shapes.filter { $0.text == nil }.flatMap(\.placedPaths)]
        groups += shapes.filter { $0.text != nil }.map(\.placedPaths)
        for group in groups {
            let polys = group.filter { $0.points.count > 1 }
            for (p, d) in zip(polys, nestingDepth(polys)) { depthLookup[p] = d }
        }

        var contours: [Polyline] = []
        var contourCuts: [MillCut] = []
        var contourOwners: [Artwork] = []
        var prefixes: [[[Vec2]]] = [] // pocket clearing that runs before a contour
        var drills: [(Vec2, Artwork)] = []

        for shape in shapes {
            let role = shape.millRole ?? layer.defaultMillRole
            let polys = shape.placedPaths.filter { $0.points.count > 1 }
            switch role {
            case .drill:
                let b = polys.bounds
                if !b.isEmpty { drills.append((b.center, shape)) }
            case .pocket:
                let depths = nestingDepth(polys)
                // Outer edges shrink by the tool radius; islands grow.
                let regions: [(Polyline, Int)] = zip(polys, depths)
                    .filter { $0.0.closed }
                    .map { (PathOffset.offset($0.0, by: $0.1 % 2 == 0 ? -r : r), $0.1) }
                    .filter { abs($0.0.signedArea) > 1e-6 }
                guard !regions.isEmpty else { continue }
                let valid = regions.map(\.0)
                let rows = hatch(valid, interval: max(0.05, layer.toolDiameter * min(max(layer.stepover, 0.05), 1)),
                                 angleDegrees: 0, bidirectional: true)
                let clearing = linkRows(rows, inside: valid, maxGap: layer.toolDiameter * 1.5)
                for (k, region) in regions.enumerated() {
                    contours.append(region.0)
                    contourCuts.append(region.1 % 2 == 0 ? .hole : .part)
                    contourOwners.append(shape)
                    prefixes.append(k == 0 ? clearing : [])
                }
            case .part, .hole, .onLine, .auto:
                for p in polys {
                    let cut: MillCut
                    if !p.closed || role == .onLine {
                        cut = .onLine
                    } else if role == .part {
                        cut = .part
                    } else if role == .hole {
                        cut = .hole
                    } else {
                        cut = (depthLookup[p] ?? 0) % 2 == 0 ? .part : .hole
                    }
                    let path: Polyline
                    switch cut {
                    case .part: path = PathOffset.offset(p, by: r)
                    case .hole: path = PathOffset.offset(p, by: -r)
                    default: path = p
                    }
                    if cut == .hole, abs(path.signedArea) < 1e-6 || path.signedArea * p.signedArea < 0 { continue } // smaller than the tool
                    contours.append(path)
                    contourCuts.append(cut)
                    contourOwners.append(shape)
                    prefixes.append([])
                }
            }
        }

        var paths: [[Vec2]] = []
        var cuts: [MillCut] = []
        var owners: [Artwork] = []
        var pos = start
        // Drill first, then contours with holes and pockets before the parts that contain them.
        for (d, shape) in drills {
            paths.append([d])
            cuts.append(.drill)
            owners.append(shape)
            pos = d
        }
        for (idx, pts) in orderIndexed(contours, from: pos, innerFirst: true) {
            for row in prefixes[idx] {
                paths.append(row)
                cuts.append(.pocketClear)
                owners.append(contourOwners[idx])
            }
            paths.append(pts)
            cuts.append(contourCuts[idx])
            owners.append(contourOwners[idx])
        }
        return (paths, cuts, owners)
    }

    /// Joins consecutive pocket rows into zig-zags where the link stays inside the pocket.
    static func linkRows(_ rows: [[Vec2]], inside boundaries: [Polyline], maxGap: Double) -> [[Vec2]] {
        func inPocket(_ p: Vec2) -> Bool {
            boundaries.filter { contains($0, p) }.count % 2 == 1
        }
        var out: [[Vec2]] = []
        for row in rows {
            if var last = out.last, let e = last.last, let s = row.first,
               e.distance(to: s) <= maxGap, inPocket((e + s) / 2) {
                last += row
                out[out.count - 1] = last
            } else {
                out.append(row)
            }
        }
        return out
    }

    // MARK: - Fill

    /// Even-odd scanline fill of closed outlines.
    public static func hatch(_ polys: [Polyline], interval: Double, angleDegrees: Double, bidirectional: Bool) -> [[Vec2]] {
        guard interval > 0.005, !polys.isEmpty else { return [] }
        let angle = angleDegrees * .pi / 180
        // Rotate so scanlines are horizontal.
        let rotated = polys.map { Polyline($0.points.map { $0.rotated(by: -angle) }, closed: true) }
        let b = rotated.bounds
        guard !b.isEmpty else { return [] }
        var edges: [(Vec2, Vec2)] = []
        for p in rotated where p.points.count > 2 {
            for i in 0..<p.points.count {
                let a = p.points[i], c = p.points[(i + 1) % p.points.count]
                if a.y != c.y { edges.append((a, c)) }
            }
        }
        var out: [[Vec2]] = []
        var y = b.minY + interval / 2
        var forward = true
        while y < b.maxY {
            var xs: [Double] = []
            for (a, c) in edges {
                let lo = min(a.y, c.y), hi = max(a.y, c.y)
                if y >= lo && y < hi {
                    xs.append(a.x + (y - a.y) * (c.x - a.x) / (c.y - a.y))
                }
            }
            xs.sort()
            var segs: [[Vec2]] = []
            var i = 0
            while i + 1 < xs.count {
                if xs[i + 1] - xs[i] > 1e-6 {
                    segs.append([Vec2(xs[i], y), Vec2(xs[i + 1], y)])
                }
                i += 2
            }
            if !forward {
                segs = segs.reversed().map { $0.reversed() }
            }
            out += segs.map { $0.map { $0.rotated(by: angle) } }
            if bidirectional { forward.toggle() }
            y += interval
        }
        return out
    }
}
