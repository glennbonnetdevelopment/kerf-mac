import Foundation

/// The moves for one layer, in design space. Each path is an explicit point list
/// (closed outlines repeat their first point at the end).
public struct ToolpathLayer: Sendable {
    public var layer: Layer
    public var paths: [[Vec2]]

    public var cutLength: Double {
        paths.reduce(0) { total, p in
            var l = 0.0
            if p.count > 1 { for i in 1..<p.count { l += p[i].distance(to: p[i - 1]) } }
            return total + l
        }
    }
}

public struct Toolpath: Sendable {
    public var layers: [ToolpathLayer]

    public var isEmpty: Bool { layers.allSatisfy { $0.paths.isEmpty } }

    public var bounds: Rect2 {
        var r = Rect2.empty
        for l in layers { for p in l.paths { for v in p { r.include(v) } } }
        return r
    }

    /// Travel (pen up / laser off) moves, for previews.
    public var travelMoves: [(Vec2, Vec2)] {
        var out: [(Vec2, Vec2)] = []
        var pos = Vec2.zero
        var first = true
        for l in layers {
            for _ in 0..<max(1, l.layer.passes) {
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
            t += l.cutLength * Double(max(1, l.layer.passes)) / speedMMs
        }
        t += travel / max(1, profile.rapidSpeed / 60)
        return t
    }
}

public enum Planner {
    /// Builds the toolpath for all enabled layers that have shapes. Fill layers run
    /// before line layers so engraving happens before parts are cut free.
    public static func plan(_ doc: KerfDocument, for kind: DeviceKind) -> Toolpath {
        var layers: [ToolpathLayer] = []
        var pos = Vec2.zero
        let ordered = doc.layers.filter { $0.mode == .fill } + doc.layers.filter { $0.mode != .fill }
        for layer in ordered where layer.enabled {
            if kind == .vinylCutter && layer.mode == .fill { continue }
            let polys = doc.shapes.filter { $0.layerID == layer.id }.flatMap(\.placedPaths).filter { $0.points.count > 1 }
            guard !polys.isEmpty else { continue }
            var paths: [[Vec2]]
            if layer.mode == .fill {
                paths = hatch(polys.filter { $0.closed }, interval: layer.fillInterval, angleDegrees: layer.fillAngle,
                              bidirectional: layer.fillBidirectional)
            } else {
                paths = order(polys, from: pos, innerFirst: true)
            }
            guard !paths.isEmpty else { continue }
            pos = paths.last?.last ?? pos
            layers.append(ToolpathLayer(layer: layer, paths: paths))
        }
        return Toolpath(layers: layers)
    }

    // MARK: - Ordering

    /// Orders outlines to reduce travel. With `innerFirst`, shapes nested inside other
    /// shapes are cut first (so letter counters and holes are cut before the outline frees the part).
    public static func order(_ polys: [Polyline], from start: Vec2, innerFirst: Bool) -> [[Vec2]] {
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
        var out: [[Vec2]] = []
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
                out.append(pts)
                pos = pts.last ?? pos
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
