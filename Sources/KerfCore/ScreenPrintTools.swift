import CoreGraphics
import CoreText
import Foundation

// MARK: - Mesh presets

/// A screen mesh with the halftone line count that holds on it.
public struct MeshPreset: Identifiable, Hashable, Sendable {
    /// Threads per inch.
    public var mesh: Int
    /// Halftone lines per inch that the mesh holds without dots falling through.
    public var lpi: Double
    /// What the mesh is usually used for.
    public var use: String

    public var id: Int { mesh }
    public var title: String { "\(mesh) mesh · \(Int(lpi)) LPI" }

    /// Common meshes. Line counts follow the rule of thumb that a mesh holds about a quarter to a fifth of
    /// its thread count in lines per inch.
    public static let all: [MeshPreset] = [
        MeshPreset(mesh: 110, lpi: 25, use: "White underbase, glitter and thick inks"),
        MeshPreset(mesh: 156, lpi: 35, use: "General spot colours on garments"),
        MeshPreset(mesh: 200, lpi: 45, use: "Fine lines and coarse halftones"),
        MeshPreset(mesh: 230, lpi: 55, use: "Halftones and photo separations"),
        MeshPreset(mesh: 305, lpi: 65, use: "Fine halftones and water-based inks"),
    ]

    public static func preset(_ mesh: Int) -> MeshPreset? { all.first { $0.mesh == mesh } }

    /// Lines per inch for any mesh count (thread count ÷ 4.5).
    public static func recommendedLPI(mesh: Int) -> Double { (Double(mesh) / 4.5).rounded() }
}

// MARK: - Exposure test film

/// A film for finding the exposure time: the same detail patches in several columns, each exposed for longer
/// by covering one more column with card as the exposure runs.
public enum ExposureTest {
    public static let filmID = UUID(uuidString: "00000000-0000-0000-0000-0000000E7E57")!
    static let columnWidth = 30.0
    static let gap = 3.0
    /// Positive and reversed line widths, mm.
    public static let lineWidths = [0.1, 0.2, 0.3, 0.5, 0.75, 1.0]
    /// Halftone patch coverages.
    public static let tones = [0.1, 0.3, 0.5, 0.7, 0.9]

    /// Exposure of each column in seconds: column 1 is covered first, the last column gets the longest.
    public static func times(steps: Int, base: Double, step: Double) -> [Double] {
        (0..<max(1, steps)).map { max(0, base) + Double($0) * max(0, step) }
    }

    /// "1:30" for 90 seconds.
    public static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The test film, laid out with the paper, mirror, line count and dot settings from `options`.
    public static func films(options: ScreenPrintOptions) -> FilmSet {
        let times = times(steps: min(12, options.testSteps), base: options.testBaseSeconds, step: options.testStepSeconds)
        let art = CGMutablePath()
        let dots = CGMutablePath()
        for (i, t) in times.enumerated() {
            let x = Double(i) * (columnWidth + gap)
            column(x: x, title: "\(i + 1)", time: clock(t), options: options, into: art, dots: dots)
        }
        let width = Double(times.count) * (columnWidth + gap) - gap
        var y = 104.0
        art.addPath(text("Cover column 1 at \(clock(times[0])), then one more column every \(clock(max(0, options.testStepSeconds))).",
                         height: 2.5, at: Vec2(0, y)))
        y += 4.5
        art.addPath(text("Choose the shortest time where every patch washes out cleanly and the emulsion doesn't feel soft.",
                         height: 2.5, at: Vec2(0, y)))
        var o = options
        o.registrationMarks = false
        o.labels = false
        o.invert = false
        let film = Film(id: filmID, name: "Exposure test", colorHex: "#000000", areas: art, dots: dots, isUnderbase: false)
        var content = ScreenPrint.rect(art.boundingBoxOfPath).union(ScreenPrint.rect(dots.boundingBoxOfPath))
        content.include(Vec2(width, 0))
        let mirror = o.mirror ? OutputMirror.horizontal.transform(about: content.center) : .identity
        return FilmSet(films: [film], options: o, content: content, frame: content, marks: CGMutablePath(), markCenters: [],
                       mirror: mirror, extent: content)
    }

    /// One column of test patches with its top-left corner at (x, 0).
    static func column(x: Double, title: String, time: String, options: ScreenPrintOptions,
                       into art: CGMutablePath, dots: CGMutablePath) {
        let w = columnWidth
        // Header: column number and its time, clear on black so the edge of the card is easy to line up.
        let header = CGMutablePath(rect: CGRect(x: x, y: 0, width: w, height: 9), transform: nil)
        let label = text("\(title)   \(time)", height: 4, at: Vec2(x + 2, 7))
        art.addPath(header.subtracting(label, using: .winding))
        // Positive lines.
        var y = 13.0
        for lw in lineWidths {
            art.addRect(CGRect(x: x + 1, y: y, width: w - 2, height: lw))
            y += 2.6
        }
        // Reversed lines: clear lines in a black block.
        y += 1
        let blockTop = y
        let block = CGMutablePath(rect: CGRect(x: x, y: blockTop, width: w, height: Double(lineWidths.count) * 2.6 + 1.5), transform: nil)
        let clear = CGMutablePath()
        var ly = blockTop + 1.2
        for lw in lineWidths {
            clear.addRect(CGRect(x: x + 1, y: ly, width: w - 2, height: lw))
            ly += 2.6
        }
        art.addPath(block.subtracting(clear, using: .winding))
        y = blockTop + Double(lineWidths.count) * 2.6 + 4
        // Halftone patches.
        let patch = (w - Double(tones.count - 1)) / Double(tones.count)
        for (k, tone) in tones.enumerated() {
            let px = x + Double(k) * (patch + 1)
            let grey = UInt8(((1 - tone) * 255).rounded())
            let img = RasterImage(width: 1, height: 1, pixels: Data([grey]))
            let square = Polyline([Vec2(0, 0), Vec2(patch, 0), Vec2(patch, patch), Vec2(0, patch)], closed: true)
            let a = Artwork(layerID: filmID, name: "tone", paths: [square], transform: .translation(px, y), image: img)
            dots.addPath(ScreenPrint.halftone(a, lpi: options.halftoneLPI, angle: options.halftoneAngle, shape: options.dotShape))
        }
        y += patch + 3
        // Fine dots, 0.2 to 1 mm across.
        var dx = x + 1
        for d in [0.2, 0.3, 0.4, 0.6, 0.8, 1.0] {
            art.addEllipse(in: CGRect(x: dx, y: y, width: d, height: d))
            dx += d + 3
        }
        y += 4
        // Small text, positive and reversed.
        art.addPath(text("Fine text 6 pt", height: 1.5, at: Vec2(x + 1, y + 2)))
        y += 4
        let small = CGMutablePath(rect: CGRect(x: x, y: y, width: w, height: 5), transform: nil)
        art.addPath(small.subtracting(text("Reversed 6 pt", height: 1.5, at: Vec2(x + 1, y + 3.5)), using: .winding))
        y += 8
        // Solid patch, to check the black is dense enough.
        art.addRect(CGRect(x: x, y: y, width: w, height: 8))
    }

    /// Text as filled outlines, `height` mm capital height, baseline starting at `p` (y down).
    public static func text(_ s: String, height: Double, at p: Vec2) -> CGPath {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, height * 1.4, nil)
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let out = CGMutablePath()
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return out }
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            let runFont: CTFont = runAttrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            for i in 0..<n {
                guard let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                // Glyphs are drawn y up; flip them into the y-down page.
                let t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: p.x + positions[i].x, ty: p.y - positions[i].y)
                out.addPath(g, transform: t)
            }
        }
        return out
    }
}

// MARK: - Colour photo separation

/// A colour, each channel 0…1.
public struct InkColor: Hashable, Codable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public var hex: String {
        func c(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    public var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    /// Squared perceptual distance ("redmean" weighting), cheap and much closer to how colours look than plain RGB.
    public func distance2(_ o: InkColor) -> Double {
        let rm = (r + o.r) / 2
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return (2 + rm) * dr * dr + 4 * dg * dg + (3 - rm) * db * db
    }
}

/// An RGBA bitmap, 8 bits per channel, rows top to bottom.
public struct ColorImage: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// R, G, B, A for each pixel (not premultiplied).
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public func color(at i: Int) -> InkColor {
        InkColor(Double(rgba[i * 4]) / 255, Double(rgba[i * 4 + 1]) / 255, Double(rgba[i * 4 + 2]) / 255)
    }

    public func isClear(at i: Int) -> Bool { rgba[i * 4 + 3] < 128 }
}

/// Splits a colour picture into spot-colour separations: one greyscale image per ink, dark where that ink
/// prints, so each becomes a halftoned film.
public enum PhotoSeparation {
    /// The `count` ink colours that best describe the picture, lightest first (the usual print order).
    /// Colours close to the garment are left to the garment, which prints no ink.
    public static func palette(_ img: ColorImage, count: Int, garment: InkColor? = nil) -> [InkColor] {
        let n = img.width * img.height
        guard n > 0, count > 0 else { return [] }
        let stride = max(1, n / 20000)
        var samples: [InkColor] = []
        var i = 0
        while i < n {
            if !img.isClear(at: i) { samples.append(img.color(at: i)) }
            i += stride
        }
        guard !samples.isEmpty else { return [] }
        // Start from colours far apart (and far from the garment), so the result doesn't depend on chance.
        var centres: [InkColor] = []
        var nearest = samples.map { s in garment.map { s.distance2($0) } ?? .infinity }
        for _ in 0..<count {
            var best = 0
            var bestD = -1.0
            for (k, d) in nearest.enumerated() {
                let dd = d.isInfinite ? 1e9 - samples[k].luminance : d
                if dd > bestD { bestD = dd; best = k }
            }
            guard bestD > 1e-6 else { break }
            let c = samples[best]
            centres.append(c)
            for k in samples.indices { nearest[k] = min(nearest[k], samples[k].distance2(c)) }
        }
        // k-means; the garment is a fixed centre that soaks up the colours it already covers.
        for _ in 0..<12 {
            var sum = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: centres.count)
            for s in samples {
                var best = -1
                var bestD = garment.map { s.distance2($0) } ?? .infinity
                for (k, c) in centres.enumerated() {
                    let d = s.distance2(c)
                    if d < bestD { bestD = d; best = k }
                }
                guard best >= 0 else { continue }
                sum[best].0 += s.r
                sum[best].1 += s.g
                sum[best].2 += s.b
                sum[best].3 += 1
            }
            for k in centres.indices where sum[k].3 > 0 {
                let m = Double(sum[k].3)
                centres[k] = InkColor(sum[k].0 / m, sum[k].1 / m, sum[k].2 / m)
            }
        }
        return centres.sorted { $0.luminance > $1.luminance }
    }

    /// How much of each ink a pixel gets: shares of 1 by closeness. `smoothing` 0 gives each pixel to its one
    /// nearest colour (a hard index separation); higher values blend neighbouring colours for smooth tones.
    static func shares(_ c: InkColor, inks: [InkColor], garment: InkColor?, smoothing: Double) -> [Double] {
        var d = inks.map { c.distance2($0) }
        if let garment { d.append(c.distance2(garment)) }
        var out = [Double](repeating: 0, count: inks.count)
        guard !d.isEmpty else { return out }
        if smoothing <= 0.001 {
            let k = d.indices.min { d[$0] < d[$1] }!
            if k < inks.count { out[k] = 1 }
            return out
        }
        // Inverse-distance weights; a lower power blends more.
        let power = 1 + (1 - min(1, smoothing)) * 7
        if let k = d.firstIndex(where: { $0 < 1e-9 }) {
            if k < inks.count { out[k] = 1 }
            return out
        }
        let w = d.map { pow(1 / $0, power / 2) }
        let total = w.reduce(0, +)
        for k in inks.indices { out[k] = w[k] / total }
        return out
    }

    /// One greyscale image per ink (black = full ink), the same size as the picture. Clear pixels print nothing.
    public static func separate(_ img: ColorImage, inks: [InkColor], garment: InkColor? = nil,
                                smoothing: Double = 0.5) -> [RasterImage] {
        let n = img.width * img.height
        var planes = [[UInt8]](repeating: [UInt8](repeating: 255, count: n), count: inks.count)
        for i in 0..<n where !img.isClear(at: i) {
            let s = shares(img.color(at: i), inks: inks, garment: garment, smoothing: smoothing)
            for k in inks.indices where s[k] > 0 {
                planes[k][i] = UInt8(((1 - s[k]) * 255).rounded())
            }
        }
        return planes.map { RasterImage(width: img.width, height: img.height, pixels: Data($0)) }
    }

    /// How the separated print looks: each ink laid on the garment by its share. RGBA, opaque.
    public static func preview(_ img: ColorImage, inks: [InkColor], garment: InkColor?, smoothing: Double) -> [UInt8] {
        let n = img.width * img.height
        let base = garment ?? InkColor(1, 1, 1)
        var out = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            var c = base
            if !img.isClear(at: i) {
                let s = shares(img.color(at: i), inks: inks, garment: garment, smoothing: smoothing)
                let inked = s.reduce(0, +)
                var r = base.r * (1 - inked), g = base.g * (1 - inked), b = base.b * (1 - inked)
                for k in inks.indices {
                    r += inks[k].r * s[k]
                    g += inks[k].g * s[k]
                    b += inks[k].b * s[k]
                }
                c = InkColor(r, g, b)
            }
            out[i * 4] = UInt8((min(1, max(0, c.r)) * 255).rounded())
            out[i * 4 + 1] = UInt8((min(1, max(0, c.g)) * 255).rounded())
            out[i * 4 + 2] = UInt8((min(1, max(0, c.b)) * 255).rounded())
        }
        return out
    }
}
