import Foundation

/// Imports ASCII DXF files (LINE, ARC, CIRCLE, ELLIPSE, LWPOLYLINE, POLYLINE, SPLINE).
/// DXF is y-up; the result is flipped to Kerf's y-down space and placed at (10, 10).
public enum DXFImporter {
    public static var flattenStep = 0.15

    public static func importFile(at url: URL) throws -> [ImportedGroup] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable("not a text DXF file")
        }
        return try importText(text)
    }

    private struct Pair {
        let code: Int
        let value: String
        var double: Double { Double(value) ?? 0 }
    }

    /// ACI colour index to hex for the standard first colours.
    static func aciColor(_ index: Int) -> String {
        switch index {
        case 1: return "#FF0000"
        case 2: return "#FFFF00"
        case 3: return "#00FF00"
        case 4: return "#00FFFF"
        case 5: return "#0000FF"
        case 6: return "#FF00FF"
        default: return "#000000"
        }
    }

    public static func importText(_ text: String) throws -> [ImportedGroup] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var pairs: [Pair] = []
        pairs.reserveCapacity(lines.count / 2)
        var i = 0
        while i + 1 < lines.count {
            if let code = Int(lines[i]) { pairs.append(Pair(code: code, value: lines[i + 1])) }
            i += 2
        }
        guard !pairs.isEmpty else { throw ImportError.unreadable("no DXF group codes found") }

        // Units from the header.
        var unitScale = 1.0
        if let idx = pairs.firstIndex(where: { $0.code == 9 && $0.value == "$INSUNITS" }), idx + 1 < pairs.count {
            switch Int(pairs[idx + 1].value) ?? 0 {
            case 1: unitScale = 25.4
            case 2: unitScale = 304.8
            case 5: unitScale = 10
            case 6: unitScale = 1000
            default: unitScale = 1
            }
        }

        // Find the ENTITIES section.
        guard let start = pairs.indices.first(where: { pairs[$0].code == 2 && pairs[$0].value == "ENTITIES" }) else {
            throw ImportError.empty
        }
        var end = pairs.count
        if let e = pairs[start...].firstIndex(where: { $0.code == 0 && $0.value == "ENDSEC" }) { end = e }

        // Split into entities.
        var entities: [(type: String, data: [Pair])] = []
        var j = start + 1
        while j < end {
            if pairs[j].code == 0 {
                let type = pairs[j].value
                var k = j + 1
                while k < end, pairs[k].code != 0 { k += 1 }
                entities.append((type, Array(pairs[(j + 1)..<k])))
                j = k
            } else {
                j += 1
            }
        }

        let step = flattenStep / unitScale
        var byColor: [String: [Polyline]] = [:]
        var order: [String] = []
        func add(_ p: Polyline, _ data: [Pair]) {
            guard p.points.count > 1 else { return }
            let color = data.first(where: { $0.code == 62 }).map { aciColor(Int($0.value) ?? 7) } ?? "#000000"
            if byColor[color] == nil { order.append(color) }
            byColor[color, default: []].append(p)
        }

        var e = 0
        while e < entities.count {
            let (type, d) = entities[e]
            switch type {
            case "LINE":
                add(Polyline([Vec2(val(d, 10), val(d, 20)), Vec2(val(d, 11), val(d, 21))]), d)
            case "CIRCLE":
                let r = val(d, 40)
                if r > 0 { add(Flatten.ellipse(center: Vec2(val(d, 10), val(d, 20)), rx: r, ry: r, step: step), d) }
            case "ARC":
                let c = Vec2(val(d, 10), val(d, 20)), r = val(d, 40)
                var a0 = val(d, 50), a1 = val(d, 51)
                if a1 <= a0 { a1 += 360 }
                a0 *= .pi / 180
                a1 *= .pi / 180
                let first = c + Vec2(cos(a0), sin(a0)) * r
                let pts = [first] + Flatten.ellipseArc(center: c, rx: r, ry: r, rotation: 0, start: a0, sweep: a1 - a0, step: step)
                add(Polyline(pts), d)
            case "ELLIPSE":
                let c = Vec2(val(d, 10), val(d, 20))
                let major = Vec2(val(d, 11), val(d, 21))
                let ratio = val(d, 40, default: 1)
                let t0 = val(d, 41, default: 0)
                var t1 = val(d, 42, default: 2 * .pi)
                if t1 <= t0 { t1 += 2 * .pi }
                let rx = major.length, ry = rx * ratio, rot = atan2(major.y, major.x)
                let first = c + Vec2(rx * cos(t0), ry * sin(t0)).rotated(by: rot)
                let pts = [first] + Flatten.ellipseArc(center: c, rx: rx, ry: ry, rotation: rot, start: t0, sweep: t1 - t0, step: step)
                let full = abs(t1 - t0 - 2 * .pi) < 1e-6
                add(full ? Polyline(Array(pts.dropLast()), closed: true) : Polyline(pts), d)
            case "LWPOLYLINE":
                let closed = (Int(d.first(where: { $0.code == 70 })?.value ?? "0") ?? 0) & 1 == 1
                var verts: [(Vec2, Double)] = []
                var x: Double?
                for p in d {
                    switch p.code {
                    case 10: x = p.double
                    case 20: if let xx = x { verts.append((Vec2(xx, p.double), 0)); x = nil }
                    case 42: if !verts.isEmpty { verts[verts.count - 1].1 = p.double }
                    default: break
                    }
                }
                add(bulgePolyline(verts, closed: closed, step: step), d)
            case "POLYLINE":
                let closed = (Int(d.first(where: { $0.code == 70 })?.value ?? "0") ?? 0) & 1 == 1
                var verts: [(Vec2, Double)] = []
                var k = e + 1
                while k < entities.count, entities[k].type == "VERTEX" {
                    let v = entities[k].data
                    verts.append((Vec2(val(v, 10), val(v, 20)), val(v, 42)))
                    k += 1
                }
                if k < entities.count, entities[k].type == "SEQEND" { k += 1 }
                add(bulgePolyline(verts, closed: closed, step: step), d)
                e = k
                continue
            case "SPLINE":
                add(spline(d, step: step), d)
            default:
                break
            }
            e += 1
        }

        // Flip y, scale to mm, join loose segments, then place at (10, 10).
        let flip = Affine.scale(unitScale, -unitScale)
        var groups = order.map { ImportedGroup(colorHex: $0, paths: PathJoiner.join(byColor[$0]!.transformed(flip), tolerance: 0.01)) }
        let all = groups.flatMap(\.paths).bounds
        guard !all.isEmpty else { throw ImportError.empty }
        let move = Affine.translation(10 - all.minX, 10 - all.minY)
        for g in groups.indices { groups[g].paths = groups[g].paths.transformed(move) }
        return groups
    }

    private static func val(_ d: [Pair], _ code: Int, default def: Double = 0) -> Double {
        d.first(where: { $0.code == code }).map(\.double) ?? def
    }

    /// Builds a polyline from vertices with bulge values (bulge applies to the segment after a vertex).
    static func bulgePolyline(_ verts: [(Vec2, Double)], closed: Bool, step: Double) -> Polyline {
        guard let first = verts.first else { return Polyline([]) }
        var pts = [first.0]
        let segCount = closed ? verts.count : verts.count - 1
        guard segCount > 0 else { return Polyline(pts) }
        for s in 0..<segCount {
            let (p1, bulge) = verts[s]
            let p2 = verts[(s + 1) % verts.count].0
            if abs(bulge) < 1e-9 {
                pts.append(p2)
                continue
            }
            let theta = 4 * atan(bulge)
            let dv = p2 - p1
            let chord = dv.length
            guard chord > 0 else { continue }
            let h = (chord / 2) / tan(theta / 2)
            let mid = (p1 + p2) / 2
            let left = Vec2(-dv.y, dv.x) / chord
            let c = mid + left * h
            let r = p1.distance(to: c)
            let a0 = atan2(p1.y - c.y, p1.x - c.x)
            var arc = Flatten.ellipseArc(center: c, rx: r, ry: r, rotation: 0, start: a0, sweep: theta, step: step)
            if !arc.isEmpty { arc[arc.count - 1] = p2 }
            pts += arc
        }
        if closed, pts.count > 1 { pts.removeLast() }
        return Polyline(pts, closed: closed).deduplicated()
    }

    /// Evaluates a B-spline from its control points and knots, or falls back to fit points.
    static func spline(_ d: [Pair], step: Double) -> Polyline {
        let degree = Int(val(d, 71, default: 3))
        let closed = (Int(d.first(where: { $0.code == 70 })?.value ?? "0") ?? 0) & 1 == 1
        let knots = d.filter { $0.code == 40 }.map(\.double)
        var ctrl: [Vec2] = [], fit: [Vec2] = []
        var cx: Double?, fx: Double?
        for p in d {
            switch p.code {
            case 10: cx = p.double
            case 20: if let x = cx { ctrl.append(Vec2(x, p.double)); cx = nil }
            case 11: fx = p.double
            case 21: if let x = fx { fit.append(Vec2(x, p.double)); fx = nil }
            default: break
            }
        }
        guard ctrl.count > degree, knots.count == ctrl.count + degree + 1 else {
            return Polyline(fit.count > 1 ? fit : ctrl, closed: closed)
        }
        let tMin = knots[degree], tMax = knots[ctrl.count]
        var len = 0.0
        for k in 1..<ctrl.count { len += ctrl[k].distance(to: ctrl[k - 1]) }
        let n = Flatten.segments(forLength: len, step: step)
        var pts: [Vec2] = []
        for s in 0...n {
            let t = tMin + (tMax - tMin) * Double(s) / Double(n)
            pts.append(deBoor(t: t, degree: degree, knots: knots, ctrl: ctrl))
        }
        if closed, pts.count > 1, pts.first!.distance(to: pts.last!) < 1e-6 { pts.removeLast() }
        return Polyline(pts, closed: closed)
    }

    static func deBoor(t: Double, degree p: Int, knots: [Double], ctrl: [Vec2]) -> Vec2 {
        // Find span k with knots[k] <= t < knots[k+1], clamped to the valid range.
        var k = p
        while k < ctrl.count - 1, t >= knots[k + 1] { k += 1 }
        var dpts = (0...p).map { ctrl[$0 + k - p] }
        if p == 0 { return dpts[0] }
        for r in 1...p {
            for j in stride(from: p, through: r, by: -1) {
                let i = j + k - p
                let denom = knots[i + p - r + 1] - knots[i]
                let alpha = denom == 0 ? 0 : (t - knots[i]) / denom
                dpts[j] = dpts[j - 1] * (1 - alpha) + dpts[j] * alpha
            }
        }
        return dpts[p]
    }
}
