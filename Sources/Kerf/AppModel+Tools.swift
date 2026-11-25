import AppKit
import CoreGraphics
import KerfCore
import UniformTypeIdentifiers

/// Image import, nesting, shape booleans, text on a path and print-and-cut.
extension AppModel {
    // MARK: - Images

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to engrave"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importImage(url) }
    }

    func importImage(_ url: URL) {
        guard let ns = NSImage(contentsOf: url), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            alertMessage = "\(url.lastPathComponent) could not be read as an image."
            return
        }
        // Size from the image's own resolution (points are 1/72 in), capped to the bed.
        var wmm = Double(ns.size.width) / 72 * 25.4
        var hmm = Double(ns.size.height) / 72 * 25.4
        let fit = min(1, profile.bedWidth * 0.9 / max(wmm, 1), profile.bedHeight * 0.9 / max(hmm, 1))
        wmm *= fit
        hmm *= fit
        guard let raster = Self.grayscale(cg, maxSide: 2000) else {
            alertMessage = "\(url.lastPathComponent) could not be converted to grayscale."
            return
        }
        checkpoint()
        let layerID = document.layer(forMode: .image, name: "Image", colorHex: "#4B5563")
        let frame = Polyline([Vec2(0, 0), Vec2(wmm, 0), Vec2(wmm, hmm), Vec2(0, hmm)], closed: true)
        let art = Artwork(layerID: layerID, name: url.deletingPathExtension().lastPathComponent, paths: [frame],
                          transform: .translation(10, 10), image: raster)
        document.shapes.append(art)
        selection = [art.id]
        currentLayerID = layerID
    }

    static func grayscale(_ image: CGImage, maxSide: Int) -> RasterImage? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 255, count: w * h)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Transparent areas become white.
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RasterImage(width: w, height: h, pixels: Data(bytes)) : nil
    }

    // MARK: - Nesting

    /// Packs the selection (or everything) onto the bed by bounding box.
    func nest() {
        let targets = selection.isEmpty ? document.shapes.map(\.id) : Array(selection)
        let shapes = document.shapes.filter { targets.contains($0.id) && document.layer($0.layerID)?.mode != .print }
        guard !shapes.isEmpty else { return }
        let sizes = shapes.map { Vec2($0.bounds.width, $0.bounds.height) }
        let area = Rect2(minX: 0, minY: 0, maxX: profile.bedWidth, maxY: profile.bedHeight).insetBy(nestSpacing)
        let placements = Nester.pack(sizes: sizes, in: area, spacing: nestSpacing, allowRotation: nestAllowRotation)
        checkpoint()
        var missed = 0
        for (shape, placement) in zip(shapes, placements) {
            guard let i = document.shapes.firstIndex(where: { $0.id == shape.id }) else { continue }
            guard let p = placement else {
                missed += 1
                continue
            }
            var t = document.shapes[i].transform
            if p.rotated {
                let c = document.shapes[i].bounds.center
                t = t.then(.translation(-c.x, -c.y)).then(.rotation(.pi / 2)).then(.translation(c.x, c.y))
            }
            document.shapes[i].transform = t
            let b = document.shapes[i].bounds
            document.shapes[i].transform = t.then(.translation(p.origin.x - b.minX, p.origin.y - b.minY))
        }
        if missed > 0 { alertMessage = "\(missed) shape(s) did not fit on the bed and were left where they were." }
    }

    // MARK: - Shape booleans

    enum BooleanOp: String, CaseIterable, Identifiable {
        case weld, subtract, intersect, exclude
        var id: String { rawValue }
        var title: String {
            switch self {
            case .weld: return "Weld"
            case .subtract: return "Subtract"
            case .intersect: return "Intersect"
            case .exclude: return "Exclude overlap"
            }
        }
    }

    static func cgPath(_ polys: [Polyline]) -> CGPath {
        let path = CGMutablePath()
        for p in polys where p.points.count > 1 {
            path.move(to: CGPoint(x: p.points[0].x, y: p.points[0].y))
            for q in p.points.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
            if p.closed { path.closeSubpath() }
        }
        return path
    }

    /// Combines the selected closed shapes. Subtract removes the later shapes from the earliest one.
    func combineSelection(_ op: BooleanOp) {
        let shapes = document.shapes.filter { selection.contains($0.id) && $0.image == nil }
        guard shapes.count >= 2 else {
            alertMessage = "Select two or more shapes to \(op.title.lowercased())."
            return
        }
        var result = Self.cgPath(shapes[0].placedPaths.filter(\.closed)).normalized(using: .evenOdd)
        for s in shapes.dropFirst() {
            let other = Self.cgPath(s.placedPaths.filter(\.closed)).normalized(using: .evenOdd)
            switch op {
            case .weld: result = result.union(other, using: .winding)
            case .subtract: result = result.subtracting(other, using: .winding)
            case .intersect: result = result.intersection(other, using: .winding)
            case .exclude: result = result.symmetricDifference(other, using: .winding)
            }
        }
        let polys = TextOutliner.flatten(result, offset: .zero, step: 0.1)
        checkpoint()
        document.shapes.removeAll { s in shapes.contains { $0.id == s.id } }
        guard !polys.isEmpty else {
            selection = []
            return
        }
        let combined = Artwork(layerID: shapes[0].layerID, name: op.title, paths: polys)
        document.shapes.append(combined)
        selection = [combined.id]
    }

    /// Joins open paths whose ends touch (within 0.1 mm) into continuous paths, closing loops.
    func joinSelectedPaths() {
        let shapes = document.shapes.filter { selection.contains($0.id) && $0.image == nil }
        guard !shapes.isEmpty else { return }
        let all = shapes.flatMap(\.placedPaths)
        let joined = PathJoiner.join(all, tolerance: 0.1)
        checkpoint()
        document.shapes.removeAll { s in shapes.contains { $0.id == s.id } }
        let art = Artwork(layerID: shapes[0].layerID, name: "Joined", paths: joined)
        document.shapes.append(art)
        selection = [art.id]
    }

    /// Splits each selected shape into one shape per outline.
    func breakApartSelection() {
        let shapes = document.shapes.filter { selection.contains($0.id) && $0.image == nil && $0.paths.count > 1 }
        guard !shapes.isEmpty else { return }
        checkpoint()
        var added: Set<UUID> = []
        for s in shapes {
            document.shapes.removeAll { $0.id == s.id }
            for p in s.placedPaths {
                let part = Artwork(layerID: s.layerID, name: s.name, paths: [p])
                document.shapes.append(part)
                added.insert(part.id)
            }
        }
        selection = added
    }

    // MARK: - Text on a path

    /// Lays the text tool's text along the outline of the selected shape.
    /// Adds editable text that follows the selected shape's outline. Drag its diamond handle on the
    /// canvas to slide it along the path.
    func addTextAlongSelection() {
        guard selection.count == 1, let base = selectedShapes.first,
              let outline = base.placedPaths.max(by: { $0.length < $1.length }), outline.points.count > 1 else {
            alertMessage = "Select one shape to put text around."
            return
        }
        let spec = TextSpec(text: textToAdd, fontName: fontName, height: textHeight)
        let width = TextOutliner.lineOutlines(for: spec).width
        var guide: [Vec2]
        if outline.closed {
            guide = PathText.outsideGuide(outline)
        } else {
            guide = outline.points
            // Read left to right.
            if let f = guide.first, let l = guide.last, l.x < f.x { guide.reverse() }
        }
        if pathTextFlip { guide.reverse() }
        var pathText = PathTextSpec(guide: guide, closed: outline.closed, gap: 1)
        let total = pathText.length
        // Centre the text at the top of a closed shape (at the bottom, reading upright, when inside),
        // or in the middle of an open path.
        if outline.closed {
            let centre = pathTextFlip ? total / 2 : total
            pathText.offset = (centre - width / 2).truncatingRemainder(dividingBy: total)
        } else {
            pathText.offset = max(0, (total - width) / 2)
        }
        let polys = TextOutliner.alongPath(spec, pathText: pathText)
        guard !polys.isEmpty else {
            alertMessage = "The text produced no outlines."
            return
        }
        checkpoint()
        var shape = Artwork(layerID: ensureCurrentLayer(), name: "Text on path: \(spec.text)", paths: polys, text: spec)
        shape.pathText = pathText
        document.shapes.append(shape)
        selection = [shape.id]
    }

    /// Changes where text sits on its path (or its gap or side) and rebuilds the letters.
    func updatePathText(_ id: UUID, to pathText: PathTextSpec, recordUndo: Bool = true) {
        guard let i = document.shapes.firstIndex(where: { $0.id == id }), let spec = document.shapes[i].text,
              document.shapes[i].pathText != nil else { return }
        let polys = TextOutliner.alongPath(spec, pathText: pathText)
        guard !polys.isEmpty else { return }
        if recordUndo { checkpoint() }
        document.shapes[i].pathText = pathText
        document.shapes[i].paths = polys
    }

    /// Moves path text to the other side of its path, keeping it in the same place.
    func flipPathText(_ id: UUID) {
        guard let shape = document.shapes.first(where: { $0.id == id }), var pt = shape.pathText, let spec = shape.text else { return }
        let width = TextOutliner.lineOutlines(for: spec).width
        let total = pt.length
        pt.guide.reverse()
        pt.offset = total - pt.offset - width
        if pt.closed { pt.offset = (pt.offset.truncatingRemainder(dividingBy: total) + total).truncatingRemainder(dividingBy: total) }
        updatePathText(id, to: pt)
    }

    // MARK: - Print and cut

    static let registrationSize = 5.0

    /// Adds three square registration marks around the selection (or all artwork) on a print-only layer.
    func addRegistrationMarks(margin: Double = 8) {
        let artwork = (selection.isEmpty ? document.shapes : selectedShapes).filter { document.layer($0.layerID)?.mode != .print }
        let b = artwork.reduce(Rect2.empty) { $0.union($1.bounds) }
        guard !b.isEmpty else {
            alertMessage = "Add artwork before adding registration marks."
            return
        }
        checkpoint()
        let layerID = document.layer(forMode: .print, name: "Registration", colorHex: "#000000")
        document.shapes.removeAll { $0.layerID == layerID && $0.name.hasPrefix("Mark ") }
        for (i, c) in Registration.markCenters(around: b, margin: margin, size: Self.registrationSize).enumerated() {
            document.shapes.append(Artwork(layerID: layerID, name: "Mark \(i + 1)", paths: [Registration.mark(at: c, size: Self.registrationSize)]))
        }
        measuredMark1 = nil
        measuredMark2 = nil
        useAlignment = false
    }

    /// Design-space centres of marks 1 and 2, if present.
    var registrationMarkCenters: [Vec2] {
        ["Mark 1", "Mark 2"].compactMap { name in
            document.shapes.first { $0.name == name && document.layer($0.layerID)?.mode == .print }?.bounds.center
        }
    }

    /// The machine-space correction from the measured mark positions, when enabled.
    var alignmentTransform: Affine {
        guard useAlignment, let m1 = measuredMark1, let m2 = measuredMark2 else { return .identity }
        let marks = registrationMarkCenters
        guard marks.count == 2 else { return .identity }
        return Registration.alignment(design: profile.toMachine(marks[0]), profile.toMachine(marks[1]), measured: m1, m2) ?? .identity
    }

    /// Exports a PDF at true size with images and print-only layers, for printing before cutting.
    func exportPrintPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "print") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pt = 72 / 25.4
        var box = CGRect(x: 0, y: 0, width: profile.bedWidth * pt, height: profile.bedHeight * pt)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            alertMessage = "Could not create the PDF."
            return
        }
        ctx.beginPDFPage(nil)
        // Design space is mm with y down.
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: pt, y: -pt)
        for shape in document.shapes {
            guard let layer = document.layer(shape.layerID), layer.mode == .print || shape.image != nil else { continue }
            if let img = shape.image, let cg = ImageCache.shared.cgImage(for: shape.id, image: img) {
                ctx.saveGState()
                let t = shape.transform
                ctx.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty))
                let f = shape.localFrame
                // Flip the image so it is upright in the y-down design space.
                ctx.translateBy(x: f.minX, y: f.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: f.width, height: f.height))
                ctx.restoreGState()
            } else {
                ctx.addPath(Self.cgPath(shape.placedPaths))
                let rgb = NSColor(hexString: layer.colorHex)
                ctx.setFillColor(rgb.cgColor)
                ctx.fillPath(using: .evenOdd)
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

extension NSColor {
    convenience init(hexString: String) {
        let v = UInt32(hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Caches CGImages for raster artwork so the canvas doesn't rebuild them every frame.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var cache: [UUID: (Int, CGImage)] = [:]

    func cgImage(for id: UUID, image: RasterImage) -> CGImage? {
        let key = image.pixels.count ^ image.width
        if let (k, cg) = cache[id], k == key { return cg }
        guard let provider = CGDataProvider(data: image.pixels as CFData),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        cache[id] = (key, cg)
        return cg
    }
}
