import Foundation

// Camera alignment for lasers: a camera above the bed shows the material on the canvas so designs can
// be placed on it. Two calibrations make the picture line up with the bed:
//  1. Lens: a checkerboard seen in several positions measures the lens's barrel distortion (LensModel).
//  2. Alignment: marks burned at known bed positions and clicked in a snapshot give the perspective
//     mapping from the (undistorted) picture to the bed (BedAlignment).

// MARK: - Small linear algebra

enum LinearAlgebra {
    /// Solves A x = b for a square `n`×`n` row-major A by Gaussian elimination with partial pivoting.
    static func solve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        guard n > 0, a.count == n * n, b.count == n else { return nil }
        var m = a, r = b
        let scale = max(1e-300, m.map { abs($0) }.max() ?? 0)
        for col in 0..<n {
            var pivot = col
            var best = abs(m[col * n + col])
            for row in (col + 1)..<n where abs(m[row * n + col]) > best {
                best = abs(m[row * n + col])
                pivot = row
            }
            guard best > scale * 1e-15 else { return nil }
            if pivot != col {
                for k in 0..<n { m.swapAt(col * n + k, pivot * n + k) }
                r.swapAt(col, pivot)
            }
            let d = m[col * n + col]
            for row in (col + 1)..<n {
                let f = m[row * n + col] / d
                if f == 0 { continue }
                for k in col..<n { m[row * n + k] -= f * m[col * n + k] }
                r[row] -= f * r[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = r[row]
            for k in (row + 1)..<n { s -= m[row * n + k] * x[k] }
            x[row] = s / m[row * n + row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// 3×3 row-major product a·b.
    static func mul3(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                out[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
            }
        }
        return out
    }

    /// Inverse of a 3×3 row-major matrix, or nil when it is singular.
    static func invert3(_ m: [Double]) -> [Double]? {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        let size = m.map { abs($0) }.max() ?? 0
        guard abs(det) > 1e-14 * max(1e-300, size * size * size) else { return nil }
        let inv = [A, -(b * i - c * h), b * f - c * e,
                   B, a * i - c * g, -(a * f - c * d),
                   C, -(a * h - b * g), a * e - b * d]
        return inv.map { $0 / det }
    }
}

// MARK: - Homography

/// A plane-to-plane perspective mapping (3×3 matrix, row-major).
public struct Homography: Codable, Hashable, Sendable {
    public var m: [Double]

    public init(_ m: [Double]) {
        precondition(m.count == 9, "A homography has 9 entries")
        self.m = m
    }

    public static let identity = Homography([1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Maps `p`, or nil when it lands at infinity.
    public func apply(_ p: Vec2) -> Vec2? {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return Vec2((m[0] * p.x + m[1] * p.y + m[2]) / w, (m[3] * p.x + m[4] * p.y + m[5]) / w)
    }

    public var inverted: Homography? { LinearAlgebra.invert3(m).map(Homography.init) }

    /// The mapping that applies `self` first, then `o`.
    public func then(_ o: Homography) -> Homography { Homography(LinearAlgebra.mul3(o.m, m)) }

    /// Least-squares homography taking each `src` point to its `dst` point (at least 4 pairs, not all on a line).
    public static func fit(from src: [Vec2], to dst: [Vec2]) -> Homography? {
        guard src.count == dst.count, src.count >= 4 else { return nil }
        guard let a = normalize(src), let b = normalize(dst) else { return nil }
        let (ns, ts) = a, (nd, td) = b
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        for (p, q) in zip(ns, nd) {
            let rows: [([Double], Double)] = [
                ([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y], q.x),
                ([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y], q.y),
            ]
            for (row, rhs) in rows {
                for i in 0..<8 {
                    atb[i] += row[i] * rhs
                    for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
                }
            }
        }
        guard let h = LinearAlgebra.solve(ata, atb, n: 8), let tdInv = td.inverted else { return nil }
        let result = ts.then(Homography(h + [1])).then(tdInv)
        // Normalise so the last entry is 1 when possible (keeps saved values readable).
        let s = abs(result.m[8]) > 1e-12 ? result.m[8] : 1
        return Homography(result.m.map { $0 / s })
    }

    /// Moves points to their centroid and scales them to an average distance of √2 (Hartley normalisation).
    private static func normalize(_ pts: [Vec2]) -> ([Vec2], Homography)? {
        let c = pts.reduce(Vec2.zero, +) / Double(pts.count)
        let mean = pts.reduce(0.0) { $0 + $1.distance(to: c) } / Double(pts.count)
        guard mean > 1e-12 else { return nil }
        let s = 2.0.squareRoot() / mean
        let t = Homography([s, 0, -s * c.x, 0, s, -s * c.y, 0, 0, 1])
        return (pts.map { ($0 - c) * s }, t)
    }
}

// MARK: - Lens model

/// A camera's focal length, centre and lens distortion (the usual radial k1–k3 and tangential p1, p2 model),
/// measured by `LensCalibration` for one picture size.
public struct LensModel: Codable, Hashable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var k1: Double
    public var k2: Double
    public var k3: Double
    public var p1: Double
    public var p2: Double
    /// Average distance between the measured and modelled checkerboard corners, in pixels.
    public var rmsError: Double
    /// How many checkerboard views the calibration used.
    public var views: Int

    public init(imageWidth: Int, imageHeight: Int, fx: Double, fy: Double, cx: Double, cy: Double,
                k1: Double = 0, k2: Double = 0, k3: Double = 0, p1: Double = 0, p2: Double = 0,
                rmsError: Double = 0, views: Int = 0) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.k1 = k1
        self.k2 = k2
        self.k3 = k3
        self.p1 = p1
        self.p2 = p2
        self.rmsError = rmsError
        self.views = views
    }

    /// Ideal (undistorted) normalised image coordinates to where the lens actually puts them.
    public func distort(normalized p: Vec2) -> Vec2 {
        let x = p.x, y = p.y, r2 = x * x + y * y
        let radial = 1 + r2 * (k1 + r2 * (k2 + r2 * k3))
        return Vec2(x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x),
                    y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y)
    }

    /// Inverse of `distort`, by fixed-point iteration.
    public func undistort(normalized d: Vec2) -> Vec2 {
        var p = d
        for _ in 0..<40 {
            let x = p.x, y = p.y, r2 = x * x + y * y
            let radial = 1 + r2 * (k1 + r2 * (k2 + r2 * k3))
            guard abs(radial) > 1e-6 else { break }
            let dx = 2 * p1 * x * y + p2 * (r2 + 2 * x * x)
            let dy = p1 * (r2 + 2 * y * y) + 2 * p2 * x * y
            let next = Vec2((d.x - dx) / radial, (d.y - dy) / radial)
            let moved = next.distance(to: p)
            p = next
            if moved < 1e-12 { break }
        }
        return p
    }

    /// A camera pixel to where an ideal, distortion-free camera with the same focal length and centre would see it.
    public func undistortPixel(_ q: Vec2) -> Vec2 {
        let n = undistort(normalized: Vec2((q.x - cx) / fx, (q.y - cy) / fy))
        return Vec2(n.x * fx + cx, n.y * fy + cy)
    }

    /// Inverse of `undistortPixel`.
    public func distortPixel(_ q: Vec2) -> Vec2 {
        let d = distort(normalized: Vec2((q.x - cx) / fx, (q.y - cy) / fy))
        return Vec2(d.x * fx + cx, d.y * fy + cy)
    }

    /// The same lens at another picture size of the same shape (the camera scaled its picture), or nil
    /// when the shape differs (a cropped mode needs its own calibration).
    public func scaled(toWidth w: Int, height h: Int) -> LensModel? {
        guard imageWidth > 0, imageHeight > 0, w > 0, h > 0 else { return nil }
        if w == imageWidth, h == imageHeight { return self }
        let sx = Double(w) / Double(imageWidth), sy = Double(h) / Double(imageHeight)
        guard abs(sx - sy) / max(sx, sy) < 0.01 else { return nil }
        var out = self
        out.imageWidth = w
        out.imageHeight = h
        out.fx *= sx
        out.fy *= sy
        out.cx = (cx + 0.5) * sx - 0.5
        out.cy = (cy + 0.5) * sy - 0.5
        out.rmsError *= sx
        return out
    }

    /// The largest squared normalised radius the picture covers once undistorted. Points farther out
    /// are outside the camera's view (the distortion polynomial isn't meaningful there).
    public var coveredRadius2: Double {
        let w = Double(imageWidth - 1), h = Double(imageHeight - 1)
        var r2 = 0.0
        for q in [Vec2(0, 0), Vec2(w, 0), Vec2(0, h), Vec2(w, h), Vec2(w / 2, 0), Vec2(w / 2, h), Vec2(0, h / 2), Vec2(w, h / 2)] {
            let n = undistort(normalized: Vec2((q.x - cx) / fx, (q.y - cy) / fy))
            r2 = max(r2, n.x * n.x + n.y * n.y)
        }
        return r2
    }

    /// How strong the barrel (negative) or pincushion (positive) distortion is at the picture's corner,
    /// as a fraction of the corner's distance from the centre.
    public var cornerDistortion: Double {
        let n = Vec2(-cx / fx, -cy / fy)
        let d = distort(normalized: n)
        return (d.length - n.length) / max(1e-9, n.length)
    }
}

/// The corners of a checkerboard found in one camera picture.
public struct CheckerboardView: Codable, Hashable, Sendable {
    /// Corner positions in the picture, in pixels (pixel centres are whole numbers).
    public var imagePoints: [Vec2]
    /// The same corners on the board, in squares.
    public var boardPoints: [Vec2]
    public var imageWidth: Int
    public var imageHeight: Int

    public init(imagePoints: [Vec2], boardPoints: [Vec2], imageWidth: Int, imageHeight: Int) {
        self.imagePoints = imagePoints
        self.boardPoints = boardPoints
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

// MARK: - Lens calibration

/// Measures a lens from several checkerboard views (Levenberg–Marquardt on all corners at once).
public enum LensCalibration {
    /// Fewest views accepted.
    public static let minimumViews = 3

    /// Calibrates from `views` (all from one picture size). Square pixels are assumed (fx = fy).
    public static func calibrate(_ views: [CheckerboardView]) -> LensModel? {
        let usable = views.filter { $0.imagePoints.count >= 6 && $0.imagePoints.count == $0.boardPoints.count }
        guard usable.count >= minimumViews, let first = usable.first else { return nil }
        let w = first.imageWidth, h = first.imageHeight
        guard usable.allSatisfy({ $0.imageWidth == w && $0.imageHeight == h }) else { return nil }

        let cx0 = Double(w - 1) / 2, cy0 = Double(h - 1) / 2
        let homographies = usable.map { Homography.fit(from: $0.boardPoints, to: $0.imagePoints) }
        guard homographies.allSatisfy({ $0 != nil }) else { return nil }
        let hs = homographies.compactMap { $0 }
        let f0 = initialFocal(hs, cx: cx0, cy: cy0, width: w, height: h)

        // Parameters: f, cx, cy, k1, k2, p1, p2, k3, then rx ry rz tx ty tz per view.
        var params = [f0, cx0, cy0, 0, 0, 0, 0, 0]
        for hm in hs { params += initialPose(hm, f: f0, cx: cx0, cy: cy0) }
        var free = [Bool](repeating: true, count: params.count)
        let many = usable.count >= 4
        free[1] = many
        free[2] = many
        free[5] = many
        free[6] = many
        free[7] = usable.count >= 6

        let problem = Problem(views: usable)
        guard let solved = problem.levenbergMarquardt(params, free: free) else { return nil }
        let p = solved.params
        let count = usable.reduce(0) { $0 + $1.imagePoints.count }
        let rms = (solved.cost / Double(max(1, count))).squareRoot()
        guard p[0] > 0, rms.isFinite else { return nil }
        return LensModel(imageWidth: w, imageHeight: h, fx: p[0], fy: p[0], cx: p[1], cy: p[2],
                         k1: p[3], k2: p[4], k3: p[7], p1: p[5], p2: p[6], rmsError: rms, views: usable.count)
    }

    /// Focal length from each view's homography (Zhang's constraints with a known centre and square
    /// pixels). Views square-on to the camera say nothing about it; then a typical webcam value is used.
    static func initialFocal(_ hs: [Homography], cx: Double, cy: Double, width: Int, height: Int) -> Double {
        let size = Double(max(width, height))
        var estimates: [Double] = []
        for hm in hs {
            var m = hm.m
            for k in 0..<3 {
                m[k] -= cx * m[6 + k]
                m[3 + k] -= cy * m[6 + k]
            }
            let h1 = (m[0], m[3], m[6]), h2 = (m[1], m[4], m[7])
            let n1 = h1.0 * h1.0 + h1.1 * h1.1, n2 = h2.0 * h2.0 + h2.1 * h2.1
            // Scale-free tests: the z parts must be noticeable next to the x, y parts.
            let zScale = (n1 + n2) / (size * size)
            let den1 = h1.2 * h2.2
            if abs(den1) > zScale * 1e-3 {
                let f2 = -(h1.0 * h2.0 + h1.1 * h2.1) / den1
                if f2 > 0 { estimates.append(f2.squareRoot()) }
            }
            let den2 = h1.2 * h1.2 - h2.2 * h2.2
            if abs(den2) > zScale * 1e-3 {
                let f2 = -(n1 - n2) / den2
                if f2 > 0 { estimates.append(f2.squareRoot()) }
            }
        }
        let sane = estimates.filter { $0 > size * 0.15 && $0 < size * 6 }.sorted()
        return sane.isEmpty ? size * 0.8 : sane[sane.count / 2]
    }

    /// Board pose (Rodrigues rotation and translation) from a homography and a guessed camera.
    static func initialPose(_ hm: Homography, f: Double, cx: Double, cy: Double) -> [Double] {
        var m = hm.m
        for k in 0..<3 {
            m[k] = (m[k] - cx * m[6 + k]) / f
            m[3 + k] = (m[3 + k] - cy * m[6 + k]) / f
        }
        let h1 = [m[0], m[3], m[6]], h2 = [m[1], m[4], m[7]], h3 = [m[2], m[5], m[8]]
        func norm(_ v: [Double]) -> Double { (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot() }
        var lambda = 2 / max(1e-12, norm(h1) + norm(h2))
        if h3[2] * lambda < 0 { lambda = -lambda }
        let r1 = h1.map { $0 * lambda }
        var r2 = h2.map { $0 * lambda }
        let t = h3.map { $0 * lambda }
        let n1 = max(1e-12, norm(r1))
        let u1 = r1.map { $0 / n1 }
        let d = u1[0] * r2[0] + u1[1] * r2[1] + u1[2] * r2[2]
        r2 = [r2[0] - d * u1[0], r2[1] - d * u1[1], r2[2] - d * u1[2]]
        let n2 = max(1e-12, norm(r2))
        let u2 = r2.map { $0 / n2 }
        let u3 = [u1[1] * u2[2] - u1[2] * u2[1], u1[2] * u2[0] - u1[0] * u2[2], u1[0] * u2[1] - u1[1] * u2[0]]
        let rot = [u1[0], u2[0], u3[0], u1[1], u2[1], u3[1], u1[2], u2[2], u3[2]]
        let r = rodrigues(from: rot)
        return [r.0, r.1, r.2, t[0], t[1], t[2]]
    }

    static func rotationMatrix(_ rx: Double, _ ry: Double, _ rz: Double) -> [Double] {
        let th = (rx * rx + ry * ry + rz * rz).squareRoot()
        if th < 1e-12 { return [1, -rz, ry, rz, 1, -rx, -ry, rx, 1] }
        let kx = rx / th, ky = ry / th, kz = rz / th, c = cos(th), s = sin(th), v = 1 - c
        return [c + kx * kx * v, kx * ky * v - kz * s, kx * kz * v + ky * s,
                ky * kx * v + kz * s, c + ky * ky * v, ky * kz * v - kx * s,
                kz * kx * v - ky * s, kz * ky * v + kx * s, c + kz * kz * v]
    }

    static func rodrigues(from r: [Double]) -> (Double, Double, Double) {
        let cosT = max(-1, min(1, (r[0] + r[4] + r[8] - 1) / 2))
        let th = acos(cosT)
        if th < 1e-9 { return (0, 0, 0) }
        if th > .pi - 1e-6 {
            var kx = max(0, (r[0] + 1) / 2).squareRoot()
            var ky = max(0, (r[4] + 1) / 2).squareRoot()
            var kz = max(0, (r[8] + 1) / 2).squareRoot()
            if kx >= ky, kx >= kz {
                if r[1] < 0 { ky = -ky }
                if r[2] < 0 { kz = -kz }
            } else if ky >= kz {
                if r[1] < 0 { kx = -kx }
                if r[5] < 0 { kz = -kz }
            } else {
                if r[2] < 0 { kx = -kx }
                if r[5] < 0 { ky = -ky }
            }
            return (kx * th, ky * th, kz * th)
        }
        let s = 2 * sin(th)
        return ((r[7] - r[5]) / s * th, (r[2] - r[6]) / s * th, (r[3] - r[1]) / s * th)
    }

    /// Where board point `b` lands in the picture for camera `p[0..<8]` and the pose at `p[pose..<pose+6]`.
    static func project(_ b: Vec2, _ p: [Double], pose: Int) -> Vec2? {
        let rot = rotationMatrix(p[pose], p[pose + 1], p[pose + 2])
        let x = rot[0] * b.x + rot[1] * b.y + p[pose + 3]
        let y = rot[3] * b.x + rot[4] * b.y + p[pose + 4]
        let z = rot[6] * b.x + rot[7] * b.y + p[pose + 5]
        guard z > 1e-9 else { return nil }
        let lens = LensModel(imageWidth: 0, imageHeight: 0, fx: p[0], fy: p[0], cx: p[1], cy: p[2],
                             k1: p[3], k2: p[4], k3: p[7], p1: p[5], p2: p[6])
        let d = lens.distort(normalized: Vec2(x / z, y / z))
        return Vec2(d.x * p[0] + p[1], d.y * p[0] + p[2])
    }

    struct Problem {
        var views: [CheckerboardView]
        let intrinsics = 8

        /// Residuals (dx, dy per corner) of one view; a big penalty where the board would be behind the camera.
        func residuals(_ p: [Double], view v: Int) -> [Double] {
            let pose = intrinsics + 6 * v
            var out: [Double] = []
            out.reserveCapacity(views[v].imagePoints.count * 2)
            for (b, q) in zip(views[v].boardPoints, views[v].imagePoints) {
                if let r = project(b, p, pose: pose) {
                    out.append(r.x - q.x)
                    out.append(r.y - q.y)
                } else {
                    out.append(1e4)
                    out.append(1e4)
                }
            }
            return out
        }

        func cost(_ p: [Double]) -> Double {
            var c = 0.0
            for v in views.indices { for r in residuals(p, view: v) { c += r * r } }
            return c
        }

        func levenbergMarquardt(_ start: [Double], free: [Bool], iterations: Int = 150) -> (params: [Double], cost: Double)? {
            var p = start
            var cost = self.cost(p)
            guard cost.isFinite else { return nil }
            var lambda = 1e-3
            let freeIdx = free.indices.filter { free[$0] }
            let n = freeIdx.count
            var position = [Int](repeating: -1, count: p.count)
            for (k, i) in freeIdx.enumerated() { position[i] = k }

            for _ in 0..<iterations {
                // Normal equations JᵀJ δ = −Jᵀr from forward-difference derivatives. A view's pose only moves
                // that view's corners, so its columns are computed from that view alone.
                var jtj = [Double](repeating: 0, count: n * n)
                var jtr = [Double](repeating: 0, count: n)
                for v in views.indices {
                    let base = residuals(p, view: v)
                    let pose = intrinsics + 6 * v
                    let columns = freeIdx.filter { $0 < intrinsics || ($0 >= pose && $0 < pose + 6) }
                    var derivs: [[Double]] = []
                    derivs.reserveCapacity(columns.count)
                    for i in columns {
                        var q = p
                        let step = 1e-6 * max(1, abs(p[i]))
                        q[i] += step
                        let moved = residuals(q, view: v)
                        derivs.append(zip(moved, base).map { ($0 - $1) / step })
                    }
                    for (a, ia) in columns.enumerated() {
                        let ka = position[ia]
                        var g = 0.0
                        for (d, r) in zip(derivs[a], base) { g += d * r }
                        jtr[ka] += g
                        for (b, ib) in columns.enumerated() where b >= a {
                            let kb = position[ib]
                            var s = 0.0
                            for (x, y) in zip(derivs[a], derivs[b]) { s += x * y }
                            jtj[ka * n + kb] += s
                            if kb != ka { jtj[kb * n + ka] += s }
                        }
                    }
                }
                var improved = false
                while lambda < 1e12 {
                    var a = jtj
                    for k in 0..<n { a[k * n + k] += lambda * max(jtj[k * n + k], 1e-9) }
                    guard let delta = LinearAlgebra.solve(a, jtr.map { -$0 }, n: n) else {
                        lambda *= 10
                        continue
                    }
                    var q = p
                    for (k, i) in freeIdx.enumerated() { q[i] += delta[k] }
                    let c = self.cost(q)
                    if c.isFinite, c < cost {
                        let gain = cost - c
                        p = q
                        cost = c
                        lambda = max(1e-9, lambda / 3)
                        improved = gain > 1e-12 * max(1, cost)
                        break
                    }
                    lambda *= 4
                }
                if !improved { break }
            }
            return (p, cost)
        }
    }
}

// MARK: - Camera-to-bed alignment

/// The perspective mapping from the undistorted camera picture to the bed, measured from burned marks.
public struct BedAlignment: Codable, Hashable, Sendable {
    /// The picture size the marks were clicked at.
    public var imageWidth: Int
    public var imageHeight: Int
    /// Undistorted picture pixels to design (canvas) millimetres.
    public var imageToBed: Homography
    /// The machine the marks were burned with; the overlay only lines up on that machine's bed.
    public var profileID: UUID?
    /// Mismatch between the clicked marks and where they were burned, in mm.
    public var rmsError: Double
    public var maxError: Double
    public var date: Date

    public init(imageWidth: Int, imageHeight: Int, imageToBed: Homography, profileID: UUID?,
                rmsError: Double, maxError: Double, date: Date = Date()) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageToBed = imageToBed
        self.profileID = profileID
        self.rmsError = rmsError
        self.maxError = maxError
        self.date = date
    }
}

/// Everything known about one camera: its lens and how its picture sits on the bed.
public struct CameraSetup: Codable, Hashable, Sendable {
    public var lens: LensModel?
    public var alignment: BedAlignment?

    public init(lens: LensModel? = nil, alignment: BedAlignment? = nil) {
        self.lens = lens
        self.alignment = alignment
    }

    /// The lens at the alignment's picture size (nil when uncalibrated or the size can't be matched).
    public func lens(width: Int, height: Int) -> LensModel? { lens?.scaled(toWidth: width, height: height) }

    /// A raw picture pixel (at `width`×`height`) to the bed, in design mm.
    public func imageToBed(_ q: Vec2, width: Int, height: Int) -> Vec2? {
        guard let a = alignment else { return nil }
        let sx = Double(a.imageWidth) / Double(width), sy = Double(a.imageHeight) / Double(height)
        let raw = Vec2((q.x + 0.5) * sx - 0.5, (q.y + 0.5) * sy - 0.5)
        let ideal = lens(width: a.imageWidth, height: a.imageHeight)?.undistortPixel(raw) ?? raw
        return a.imageToBed.apply(ideal)
    }

    /// Builds the mapping that draws the camera picture over `area` of the bed at `mmPerPixel`.
    /// Pixels the camera can't see are left transparent.
    public func bedRemap(area: Rect2, mmPerPixel: Double, sourceWidth: Int, sourceHeight: Int) -> CameraRemap? {
        guard let a = alignment, let toImage = a.imageToBed.inverted, !area.isEmpty, mmPerPixel > 0 else { return nil }
        let lens = self.lens(width: a.imageWidth, height: a.imageHeight)
        let limit = lens.map { $0.coveredRadius2 * 1.02 }
        let w = max(1, Int((area.width / mmPerPixel).rounded())), h = max(1, Int((area.height / mmPerPixel).rounded()))
        let sx = Double(sourceWidth) / Double(a.imageWidth), sy = Double(sourceHeight) / Double(a.imageHeight)
        let iw = Double(a.imageWidth), ih = Double(a.imageHeight)
        return CameraRemap(width: w, height: h, sourceWidth: sourceWidth, sourceHeight: sourceHeight) { x, y in
            let bed = Vec2(area.minX + (Double(x) + 0.5) * mmPerPixel, area.minY + (Double(y) + 0.5) * mmPerPixel)
            guard let ideal = toImage.apply(bed) else { return nil }
            var raw = ideal
            if let lens, let limit {
                let nx = (ideal.x - lens.cx) / lens.fx, ny = (ideal.y - lens.cy) / lens.fy
                guard nx * nx + ny * ny <= limit else { return nil }
                raw = lens.distortPixel(ideal)
            }
            guard raw.x >= -0.5, raw.y >= -0.5, raw.x <= iw - 0.5, raw.y <= ih - 0.5 else { return nil }
            return Vec2((raw.x + 0.5) * sx - 0.5, (raw.y + 0.5) * sy - 0.5)
        }
    }

    /// Builds the mapping that straightens the raw picture (same size, distortion removed).
    public func undistortRemap(sourceWidth: Int, sourceHeight: Int) -> CameraRemap? {
        guard let lens = lens(width: sourceWidth, height: sourceHeight) else { return nil }
        let limit = lens.coveredRadius2 * 1.02
        return CameraRemap(width: sourceWidth, height: sourceHeight, sourceWidth: sourceWidth, sourceHeight: sourceHeight) { x, y in
            let ideal = Vec2(Double(x), Double(y))
            let nx = (ideal.x - lens.cx) / lens.fx, ny = (ideal.y - lens.cy) / lens.fy
            guard nx * nx + ny * ny <= limit else { return nil }
            return lens.distortPixel(ideal)
        }
    }
}

/// The burned target used to align the camera with the bed.
public enum CameraAlignment {
    /// Mark centres spread evenly over `area`, numbered left to right, then top to bottom.
    public static func markCentres(in area: Rect2, columns: Int, rows: Int) -> [Vec2] {
        let c = max(2, columns), r = max(2, rows)
        var out: [Vec2] = []
        for j in 0..<r {
            for i in 0..<c {
                out.append(Vec2(area.minX + area.width * Double(i) / Double(c - 1),
                                area.minY + area.height * Double(j) / Double(r - 1)))
            }
        }
        return out
    }

    /// Outlines to burn: each mark is a cross in a circle, `size` mm across. Mark 1 also gets a small
    /// inner ring so it can be told apart however the camera is turned.
    public static func targetPaths(marks: [Vec2], size: Double) -> [Polyline] {
        let r = max(1, size / 2)
        var out: [Polyline] = []
        for (k, m) in marks.enumerated() {
            out.append(Polyline([Vec2(m.x - r, m.y), Vec2(m.x + r, m.y)]))
            out.append(Polyline([Vec2(m.x, m.y - r), Vec2(m.x, m.y + r)]))
            out.append(Flatten.ellipse(center: m, rx: r * 0.75, ry: r * 0.75, step: 0.3))
            if k == 0 { out.append(Flatten.ellipse(center: m, rx: r * 0.35, ry: r * 0.35, step: 0.2)) }
        }
        return out
    }

    /// The alignment from clicked mark positions (`image`, undistorted pixels) and where they were
    /// burned (`bed`, mm). Needs at least four marks, not all in a line.
    public static func fit(image: [Vec2], bed: [Vec2]) -> (homography: Homography, rms: Double, max: Double)? {
        guard image.count == bed.count, image.count >= 4, let h = Homography.fit(from: image, to: bed) else { return nil }
        var sum = 0.0, worst = 0.0
        for (q, b) in zip(image, bed) {
            guard let p = h.apply(q) else { return nil }
            let e = p.distance(to: b)
            sum += e * e
            worst = max(worst, e)
        }
        return (h, (sum / Double(image.count)).squareRoot(), worst)
    }

    /// The centre of the dark mark near `point` in a picture, found from the dark pixels' balance point
    /// in a window `radius` pixels around it, re-centred a few times. Nil when there's no clear mark.
    public static func snapToMark(_ img: GrayImage, near point: Vec2, radius: Double) -> Vec2? {
        let rad = max(4, Int(radius.rounded()))
        var c = point
        for _ in 0..<6 {
            let x0 = max(0, Int(c.x) - rad), x1 = min(img.width - 1, Int(c.x) + rad)
            let y0 = max(0, Int(c.y) - rad), y1 = min(img.height - 1, Int(c.y) + rad)
            guard x1 > x0 + 2, y1 > y0 + 2 else { return nil }
            var values: [UInt8] = []
            values.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
            for y in y0...y1 { for x in x0...x1 { values.append(img[x, y]) } }
            guard let lo = values.min(), let hi = values.max(), Int(hi) - Int(lo) >= 25 else { return nil }
            let t = Double(CameraTrace.otsuThreshold(values))
            var sx = 0.0, sy = 0.0, sw = 0.0
            let r2 = Double(rad * rad)
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - c.x, dy = Double(y) - c.y
                    guard dx * dx + dy * dy <= r2 else { continue }
                    let v = Double(img[x, y])
                    if v < t {
                        let wgt = t - v
                        sx += Double(x) * wgt
                        sy += Double(y) * wgt
                        sw += wgt
                    }
                }
            }
            guard sw > 0 else { return nil }
            let next = Vec2(sx / sw, sy / sw)
            let moved = next.distance(to: c)
            c = next
            if moved < 0.05 { break }
        }
        return c.distance(to: point) <= radius * 1.5 ? c : nil
    }
}

// MARK: - Picture remapping

/// A precomputed per-pixel lookup that warps a camera picture (straightening it, or onto the bed).
/// Build it once per calibration and apply it to every frame.
public struct CameraRemap: Sendable {
    public let width: Int
    public let height: Int
    /// The picture size the lookup was made for; other sizes are scaled to it.
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// Source x, y for each output pixel; negative x means "not seen".
    let coords: [Float]

    public init(width: Int, height: Int, sourceWidth: Int, sourceHeight: Int, map: (Int, Int) -> Vec2?) {
        self.width = width
        self.height = height
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        var c = [Float](repeating: -1, count: width * height * 2)
        for y in 0..<height {
            for x in 0..<width {
                if let s = map(x, y), s.x.isFinite, s.y.isFinite {
                    c[(y * width + x) * 2] = Float(s.x)
                    c[(y * width + x) * 2 + 1] = Float(s.y)
                }
            }
        }
        coords = c
    }

    /// Source position for an output pixel, if the camera sees it.
    public func source(x: Int, y: Int) -> Vec2? {
        let i = (y * width + x) * 2
        guard x >= 0, y >= 0, x < width, y < height, coords[i] >= -0.5 else { return nil }
        return Vec2(Double(coords[i]), Double(coords[i + 1]))
    }

    /// Warps a 4-byte-per-pixel picture (BGRA). Unseen pixels come out fully transparent (all zero);
    /// seen ones are opaque. The result is `width`×`height`, 4 bytes per pixel, rows packed.
    public func apply(bgra src: UnsafeRawBufferPointer, width sw: Int, height sh: Int, bytesPerRow: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        guard sw > 1, sh > 1, let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self),
              src.count >= bytesPerRow * sh else { return out }
        let fx = Float(sw) / Float(sourceWidth), fy = Float(sh) / Float(sourceHeight)
        let maxX = Float(sw - 1), maxY = Float(sh - 1)
        coords.withUnsafeBufferPointer { cp in
            out.withUnsafeMutableBufferPointer { op in
                for i in 0..<(width * height) {
                    let cxs = cp[i * 2]
                    guard cxs >= -0.5 else { continue }
                    let x = min(maxX, max(0, (cxs + 0.5) * fx - 0.5))
                    let y = min(maxY, max(0, (cp[i * 2 + 1] + 0.5) * fy - 0.5))
                    let x0 = min(sw - 2, Int(x)), y0 = min(sh - 2, Int(y))
                    let ax = x - Float(x0), ay = y - Float(y0)
                    let r0 = base + y0 * bytesPerRow + x0 * 4
                    let r1 = r0 + bytesPerRow
                    let o = i * 4
                    for ch in 0..<3 {
                        let top = Float(r0[ch]) * (1 - ax) + Float(r0[ch + 4]) * ax
                        let bottom = Float(r1[ch]) * (1 - ax) + Float(r1[ch + 4]) * ax
                        op[o + ch] = UInt8(min(255, max(0, top * (1 - ay) + bottom * ay + 0.5)))
                    }
                    op[o + 3] = 255
                }
            }
        }
        return out
    }
}
