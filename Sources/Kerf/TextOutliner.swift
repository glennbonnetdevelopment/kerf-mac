import AppKit
import CoreText
import KerfCore

/// Converts a line of text into outline polylines using system fonts.
enum TextOutliner {
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
