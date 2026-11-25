import Foundation

/// A 2D point or vector, in millimetres unless stated otherwise.
public struct Vec2: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec2 {
        let l = length
        return l > 0 ? self / l : .zero
    }
    public func distance(to o: Vec2) -> Double { (self - o).length }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public func rotated(by radians: Double) -> Vec2 {
        let c = cos(radians), s = sin(radians)
        return Vec2(x * c - y * s, x * s + y * c)
    }
}

/// An axis-aligned rectangle.
public struct Rect2: Hashable, Codable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static let empty = Rect2(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    public var isEmpty: Bool { minX > maxX || minY > maxY }
    public var width: Double { isEmpty ? 0 : maxX - minX }
    public var height: Double { isEmpty ? 0 : maxY - minY }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }
    public var origin: Vec2 { Vec2(minX, minY) }

    public mutating func include(_ p: Vec2) {
        minX = Swift.min(minX, p.x)
        minY = Swift.min(minY, p.y)
        maxX = Swift.max(maxX, p.x)
        maxY = Swift.max(maxY, p.y)
    }

    public func union(_ o: Rect2) -> Rect2 {
        if isEmpty { return o }
        if o.isEmpty { return self }
        return Rect2(minX: Swift.min(minX, o.minX), minY: Swift.min(minY, o.minY),
                     maxX: Swift.max(maxX, o.maxX), maxY: Swift.max(maxY, o.maxY))
    }

    public func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func contains(_ r: Rect2, tolerance: Double = 0) -> Bool {
        r.minX >= minX - tolerance && r.maxX <= maxX + tolerance &&
            r.minY >= minY - tolerance && r.maxY <= maxY + tolerance
    }

    public func insetBy(_ d: Double) -> Rect2 {
        Rect2(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }
}

/// A 2D affine transform using the SVG matrix(a b c d e f) convention:
/// x' = a*x + c*y + tx, y' = b*x + d*y + ty.
public struct Affine: Hashable, Codable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ x: Double, _ y: Double) -> Affine {
        Affine(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public static func scale(_ sx: Double, _ sy: Double) -> Affine {
        Affine(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    public static func rotation(_ radians: Double) -> Affine {
        let co = cos(radians), si = sin(radians)
        return Affine(a: co, b: si, c: -si, d: co, tx: 0, ty: 0)
    }

    public static func skewX(_ radians: Double) -> Affine {
        Affine(a: 1, b: 0, c: tan(radians), d: 1, tx: 0, ty: 0)
    }

    public static func skewY(_ radians: Double) -> Affine {
        Affine(a: 1, b: tan(radians), c: 0, d: 1, tx: 0, ty: 0)
    }

    public func apply(_ p: Vec2) -> Vec2 {
        Vec2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }

    /// Returns the transform that applies `self` first, then `o`.
    public func then(_ o: Affine) -> Affine {
        Affine(a: o.a * a + o.c * b,
               b: o.b * a + o.d * b,
               c: o.a * c + o.c * d,
               d: o.b * c + o.d * d,
               tx: o.a * tx + o.c * ty + o.tx,
               ty: o.b * tx + o.d * ty + o.ty)
    }

    public var determinant: Double { a * d - b * c }

    /// Approximate uniform scale factor of the transform.
    public var meanScale: Double { abs(determinant).squareRoot() }

    public var isIdentity: Bool { self == .identity }
}

/// A flattened path: a list of points, optionally closed (the last point
/// connects back to the first; the first point is not repeated).
public struct Polyline: Hashable, Codable, Sendable {
    public var points: [Vec2]
    public var closed: Bool

    public init(_ points: [Vec2], closed: Bool = false) {
        self.points = points
        self.closed = closed
    }

    public var bounds: Rect2 {
        var r = Rect2.empty
        for p in points { r.include(p) }
        return r
    }

    /// Points including the closing point for closed polylines.
    public var drawnPoints: [Vec2] {
        guard closed, let first = points.first, points.count > 1 else { return points }
        return points + [first]
    }

    public var length: Double {
        let pts = drawnPoints
        guard pts.count > 1 else { return 0 }
        var l = 0.0
        for i in 1..<pts.count { l += pts[i].distance(to: pts[i - 1]) }
        return l
    }

    public func transformed(_ t: Affine) -> Polyline {
        Polyline(points.map(t.apply), closed: closed)
    }

    public var reversed: Polyline { Polyline(points.reversed(), closed: closed) }

    /// For a closed polyline, rotate so that the point at `index` is first.
    public func rotatedStart(to index: Int) -> Polyline {
        guard closed, index > 0, index < points.count else { return self }
        return Polyline(Array(points[index...] + points[..<index]), closed: true)
    }

    /// Signed area (positive = counter-clockwise in a y-up system).
    public var signedArea: Double {
        guard points.count > 2 else { return 0 }
        var s = 0.0
        for i in 0..<points.count {
            let p = points[i], q = points[(i + 1) % points.count]
            s += p.x * q.y - q.x * p.y
        }
        return s / 2
    }

    /// Removes consecutive duplicate points.
    public func deduplicated(tolerance: Double = 1e-6) -> Polyline {
        var out: [Vec2] = []
        out.reserveCapacity(points.count)
        for p in points where out.last.map({ $0.distance(to: p) > tolerance }) ?? true {
            out.append(p)
        }
        if closed, out.count > 1, let f = out.first, let l = out.last, f.distance(to: l) <= tolerance {
            out.removeLast()
        }
        return Polyline(out, closed: closed)
    }
}

public extension Array where Element == Polyline {
    var bounds: Rect2 {
        reduce(Rect2.empty) { $0.union($1.bounds) }
    }

    func transformed(_ t: Affine) -> [Polyline] { map { $0.transformed(t) } }
}

// MARK: - Curve flattening

public enum Flatten {
    /// Number of segments for a curve whose control polygon has length `len`,
    /// so each segment is roughly `step` long.
    static func segments(forLength len: Double, step: Double) -> Int {
        guard step > 0, len.isFinite else { return 8 }
        return Swift.min(512, Swift.max(4, Int((len / step).rounded(.up))))
    }

    public static func cubic(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, step: Double) -> [Vec2] {
        let n = segments(forLength: p0.distance(to: p1) + p1.distance(to: p2) + p2.distance(to: p3), step: step)
        var out: [Vec2] = []
        out.reserveCapacity(n)
        for i in 1...n {
            let t = Double(i) / Double(n), mt = 1 - t
            let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
            out.append(Vec2(a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                            a * p0.y + b * p1.y + c * p2.y + d * p3.y))
        }
        return out
    }

    public static func quadratic(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, step: Double) -> [Vec2] {
        let n = segments(forLength: p0.distance(to: p1) + p1.distance(to: p2), step: step)
        var out: [Vec2] = []
        out.reserveCapacity(n)
        for i in 1...n {
            let t = Double(i) / Double(n), mt = 1 - t
            let a = mt * mt, b = 2 * mt * t, c = t * t
            out.append(Vec2(a * p0.x + b * p1.x + c * p2.x, a * p0.y + b * p1.y + c * p2.y))
        }
        return out
    }

    /// Points on an ellipse arc (excluding the start point).
    public static func ellipseArc(center: Vec2, rx: Double, ry: Double, rotation: Double,
                                  start: Double, sweep: Double, step: Double) -> [Vec2] {
        let approxLen = abs(sweep) * Swift.max(rx, ry)
        let n = segments(forLength: approxLen, step: step)
        let cr = cos(rotation), sr = sin(rotation)
        var out: [Vec2] = []
        out.reserveCapacity(n)
        for i in 1...n {
            let t = start + sweep * Double(i) / Double(n)
            let ex = rx * cos(t), ey = ry * sin(t)
            out.append(Vec2(center.x + ex * cr - ey * sr, center.y + ex * sr + ey * cr))
        }
        return out
    }

    public static func ellipse(center: Vec2, rx: Double, ry: Double, step: Double) -> Polyline {
        var pts = [Vec2(center.x + rx, center.y)]
        pts += ellipseArc(center: center, rx: rx, ry: ry, rotation: 0, start: 0, sweep: 2 * .pi, step: step)
        pts.removeLast() // same as the first point
        return Polyline(pts, closed: true)
    }

    /// SVG endpoint-parameterised arc to points (excluding the start point).
    public static func svgArc(from p0: Vec2, to p1: Vec2, rx rxIn: Double, ry ryIn: Double,
                              xAxisRotationDegrees: Double, largeArc: Bool, sweep: Bool, step: Double) -> [Vec2] {
        var rx = abs(rxIn), ry = abs(ryIn)
        if p0 == p1 { return [] }
        if rx == 0 || ry == 0 { return [p1] }
        let phi = xAxisRotationDegrees * .pi / 180
        let cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cp * dx + sp * dy
        let y1p = -sp * dx + cp * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s
            ry *= s
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (Swift.max(0, num) / den).squareRoot()
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
        let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        if sweep && dtheta < 0 { dtheta += 2 * .pi }
        var pts = ellipseArc(center: Vec2(cx, cy), rx: rx, ry: ry, rotation: phi, start: theta1, sweep: dtheta, step: step)
        if !pts.isEmpty { pts[pts.count - 1] = p1 } // snap exactly to the end point
        return pts
    }
}

// MARK: - Joining loose segments

public enum PathJoiner {
    /// Joins open polylines whose endpoints touch into longer chains, and closes
    /// chains whose ends meet. Useful for DXF files made of separate LINE entities.
    public static func join(_ input: [Polyline], tolerance: Double = 0.01) -> [Polyline] {
        var closed = input.filter { $0.closed || $0.points.count < 2 }
        var open = input.filter { !$0.closed && $0.points.count >= 2 }
        var result: [Polyline] = []

        while var chain = open.popLast() {
            var extended = true
            while extended {
                extended = false
                for i in stride(from: open.count - 1, through: 0, by: -1) {
                    let cand = open[i]
                    guard let cs = cand.points.first, let ce = cand.points.last,
                          let s = chain.points.first, let e = chain.points.last else { continue }
                    if e.distance(to: cs) <= tolerance {
                        chain.points += cand.points.dropFirst()
                    } else if e.distance(to: ce) <= tolerance {
                        chain.points += cand.points.reversed().dropFirst()
                    } else if s.distance(to: ce) <= tolerance {
                        chain.points = cand.points + chain.points.dropFirst()
                    } else if s.distance(to: cs) <= tolerance {
                        chain.points = cand.points.reversed() + chain.points.dropFirst()
                    } else {
                        continue
                    }
                    open.remove(at: i)
                    extended = true
                }
            }
            if chain.points.count > 2, let f = chain.points.first, let l = chain.points.last, f.distance(to: l) <= tolerance {
                chain.points.removeLast()
                chain.closed = true
            }
            result.append(chain)
        }
        closed.append(contentsOf: result)
        return closed
    }
}
