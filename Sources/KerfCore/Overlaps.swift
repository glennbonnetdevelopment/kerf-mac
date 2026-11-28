import CoreGraphics
import Foundation

/// Cleans up outlines that overlap so a knife or laser follows only the outside edge.
///
/// Script fonts draw each letter as strokes that cross one another, and joined letters overlap their
/// neighbours. Cut as they are, the blade slices through the middle of the letters. Fixing the overlaps
/// merges each set of overlapping outlines into one outline (a weld), keeping real holes such as the
/// inside of an "o".
public enum OverlapFixer {
    /// One result of `fix`: either a single shape with its outlines cleaned, or several overlapping
    /// shapes on the same layer welded into one.
    public struct Group: Equatable, Sendable {
        /// Indexes into the shapes passed to `fix`, in their original order.
        public var members: [Int]
        /// For one member, the cleaned outlines in that shape's own coordinates (keep its transform).
        /// For several members, the welded outlines in bed coordinates (use an identity transform).
        public var paths: [Polyline]
        /// Length of cut line removed, in mm.
        public var removedLength: Double
        /// True when this group differs from what went in.
        public var changed: Bool
    }

    /// Cleans every shape's own overlaps, then welds shapes on the same layer that overlap each other.
    /// Text shapes trust the font's outline directions (the way the font is meant to be filled); other
    /// shapes treat an outline that lies wholly inside another as a hole.
    public static func fix(_ shapes: [Artwork]) -> [Group] {
        // Each shape on its own, in its own coordinates.
        let cleaned: [(local: [Polyline], placed: [Polyline], removed: Double, changed: Bool)] = shapes.map { s in
            let r = resolve(s.paths, trustWinding: s.text != nil)
            let placed = s.transform.isIdentity ? r.paths : r.paths.transformed(s.transform)
            return (r.paths, placed, r.removedLength, r.changed)
        }

        // Shapes on the same layer whose filled areas overlap form one group.
        var parent = Array(shapes.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        let fills = cleaned.map { filledPath(orientedByNesting($0.placed.filter(\.closed))) }
        let bounds = cleaned.map { $0.placed.filter(\.closed).bounds }
        for i in shapes.indices {
            for j in shapes.indices where j > i && shapes[i].layerID == shapes[j].layerID {
                guard !bounds[i].isEmpty, !bounds[j].isEmpty, bounds[i].intersects(bounds[j]) else { continue }
                if fills[i].intersects(fills[j], using: .winding) {
                    let a = root(i), b = root(j)
                    if a != b { parent[max(a, b)] = min(a, b) }
                }
            }
        }
        var members: [Int: [Int]] = [:]
        for i in shapes.indices { members[root(i), default: []].append(i) }

        return members.keys.sorted().map { key in
            let ids = members[key]!
            if ids.count == 1 {
                let c = cleaned[ids[0]]
                return Group(members: ids, paths: c.local, removedLength: c.removed, changed: c.changed)
            }
            let placed = ids.flatMap { cleaned[$0].placed }
            let before = ids.reduce(0.0) { $0 + closedLength(shapes[$1].placedPaths) }
            // Each member is clean now, so nesting gives the right directions for the weld.
            let r = resolve(placed, trustWinding: false)
            return Group(members: ids, paths: r.paths, removedLength: max(0, before - closedLength(r.paths)), changed: true)
        }
    }

    /// Merges overlapping closed outlines into clean, non-overlapping ones. Open paths are kept as they are.
    /// - Parameter trustWinding: fill by the outlines' own directions (right for font outlines); otherwise an
    ///   outline wholly inside another one is a hole and everything else is filled.
    public static func resolve(_ paths: [Polyline], trustWinding: Bool, step: Double = 0.1)
        -> (paths: [Polyline], removedLength: Double, changed: Bool) {
        let closed = paths.filter { $0.closed && $0.points.count > 2 }
        let open = paths.filter { !($0.closed && $0.points.count > 2) }
        guard !closed.isEmpty else { return (paths, 0, false) }
        let input = trustWinding ? closed : orientedByNesting(closed)
        let merged = polylines(filledPath(input).normalized(using: .winding), step: step)
            .filter { $0.points.count > 2 && abs($0.signedArea) > 1e-4 }
        guard !merged.isEmpty else { return (paths, 0, false) }
        let removed = closedLength(closed) - closedLength(merged)
        // Tiny differences are just rounding where nothing overlapped; leave such shapes alone.
        let changed = removed > 0.05 || merged.count != closed.count
        return changed ? (merged + open, max(0, removed), true) : (paths, 0, false)
    }

    /// Directions for the non-zero fill rule: outlines inside an even number of others run one way,
    /// those inside an odd number (holes) run the other. Outlines that only cross don't count as inside.
    public static func orientedByNesting(_ paths: [Polyline]) -> [Polyline] {
        let boxes = paths.map(\.bounds)
        return paths.indices.map { i in
            var depth = 0
            for j in paths.indices where j != i && boxes[j].contains(boxes[i], tolerance: 1e-9) {
                if isWhollyInside(paths[i], paths[j]) { depth += 1 }
            }
            let outer = depth % 2 == 0
            return (paths[i].signedArea > 0) == outer ? paths[i] : paths[i].reversed
        }
    }

    /// True when every sampled point of `inner` lies inside `outer`.
    static func isWhollyInside(_ inner: Polyline, _ outer: Polyline) -> Bool {
        let pts = inner.points
        guard !pts.isEmpty else { return false }
        let stride = max(1, pts.count / 48)
        var i = 0
        while i < pts.count {
            if !Planner.contains(outer, pts[i]) { return false }
            i += stride
        }
        return true
    }

    static func closedLength(_ paths: [Polyline]) -> Double {
        paths.filter(\.closed).reduce(0) { $0 + $1.length }
    }

    public static func filledPath(_ polys: [Polyline]) -> CGPath {
        let path = CGMutablePath()
        for p in polys where p.points.count > 1 {
            path.move(to: CGPoint(x: p.points[0].x, y: p.points[0].y))
            for q in p.points.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
            if p.closed { path.closeSubpath() }
        }
        return path
    }

    /// The path's outlines as polylines, with curves split into segments about `step` long.
    public static func polylines(_ path: CGPath, step: Double) -> [Polyline] {
        var out: [Polyline] = []
        var current: [Vec2] = []
        var pos = Vec2.zero
        func v(_ p: CGPoint) -> Vec2 { Vec2(Double(p.x), Double(p.y)) }
        func flush(closed: Bool) {
            if current.count > 1 { out.append(Polyline(current, closed: closed).deduplicated()) }
            current = []
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                flush(closed: false)
                pos = v(e.points[0])
                current = [pos]
            case .addLineToPoint:
                pos = v(e.points[0])
                current.append(pos)
            case .addQuadCurveToPoint:
                let c = v(e.points[0]), p = v(e.points[1])
                current += Flatten.quadratic(pos, c, p, step: step)
                pos = p
            case .addCurveToPoint:
                let c1 = v(e.points[0]), c2 = v(e.points[1]), p = v(e.points[2])
                current += Flatten.cubic(pos, c1, c2, p, step: step)
                pos = p
            case .closeSubpath:
                flush(closed: true)
            @unknown default:
                break
            }
        }
        flush(closed: false)
        // A closed subpath that ended by moving back to its start is still closed.
        return out.map { p in
            guard !p.closed, p.points.count > 2, let f = p.points.first, let l = p.points.last, f.distance(to: l) < 1e-6
            else { return p }
            return Polyline(Array(p.points.dropLast()), closed: true)
        }
    }
}
