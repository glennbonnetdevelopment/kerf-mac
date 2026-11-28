import AppKit
import CoreGraphics
import KerfCore
import UniformTypeIdentifiers

/// Screen printing: films for each colour (positives or negatives, all black), printing or saving them,
/// stencil masks for the vinyl cutter, and inverting shapes to a negative.
extension AppModel {
    /// The films for the design with the current settings.
    var screenPrintFilms: FilmSet { ScreenPrint.cachedFilms(for: document, options: screenPrint) }

    /// Layers that can become films, in print order.
    var screenPrintLayers: [Layer] { ScreenPrint.separationLayers(document) }

    /// Turns a layer's film on or off.
    func setScreenPrintLayer(_ id: UUID, included: Bool) {
        if included { screenPrint.excludedLayers.remove(id) } else { screenPrint.excludedLayers.insert(id) }
    }

    /// Sets a layer's spread (positive) or choke (negative) in mm, undoably.
    func setScreenSpread(_ id: UUID, _ mm: Double) {
        guard let i = document.layers.firstIndex(where: { $0.id == id }), document.layers[i].screenSpread != mm else { return }
        checkpoint()
        document.layers[i].screenSpread = mm
    }

    // MARK: - Output

    private var filmJobName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Screen print" }

    /// Saves every film as one page of a PDF, at true size.
    func saveFilmsPDF() {
        let set = screenPrintFilms
        guard !set.isEmpty else {
            alertMessage = "Nothing to put on film: add artwork on an enabled layer first."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filmJobName + " films.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let pt = 72 / 25.4
        let page = set.pageSize
        var box = CGRect(x: 0, y: 0, width: page.x * pt, height: page.y * pt)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            alertMessage = "Could not create the PDF."
            return
        }
        let offset = set.pageOffset
        for i in set.films.indices {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: pt, y: -pt)
            ctx.translateBy(x: offset.x, y: offset.y)
            ScreenPrint.draw(i, of: set, in: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Prints every film, one per page, at 100% through the macOS print dialog.
    func printFilms() {
        let set = screenPrintFilms
        guard !set.isEmpty else {
            alertMessage = "Nothing to put on film: add artwork on an enabled layer first."
            return
        }
        let pt = 72 / 25.4
        let page = set.pageSize
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let portrait = Vec2(min(page.x, page.y), max(page.x, page.y))
        info.paperSize = NSSize(width: portrait.x * pt, height: portrait.y * pt)
        info.orientation = page.x > page.y ? .landscape : .portrait
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

        let view = FilmPagesView(set: set, pageSize: NSSize(width: page.x * pt, height: page.y * pt))
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = filmJobName + " films"
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.insert(.showsPreview)
        op.printPanel.options.remove(.showsScaling)
        op.run()
    }

    /// Adds each film's outlines to the design as its own Cut layer, for cutting vinyl stencil masks.
    /// The new layers start turned off so you can cut them one at a time.
    func addStencilMaskLayers() {
        let set = screenPrintFilms
        let indices = set.films.indices.filter { !ScreenPrint.cutLines($0, of: set).isEmpty }
        guard !indices.isEmpty else {
            alertMessage = "No artwork to cut: images become halftone dots, which are too small to weed."
            return
        }
        checkpoint()
        let mode: LayerMode = profile.kind == .vinylCutter ? .cut : defaultMode
        for i in indices {
            let film = set.films[i]
            let name = "Stencil \(i + 1) – \(film.name)"
            // Replace masks made earlier for the same film.
            if let old = document.layers.first(where: { $0.name == name }) {
                document.shapes.removeAll { $0.layerID == old.id }
                document.layers.removeAll { $0.id == old.id }
            }
            var layer = Layer(name: name, colorHex: film.isUnderbase ? "#9CA3AF" : film.colorHex, mode: mode)
            layer.enabled = false
            document.layers.append(layer)
            document.shapes.append(Artwork(layerID: layer.id, name: name, paths: ScreenPrint.cutLines(i, of: set)))
        }
        alertMessage = "Added \(indices.count) stencil layer\(indices.count == 1 ? "" : "s"), turned off. "
            + "To cut one, turn it on and turn the other layers off. Knockouts, trap and choke are already in the outlines."
    }

    // MARK: - Invert

    /// Replaces the selected shapes with a negative: a frame around them with the shapes cut out.
    func invertSelectionToNegative() {
        let shapes = selectedShapes.filter { $0.image == nil }
        guard !shapes.isEmpty else {
            alertMessage = "Select the shapes to invert. Images can be inverted in their layer's settings."
            return
        }
        let paths = ScreenPrint.negative(of: shapes, margin: max(0.1, negativeMargin))
        guard !paths.isEmpty else {
            alertMessage = "The selected shapes have no filled area to invert."
            return
        }
        checkpoint()
        document.shapes.removeAll { s in shapes.contains { $0.id == s.id } }
        let negative = Artwork(layerID: shapes[0].layerID, name: "Negative", paths: paths)
        document.shapes.append(negative)
        selection = [negative.id]
    }

    /// Inverts every shape on a layer into one negative.
    func invertLayerToNegative(_ id: UUID) {
        selection = Set(document.shapes.filter { $0.layerID == id && $0.image == nil }.map(\.id))
        invertSelectionToNegative()
    }
}

/// All the films stacked one per page, for NSPrintOperation.
final class FilmPagesView: NSView {
    let set: FilmSet
    let pageSize: NSSize

    init(set: FilmSet, pageSize: NSSize) {
        self.set = set
        self.pageSize = pageSize
        super.init(frame: NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height * CGFloat(max(1, set.films.count))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, set.films.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: pageSize.height * CGFloat(page - 1), width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        dirtyRect.fill()
        let pt = 72 / 25.4
        let offset = set.pageOffset
        for i in set.films.indices {
            let r = rectForPage(i + 1)
            guard r.intersects(dirtyRect) else { continue }
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.translateBy(x: r.minX, y: r.minY)
            ctx.scaleBy(x: pt, y: pt)
            ctx.translateBy(x: offset.x, y: offset.y)
            ScreenPrint.draw(i, of: set, in: ctx)
            ctx.restoreGState()
        }
    }
}
