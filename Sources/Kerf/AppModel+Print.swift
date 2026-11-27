import AppKit
import CoreGraphics
import KerfCore
import UniformTypeIdentifiers

/// One thing to print, ready to draw in design space (mm, y down).
struct PrintItem {
    var paths: [Polyline] = []
    var color: CGColor = .black
    var image: CGImage?
    var transform: Affine = .identity
    var frame: Rect2 = .empty
    var bounds: Rect2
}

/// Print preview, printing through the macOS print system, and GCC AAS optical registration.
extension AppModel {
    // MARK: - What prints

    /// Images and print-only layers (registration marks, print artwork), in drawing order.
    func printItems() -> [PrintItem] {
        var out: [PrintItem] = []
        for shape in document.machineShapes() {
            guard let layer = document.layer(shape.layerID), layer.mode == .print || shape.image != nil else { continue }
            if let img = shape.image {
                guard let cg = ImageCache.shared.cgImage(for: shape.id, image: img) else { continue }
                out.append(PrintItem(image: cg, transform: shape.transform, frame: shape.localFrame, bounds: shape.bounds))
            } else {
                out.append(PrintItem(paths: shape.placedPaths, color: NSColor(hexString: layer.colorHex).cgColor, bounds: shape.bounds))
            }
        }
        return out
    }

    /// The cut lines of the current job (design space), for showing on the preview.
    var printPreviewCuts: [[Vec2]] {
        toolpath.layers.filter { ![.fill, .image, .print].contains($0.layer.mode) }.flatMap(\.paths)
    }

    /// Draws print items (and optionally cut lines as hairlines) into a context set up in design space.
    nonisolated static func drawPrint(_ items: [PrintItem], cuts: [[Vec2]]?, cutLineWidth: Double = 0.15, in ctx: CGContext) {
        for item in items {
            if let cg = item.image {
                ctx.saveGState()
                let t = item.transform
                ctx.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty))
                let f = item.frame
                // Flip the image so it is upright in the y-down design space.
                ctx.translateBy(x: f.minX, y: f.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: f.width, height: f.height))
                ctx.restoreGState()
            } else {
                for p in item.paths where p.points.count > 1 {
                    ctx.move(to: CGPoint(x: p.points[0].x, y: p.points[0].y))
                    for q in p.points.dropFirst() { ctx.addLine(to: CGPoint(x: q.x, y: q.y)) }
                    if p.closed { ctx.closePath() }
                }
                ctx.setFillColor(item.color)
                ctx.fillPath(using: .evenOdd)
            }
        }
        if let cuts, !cuts.isEmpty {
            let path = CGMutablePath()
            for p in cuts where p.count > 1 {
                path.move(to: CGPoint(x: p[0].x, y: p[0].y))
                for q in p.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
            }
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1))
            ctx.setLineWidth(cutLineWidth)
            ctx.strokePath()
        }
    }

    /// Everything the printed page has to hold: print items, plus the cut lines so the layout matches the cut.
    func printContentBounds(items: [PrintItem]) -> Rect2 {
        var r = items.reduce(Rect2.empty) { $0.union($1.bounds) }
        for p in printPreviewCuts { for v in p { r.include(v) } }
        return r
    }

    /// The page offset for the current print settings.
    func printOffset(items: [PrintItem]) -> Vec2 {
        PrintLayout.offset(content: printContentBounds(items: items), page: printSettings.pageSize,
                           placement: printSettings.placement, margin: printSettings.margin)
    }

    // MARK: - Printing

    /// Prints the page as laid out in the preview, at 100% scale, through the macOS print dialog.
    func printSheet() {
        let items = printItems()
        guard !items.isEmpty else {
            alertMessage = "Nothing to print: add artwork or registration marks first."
            return
        }
        let s = printSettings
        let pt = 72 / 25.4
        let page = s.pageSize
        let offset = printOffset(items: items)
        let cuts = s.printCutLines ? printPreviewCuts : nil

        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = NSSize(width: s.paper.size.x * pt, height: s.paper.size.y * pt)
        info.orientation = s.landscape ? .landscape : .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
        info.jobDisposition = .spool

        let view = PrintPageView(frame: NSRect(x: 0, y: 0, width: page.x * pt, height: page.y * pt))
        view.drawPage = { ctx in
            ctx.scaleBy(x: pt, y: pt)
            ctx.translateBy(x: offset.x, y: offset.y)
            AppModel.drawPrint(items, cuts: cuts, in: ctx)
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = fileURL?.deletingPathExtension().lastPathComponent ?? "KerfKutter print"
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.insert(.showsPreview)
        op.printPanel.options.remove(.showsScaling)
        op.run()
    }

    /// Saves the page as laid out in the preview as a PDF at true size.
    func savePrintPagePDF() {
        let items = printItems()
        let page = printSettings.pageSize
        writePrintPDF(items: items, page: page, offset: printOffset(items: items),
                      cuts: printSettings.printCutLines ? printPreviewCuts : nil)
    }

    /// Exports a PDF the size of the bed, with images and print-only layers where they sit on the bed.
    func exportPrintPDF() {
        writePrintPDF(items: printItems(), page: Vec2(profile.bedWidth, profile.bedHeight), offset: .zero, cuts: nil)
    }

    private func writePrintPDF(items: [PrintItem], page: Vec2, offset: Vec2, cuts: [[Vec2]]?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "print") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pt = 72 / 25.4
        var box = CGRect(x: 0, y: 0, width: page.x * pt, height: page.y * pt)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            alertMessage = "Could not create the PDF."
            return
        }
        ctx.beginPDFPage(nil)
        // Design space is mm with y down.
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: pt, y: -pt)
        ctx.translateBy(x: offset.x, y: offset.y)
        Self.drawPrint(items, cuts: cuts, in: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: - GCC AAS II

    /// Adds four GCC AAS II L marks around `bounds`. Mark 1 is the origin mark, at the corner nearest the cutter's origin.
    func addAASMarks(around bounds: Rect2, layerID: UUID) {
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        let length = clamp(registrationMarkSize, GCCAAS.lengthRange)
        let thickness = clamp(registrationLineWidth, GCCAAS.thicknessRange)
        let margin = clamp(registrationMargin, GCCAAS.marginRange)
        let corners = GCCAAS.markCorners(around: bounds, margin: margin, thickness: thickness)
        let o = GCCAAS.originIndex(for: profile, corners: corners)
        let order = [o] + corners.indices.filter { $0 != o }
        for (n, i) in order.enumerated() {
            let c = corners[i]
            let corner = Vec2(c.x < bounds.center.x ? -1 : 1, c.y < bounds.center.y ? -1 : 1)
            let paths = GCCAAS.mark(length: length, thickness: thickness, corner: corner, isOrigin: n == 0)
            document.shapes.append(Artwork(layerID: layerID, name: "Mark \(n + 1)", paths: paths, transform: .translation(c.x, c.y)))
        }
        measuredMark1 = nil
        measuredMark2 = nil
        useAlignment = false
    }

    /// Registration points of every mark (Mark 1, Mark 2, …) on print-only layers, in mark order.
    var allRegistrationPoints: [Vec2] {
        document.shapes
            .filter { $0.name.hasPrefix("Mark ") && document.layer($0.layerID)?.mode == .print }
            .sorted { (Int($0.name.dropFirst(5)) ?? 0) < (Int($1.name.dropFirst(5)) ?? 0) }
            .map { $0.localFrame.insetBy(-1e-6).contains(.zero) ? $0.transform.apply(.zero) : $0.bounds.center }
    }

    /// The AAS job for the four marks on the sheet, when this cutter reads marks optically.
    var aasJob: GCCAAS.Job? {
        guard profile.kind == .vinylCutter, profile.aasEnabled, profile.language == .hpgl else { return nil }
        return GCCAAS.job(marks: allRegistrationPoints, profile: profile)
    }

    /// True when the next cut will ask the cutter to read the marks first.
    var aasActive: Bool { useAAS && aasJob != nil }

    /// Cutter commands that only read the marks, to check the sensor finds them.
    func aasScanOnlyText() -> String? {
        guard let job = aasJob else { return nil }
        return GCCAAS.scanOnly(job, units: profile.aasUnits, unitsPerMM: profile.unitsPerMM)
    }
}

/// A page-sized view that draws through a closure, for NSPrintOperation.
final class PrintPageView: NSView {
    var drawPage: ((CGContext) -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        ctx.saveGState()
        drawPage?(ctx)
        ctx.restoreGState()
    }
}
