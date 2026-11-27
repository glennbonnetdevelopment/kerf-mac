import Foundation

/// One reading of the pointer while drawing freehand.
public struct StrokeSample: Hashable, Sendable {
    public var point: Vec2
    /// How hard the pen pressed, 0…1. A mouse always reports 1.
    public var pressure: Double
    /// Seconds, from any fixed starting point.
    public var time: Double

    public init(_ point: Vec2, pressure: Double = 1, time: Double = 0) {
        self.point = point
        self.pressure = pressure
        self.time = time
    }
}

/// How a brush stroke's width changes along the stroke.
public struct BrushOptions: Hashable, Sendable {
    /// Full width of the stroke in mm.
    public var width: Double
    /// How much fast movement (or light pen pressure) thins the stroke, 0 (never) … 1 (down to a hairline).
    public var thinning: Double
    /// Narrow the stroke to a point at both ends.
    public var taper: Bool
    /// Use pen pressure when the device reports it (a tablet or a pressure-sensitive trackpad).
    public var usePressure: Bool

    public init(width: Double = 3, thinning: Double = 0.5, taper: Bool = true, usePressure: Bool = true) {
        self.width = width
        self.thinning = thinning
        self.taper = taper
        self.usePressure = usePressure
    }
}

/// Freehand drawing: smoothing pen strokes into clean paths and turning brush strokes into outlines.
public enum Freehand {
    /// Smooths raw pointer positions into a path. `tolerance` is how far (mm) the result may stray from the
    /// hand-drawn line to iron out wobble; the stroke closes when it ends within `closeDistance` of its start.
    public static func smooth(_ raw: [Vec2], tolerance: Double, closeDistance: Double = 0, step: Double = 0.2) -> Polyline {
        var pts = dedupe(raw, minDistance: max(1e-4, tolerance * 0.25))
        guard pts.count > 2 else { return Polyline(pts) }
        var closed = false
        if closeDistance > 0, pts.count > 4, let f = pts.first, let l = pts.last, f.distance(to: l) <= closeDistance {
            let len = Polyline(pts).length
            if len > closeDistance * 4 {
                closed = true
                while pts.count > 3, let l = pts.last, l.distance(to: pts[0]) <= closeDistance * 0.5 { pts.removeLast() }
            }
        }
        pts = relax(pts, closed: closed, iterations: 2)
        let keys: [Vec2]
        if closed {
            keys = Contour.simplify(Polyline(pts, closed: true), tolerance: tolerance).points
        } else {
            keys = Contour.rdp(pts, tolerance: tolerance)
        }
        guard keys.count > 2 else { return Polyline(keys, closed: false) }
        return Polyline(catmullRom(keys, closed: closed, step: step), closed: closed).deduplicated()
    }

    /// The outline of a brush stroke: a closed shape (or a ring, when the stroke closes on itself) whose width
    /// follows the options. The outline may overlap itself where the stroke crosses itself; fill it with the
    /// non-zero rule, or clean it with a path boolean. `speedReference` is the speed (mm/s) that thins the stroke
    /// by half of `thinning`.
    public static func brushOutline(_ samples: [StrokeSample], options: BrushOptions, tolerance: Double,
                                    closeDistance: Double = 0, speedReference: Double = 150) -> [Polyline] {
        let radius = max(0.01, options.width / 2)
        guard let first = samples.first else { return [] }
        let raw = samples.map(\.point)
        let extent = raw.reduce(Rect2.empty) { r, p in var r = r; r.include(p); return r }
        if max(extent.width, extent.height) < max(radius * 0.5, tolerance) {
            return [dot(at: first.point, radius: radius)]
        }

        // How wide each raw sample should be, 0…1 of the full width.
        let rawLength = cumulativeLengths(raw)
        let factors = widthFactors(samples, options: options, speedReference: speedReference)

        let center = smooth(raw, tolerance: tolerance, closeDistance: closeDistance, step: 0.2)
        let spacing = min(1, max(0.1, radius / 3))
        var pts = resample(center.drawnPoints, spacing: spacing)
        if center.closed, pts.count > 2, let f = pts.first, let l = pts.last, f.distance(to: l) < spacing * 0.5 { pts.removeLast() }
        guard pts.count >= 2 else { return [dot(at: first.point, radius: radius)] }

        let centerLength = cumulativeLengths(pts)
        let total = max(1e-9, centerLength.last ?? 0)
        let rawTotal = max(1e-9, rawLength.last ?? 0)
        let minFraction = 0.08
        let taperLength = min(radius * 8, total * 0.3)
        var widths: [Double] = []
        widths.reserveCapacity(pts.count)
        for i in pts.indices {
            let s = centerLength[i]
            var f = interpolate(factors, at: s / total * rawTotal, positions: rawLength)
            if options.taper, !center.closed, taperLength > 0 {
                let edge = min(s, total - s) / taperLength
                f *= minFraction + (1 - minFraction) * smoothstep(min(1, edge))
            }
            widths.append(radius * max(minFraction, f))
        }

        // Left and right edges along the normals.
        var left: [Vec2] = [], right: [Vec2] = [], tangents: [Vec2] = []
        let n = pts.count
        for i in 0..<n {
            let prev = center.closed ? pts[(i - 1 + n) % n] : pts[max(0, i - 1)]
            let next = center.closed ? pts[(i + 1) % n] : pts[min(n - 1, i + 1)]
            var t = (next - prev).normalized
            if t == .zero { t = tangents.last ?? Vec2(1, 0) }
            tangents.append(t)
            let normal = Vec2(-t.y, t.x)
            left.append(pts[i] + normal * widths[i])
            right.append(pts[i] - normal * widths[i])
        }

        if center.closed {
            return [Polyline(left, closed: true), Polyline(right.reversed(), closed: true)]
        }
        var outline = left
        outline += cap(center: pts[n - 1], tangent: tangents[n - 1], radius: widths[n - 1])
        outline += right.reversed()
        outline += cap(center: pts[0], tangent: -tangents[0], radius: widths[0])
        return [Polyline(outline, closed: true).deduplicated()]
    }

    // MARK: - Helpers

    static func dot(at p: Vec2, radius: Double) -> Polyline {
        Flatten.ellipse(center: p, rx: radius, ry: radius, step: max(0.05, radius / 12))
    }

    /// Half circle from the left edge round the front to the right edge (left = tangent turned anticlockwise),
    /// not including either end.
    static func cap(center c: Vec2, tangent t: Vec2, radius r: Double) -> [Vec2] {
        let normal = Vec2(-t.y, t.x)
        let steps = max(6, Int((Double.pi * r / 0.2).rounded(.up)))
        return (1..<steps).map { i in
            let a = Double.pi * Double(i) / Double(steps)
            return c + (normal * cos(a) + t * sin(a)) * r
        }
    }

    static func dedupe(_ pts: [Vec2], minDistance: Double) -> [Vec2] {
        var out: [Vec2] = []
        out.reserveCapacity(pts.count)
        for p in pts where out.last.map({ $0.distance(to: p) >= minDistance }) ?? true { out.append(p) }
        // Keep the real end point so the stroke finishes where the pointer let go.
        if let l = pts.last, let o = out.last, o != l {
            if out.count > 1 { out[out.count - 1] = l } else { out.append(l) }
        }
        return out
    }

    /// Light neighbour averaging that takes the jitter out before simplifying. Ends stay put on open strokes.
    static func relax(_ pts: [Vec2], closed: Bool, iterations: Int) -> [Vec2] {
        var cur = pts
        let n = cur.count
        guard n > 2 else { return cur }
        for _ in 0..<iterations {
            var next = cur
            for i in 0..<n {
                if !closed, i == 0 || i == n - 1 { continue }
                let a = cur[(i - 1 + n) % n], b = cur[(i + 1) % n]
                next[i] = a * 0.25 + cur[i] * 0.5 + b * 0.25
            }
            cur = next
        }
        return cur
    }

    /// A Catmull–Rom spline through `keys`, flattened to points about `step` apart.
    static func catmullRom(_ keys: [Vec2], closed: Bool, step: Double) -> [Vec2] {
        let n = keys.count
        guard n > 2 else { return keys }
        func key(_ i: Int) -> Vec2 {
            if closed { return keys[(i % n + n) % n] }
            if i < 0 { return keys[0] * 2 - keys[1] }
            if i >= n { return keys[n - 1] * 2 - keys[n - 2] }
            return keys[i]
        }
        var out = [keys[0]]
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let p0 = key(i - 1), p1 = key(i), p2 = key(i + 1), p3 = key(i + 2)
            // Limit the handles to the segment's length so sharp turns don't loop.
            let len = p1.distance(to: p2)
            var h1 = (p2 - p0) / 6, h2 = (p3 - p1) / 6
            if h1.length > len * 0.5 { h1 = h1.normalized * (len * 0.5) }
            if h2.length > len * 0.5 { h2 = h2.normalized * (len * 0.5) }
            out += Flatten.cubic(p1, p1 + h1, p2 - h2, p2, step: step)
        }
        if closed { out.removeLast() } // back at the first key
        return out
    }

    static func cumulativeLengths(_ pts: [Vec2]) -> [Double] {
        var out = [0.0]
        out.reserveCapacity(pts.count)
        for i in pts.indices.dropFirst() { out.append(out[i - 1] + pts[i].distance(to: pts[i - 1])) }
        return out
    }

    /// Points evenly `spacing` apart along the run, keeping both ends.
    static func resample(_ pts: [Vec2], spacing: Double) -> [Vec2] {
        guard pts.count > 1, spacing > 0 else { return pts }
        var out = [pts[0]]
        var carry = 0.0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let seg = a.distance(to: b)
            guard seg > 0 else { continue }
            var d = spacing - carry
            while d <= seg {
                out.append(a + (b - a) * (d / seg))
                d += spacing
            }
            carry = seg - (d - spacing)
        }
        if let l = pts.last, let o = out.last, o.distance(to: l) > spacing * 0.25 { out.append(l) } else if out.count > 1 { out[out.count - 1] = pts.last! }
        return out
    }

    static func interpolate(_ values: [Double], at s: Double, positions: [Double]) -> Double {
        guard let firstValue = values.first else { return 1 }
        guard values.count > 1, s > positions[0] else { return firstValue }
        guard s < positions[positions.count - 1] else { return values[values.count - 1] }
        var lo = 0, hi = positions.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if positions[mid] <= s { lo = mid } else { hi = mid }
        }
        let span = positions[hi] - positions[lo]
        let t = span > 0 ? (s - positions[lo]) / span : 0
        return values[lo] + (values[hi] - values[lo]) * t
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// Width (0…1) at each sample: from pressure when the device reports varying pressure, otherwise from speed.
    static func widthFactors(_ samples: [StrokeSample], options: BrushOptions, speedReference: Double) -> [Double] {
        let thin = min(1, max(0, options.thinning))
        guard thin > 0 else { return samples.map { _ in 1 } }
        let pressures = samples.map(\.pressure)
        let hasPressure = options.usePressure && (pressures.max() ?? 1) - (pressures.min() ?? 1) > 0.05
        var raw: [Double]
        if hasPressure {
            raw = pressures.map { 1 - thin * (1 - min(1, max(0, $0))) }
        } else {
            raw = samples.indices.map { i -> Double in
                guard i > 0 else { return 1 }
                let dt = samples[i].time - samples[i - 1].time
                guard dt > 1e-4 else { return .nan }
                let speed = samples[i].point.distance(to: samples[i - 1].point) / dt
                let normalized = speed / (speed + max(1e-6, speedReference))
                return 1 - thin * normalized
            }
            // Fill gaps where two readings came at the same moment.
            var last = 1.0
            for i in raw.indices { if raw[i].isNaN { raw[i] = last } else { last = raw[i] } }
            if raw.count > 1 { raw[0] = raw[1] }
        }
        // Even out the readings so the edge doesn't ripple.
        let window = 3
        return raw.indices.map { i in
            let lo = max(0, i - window), hi = min(raw.count - 1, i + window)
            return raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }
}

/// Rubbing out parts of paths along an eraser trail.
public enum Eraser {
    /// Distance from `p` to the nearest point of the trail.
    public static func distance(_ p: Vec2, toTrail trail: [Vec2]) -> Double {
        guard let first = trail.first else { return .infinity }
        guard trail.count > 1 else { return p.distance(to: first) }
        var best = Double.infinity
        for i in 1..<trail.count {
            best = min(best, segmentDistance(p, trail[i - 1], trail[i]))
        }
        return best
    }

    static func segmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let l2 = ab.dot(ab)
        guard l2 > 1e-18 else { return p.distance(to: a) }
        let t = min(1, max(0, (p - a).dot(ab) / l2))
        return p.distance(to: a + ab * t)
    }

    static func segmentsCross(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let r = b - a, s = d - c
        let den = r.cross(s)
        guard abs(den) > 1e-12 else { return false }
        let t = (c - a).cross(s) / den, u = (c - a).cross(r) / den
        return t >= 0 && t <= 1 && u >= 0 && u <= 1
    }

    static func trailBounds(_ trail: [Vec2], radius: Double) -> Rect2 {
        var r = Rect2.empty
        for p in trail { r.include(p) }
        return r.insetBy(-radius)
    }

    /// True when the eraser trail passes over the path's line (or, for a closed path, starts inside it).
    public static func touches(_ path: Polyline, trail: [Vec2], radius: Double, insideCounts: Bool = false) -> Bool {
        guard !trail.isEmpty, path.points.count > 0, path.bounds.insetBy(-radius).intersects(trailBounds(trail, radius: 0)) else { return false }
        let pts = path.drawnPoints
        if pts.count == 1 { return distance(pts[0], toTrail: trail) <= radius }
        for i in 1..<pts.count {
            // Trail points near the path's segment, or a trail segment crossing it.
            for q in trail where segmentDistance(q, pts[i - 1], pts[i]) <= radius { return true }
            for k in trail.indices.dropFirst() where segmentsCross(pts[i - 1], pts[i], trail[k - 1], trail[k]) { return true }
        }
        for p in pts where distance(p, toTrail: trail) <= radius { return true }
        if insideCounts, path.closed, Planner.contains(path, trail[0]) { return true }
        return false
    }

    /// Removes the parts of `paths` within `radius` of the trail, splitting lines where the eraser crossed.
    /// Closed paths that are crossed open up; untouched paths come back unchanged.
    public static func split(_ paths: [Polyline], trail: [Vec2], radius: Double) -> [Polyline] {
        guard !trail.isEmpty, radius > 0 else { return paths }
        let tb = trailBounds(trail, radius: radius)
        let step = max(0.02, radius / 4)
        var out: [Polyline] = []
        for path in paths {
            guard path.points.count > 1, path.bounds.intersects(tb), touches(path, trail: trail, radius: radius) else {
                out.append(path)
                continue
            }
            out += splitOne(path, trail: trail, radius: radius, step: step, bounds: tb)
        }
        return out
    }

    static func splitOne(_ path: Polyline, trail: [Vec2], radius: Double, step: Double, bounds tb: Rect2) -> [Polyline] {
        func erased(_ p: Vec2) -> Bool { tb.contains(p) && distance(p, toTrail: trail) <= radius }

        // Walk the path in small steps near the eraser, recording each point and whether it survives.
        var src = path.drawnPoints
        if path.closed, let i = src.indices.first(where: { erased(src[$0]) }), i > 0 {
            // Start the walk on an erased point so the loop opens there.
            src = Array(src[i..<(src.count - 1)]) + Array(src[0...i])
        }
        var pieces: [[Vec2]] = []
        var current: [Vec2] = []
        var prev = src[0]
        var prevErased = erased(prev)
        var anyErased = prevErased
        if !prevErased { current.append(prev) }

        func boundary(_ a: Vec2, _ b: Vec2, aErased: Bool) -> Vec2 {
            var lo = a, hi = b
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                if erased(mid) == aErased { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }

        for k in 1..<src.count {
            let a = src[k - 1], b = src[k]
            let seg = a.distance(to: b)
            let segBounds = Rect2(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
            let near = segBounds.intersects(tb)
            let count = near ? max(1, Int((seg / step).rounded(.up))) : 1
            for j in 1...count {
                let p = j == count ? b : a + (b - a) * (Double(j) / Double(count))
                let e = near ? erased(p) : false
                if e { anyErased = true }
                if e != prevErased {
                    let cut = boundary(prev, p, aErased: prevErased)
                    if prevErased {
                        current = [cut]
                    } else {
                        current.append(cut)
                        pieces.append(current)
                        current = []
                    }
                }
                if !e {
                    // Only keep the original corners (and the walk's end) so straight lines stay light.
                    if j == count { current.append(p) }
                }
                prev = p
                prevErased = e
            }
        }
        if !current.isEmpty { pieces.append(current) }
        // Nothing was rubbed out after all (the eraser only grazed the line between samples).
        if !anyErased { return [path] }
        // A loop that was walked from a surviving point: its last and first pieces are one piece.
        if path.closed, pieces.count > 1, !erased(src[0]), let last = pieces.popLast() {
            pieces[0] = last + pieces[0].dropFirst()
        }

        return pieces.compactMap { run in
            let poly = Polyline(run).deduplicated(tolerance: 1e-6)
            return poly.points.count > 1 && poly.length > 1e-3 ? poly : nil
        }
    }

    /// Paths with every one the trail touches removed.
    public static func removeTouched(_ paths: [Polyline], trail: [Vec2], radius: Double) -> [Polyline] {
        paths.filter { !touches($0, trail: trail, radius: radius) }
    }

    /// The area the eraser swept, as a closed outline (overlapping itself where the trail crosses; fill with non-zero).
    public static func sweptArea(_ trail: [Vec2], radius: Double) -> [Polyline] {
        guard let first = trail.first else { return [] }
        let samples = trail.map { StrokeSample($0) }
        if trail.count == 1 { return [Freehand.dot(at: first, radius: radius)] }
        return Freehand.brushOutline(samples, options: BrushOptions(width: radius * 2, thinning: 0, taper: false, usePressure: false),
                                     tolerance: 0.01)
    }
}
