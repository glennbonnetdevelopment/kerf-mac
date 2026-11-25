import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Shapes, images, text and layers read from another program's project file.
/// Everything is in Kerf design space (mm, y down).
public struct ProjectImport: Sendable {
    public struct Shape: Sendable {
        public var layerIndex: Int
        public var paths: [Polyline]
    }

    public struct Image: Sendable {
        public var layerIndex: Int
        public var name: String
        /// Encoded image file (PNG or JPEG).
        public var data: Data
        /// The image's frame in its own coordinates (mm, y down); the picture fills it.
        public var frame: Rect2
        public var transform: Affine
    }

    public struct Text: Sendable {
        public var layerIndex: Int
        public var text: String
        public var fontFamily: String
        /// Cap height in mm.
        public var height: Double
        /// 0 left, 1 centre, 2 right.
        public var alignment: Int
        /// Maps outlines whose baseline-left is at (0, 0) (y down) into place.
        public var transform: Affine
    }

    public var layers: [Int: Layer] = [:]
    public var shapes: [Shape] = []
    public var images: [Image] = []
    public var texts: [Text] = []
    public var workpiece: Workpiece?
    /// Things that could not be brought across.
    public var warnings: [String] = []

    public init() {}
}

/// A minimal XML element tree.
final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.attributes["Value"] }
    func double(_ key: String) -> Double? { attributes[key].flatMap(Double.init) }

    static func parse(_ data: Data) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw ImportError.unreadable(parser.parserError?.localizedDescription ?? "not valid XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XMLNode] = []
        var root: XMLNode?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(name: elementName, attributes: attributeDict)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}

// MARK: - LightBurn

/// Reads LightBurn project files (.lbrn2, and the older .lbrn): layers with their settings, vector
/// shapes (paths, rectangles, ellipses, groups), images, and text.
public enum LightBurnImporter {
    /// LightBurn's fixed layer colours, by layer number.
    public static let palette = [
        "#000000", "#0000FF", "#FF0000", "#00E000", "#D0D000", "#FF8000", "#00E0E0", "#FF00FF",
        "#B4B4B4", "#0000A0", "#A00000", "#00A000", "#A0A000", "#C08000", "#00A0FF", "#A000A0",
        "#808080", "#7D87B9", "#BB7784", "#4A6FE3", "#D33F6A", "#8CD78C", "#F0B98D", "#F6C4E1",
        "#FA9ED4", "#500A78", "#B45A00", "#004754", "#86FA88", "#FFDB66",
    ]

    /// - Parameter bedHeight: LightBurn measures up from the bottom of the bed; Kerf measures down from the top.
    public static func parse(_ data: Data, bedWidth: Double = 0, bedHeight: Double) throws -> ProjectImport {
        let root = try XMLNode.parse(data)
        guard root.name == "LightBurnProject" else { throw ImportError.unreadable("not a LightBurn project") }
        var result = ProjectImport()
        // Normally LightBurn measures y up from the bottom of the bed. With MirrorY (machines whose origin
        // is at the top, such as the xTool D1) it measures down from the top like Kerf. MirrorX measures x from the right.
        let mirrorY = root.attributes["MirrorY"]?.lowercased() == "true"
        let mirrorX = root.attributes["MirrorX"]?.lowercased() == "true"
        var world = mirrorY ? Affine.identity : Affine(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bedHeight)
        if mirrorX { world = world.then(Affine(a: -1, b: 0, c: 0, d: 1, tx: bedWidth, ty: 0)) }

        for node in root.children where node.name.hasPrefix("CutSetting") {
            let index = node.value("index").flatMap(Int.init) ?? 0
            result.layers[index] = layer(from: node, index: index)
        }

        // Pictures and text are drawn top-down on screen, so they flip whenever the world does.
        // A mirrored world axis is undone locally so the picture or lettering isn't mirrored.
        var screenFlip = mirrorY ? Affine.identity : Affine(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        if mirrorX { screenFlip = screenFlip.then(Affine(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)) }
        var ctx = Context(world: world, screenFlip: screenFlip, verts: [:], prims: [:])
        for node in root.children where node.name == "Shape" {
            walk(node, parent: .identity, into: &result, ctx: &ctx)
        }
        // Shapes on layers with no settings block still get a layer.
        let used = Set(result.shapes.map(\.layerIndex) + result.images.map(\.layerIndex) + result.texts.map(\.layerIndex))
        for i in used where result.layers[i] == nil {
            result.layers[i] = Layer(name: String(format: "C%02d", i), colorHex: palette[i % palette.count], mode: .line)
        }
        return result
    }

    static func layer(from node: XMLNode, index: Int) -> Layer {
        let type = node.attributes["type"] ?? "Cut"
        let mode: LayerMode
        switch type {
        case "Image": mode = .image
        case "Scan", "Offset", "Scan+Cut": mode = .fill
        default: mode = .line
        }
        var layer = Layer(name: node.value("name") ?? String(format: "C%02d", index),
                          colorHex: palette[index % palette.count], mode: mode)
        // LightBurn stores speeds in mm per second.
        if let v = node.value("speed").flatMap(Double.init) { layer.speed = v * 60 }
        if let v = node.value("maxPower").flatMap(Double.init) { layer.power = v }
        if let v = node.value("minPower").flatMap(Double.init) { layer.powerMin = v }
        if let v = node.value("numPasses").flatMap(Int.init) { layer.passes = max(1, v) }
        if let v = node.value("interval").flatMap(Double.init), v > 0 { layer.fillInterval = v }
        if let v = node.value("angle").flatMap(Double.init) { layer.fillAngle = v }
        if let v = node.value("negative") { layer.invertImage = v == "1" }
        if let v = node.value("ditherMode") {
            switch v.lowercased() {
            case "threshold": layer.dither = .threshold
            case "grayscale": layer.dither = .grayscale
            case "atkinson": layer.dither = .atkinson
            default: layer.dither = .floydSteinberg
            }
        }
        if let v = node.value("hide") { layer.enabled = v != "1" }
        return layer
    }

    struct Vertex {
        var p: Vec2
        var c0: Vec2?
        var c1: Vec2?
    }

    enum Prim {
        case line(Int, Int)
        case bezier(Int, Int)
    }

    struct Context {
        var world: Affine
        var screenFlip: Affine
        var verts: [String: [Vertex]]
        var prims: [String: [Prim]]
    }

    static func xform(_ node: XMLNode) -> Affine {
        let n = (node.child("XForm")?.text ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .compactMap { Double($0) }
        guard n.count == 6 else { return .identity }
        return Affine(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
    }

    static func walk(_ node: XMLNode, parent: Affine, into result: inout ProjectImport, ctx: inout Context) {
        let type = node.attributes["Type"] ?? ""
        let cut = node.attributes["CutIndex"].flatMap(Int.init) ?? 0
        let local = xform(node).then(parent) // shape space → LightBurn world
        let toDesign = local.then(ctx.world)

        func add(_ polys: [Polyline]) {
            let placed = polys.map { $0.transformed(toDesign) }.filter { $0.points.count > 1 }
            if !placed.isEmpty { result.shapes.append(.init(layerIndex: cut, paths: placed)) }
        }

        switch type {
        case "Group":
            for child in node.child("Children")?.children ?? [] where child.name == "Shape" {
                walk(child, parent: local, into: &result, ctx: &ctx)
            }
        case "Rect":
            let w = node.double("W") ?? 0, h = node.double("H") ?? 0, r = node.double("Cr") ?? 0
            add([ShapeLibrary.roundedRect(Rect2(minX: -w / 2, minY: -h / 2, maxX: w / 2, maxY: h / 2), radius: r)])
        case "Ellipse":
            let rx = node.double("Rx") ?? 0, ry = node.double("Ry") ?? 0
            if rx > 0, ry > 0 { add([Flatten.ellipse(center: .zero, rx: rx, ry: ry, step: 0.1)]) }
        case "Path", "Polygon", "Polyline":
            let polys = paths(node, ctx: &ctx)
            if polys.isEmpty {
                result.warnings.append("A \(type.lowercased()) shape had no points Kerf could read.")
            } else {
                add(polys)
            }
        case "Text":
            // Newer files carry the laid-out outlines; use them so the result matches exactly.
            if let backup = node.child("BackupPath") {
                let polys = paths(backup, ctx: &ctx)
                if !polys.isEmpty {
                    add(polys.map { $0.transformed(xform(backup)) })
                    return
                }
            }
            let str = node.attributes["Str"] ?? ""
            guard !str.isEmpty else { return }
            let family = (node.attributes["Font"] ?? "Helvetica").split(separator: ",").first.map(String.init) ?? "Helvetica"
            let height = node.double("H") ?? 10
            // Outlines are y down with the baseline at 0; turn them to match LightBurn's text space.
            let flip = ctx.screenFlip
            result.texts.append(.init(layerIndex: cut, text: str, fontFamily: family, height: height,
                                      alignment: node.attributes["AH"].flatMap(Int.init) ?? 0,
                                      transform: flip.then(toDesign)))
        case "Bitmap":
            let w = node.double("W") ?? 0, h = node.double("H") ?? 0
            guard w > 0, h > 0, let b64 = node.attributes["Data"], let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                result.warnings.append("An image had no embedded picture data.")
                return
            }
            let name = (node.attributes["File"] ?? "Image").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "Image"
            // Image rows run top to bottom on screen.
            let flip = ctx.screenFlip
            result.images.append(.init(layerIndex: cut, name: name, data: data,
                                       frame: Rect2(minX: -w / 2, minY: -h / 2, maxX: w / 2, maxY: h / 2),
                                       transform: flip.then(toDesign)))
        default:
            if !type.isEmpty { result.warnings.append("Skipped a \(type) shape, which Kerf can't read yet.") }
        }
    }

    /// Polylines from a shape's VertList and PrimList (or ones shared from an earlier shape by id).
    static func paths(_ node: XMLNode, ctx: inout Context) -> [Polyline] {
        var vlist: [Vertex]?
        if let text = node.child("VertList")?.text, !text.isEmpty {
            vlist = parseVerts(text)
            if let id = node.attributes["VertID"] { ctx.verts[id] = vlist }
        } else if let id = node.attributes["VertID"] {
            vlist = ctx.verts[id]
        }
        guard let v = vlist, !v.isEmpty else { return [] }
        var plist: [Prim]?
        if let text = node.child("PrimList")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            plist = parsePrims(text, count: v.count)
            if let id = node.attributes["PrimID"] { ctx.prims[id] = plist }
        } else if let id = node.attributes["PrimID"] {
            plist = ctx.prims[id]
        }
        let primitives = plist ?? (0..<max(0, v.count - 1)).map { Prim.line($0, $0 + 1) }
        return chain(primitives, verts: v)
    }

    /// Parses "V1 2c0x3c0y4c1x5c1y6V..." into vertices with optional control points.
    static func parseVerts(_ s: String) -> [Vertex] {
        var out: [Vertex] = []
        for chunk in s.split(separator: "V") {
            var str = String(chunk)
            func take(_ key: String) -> Double? {
                guard let r = str.range(of: key) else { return nil }
                let rest = str[r.upperBound...]
                let num = rest.prefix { "0123456789.-+eE".contains($0) }
                str.removeSubrange(r.lowerBound..<rest.index(rest.startIndex, offsetBy: num.count))
                return Double(num)
            }
            let c0x = take("c0x"), c0y = take("c0y"), c1x = take("c1x"), c1y = take("c1y")
            let nums = str.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).compactMap { Double($0) }
            guard nums.count >= 2 else { continue }
            var vert = Vertex(p: Vec2(nums[0], nums[1]))
            if let x = c0x, let y = c0y { vert.c0 = Vec2(x, y) }
            if let x = c1x, let y = c1y { vert.c1 = Vec2(x, y) }
            out.append(vert)
        }
        return out
    }

    /// Parses "L0 1B1 2..." primitives. "LineClosed" means straight lines through every vertex, closed.
    static func parsePrims(_ s: String, count: Int) -> [Prim] {
        if s.hasPrefix("LineClosed") { return (0..<count).map { .line($0, ($0 + 1) % count) } }
        if s.hasPrefix("LineOpen") { return (0..<max(0, count - 1)).map { .line($0, $0 + 1) } }
        var out: [Prim] = []
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        while !scanner.isAtEnd {
            guard let kind = scanner.scanCharacter() else { break }
            guard let a = scanner.scanInt(), let b = scanner.scanInt() else { break }
            switch kind {
            case "B": out.append(.bezier(a, b))
            case "L": out.append(.line(a, b))
            default: break
            }
        }
        return out
    }

    /// Joins primitives end to end into polylines, closing those that return to their start.
    static func chain(_ prims: [Prim], verts: [Vertex]) -> [Polyline] {
        var out: [Polyline] = []
        var current: [Vec2] = []
        var startIndex = -1, lastIndex = -1
        func finish() {
            guard current.count > 1 else { current = []; return }
            let closed = startIndex == lastIndex
            if closed { current.removeLast() }
            out.append(Polyline(current, closed: closed && current.count > 2))
            current = []
        }
        for prim in prims {
            let (a, b): (Int, Int)
            switch prim {
            case .line(let x, let y), .bezier(let x, let y): (a, b) = (x, y)
            }
            guard a >= 0, b >= 0, a < verts.count, b < verts.count else { continue }
            if current.isEmpty || a != lastIndex {
                finish()
                current = [verts[a].p]
                startIndex = a
            }
            switch prim {
            case .line:
                current.append(verts[b].p)
            case .bezier:
                let p0 = verts[a].p, p3 = verts[b].p
                current += Flatten.cubic(p0, verts[a].c0 ?? p0, verts[b].c1 ?? p3, p3, step: 0.1)
            }
            lastIndex = b
        }
        finish()
        return out
    }
}

// MARK: - Easy Cut / Sure Cuts A Lot

/// Reads what can be read from Easy Cut Pro / Easy Sign Cut Pro / Sure Cuts A Lot (.esc5, .scut5)
/// projects: the mat size and the pictures embedded in the file. The cut paths in these files are
/// stored scrambled, so they are reported rather than imported.
public enum EasyCutImporter {
    public static func parse(_ data: Data) throws -> ProjectImport {
        // The file starts with a malformed "<xml ...>" line; parse from the real root element.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<sure_cuts_alot"), let end = text.range(of: "</sure_cuts_alot>", options: .backwards) else {
            throw ImportError.unreadable("not an Easy Cut project")
        }
        let body = String(text[start.lowerBound..<end.upperBound])
        let root = try XMLNode.parse(Data(body.utf8))
        var result = ProjectImport()

        if let mat = find(root, "scal5_data") {
            let wu = mat.double("mat_wu") ?? 0, hu = mat.double("mat_hu") ?? 0
            // Mat sizes are stored in thousandths of the mat's unit (inches here).
            let unit = (mat.attributes["mat_units"] ?? "in") == "in" ? 25.4 : 1.0
            var w = wu / 1000 * unit, h = hu / 1000 * unit
            if mat.attributes["mat_orientation"] == "vertical", w > h { swap(&w, &h) }
            if w > 0, h > 0 {
                let machine = mat.attributes["cut_machine"].map { "\($0) mat" } ?? "Cutting mat"
                result.workpiece = Workpiece(kind: .mat, name: String(format: "%@ %.1f × %.1f in", machine, w / 25.4, h / 25.4),
                                             width: w, height: h, thickness: 0.3)
            }
        }

        var images = 0, paths = 0
        visit(root) { node in
            if node.name == "pth" { paths += 1 }
            guard node.name == "image", let b64 = node.attributes["img_data"],
                  let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return }
            images += 1
            let px = node.double("img_w") ?? 1, py = node.double("img_h") ?? 1
            let dpi = max(1, node.double("img_dpix") ?? 300)
            var w = px / dpi * 25.4, h = py / dpi * 25.4
            // Turn the picture the way the project turns it (quarter turns only).
            var quarterTurns = 0
            if let t = node.child("transform"), let b = t.double("b"), let a = t.double("a"), abs(b) > abs(a) {
                quarterTurns = b < 0 ? 3 : 1
            }
            // Fit inside the mat, keeping proportions.
            let rotated = quarterTurns % 2 == 1
            if let mat = result.workpiece {
                let bw = rotated ? h : w, bh = rotated ? w : h
                let k = min(1, mat.width * 0.95 / bw, mat.height * 0.95 / bh)
                w *= k
                h *= k
            }
            let name = (node.attributes["img_src2"] ?? "Image").split(separator: "/").last.map(String.init) ?? "Image"
            var t = Affine.rotation(Double(quarterTurns) * .pi / 2)
            let mat = result.workpiece.map { Vec2($0.width / 2, $0.height / 2) } ?? Vec2(w / 2, h / 2)
            t = t.then(.translation(mat.x, mat.y))
            result.images.append(.init(layerIndex: 0, name: name, data: data,
                                       frame: Rect2(minX: -w / 2, minY: -h / 2, maxX: w / 2, maxY: h / 2), transform: t))
        }
        if paths > 0 {
            result.warnings.append("This file's \(paths) cut path\(paths == 1 ? " is" : "s are") stored in a scrambled form that Kerf can't read. Export the design from Easy Cut as SVG to bring the cut lines across.")
        }
        if images == 0 && paths == 0 { result.warnings.append("The file holds no pictures or shapes.") }
        return result
    }

    static func find(_ node: XMLNode, _ name: String) -> XMLNode? {
        if node.name == name { return node }
        for c in node.children { if let f = find(c, name) { return f } }
        return nil
    }

    static func visit(_ node: XMLNode, _ body: (XMLNode) -> Void) {
        body(node)
        for c in node.children { visit(c, body) }
    }
}
