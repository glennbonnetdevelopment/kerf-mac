import AppKit
import KerfCore

extension AppModel {
    /// Adds a cut line that outlines the selected artwork (or all printed artwork) at `contourOffset` mm,
    /// for print and cut. Images count by their non-white pixels, so a sticker's shape is followed,
    /// not its rectangle. Holes inside the artwork are left out so the piece comes out whole.
    func addContourCut() {
        let pool = selection.isEmpty ? document.shapes : selectedShapes
        let contourLayer = document.layers.first { $0.name == Self.contourLayerName }?.id
        let artwork = pool.filter { $0.layerID != contourLayer && !$0.name.hasPrefix("Mark ") }
        let bounds = artwork.reduce(Rect2.empty) { $0.union($1.bounds) }
        guard !artwork.isEmpty, !bounds.isEmpty else {
            alertMessage = "Select the artwork to put a contour cut around."
            return
        }
        let offset = max(0, contourOffset)
        var mask = Contour.grid(for: bounds, margin: offset, maxCells: 1600, finest: 0.1)
        Self.rasterize(artwork, into: &mask)
        guard mask.cells.contains(true) else {
            alertMessage = "The selected artwork has nothing to outline (images that are all white are skipped)."
            return
        }
        let loops = Contour.outline(mask, offset: offset, smoothing: 2)
        guard !loops.isEmpty else {
            alertMessage = "Could not build a contour around the selection."
            return
        }
        checkpoint()
        let layerID: UUID
        if let existing = contourLayer {
            layerID = existing
        } else {
            var layer = Layer(name: Self.contourLayerName, colorHex: "#FF00FF", mode: defaultMode)
            layer.enabled = true
            document.layers.append(layer)
            layerID = layer.id
        }
        let shape = Artwork(layerID: layerID, name: "Contour cut", paths: loops)
        document.shapes.append(shape)
        selection = [shape.id]
    }

    static let contourLayerName = "Contour cut"

    /// Marks the cells of `mask` covered by the artwork: filled vector shapes (even-odd), stroked open
    /// paths, and the darker-than-white pixels of images.
    static func rasterize(_ artwork: [Artwork], into mask: inout Contour.Mask) {
        let w = mask.width, h = mask.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Map design mm (y down) onto the bitmap so memory row 0 is the grid's top row.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1 / mask.cell, y: -1 / mask.cell)
        ctx.translateBy(x: -mask.origin.x, y: -mask.origin.y)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(max(0.2, mask.cell * 1.5))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for shape in artwork where shape.image == nil {
            let placed = shape.placedPaths
            let closed = placed.filter { $0.closed && $0.points.count > 2 }
            let open = placed.filter { !$0.closed || $0.points.count <= 2 }
            if !closed.isEmpty {
                ctx.addPath(cgPath(closed))
                ctx.fillPath(using: .evenOdd)
            }
            if !open.isEmpty {
                ctx.addPath(cgPath(open))
                ctx.strokePath()
            }
        }
        guard let data = ctx.data else { return }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        for i in 0..<(w * h) where bytes[i] > 127 { mask.cells[i] = true }

        // Images: test each cell centre against the image's pixels.
        for shape in artwork {
            guard let img = shape.image else { continue }
            let frame = shape.localFrame
            guard frame.width > 0, frame.height > 0 else { continue }
            let inverse = shape.transform.inverted
            let b = shape.bounds
            let x0 = max(0, Int(((b.minX - mask.origin.x) / mask.cell).rounded(.down)))
            let x1 = min(w - 1, Int(((b.maxX - mask.origin.x) / mask.cell).rounded(.up)))
            let y0 = max(0, Int(((b.minY - mask.origin.y) / mask.cell).rounded(.down)))
            let y1 = min(h - 1, Int(((b.maxY - mask.origin.y) / mask.cell).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 where !mask.cells[y * w + x] {
                    let p = Vec2(mask.origin.x + (Double(x) + 0.5) * mask.cell, mask.origin.y + (Double(y) + 0.5) * mask.cell)
                    let local = inverse.apply(p)
                    let u = (local.x - frame.minX) / frame.width, v = (local.y - frame.minY) / frame.height
                    if let level = img.brightness(u: u, v: v), level < 0.92 { mask.cells[y * w + x] = true }
                }
            }
        }
    }
}
