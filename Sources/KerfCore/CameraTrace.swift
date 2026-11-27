import Foundation

/// Turns the camera's picture of the bed into cut outlines: dark (or light) areas become closed shapes,
/// placed exactly where they are on the bed. Good for cutting around a drawing or tracing a part.
public enum CameraTrace {
    /// Grayscale and "seen by the camera" flags from a BGRA picture where unseen pixels are transparent.
    public static func grayscale(bgra: [UInt8], width: Int, height: Int) -> (gray: [UInt8], seen: [Bool]) {
        var gray = [UInt8](repeating: 255, count: width * height)
        var seen = [Bool](repeating: false, count: width * height)
        guard bgra.count >= width * height * 4 else { return (gray, seen) }
        for i in 0..<(width * height) {
            let o = i * 4
            guard bgra[o + 3] > 0 else { continue }
            seen[i] = true
            gray[i] = UInt8((Int(bgra[o]) * 29 + Int(bgra[o + 1]) * 150 + Int(bgra[o + 2]) * 77) >> 8)
        }
        return (gray, seen)
    }

    /// Otsu's threshold: the grey level that best splits the values into a dark and a light group.
    public static func otsuThreshold(_ values: [UInt8], seen: [Bool]? = nil) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        var total = 0
        for (i, v) in values.enumerated() where seen?[i] ?? true {
            hist[Int(v)] += 1
            total += 1
        }
        guard total > 0 else { return 128 }
        var sumAll = 0.0
        for (v, c) in hist.enumerated() { sumAll += Double(v * c) }
        var sumDark = 0.0, countDark = 0
        var best = 0.0, threshold = 128
        for t in 0..<256 {
            countDark += hist[t]
            guard countDark > 0 else { continue }
            let countLight = total - countDark
            if countLight == 0 { break }
            sumDark += Double(t * hist[t])
            let meanDark = sumDark / Double(countDark)
            let meanLight = (sumAll - sumDark) / Double(countLight)
            let between = Double(countDark) * Double(countLight) * (meanDark - meanLight) * (meanDark - meanLight)
            if between > best {
                best = between
                threshold = t + 1
            }
        }
        return UInt8(min(255, threshold))
    }

    public struct Options: Hashable, Sendable {
        /// Pixels darker than this are traced (lighter ones when `traceLight` is on).
        public var threshold: UInt8
        /// Trace light areas instead of dark ones (light drawings on dark material).
        public var traceLight: Bool
        /// Shapes (and holes) smaller than this many mm² are dropped as specks.
        public var minimumArea: Double
        /// Rounding passes for the pixel stair steps.
        public var smoothing: Int

        public init(threshold: UInt8 = 128, traceLight: Bool = false, minimumArea: Double = 4, smoothing: Int = 2) {
            self.threshold = threshold
            self.traceLight = traceLight
            self.minimumArea = minimumArea
            self.smoothing = smoothing
        }
    }

    /// Outlines of the inked areas in a `width`×`height` picture whose top-left pixel corner is at
    /// `origin` on the bed, `cell` mm per pixel. Only pixels inside `region` (bed mm) are used, if given.
    public static func trace(gray: [UInt8], seen: [Bool]?, width: Int, height: Int, origin: Vec2, cell: Double,
                             region: Rect2? = nil, options: Options) -> [Polyline] {
        guard width > 0, height > 0, gray.count >= width * height, cell > 0 else { return [] }
        var x0 = 0, y0 = 0, x1 = width, y1 = height
        if let r = region {
            x0 = max(0, Int(((r.minX - origin.x) / cell).rounded(.down)))
            y0 = max(0, Int(((r.minY - origin.y) / cell).rounded(.down)))
            x1 = min(width, Int(((r.maxX - origin.x) / cell).rounded(.up)))
            y1 = min(height, Int(((r.maxY - origin.y) / cell).rounded(.up)))
        }
        guard x1 > x0, y1 > y0 else { return [] }
        var mask = Contour.Mask(width: x1 - x0, height: y1 - y0,
                                origin: Vec2(origin.x + Double(x0) * cell, origin.y + Double(y0) * cell), cell: cell)
        var any = false
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y * width + x
                guard seen?[i] ?? true else { continue }
                let ink = options.traceLight ? gray[i] >= options.threshold : gray[i] < options.threshold
                if ink {
                    mask.cells[(y - y0) * mask.width + (x - x0)] = true
                    any = true
                }
            }
        }
        guard any else { return [] }
        return Contour.trace(mask)
            .filter { abs($0.signedArea) >= max(0, options.minimumArea) }
            .map { Contour.smooth($0, iterations: options.smoothing) }
            .map { Contour.simplify($0, tolerance: cell * 0.4) }
            .filter { $0.points.count > 2 }
    }
}
