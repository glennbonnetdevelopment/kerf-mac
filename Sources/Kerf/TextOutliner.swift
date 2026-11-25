import AppKit
import CoreText
import KerfCore

/// Converts a line of text into outline polylines using system fonts.
enum TextOutliner {
    /// Outlines for a text spec, with the top-left of the text's bounds at (0, 0).
    static func outlines(for spec: TextSpec) -> [Polyline] {
        let raw = outlines(text: spec.text, fontName: spec.fontName, height: spec.height)
        let b = raw.bounds
        guard !b.isEmpty else { return [] }
        return raw.transformed(.translation(-b.minX, -b.minY))
    }

    struct Glyph {
        /// Outlines in y-down space, baseline at y = 0.
        var paths: [Polyline]
        /// Left edge and advance width along the baseline.
        var x: Double
        var advance: Double
    }

    /// Per-glyph outlines, for laying text along a path.
    static func glyphs(text: String, fontName: String, height: Double, step: Double = 0.1) -> [Glyph] {
        guard !text.isEmpty else { return [] }
        let probe = NSFont(name: fontName, size: 100) ?? NSFont.systemFont(ofSize: 100)
        let capRatio = probe.capHeight > 0 ? probe.capHeight / 100 : 0.7
        let size = CGFloat(height) / capRatio
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        var out: [Glyph] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont: CTFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? (font as CTFont)
            for i in 0..<count {
                var paths: [Polyline] = []
                if let path = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    paths = flatten(path, offset: .zero, step: step).transformed(.scale(1, -1))
                }
                out.append(Glyph(paths: paths, x: Double(positions[i].x), advance: Double(advances[i].width)))
            }
        }
        return out
    }

    /// Text outlines in line coordinates: x along the baseline from the first letter, y down, baseline at 0.
    static func lineOutlines(for spec: TextSpec) -> (paths: [Polyline], width: Double) {
        let laid = glyphs(text: spec.text, fontName: spec.fontName, height: spec.height)
        let paths = laid.flatMap { g in g.paths.transformed(.translation(g.x, 0)) }
        let width = laid.map { $0.x + $0.advance }.max() ?? 0
        return (paths, width)
    }

    /// Text bent along a path, in the path's coordinates.
    static func alongPath(_ spec: TextSpec, pathText: PathTextSpec) -> [Polyline] {
        PathText.place(lineOutlines(for: spec).paths, spec: pathText, smoothing: max(0.5, spec.height * 0.3))
    }

    /// - Parameter height: approximate capital-letter height in mm.
    static func outlines(text: String, fontName: String, height: Double, step: Double = 0.1) -> [Polyline] {
        guard !text.isEmpty else { return [] }
        let probe = NSFont(name: fontName, size: 100) ?? NSFont.systemFont(ofSize: 100)
        let capRatio = probe.capHeight > 0 ? probe.capHeight / 100 : 0.7
        let size = CGFloat(height) / capRatio
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }

        var result: [Polyline] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont: CTFont
            if let f = attrs[kCTFontAttributeName as String] {
                runFont = f as! CTFont
            } else {
                runFont = font as CTFont
            }
            for i in 0..<count {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                let origin = Vec2(Double(positions[i].x), Double(positions[i].y))
                result += flatten(path, offset: origin, step: step)
            }
        }
        // CoreText is y-up; the design space is y-down.
        return result.transformed(.scale(1, -1))
    }

    static func flatten(_ path: CGPath, offset: Vec2, step: Double) -> [Polyline] {
        var out: [Polyline] = []
        var current: [Vec2] = []
        var pos = Vec2.zero
        func v(_ p: CGPoint) -> Vec2 { Vec2(Double(p.x), Double(p.y)) + offset }
        func flush(closed: Bool) {
            if current.count > 1 { out.append(Polyline(current, closed: closed).deduplicated()) }
            current = []
        }
        path.applyWithBlock { elementPtr in
            let e = elementPtr.pointee
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
        return out
    }

    /// Font family members suitable for the picker.
    static var availableFonts: [String] {
        NSFontManager.shared.availableFonts
    }
}
