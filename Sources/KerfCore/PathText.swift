import Foundation

/// Bends text outlines along a guide path, point by point, so letters follow curves.
public enum PathText {
    /// Places outlines given in line coordinates (x along the baseline, y down, baseline at 0)
    /// along `spec.guide`. Each outline is subdivided first so long straight edges bend too.
    public static func place(_ outlines: [Polyline], spec: PathTextSpec, smoothing: Double = 1) -> [Polyline] {
        let guide = Guide(spec.guide, closed: spec.closed)
        guard guide.total > 0 else { return [] }
        return outlines.map { poly in
            let pts = subdivide(poly, maxStep: 0.25).map { q -> Vec2 in
                let s = spec.offset + q.x
                let (p, t) = guide.frame(at: s, window: smoothing)
                let n = Vec2(-t.y, t.x)
                return p + n * (q.y - spec.gap)
            }
            return Polyline(pts, closed: poly.closed)
        }
    }

    /// A circular guide for curving a line of text `width` mm long by `degrees` of arc.
    /// Positive arches upward (letters outside the circle), negative bends into a bowl (letters inside).
    /// The arc is exactly `width` long, with its middle at (width / 2, 0).
    public static func arcGuide(width: Double, degrees: Double) -> PathTextSpec {
        let w = max(0.01, width)
        let theta = min(360, abs(degrees)) * Double.pi / 180
        guard theta > 1e-4 else { return PathTextSpec(guide: [Vec2(0, 0), Vec2(w, 0)], closed: false, gap: 0) }
        let r = w / theta
        let steps = max(24, Int(abs(degrees).rounded(.up)))
        let pts = (0...steps).map { i -> Vec2 in
            let f = Double(i) / Double(steps)
            if degrees > 0 {
                // Over the top of a circle centred below the text.
                let a = -Double.pi / 2 - theta / 2 + theta * f
                return Vec2(w / 2 + r * cos(a), r + r * sin(a))
            } else {
                // Along the bottom of a circle centred above the text.
                let a = Double.pi / 2 + theta / 2 - theta * f
                return Vec2(w / 2 + r * cos(a), -r + r * sin(a))
            }
        }
        return PathTextSpec(guide: pts, closed: false, gap: 0)
    }

    /// The point on the guide at arc length `s`.
    public static func point(on spec: PathTextSpec, at s: Double) -> Vec2? {
        let guide = Guide(spec.guide, closed: spec.closed)
        guard guide.total > 0 else { return nil }
        return guide.frame(at: s, window: 0.01).0
    }

    /// Arc length of the guide point nearest `p`.
    public static func nearestOffset(on spec: PathTextSpec, to p: Vec2) -> Double {
        let g = spec.guide
        guard g.count > 1 else { return 0 }
        var best = Double.infinity, bestS = 0.0, run = 0.0
        for i in 1..<g.count {
            let a = g[i - 1], b = g[i]
            let ab = b - a, len = ab.length
            let t = len > 0 ? max(0, min(1, (p - a).dot(ab) / (len * len))) : 0
            let d = (a + ab * t).distance(to: p)
            if d < best { best = d; bestS = run + len * t }
            run += len
        }
        return bestS
    }

    /// A closed guide oriented so text stands outside (clockwise on screen), starting at its top.
    public static func outsideGuide(_ poly: Polyline) -> [Vec2] {
        var pts = poly.deduplicated().points
        guard pts.count > 2 else { return poly.drawnPoints }
        if Polyline(pts, closed: true).signedArea < 0 { pts.reverse() }
        // Start at the topmost point (smallest y; leftmost on ties) so offset 0 is the top centre.
        let top = pts.indices.min { pts[$0].y < pts[$1].y - 1e-9 || (abs(pts[$0].y - pts[$1].y) <= 1e-9 && pts[$0].x < pts[$1].x) }!
        pts = Array(pts[top...] + pts[..<top])
        return pts + [pts[0]]
    }

    static func subdivide(_ poly: Polyline, maxStep: Double) -> [Vec2] {
        let src = poly.points
        guard src.count > 1 else { return src }
        var out: [Vec2] = [src[0]]
        let n = poly.closed ? src.count : src.count - 1
        for i in 0..<n {
            let a = src[i], b = src[(i + 1) % src.count]
            let pieces = max(1, Int((a.distance(to: b) / maxStep).rounded(.up)))
            for k in 1...pieces {
                if poly.closed && i == n - 1 && k == pieces { break } // closing point is implied
                out.append(a + (b - a) * (Double(k) / Double(pieces)))
            }
        }
        return out
    }

    struct Guide {
        var pts: [Vec2]
        var cum: [Double]
        var closed: Bool
        var total: Double { cum.last ?? 0 }

        init(_ guide: [Vec2], closed: Bool) {
            var pts = guide
            if closed, let f = pts.first, let l = pts.last, f.distance(to: l) > 1e-9 { pts.append(f) }
            self.pts = pts
            self.closed = closed
            var cum = [0.0]
            for i in pts.indices.dropFirst() { cum.append(cum[i - 1] + pts[i].distance(to: pts[i - 1])) }
            self.cum = cum
        }

        func raw(_ s: Double) -> Vec2 {
            guard pts.count > 1 else { return pts.first ?? .zero }
            var s = s
            if closed {
                s = s.truncatingRemainder(dividingBy: total)
                if s < 0 { s += total }
            } else if s < 0 {
                let t = (pts[1] - pts[0]).normalized
                return pts[0] + t * s
            } else if s > total {
                let t = (pts[pts.count - 1] - pts[pts.count - 2]).normalized
                return pts[pts.count - 1] + t * (s - total)
            }
            // Binary search for the segment.
            var lo = 1, hi = cum.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if cum[mid] < s { lo = mid + 1 } else { hi = mid }
            }
            let seg = max(1e-12, cum[lo] - cum[lo - 1])
            return pts[lo - 1] + (pts[lo] - pts[lo - 1]) * ((s - cum[lo - 1]) / seg)
        }

        /// Position and unit tangent; the tangent is averaged over ±window mm to round sharp corners.
        func frame(at s: Double, window: Double) -> (Vec2, Vec2) {
            let w = max(0.01, window)
            let d = raw(s + w) - raw(s - w)
            let t = d.length > 1e-12 ? d.normalized : Vec2(1, 0)
            return (raw(s), t)
        }
    }
}
