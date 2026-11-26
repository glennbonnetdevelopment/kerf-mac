import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Outlines grouped by the colour they were drawn with in the source file.
public struct ImportedGroup: Sendable {
    public var colorHex: String
    public var paths: [Polyline]
    /// Line width in mm when the paths were drawn as strokes with no fill; nil for filled shapes.
    public var strokeWidth: Double?

    public init(colorHex: String, paths: [Polyline], strokeWidth: Double? = nil) {
        self.colorHex = colorHex
        self.paths = paths
        self.strokeWidth = strokeWidth
    }
}

public enum ImportError: Error, LocalizedError {
    case unreadable(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "The file could not be read: \(why)"
        case .empty: return "The file contains no vector outlines Kerf can use."
        }
    }
}

/// Imports SVG files into millimetre outlines (y down, as in SVG).
public enum SVGImporter {
    /// Curve flattening step in mm.
    public static var flattenStep = 0.15

    public static func importFile(at url: URL) throws -> [ImportedGroup] {
        try importData(Data(contentsOf: url))
    }

    public static func importData(_ data: Data) throws -> [ImportedGroup] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        if !parser.parse(), delegate.groups.isEmpty {
            throw ImportError.unreadable(parser.parserError?.localizedDescription ?? "invalid XML")
        }
        let groups = delegate.orderedGroups()
        if groups.isEmpty { throw ImportError.empty }
        return groups
    }

    // MARK: - Lengths and units

    /// Parses an SVG length into millimetres. Bare numbers are CSS pixels (1/96 in).
    static func lengthInMM(_ s: String?) -> Double? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let units: [(String, Double)] = [("mm", 1), ("cm", 10), ("in", 25.4), ("pt", 25.4 / 72), ("pc", 25.4 / 6), ("px", 25.4 / 96)]
        var factor = 25.4 / 96
        for (u, f) in units where s.hasSuffix(u) {
            factor = f
            s.removeLast(u.count)
            break
        }
        if s.hasSuffix("%") { return nil }
        guard let v = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return v * factor
    }

    static func numbers(_ s: String) -> [Double] {
        var scanner = NumberScanner(s)
        var out: [Double] = []
        while let n = scanner.nextNumber() { out.append(n) }
        return out
    }

    // MARK: - Transform attribute

    static func parseTransform(_ s: String) -> Affine {
        var result = Affine.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r")).lowercased()
            let args = SVGImporter.numbers(String(rest[rest.index(after: open)..<close]))
            var t = Affine.identity
            switch name {
            case "matrix" where args.count == 6:
                t = Affine(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case "translate" where !args.isEmpty:
                t = .translation(args[0], args.count > 1 ? args[1] : 0)
            case "scale" where !args.isEmpty:
                t = .scale(args[0], args.count > 1 ? args[1] : args[0])
            case "rotate" where !args.isEmpty:
                let r = Affine.rotation(args[0] * .pi / 180)
                if args.count >= 3 {
                    t = Affine.translation(-args[1], -args[2]).then(r).then(.translation(args[1], args[2]))
                } else {
                    t = r
                }
            case "skewx" where !args.isEmpty:
                t = .skewX(args[0] * .pi / 180)
            case "skewy" where !args.isEmpty:
                t = .skewY(args[0] * .pi / 180)
            default:
                break
            }
            // transform="A B" means A(B(p)): B applies first.
            result = t.then(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    // MARK: - Colours

    static let namedColors: [String: String] = [
        "black": "#000000", "white": "#FFFFFF", "red": "#FF0000", "green": "#008000", "lime": "#00FF00",
        "blue": "#0000FF", "yellow": "#FFFF00", "cyan": "#00FFFF", "aqua": "#00FFFF", "magenta": "#FF00FF",
        "fuchsia": "#FF00FF", "gray": "#808080", "grey": "#808080", "orange": "#FFA500", "purple": "#800080",
        "navy": "#000080", "maroon": "#800000", "olive": "#808000", "teal": "#008080", "silver": "#C0C0C0",
    ]

    /// Returns "#RRGGBB", "none", or nil when unspecified.
    static func parseColor(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if s == "none" || s == "transparent" { return "none" }
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            if hex.count == 3 {
                return "#" + hex.map { "\($0)\($0)" }.joined().uppercased()
            }
            if hex.count >= 6 { return "#" + hex.prefix(6).uppercased() }
            return nil
        }
        if s.hasPrefix("rgb") {
            let n = SVGImporter.numbers(s.replacingOccurrences(of: "%", with: ""))
            guard n.count >= 3 else { return nil }
            let scale = s.contains("%") ? 2.55 : 1.0
            let comps = n.prefix(3).map { Int(max(0, min(255, ($0 * scale).rounded()))) }
            return String(format: "#%02lX%02lX%02lX", comps[0], comps[1], comps[2])
        }
        if s.hasPrefix("url(") { return "#000000" }
        return namedColors[s]
    }

    // MARK: - Parser delegate

    private struct Style {
        var transform = Affine.identity
        var stroke: String?
        var fill: String? = "#000000" // SVG default fill is black
        /// In user units; SVG's default is 1.
        var strokeWidth = 1.0
        var hidden = false
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var stack: [Style] = []
        var skipDepth = 0
        var groups: [String: [Polyline]] = [:]
        var order: [String] = []
        var sawRoot = false

        static let skipped: Set<String> = ["defs", "clippath", "mask", "symbol", "marker", "pattern", "metadata", "title", "desc", "style", "text", "lineargradient", "radialgradient", "filter"]

        func orderedGroups() -> [ImportedGroup] {
            order.compactMap { key in
                guard let p = groups[key], !p.isEmpty else { return nil }
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                return ImportedGroup(colorHex: parts[0], paths: p, strokeWidth: parts.count > 1 ? Double(parts[1]) : nil)
            }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
            let name = (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
            if skipDepth > 0 || Self.skipped.contains(name) {
                skipDepth += 1
                return
            }
            var style = stack.last ?? Style()
            var props = attrs
            if let css = attrs["style"] {
                for decl in css.split(separator: ";") {
                    let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { props[kv[0].lowercased()] = kv[1] }
                }
            }
            if let s = SVGImporter.parseColor(props["stroke"]) { style.stroke = s }
            if let f = SVGImporter.parseColor(props["fill"]) { style.fill = f }
            if let w = props["stroke-width"].flatMap({ SVGImporter.numbers($0).first }), w >= 0 { style.strokeWidth = w }
            if props["display"] == "none" || props["visibility"] == "hidden" { style.hidden = true }

            var local = Affine.identity
            if name == "svg" && !sawRoot {
                sawRoot = true
                local = rootTransform(attrs)
            } else if name == "svg" {
                // Nested viewport: honour x/y placement only.
                local = .translation(Double(attrs["x"] ?? "") ?? 0, Double(attrs["y"] ?? "") ?? 0)
            }
            if let t = attrs["transform"] { local = SVGImporter.parseTransform(t).then(local) }
            style.transform = local.then(style.transform)
            stack.append(style)

            guard !style.hidden else { return }
            let step = SVGImporter.flattenStep / max(style.transform.meanScale, 1e-9)
            var paths: [Polyline] = []
            func num(_ k: String) -> Double { Double(attrs[k]?.trimmingCharacters(in: .whitespaces) ?? "") ?? lengthFallback(attrs[k]) }

            switch name {
            case "path":
                if let d = attrs["d"] { paths = SVGPathParser.parse(d, step: step) }
            case "rect":
                paths = rect(x: num("x"), y: num("y"), w: num("width"), h: num("height"),
                             rx: attrs["rx"].map { _ in num("rx") }, ry: attrs["ry"].map { _ in num("ry") }, step: step)
            case "circle":
                let r = num("r")
                if r > 0 { paths = [Flatten.ellipse(center: Vec2(num("cx"), num("cy")), rx: r, ry: r, step: step)] }
            case "ellipse":
                let rx = num("rx"), ry = num("ry")
                if rx > 0, ry > 0 { paths = [Flatten.ellipse(center: Vec2(num("cx"), num("cy")), rx: rx, ry: ry, step: step)] }
            case "line":
                paths = [Polyline([Vec2(num("x1"), num("y1")), Vec2(num("x2"), num("y2"))])]
            case "polyline", "polygon":
                let n = SVGImporter.numbers(attrs["points"] ?? "")
                var pts: [Vec2] = []
                var i = 0
                while i + 1 < n.count {
                    pts.append(Vec2(n[i], n[i + 1]))
                    i += 2
                }
                if pts.count > 1 { paths = [Polyline(pts, closed: name == "polygon").deduplicated()] }
            default:
                break
            }
            guard !paths.isEmpty else { return }
            let color: String
            if let s = style.stroke, s != "none" { color = s }
            else if let f = style.fill, f != "none" { color = f }
            else { color = "#000000" }
            let placed = paths.transformed(style.transform).filter { $0.points.count > 1 }
            // Outlines drawn only as a stroke keep their line width (in mm), so embroidery can sew them as lines.
            let strokeOnly = (style.stroke.map { $0 != "none" } ?? false) && (style.fill == nil || style.fill == "none")
            let key = strokeOnly
                ? color + String(format: "|%.2f", style.strokeWidth * style.transform.meanScale)
                : color
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(contentsOf: placed)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            if !stack.isEmpty { stack.removeLast() }
        }

        private func lengthFallback(_ s: String?) -> Double {
            // Lengths with units inside the drawing: convert to user units (px).
            guard let mm = SVGImporter.lengthInMM(s) else { return 0 }
            return mm / (25.4 / 96)
        }

        /// Maps the root viewport to millimetres.
        private func rootTransform(_ attrs: [String: String]) -> Affine {
            let vb = attrs["viewBox"].map { SVGImporter.numbers($0) } ?? []
            let wmm = SVGImporter.lengthInMM(attrs["width"])
            let hmm = SVGImporter.lengthInMM(attrs["height"])
            if vb.count == 4, vb[2] > 0, vb[3] > 0 {
                let sx = wmm.map { $0 / vb[2] } ?? (hmm.map { $0 / vb[3] } ?? 25.4 / 96)
                let sy = hmm.map { $0 / vb[3] } ?? sx
                return Affine.translation(-vb[0], -vb[1]).then(.scale(sx, sy))
            }
            return .scale(25.4 / 96, 25.4 / 96)
        }

        private func rect(x: Double, y: Double, w: Double, h: Double, rx: Double?, ry: Double?, step: Double) -> [Polyline] {
            guard w > 0, h > 0 else { return [] }
            var rX = rx ?? ry ?? 0, rY = ry ?? rx ?? 0
            rX = min(rX, w / 2)
            rY = min(rY, h / 2)
            if rX <= 0 || rY <= 0 {
                return [Polyline([Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h)], closed: true)]
            }
            var pts: [Vec2] = [Vec2(x + rX, y), Vec2(x + w - rX, y)]
            pts += Flatten.ellipseArc(center: Vec2(x + w - rX, y + rY), rx: rX, ry: rY, rotation: 0, start: -.pi / 2, sweep: .pi / 2, step: step)
            pts.append(Vec2(x + w, y + h - rY))
            pts += Flatten.ellipseArc(center: Vec2(x + w - rX, y + h - rY), rx: rX, ry: rY, rotation: 0, start: 0, sweep: .pi / 2, step: step)
            pts.append(Vec2(x + rX, y + h))
            pts += Flatten.ellipseArc(center: Vec2(x + rX, y + h - rY), rx: rX, ry: rY, rotation: 0, start: .pi / 2, sweep: .pi / 2, step: step)
            pts.append(Vec2(x, y + rY))
            pts += Flatten.ellipseArc(center: Vec2(x + rX, y + rY), rx: rX, ry: rY, rotation: 0, start: .pi, sweep: .pi / 2, step: step)
            return [Polyline(pts, closed: true).deduplicated()]
        }
    }
}

/// Scans numbers out of SVG attribute strings, handling forms like "1.5.5", "10-5" and "1e-3".
struct NumberScanner {
    let chars: [Character]
    var i = 0

    init(_ s: String) { chars = Array(s) }

    var atEnd: Bool { i >= chars.count }

    mutating func skipSeparators() {
        while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" {
            i += 1
        }
    }

    func peek() -> Character? {
        var j = i
        while j < chars.count, chars[j] == " " || chars[j] == "," || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
        return j < chars.count ? chars[j] : nil
    }

    mutating func nextNumber() -> Double? {
        skipSeparators()
        guard i < chars.count else { return nil }
        let start = i
        if chars[i] == "+" || chars[i] == "-" { i += 1 }
        var sawDigit = false, sawDot = false
        while i < chars.count {
            let c = chars[i]
            if c.isASCII && c.isNumber { sawDigit = true; i += 1 }
            else if c == "." && !sawDot { sawDot = true; i += 1 }
            else { break }
        }
        if sawDigit, i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                i = j
                while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
            }
        }
        guard sawDigit, let v = Double(String(chars[start..<i])) else {
            i = start
            return nil
        }
        return v
    }

    /// Arc flags may be written without separators ("a1 1 0 01 5 5").
    mutating func nextFlag() -> Bool? {
        skipSeparators()
        guard i < chars.count else { return nil }
        if chars[i] == "0" { i += 1; return false }
        if chars[i] == "1" { i += 1; return true }
        return nil
    }

    mutating func nextCommand() -> Character? {
        skipSeparators()
        guard i < chars.count, chars[i].isLetter, chars[i] != "e", chars[i] != "E" else { return nil }
        defer { i += 1 }
        return chars[i]
    }
}

/// Parses SVG path data into flattened polylines (in path coordinates).
public enum SVGPathParser {
    public static func parse(_ d: String, step: Double) -> [Polyline] {
        var s = NumberScanner(d)
        var out: [Polyline] = []
        var current: [Vec2] = []
        var pos = Vec2.zero, start = Vec2.zero
        var lastControl: Vec2? = nil
        var lastCmd: Character = " "
        var cmd: Character = " "

        func flush(closed: Bool) {
            if current.count > 1 { out.append(Polyline(current, closed: closed).deduplicated()) }
            current = []
        }

        func pt(_ rel: Bool) -> Vec2? {
            guard let x = s.nextNumber(), let y = s.nextNumber() else { return nil }
            return rel ? pos + Vec2(x, y) : Vec2(x, y)
        }

        while !s.atEnd {
            if let c = s.nextCommand() {
                cmd = c
            } else if cmd == " " || s.peek() == nil {
                break
            } else if !(s.peek().map { $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." } ?? false) {
                // Unknown character: skip it.
                s.i += 1
                continue
            }
            let rel = cmd.isLowercase
            switch cmd.uppercased().first! {
            case "M":
                guard let p = pt(rel) else { cmd = " "; continue }
                flush(closed: false)
                pos = p
                start = p
                current = [p]
                lastControl = nil
                // Subsequent pairs are implicit line-tos.
                cmd = rel ? "l" : "L"
                lastCmd = "M"
                continue
            case "L":
                guard let p = pt(rel) else { cmd = " "; continue }
                if current.isEmpty { current = [pos] }
                current.append(p)
                pos = p
                lastControl = nil
            case "H":
                guard let x = s.nextNumber() else { cmd = " "; continue }
                if current.isEmpty { current = [pos] }
                pos = Vec2(rel ? pos.x + x : x, pos.y)
                current.append(pos)
                lastControl = nil
            case "V":
                guard let y = s.nextNumber() else { cmd = " "; continue }
                if current.isEmpty { current = [pos] }
                pos = Vec2(pos.x, rel ? pos.y + y : y)
                current.append(pos)
                lastControl = nil
            case "C":
                guard let c1 = pt(rel), let c2 = pt(rel), let p = pt(rel) else { cmd = " "; continue }
                if current.isEmpty { current = [pos] }
                current += Flatten.cubic(pos, c1, c2, p, step: step)
                lastControl = c2
                pos = p
            case "S":
                guard let c2 = pt(rel), let p = pt(rel) else { cmd = " "; continue }
                let c1 = ("CS".contains(lastCmd.uppercased().first!) ? lastControl.map { pos * 2 - $0 } : nil) ?? pos
                if current.isEmpty { current = [pos] }
                current += Flatten.cubic(pos, c1, c2, p, step: step)
                lastControl = c2
                pos = p
            case "Q":
                guard let c = pt(rel), let p = pt(rel) else { cmd = " "; continue }
                if current.isEmpty { current = [pos] }
                current += Flatten.quadratic(pos, c, p, step: step)
                lastControl = c
                pos = p
            case "T":
                guard let p = pt(rel) else { cmd = " "; continue }
                let c = ("QT".contains(lastCmd.uppercased().first!) ? lastControl.map { pos * 2 - $0 } : nil) ?? pos
                if current.isEmpty { current = [pos] }
                current += Flatten.quadratic(pos, c, p, step: step)
                lastControl = c
                pos = p
            case "A":
                guard let rx = s.nextNumber(), let ry = s.nextNumber(), let rot = s.nextNumber(),
                      let large = s.nextFlag(), let sweep = s.nextFlag(), let p = pt(rel) else { cmd = " "; continue }
                if current.isEmpty { current = [pos] }
                current += Flatten.svgArc(from: pos, to: p, rx: rx, ry: ry, xAxisRotationDegrees: rot,
                                          largeArc: large, sweep: sweep, step: step)
                lastControl = nil
                pos = p
            case "Z":
                flush(closed: true)
                pos = start
                lastControl = nil
                lastCmd = "Z"
                cmd = " "
                continue
            default:
                cmd = " "
                continue
            }
            lastCmd = cmd
        }
        flush(closed: false)
        return out
    }
}
