import Foundation

/// An 8-bit grayscale picture, rows top to bottom.
public struct GrayImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "Pixel count must match the size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        pixels[min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))]
    }

    /// Converts a BGRA picture (4 bytes per pixel).
    public static func fromBGRA(_ src: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> GrayImage {
        var out = [UInt8](repeating: 0, count: width * height)
        guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self), src.count >= bytesPerRow * height else {
            return GrayImage(width: width, height: height, pixels: out)
        }
        for y in 0..<height {
            let row = base + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                // Rec. 601 luma from B, G, R.
                out[y * width + x] = UInt8((Int(p[0]) * 29 + Int(p[1]) * 150 + Int(p[2]) * 77) >> 8)
            }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    /// Box-averaged copy `factor` times smaller.
    public func downscaled(by factor: Int) -> GrayImage {
        guard factor > 1 else { return self }
        let w = max(1, width / factor), h = max(1, height / factor)
        var out = [UInt8](repeating: 0, count: w * h)
        let area = factor * factor
        for y in 0..<h {
            for x in 0..<w {
                var s = 0
                for dy in 0..<factor {
                    let row = (y * factor + dy) * width + x * factor
                    for dx in 0..<factor { s += Int(pixels[row + dx]) }
                }
                out[y * w + x] = UInt8(s / area)
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

/// Finds the inner corners of a printed or engraved checkerboard in a camera picture, for lens calibration.
public enum CheckerboardDetector {
    /// Looks for a board with `columns` × `rows` inner corners (squares where four squares meet; a board of
    /// 10 × 7 squares has 9 × 6). Returns the corners with their board positions, or nil when the whole
    /// board isn't visible.
    public static func detect(_ image: GrayImage, columns: Int, rows: Int) -> CheckerboardView? {
        guard columns >= 3, rows >= 3, image.width >= 32, image.height >= 32 else { return nil }
        let longest = max(image.width, image.height)
        var factors: [Int] = []
        for target in [800, 1300, 520] {
            let f = max(1, Int((Double(longest) / Double(target)).rounded()))
            if !factors.contains(f) { factors.append(f) }
        }
        for f in factors {
            let small = image.downscaled(by: f)
            let smooth = Self.float(small)
            for sigma in [1.2, 2.0, 3.2] {
                let blurred = blur(smooth, small.width, small.height, sigma: sigma)
                let found = candidates(blurred, small.width, small.height, sigma: sigma)
                guard found.count >= columns * rows,
                      let grid = assemble(found, columns: columns, rows: rows) else { continue }
                let scale = Double(f)
                let full = grid.points.map { Vec2(($0.x + 0.5) * scale - 0.5, ($0.y + 0.5) * scale - 0.5) }
                let refined = refine(image, full, halfWindow: max(3, Int(grid.spacing * scale * 0.3)))
                return CheckerboardView(imagePoints: refined, boardPoints: grid.board,
                                        imageWidth: image.width, imageHeight: image.height)
            }
        }
        return nil
    }

    static func float(_ img: GrayImage) -> [Float] { img.pixels.map { Float($0) } }

    /// Separable Gaussian blur.
    static func blur(_ src: [Float], _ w: Int, _ h: Int, sigma: Double) -> [Float] {
        let r = max(1, Int((sigma * 3).rounded(.up)))
        var k = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = k.reduce(0, +)
        k = k.map { $0 / sum }
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var s: Float = 0
                for (j, kv) in k.enumerated() {
                    let xx = min(w - 1, max(0, x + j - r))
                    s += src[row + xx] * kv
                }
                tmp[row + x] = s
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for (j, kv) in k.enumerated() {
                    let yy = min(h - 1, max(0, y + j - r))
                    s += tmp[yy * w + x] * kv
                }
                out[y * w + x] = s
            }
        }
        return out
    }

    /// Saddle points: places where the image curves up one way and down the other (negative Hessian
    /// determinant), confirmed by a ring around them that goes light, dark, light, dark.
    static func candidates(_ f: [Float], _ w: Int, _ h: Int, sigma: Double) -> [Vec2] {
        guard w > 8, h > 8 else { return [] }
        var resp = [Float](repeating: 0, count: w * h)
        var maxR: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let c = f[i]
                let dxx = f[i - 1] - 2 * c + f[i + 1]
                let dyy = f[i - w] - 2 * c + f[i + w]
                let dxy = (f[i - w - 1] + f[i + w + 1] - f[i - w + 1] - f[i + w - 1]) / 4
                let r = dxy * dxy - dxx * dyy
                if r > 0 {
                    resp[i] = r
                    if r > maxR { maxR = r }
                }
            }
        }
        guard maxR > 0 else { return [] }
        let threshold = maxR * 0.02
        let rad = max(2, Int((sigma * 1.5).rounded()))
        let ring = max(3.0, sigma * 2.5)
        let margin = rad + Int(ring.rounded(.up)) + 1
        guard w > 2 * margin + 1, h > 2 * margin + 1 else { return [] }
        var out: [(Vec2, Float)] = []
        for y in margin..<(h - margin) {
            for x in margin..<(w - margin) {
                let r = resp[y * w + x]
                guard r > threshold else { continue }
                var isMax = true
                scan: for dy in -rad...rad {
                    for dx in -rad...rad where dx != 0 || dy != 0 {
                        let o = resp[(y + dy) * w + x + dx]
                        if o > r || (o == r && (dy < 0 || (dy == 0 && dx < 0))) {
                            isMax = false
                            break scan
                        }
                    }
                }
                guard isMax, ringAlternates(f, w, h, x, y, radius: ring) else { continue }
                // Sub-pixel peak from a parabola through the neighbours.
                let l = resp[y * w + x - 1], rr = resp[y * w + x + 1], u = resp[(y - 1) * w + x], d = resp[(y + 1) * w + x]
                let denX = l - 2 * r + rr, denY = u - 2 * r + d
                let ox = denX < 0 ? Double(max(-0.5, min(0.5, 0.5 * (l - rr) / denX))) : 0
                let oy = denY < 0 ? Double(max(-0.5, min(0.5, 0.5 * (u - d) / denY))) : 0
                out.append((Vec2(Double(x) + ox, Double(y) + oy), r))
            }
        }
        out.sort { $0.1 > $1.1 }
        return out.prefix(1500).map { $0.0 }
    }

    /// True when a circle around (x, y) crosses exactly four light/dark boundaries, with real contrast.
    static func ringAlternates(_ f: [Float], _ w: Int, _ h: Int, _ x: Int, _ y: Int, radius: Double) -> Bool {
        let n = 32
        var v = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let a = Double(k) / Double(n) * 2 * .pi
            v[k] = sample(f, w, h, Double(x) + cos(a) * radius, Double(y) + sin(a) * radius)
        }
        guard let lo = v.min(), let hi = v.max(), hi - lo > 30 else { return false }
        let mid = (lo + hi) / 2
        let bright = v.map { $0 > mid }
        // Start counting at a boundary so no run is split across the wrap-around.
        guard let start = (0..<n).first(where: { bright[$0] != bright[($0 + n - 1) % n] }) else { return false }
        var changes = 0
        var run = 0, shortest = n
        for step in 0..<n {
            let k = (start + step) % n
            run += 1
            if bright[k] != bright[(k + 1) % n] {
                changes += 1
                shortest = min(shortest, run)
                run = 0
            }
        }
        return changes == 4 && shortest >= 3
    }

    static func sample(_ f: [Float], _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> Float {
        let xc = min(Double(w - 1), max(0, x)), yc = min(Double(h - 1), max(0, y))
        let x0 = min(w - 2, Int(xc)), y0 = min(h - 2, Int(yc))
        let ax = Float(xc - Double(x0)), ay = Float(yc - Double(y0))
        let i = y0 * w + x0
        let top = f[i] * (1 - ax) + f[i + 1] * ax
        let bottom = f[i + w] * (1 - ax) + f[i + w + 1] * ax
        return top * (1 - ay) + bottom * ay
    }

    struct Key: Hashable, Comparable {
        var i: Int
        var j: Int
        static func < (a: Key, b: Key) -> Bool { a.j != b.j ? a.j < b.j : a.i < b.i }
    }

    /// Links saddle points into a grid: start from a point near the middle, step to its neighbours,
    /// and keep predicting where the next corner should be until the grid stops growing.
    static func assemble(_ pts: [Vec2], columns: Int, rows: Int) -> (points: [Vec2], board: [Vec2], spacing: Double)? {
        let need = columns * rows
        guard pts.count >= need else { return nil }
        let centroid = pts.reduce(Vec2.zero, +) / Double(pts.count)
        let seeds = pts.indices.sorted { pts[$0].distance(to: centroid) < pts[$1].distance(to: centroid) }.prefix(25)
        let biggest = max(columns, rows), smallest = min(columns, rows)

        func nearest(to p: Vec2, excluding used: Set<Int>) -> (Int, Double)? {
            var best: (Int, Double)?
            for (k, q) in pts.enumerated() where !used.contains(k) {
                let d = q.distance(to: p)
                if best == nil || d < best!.1 { best = (k, d) }
            }
            return best
        }

        for seed in seeds {
            let s = pts[seed]
            let order = pts.indices.filter { $0 != seed }.sorted { pts[$0].distance(to: s) < pts[$1].distance(to: s) }
            guard let n1 = order.first else { continue }
            let v1 = pts[n1] - s
            guard v1.length > 2 else { continue }
            guard let n2 = order.prefix(8).first(where: { k in
                let v = pts[k] - s
                let ratio = v.length / v1.length
                return ratio > 0.6 && ratio < 1.6 && abs(v.normalized.dot(v1.normalized)) < 0.5
            }) else { continue }

            var grid: [Key: Int] = [Key(i: 0, j: 0): seed, Key(i: 1, j: 0): n1, Key(i: 0, j: 1): n2]
            var used: Set<Int> = [seed, n1, n2]
            var growing = true
            var tooBig = false
            while growing, !tooBig {
                growing = false
                var frontier = Set<Key>()
                for k in grid.keys {
                    for d in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nk = Key(i: k.i + d.0, j: k.j + d.1)
                        if grid[nk] == nil { frontier.insert(nk) }
                    }
                }
                for k in frontier.sorted() {
                    guard let guess = predict(k, grid, pts), guess.1 > 1,
                          let hit = nearest(to: guess.0, excluding: used), hit.1 < 0.3 * guess.1 else { continue }
                    grid[k] = hit.0
                    used.insert(hit.0)
                    growing = true
                }
                let isRange = grid.keys.map(\.i), jsRange = grid.keys.map(\.j)
                let gw = isRange.max()! - isRange.min()! + 1, gh = jsRange.max()! - jsRange.min()! + 1
                if max(gw, gh) > biggest || min(gw, gh) > smallest { tooBig = true }
            }
            guard !tooBig else { continue }
            let iMin = grid.keys.map(\.i).min()!, iMax = grid.keys.map(\.i).max()!
            let jMin = grid.keys.map(\.j).min()!, jMax = grid.keys.map(\.j).max()!
            let gw = iMax - iMin + 1, gh = jMax - jMin + 1
            guard grid.count == need, gw * gh == need,
                  (gw == columns && gh == rows) || (gw == rows && gh == columns) else { continue }

            func at(_ i: Int, _ j: Int) -> Vec2 { pts[grid[Key(i: i + iMin, j: j + jMin)]!] }
            // Board x to the right and y down as the camera sees it (a mirrored labelling would need a
            // reflection, which no camera pose can produce).
            let ax = at(1, 0) - at(0, 0), ay = at(0, 1) - at(0, 0)
            let mirror = ax.cross(ay) < 0
            var points: [Vec2] = [], board: [Vec2] = []
            var spacings: [Double] = []
            for j in 0..<gh {
                for i in 0..<gw {
                    let src = mirror ? gw - 1 - i : i
                    points.append(at(src, j))
                    board.append(Vec2(Double(i), Double(j)))
                    if i > 0 { spacings.append(at(src, j).distance(to: at(mirror ? src + 1 : src - 1, j))) }
                }
            }
            spacings.sort()
            return (points, board, spacings[spacings.count / 2])
        }
        return nil
    }

    /// Where grid position `k` should be, from its known neighbours, and the local corner spacing.
    static func predict(_ k: Key, _ grid: [Key: Int], _ pts: [Vec2]) -> (Vec2, Double)? {
        var sum = Vec2.zero, spacing = 0.0, n = 0
        for d in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            if let a = grid[Key(i: k.i - d.0, j: k.j - d.1)], let b = grid[Key(i: k.i - 2 * d.0, j: k.j - 2 * d.1)] {
                sum = sum + pts[a] * 2 - pts[b]
                spacing += pts[a].distance(to: pts[b])
                n += 1
            }
        }
        if n == 0 {
            for d in [(1, 1), (1, -1), (-1, 1), (-1, -1)] {
                if let a = grid[Key(i: k.i - d.0, j: k.j)], let b = grid[Key(i: k.i, j: k.j - d.1)],
                   let c = grid[Key(i: k.i - d.0, j: k.j - d.1)] {
                    sum = sum + pts[a] + pts[b] - pts[c]
                    spacing += min(pts[a].distance(to: pts[c]), pts[b].distance(to: pts[c]))
                    n += 1
                }
            }
        }
        guard n > 0 else { return nil }
        return (sum / Double(n), spacing / Double(n))
    }

    /// Sub-pixel corner positions: at a true corner every edge gradient in the window points at the
    /// corner, so solve for the point that best fits that (the classic "corner sub-pixel" method).
    static func refine(_ img: GrayImage, _ pts: [Vec2], halfWindow hw: Int) -> [Vec2] {
        let w = img.width, h = img.height
        let g = blur(float(img), w, h, sigma: 1.0)
        let sigma2 = 2 * pow(Double(hw) * 0.6, 2)
        return pts.map { p in
            var q = p
            for _ in 0..<15 {
                var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
                let cxI = Int(q.x.rounded()), cyI = Int(q.y.rounded())
                for dy in -hw...hw {
                    let y = cyI + dy
                    guard y > 0, y < h - 1 else { continue }
                    for dx in -hw...hw {
                        let x = cxI + dx
                        guard x > 0, x < w - 1 else { continue }
                        let i = y * w + x
                        let gx = Double(g[i + 1] - g[i - 1]) / 2, gy = Double(g[i + w] - g[i - w]) / 2
                        let wgt = exp(-Double(dx * dx + dy * dy) / sigma2)
                        let gxx = gx * gx * wgt, gxy = gx * gy * wgt, gyy = gy * gy * wgt
                        a11 += gxx
                        a12 += gxy
                        a22 += gyy
                        b1 += gxx * Double(x) + gxy * Double(y)
                        b2 += gxy * Double(x) + gyy * Double(y)
                    }
                }
                let det = a11 * a22 - a12 * a12
                guard det > 1e-9 * max(1, a11 * a22) else { break }
                let next = Vec2((a22 * b1 - a12 * b2) / det, (a11 * b2 - a12 * b1) / det)
                guard next.distance(to: p) <= Double(hw) else { break }
                let moved = next.distance(to: q)
                q = next
                if moved < 0.01 { break }
            }
            return q
        }
    }
}
