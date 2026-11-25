import Foundation

/// One engraving line of an image: pixels of `step` mm starting at `x0`, with power 0…255.
public struct RasterRow: Sendable, Hashable {
    public var y: Double
    public var x0: Double
    public var step: Double
    public var power: [UInt8]
    public var reversed: Bool

    public var x1: Double { x0 + Double(power.count) * step }
}

public enum Raster {
    /// Applies a dither to a grid of brightness values (0 black … 1 white), returning burn power 0…255.
    public static func dither(_ gray: [Double], width: Int, height: Int, mode: DitherMode) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: gray.count)
        switch mode {
        case .threshold:
            for i in gray.indices { out[i] = gray[i] < 0.5 ? 255 : 0 }
        case .grayscale:
            for i in gray.indices { out[i] = UInt8(max(0, min(255, ((1 - gray[i]) * 255).rounded()))) }
        case .floydSteinberg, .atkinson:
            var g = gray
            let kernel: [(Int, Int, Double)] = mode == .floydSteinberg
                ? [(1, 0, 7.0 / 16), (-1, 1, 3.0 / 16), (0, 1, 5.0 / 16), (1, 1, 1.0 / 16)]
                : [(1, 0, 1.0 / 8), (2, 0, 1.0 / 8), (-1, 1, 1.0 / 8), (0, 1, 1.0 / 8), (1, 1, 1.0 / 8), (0, 2, 1.0 / 8)]
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    let old = g[i]
                    let new = old < 0.5 ? 0.0 : 1.0
                    out[i] = new == 0 ? 255 : 0
                    let err = old - new
                    for (dx, dy, w) in kernel {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, nx < width, ny < height { g[ny * width + nx] += err * w }
                    }
                }
            }
        }
        return out
    }

    /// Engraving rows for an image artwork, sampled every `layer.fillInterval` mm.
    /// Rotated images are sampled on their bounding box, so rotation is honoured pixel by pixel.
    public static func rows(for art: Artwork, layer: Layer) -> [RasterRow] {
        guard let img = art.image else { return [] }
        let frame = art.localFrame
        guard frame.width > 0, frame.height > 0 else { return [] }
        let b = art.bounds
        let step = max(0.02, layer.fillInterval)
        let cols = Int((b.width / step).rounded(.up)), rowCount = Int((b.height / step).rounded(.up))
        guard cols > 0, rowCount > 0, cols * rowCount <= 60_000_000 else { return [] }
        let inv = art.transform.inverted

        var gray = [Double](repeating: 1, count: cols * rowCount)
        for r in 0..<rowCount {
            let y = b.minY + (Double(r) + 0.5) * step
            for c in 0..<cols {
                let x = b.minX + (Double(c) + 0.5) * step
                let local = inv.apply(Vec2(x, y))
                let u = (local.x - frame.minX) / frame.width, v = (local.y - frame.minY) / frame.height
                if var value = img.brightness(u: u, v: v) {
                    if layer.invertImage { value = 1 - value }
                    gray[r * cols + c] = value
                }
            }
        }
        // Pixels outside the image are white, so they never burn.
        let power = dither(gray, width: cols, height: rowCount, mode: layer.dither)

        var out: [RasterRow] = []
        var forward = true
        for r in 0..<rowCount {
            let row = power[(r * cols)..<((r + 1) * cols)]
            guard let first = row.firstIndex(where: { $0 > 0 }), let last = row.lastIndex(where: { $0 > 0 }) else { continue }
            let y = b.minY + (Double(r) + 0.5) * step
            out.append(RasterRow(y: y, x0: b.minX + Double(first - r * cols) * step, step: step,
                                 power: Array(power[first...last]), reversed: !forward))
            if layer.fillBidirectional { forward.toggle() }
        }
        return out
    }
}

// MARK: - Path offsetting (CNC tool compensation)

public enum PathOffset {
    /// Offsets a closed polygon by `distance` mm: positive grows it, negative shrinks it.
    /// Uses mitred corners (bevelled when very sharp). Works well for simple shapes and
    /// offsets smaller than the shape's features.
    public static func offset(_ poly: Polyline, by distance: Double) -> Polyline {
        let pts = poly.deduplicated().points
        guard poly.closed, pts.count > 2, distance != 0 else { return poly }
        // Positive signed area (counter-clockwise in a y-up frame) means the right-hand normal points outward.
        let sign: Double = poly.signedArea > 0 ? 1 : -1
        let n = pts.count
        var out: [Vec2] = []
        for i in 0..<n {
            let prev = pts[(i - 1 + n) % n], cur = pts[i], next = pts[(i + 1) % n]
            let d0 = (cur - prev).normalized, d1 = (next - cur).normalized
            let n0 = Vec2(d0.y, -d0.x) * sign, n1 = Vec2(d1.y, -d1.x) * sign
            let bis = (n0 + n1)
            let bl = bis.length
            if bl < 1e-9 {
                out.append(cur + n0 * distance)
                continue
            }
            let miter = bis / bl
            let cosHalf = miter.dot(n0)
            let len = distance / max(cosHalf, 1e-9)
            if abs(len) > abs(distance) * 3 {
                // Very sharp corner: bevel instead of a long spike.
                out.append(cur + n0 * distance)
                out.append(cur + n1 * distance)
            } else {
                out.append(cur + miter * len)
            }
        }
        return Polyline(out, closed: true)
    }
}

// MARK: - Nesting

public enum Nester {
    public struct Placement: Sendable, Equatable {
        /// Where the item's bounding box's top-left corner goes.
        public var origin: Vec2
        /// Whether the item is turned 90°.
        public var rotated: Bool
    }

    /// Packs bounding boxes into `area` row by row (tallest first). Items that don't fit return nil.
    public static func pack(sizes: [Vec2], in area: Rect2, spacing: Double, allowRotation: Bool) -> [Placement?] {
        var result = [Placement?](repeating: nil, count: sizes.count)
        // Orient each item so it is no taller than it is wide (packs rows better), if it then still fits.
        var oriented: [(index: Int, size: Vec2, rotated: Bool)] = sizes.enumerated().map { i, s in
            if allowRotation, s.y > s.x, s.y <= area.width { return (i, Vec2(s.y, s.x), true) }
            return (i, s, false)
        }
        oriented.sort { $0.size.y > $1.size.y }

        var x = area.minX, y = area.minY, rowHeight = 0.0
        for item in oriented {
            var size = item.size, rotated = item.rotated
            if size.x > area.width, allowRotation, size.y <= area.width {
                size = Vec2(size.y, size.x)
                rotated.toggle()
            }
            if x + size.x > area.maxX + 1e-9 {
                x = area.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            guard x + size.x <= area.maxX + 1e-9, y + size.y <= area.maxY + 1e-9 else { continue }
            result[item.index] = Placement(origin: Vec2(x, y), rotated: rotated)
            x += size.x + spacing
            rowHeight = max(rowHeight, size.y)
        }
        return result
    }
}

// MARK: - Print and cut

public enum Registration {
    /// Centres of three registration marks (top-left, top-right, bottom-left) around `bounds`.
    public static func markCenters(around bounds: Rect2, margin: Double, size: Double) -> [Vec2] {
        let r = bounds.insetBy(-(margin + size / 2))
        return [Vec2(r.minX, r.minY), Vec2(r.maxX, r.minY), Vec2(r.minX, r.maxY)]
    }

    /// A filled-square registration mark outline.
    public static func mark(at c: Vec2, size: Double) -> Polyline {
        let h = size / 2
        return Polyline([Vec2(c.x - h, c.y - h), Vec2(c.x + h, c.y - h), Vec2(c.x + h, c.y + h), Vec2(c.x - h, c.y + h)], closed: true)
    }

    /// The similarity transform (rotate, scale, move) taking two design points onto two measured points.
    public static func alignment(design a: Vec2, _ b: Vec2, measured a2: Vec2, _ b2: Vec2) -> Affine? {
        let d = b - a, m = b2 - a2
        guard d.length > 1e-6, m.length > 1e-6 else { return nil }
        let angle = atan2(m.y, m.x) - atan2(d.y, d.x)
        let scale = m.length / d.length
        return Affine.translation(-a.x, -a.y)
            .then(.rotation(angle))
            .then(.scale(scale, scale))
            .then(.translation(a2.x, a2.y))
    }
}
