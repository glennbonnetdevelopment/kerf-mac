import CoreGraphics
import CoreText
import Foundation

// MARK: - Options

/// The dot used to turn grey tones (photos, gradients) into solid black for a screen.
public enum HalftoneDotShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case round, square, line
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .round: return "Round dots"
        case .square: return "Square dots"
        case .line: return "Lines"
        }
    }
}

/// Settings for screen-print films and stencils, remembered between launches.
public struct ScreenPrintOptions: Codable, Hashable, Sendable {
    /// Layers left out of the films (every other enabled layer with artwork gets one).
    public var excludedLayers: Set<UUID> = []
    /// Remove a colour wherever a colour printed after it covers it, so inks don't pile up.
    public var knockout = true
    /// How far (mm) a colour still runs under the colour printed on top of it, so small misregistration
    /// doesn't leave a gap of bare shirt between them.
    public var trap = 0.25
    /// Add a white underbase film first: every colour together, choked so it hides under them.
    public var underbase = false
    /// How far (mm) the underbase is pulled in from the colours' edges.
    public var underbaseChoke = 0.25
    /// Print a negative: the artwork clear on a black frame (for blockout or a vinyl stencil mask).
    public var invert = false
    /// Black border around the artwork on a negative, mm.
    public var negativeMargin = 10.0
    /// Flip every film left to right, for printing on the back of the film (emulsion side up).
    public var mirror = false
    /// Put the same registration targets on every film so the screens line up.
    public var registrationMarks = true
    public var markSize = 10.0
    /// Gap between the artwork (or the negative's frame) and the marks, mm.
    public var markMargin = 8.0
    /// Print the colour name and film number under the artwork.
    public var labels = true
    /// Halftone lines per inch for images. 35 to 55 suits most inkjet films and 156 to 230 mesh.
    public var halftoneLPI = 45.0
    /// Halftone screen angle in degrees. 22.5° keeps the dots from lining up with the mesh threads.
    public var halftoneAngle = 22.5
    public var dotShape: HalftoneDotShape = .round
    /// The mesh count picked from the presets (threads per inch), which set `halftoneLPI`; nil when typed by hand.
    public var mesh: Int?
    /// Exposure test film: how many columns, the shortest exposure, and the time added per column (seconds).
    public var testSteps = 6
    public var testBaseSeconds = 60.0
    public var testStepSeconds = 30.0
    /// Paper the films print on, unless `fitToArtwork`.
    public var paper: PaperSize = .letter
    /// Make each film page just big enough for the artwork instead of a paper size.
    public var fitToArtwork = false
    public var landscape = false
    /// Blank border around a film sized to the artwork, mm.
    public var pageMargin = 10.0

    public init() {}

    /// Missing keys fall back to defaults so settings saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenPrintOptions()
        excludedLayers = try c.decodeIfPresent(Set<UUID>.self, forKey: .excludedLayers) ?? d.excludedLayers
        knockout = try c.decodeIfPresent(Bool.self, forKey: .knockout) ?? d.knockout
        trap = try c.decodeIfPresent(Double.self, forKey: .trap) ?? d.trap
        underbase = try c.decodeIfPresent(Bool.self, forKey: .underbase) ?? d.underbase
        underbaseChoke = try c.decodeIfPresent(Double.self, forKey: .underbaseChoke) ?? d.underbaseChoke
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? d.invert
        negativeMargin = try c.decodeIfPresent(Double.self, forKey: .negativeMargin) ?? d.negativeMargin
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? d.mirror
        registrationMarks = try c.decodeIfPresent(Bool.self, forKey: .registrationMarks) ?? d.registrationMarks
        markSize = try c.decodeIfPresent(Double.self, forKey: .markSize) ?? d.markSize
        markMargin = try c.decodeIfPresent(Double.self, forKey: .markMargin) ?? d.markMargin
        labels = try c.decodeIfPresent(Bool.self, forKey: .labels) ?? d.labels
        halftoneLPI = try c.decodeIfPresent(Double.self, forKey: .halftoneLPI) ?? d.halftoneLPI
        halftoneAngle = try c.decodeIfPresent(Double.self, forKey: .halftoneAngle) ?? d.halftoneAngle
        dotShape = try c.decodeIfPresent(HalftoneDotShape.self, forKey: .dotShape) ?? d.dotShape
        mesh = try c.decodeIfPresent(Int.self, forKey: .mesh)
        testSteps = try c.decodeIfPresent(Int.self, forKey: .testSteps) ?? d.testSteps
        testBaseSeconds = try c.decodeIfPresent(Double.self, forKey: .testBaseSeconds) ?? d.testBaseSeconds
        testStepSeconds = try c.decodeIfPresent(Double.self, forKey: .testStepSeconds) ?? d.testStepSeconds
        paper = try c.decodeIfPresent(PaperSize.self, forKey: .paper) ?? d.paper
        fitToArtwork = try c.decodeIfPresent(Bool.self, forKey: .fitToArtwork) ?? d.fitToArtwork
        landscape = try c.decodeIfPresent(Bool.self, forKey: .landscape) ?? d.landscape
        pageMargin = try c.decodeIfPresent(Double.self, forKey: .pageMargin) ?? d.pageMargin
    }

    private enum CodingKeys: String, CodingKey {
        case excludedLayers, knockout, trap, underbase, underbaseChoke, invert, negativeMargin, mirror,
             registrationMarks, markSize, markMargin, labels, halftoneLPI, halftoneAngle, dotShape, mesh, testSteps, testBaseSeconds, testStepSeconds, paper, fitToArtwork,
             landscape, pageMargin
    }

    private static let key = "screenPrint"

    public static func load(_ defaults: UserDefaults = .standard) -> ScreenPrintOptions {
        guard let data = defaults.data(forKey: key),
              let o = try? JSONDecoder().decode(ScreenPrintOptions.self, from: data) else { return ScreenPrintOptions() }
        return o
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - Films

/// One screen: everything that prints in one ink, as solid black areas in bed coordinates (mm, y down).
public struct Film: Identifiable {
    /// The layer's id, or `ScreenPrint.underbaseID`.
    public var id: UUID
    public var name: String
    /// The ink colour, "#RRGGBB".
    public var colorHex: String
    /// Vector artwork after spread or choke and knockout, filled with the non-zero rule.
    public var areas: CGPath
    /// Halftone dots for images on this layer.
    public var dots: CGPath
    public var isUnderbase: Bool

    public var isEmpty: Bool { areas.isEmpty && dots.isEmpty }
}

/// The films for a design: one per ink, all laid out on the same frame so they register.
public struct FilmSet {
    public var films: [Film]
    public var options: ScreenPrintOptions
    /// All the artwork together, mm.
    public var content: Rect2
    /// The black frame of a negative (the artwork plus its margin); the artwork itself for a positive.
    public var frame: Rect2
    /// Registration targets, the same on every film.
    public var marks: CGPath
    public var markCenters: [Vec2]
    /// Flips the artwork and marks for emulsion-side output (identity when off).
    public var mirror: Affine
    /// Everything that prints on a film: frame, marks and label.
    public var extent: Rect2

    public var isEmpty: Bool { films.allSatisfy(\.isEmpty) }

    /// The film's label, like "2 of 3 · Red #E5222D".
    public func label(for index: Int) -> String {
        let f = films[index]
        var s = "\(index + 1) of \(films.count) · \(f.name)"
        if !f.isUnderbase { s += " \(f.colorHex.uppercased())" }
        if options.invert { s += " · negative" }
        if options.mirror { s += " · mirrored" }
        return s
    }

    /// Page width and height in mm.
    public var pageSize: Vec2 {
        if !options.fitToArtwork {
            let s = options.paper.size
            return options.landscape ? Vec2(s.y, s.x) : s
        }
        let m = max(0, options.pageMargin)
        return Vec2(max(1, extent.width + m * 2), max(1, extent.height + m * 2))
    }

    /// Translation from bed coordinates to the page, the same for every film.
    public var pageOffset: Vec2 {
        guard !extent.isEmpty else { return .zero }
        if !options.fitToArtwork {
            return PrintLayout.offset(content: extent, page: pageSize, placement: .center, margin: options.pageMargin)
        }
        let m = max(0, options.pageMargin)
        return Vec2(m - extent.minX, m - extent.minY)
    }

    /// True when every film fits on its page.
    public var fitsPage: Bool {
        extent.isEmpty || PrintLayout.fits(content: extent, offset: pageOffset, page: pageSize, margin: 0)
    }
}

/// Screen-printing output: colour separations as black films (positives or negatives) with registration
/// marks, halftoned images, spread and choke, knockouts with trap, a white underbase and mirrored output.
public enum ScreenPrint {
    /// The id of the white underbase film.
    public static let underbaseID = UUID(uuidString: "00000000-0000-0000-0000-00000000B45E")!
    /// Line width of the registration targets, mm.
    static let markLine = 0.25
    /// Height of the label text, mm.
    static let labelHeight = 3.0
    /// Width given to open lines that have no stroke width of their own, mm.
    static let hairline = 0.5

    // MARK: Which layers

    /// Shapes that print on a screen: machine shapes on enabled, non-embroidery layers, without
    /// print-and-cut registration marks.
    static func printableShapes(_ doc: KerfDocument) -> [Artwork] {
        doc.machineShapes().filter { s in
            guard let l = doc.layer(s.layerID), l.enabled, l.output != .embroidery else { return false }
            return !(l.mode == .print && s.name.hasPrefix("Mark "))
        }
    }

    /// Layers that can become a film, in print order (the order of the Layers list, first printed first).
    public static func separationLayers(_ doc: KerfDocument) -> [Layer] {
        let used = Set(printableShapes(doc).map(\.layerID))
        return doc.layers.filter { used.contains($0.id) }
    }

    // MARK: Building films

    /// The films for `doc`. Colours printed later sit on top and knock out the ones before them.
    public static func films(for doc: KerfDocument, options o: ScreenPrintOptions) -> FilmSet {
        let shapes = printableShapes(doc)
        let layers = separationLayers(doc).filter { !o.excludedLayers.contains($0.id) }
        var areas: [CGPath] = []
        var dots: [CGPath] = []
        for layer in layers {
            let mine = shapes.filter { $0.layerID == layer.id }
            areas.append(spread(area(of: mine), by: layer.screenSpread))
            let d = CGMutablePath()
            for s in mine where s.image != nil {
                d.addPath(halftone(s, invert: layer.invertImage, lpi: o.halftoneLPI, angle: layer.screenAngle ?? o.halftoneAngle,
                                   shape: o.dotShape))
            }
            dots.append(d)
        }

        var films: [Film] = []
        if o.underbase, !layers.isEmpty {
            let all = areas.reduce(CGMutablePath() as CGPath) { $0.union($1, using: .winding) }
            let d = CGMutablePath()
            for p in dots { d.addPath(p) }
            films.append(Film(id: underbaseID, name: "White underbase", colorHex: "#FFFFFF",
                              areas: spread(all, by: -max(0, o.underbaseChoke)), dots: d, isUnderbase: true))
        }
        for (i, layer) in layers.enumerated() {
            var a = areas[i]
            if o.knockout, i + 1 < areas.count, !a.isEmpty {
                let above = areas[(i + 1)...].reduce(CGMutablePath() as CGPath) { $0.union($1, using: .winding) }
                if !above.isEmpty { a = a.subtracting(spread(above, by: -max(0, o.trap)), using: .winding) }
            }
            films.append(Film(id: layer.id, name: layer.name, colorHex: layer.colorHex, areas: a, dots: dots[i], isUnderbase: false))
        }

        var content = Rect2.empty
        for f in films {
            content = content.union(rect(f.areas.boundingBoxOfPath))
            content = content.union(rect(f.dots.boundingBoxOfPath))
        }
        let frame = o.invert && !content.isEmpty ? content.insetBy(-max(0, o.negativeMargin)) : content
        var extent = frame
        var centers: [Vec2] = []
        let marks = CGMutablePath()
        if o.registrationMarks, !frame.isEmpty {
            let size = max(1, o.markSize)
            centers = markCenters(around: frame, margin: max(0, o.markMargin), size: size)
            for c in centers {
                marks.addPath(target(at: c, size: size))
                extent.include(c - Vec2(size / 2, size / 2))
                extent.include(c + Vec2(size / 2, size / 2))
            }
        }
        let mirror = o.mirror && !frame.isEmpty ? OutputMirror.horizontal.transform(about: frame.center) : .identity
        var set = FilmSet(films: films, options: o, content: content, frame: frame, marks: marks, markCenters: centers,
                          mirror: mirror, extent: extent)
        if o.labels, !frame.isEmpty {
            // Room for the longest label (Helvetica averages about 0.6 of its size per character).
            let longest = films.indices.map { set.label(for: $0).count }.max() ?? 0
            let width = Double(longest) * labelHeight * 1.35 * 0.6
            set.extent.include(Vec2(frame.minX + width, set.registrationBottom + 2 + labelHeight * 1.4))
        }
        return set
    }

    /// `films`, remembering recent results so the preview can redraw quickly.
    public static func cachedFilms(for doc: KerfDocument, options: ScreenPrintOptions) -> FilmSet {
        var h = Hasher()
        h.combine(doc)
        h.combine(options)
        let key = h.finalize()
        if let hit = cache.get(key) { return hit }
        let set = films(for: doc, options: options)
        cache.set(key, set)
        return set
    }

    /// The filled area of shapes in bed coordinates, overlaps merged. Lines drawn as strokes (and open
    /// paths) become bands as wide as their stroke.
    public static func area(of shapes: [Artwork]) -> CGPath {
        var result: CGPath = CGMutablePath()
        for s in shapes where s.image == nil {
            let p = area(of: s)
            result = result.isEmpty ? p : result.union(p, using: .winding)
        }
        return result
    }

    static func area(of s: Artwork) -> CGPath {
        let placed = s.placedPaths
        if let w = s.strokeWidth, w > 0 {
            return OverlapFixer.filledPath(placed)
                .copy(strokingWithWidth: w * max(1e-6, s.transform.meanScale), lineCap: .round, lineJoin: .round, miterLimit: 4)
                .normalized(using: .winding)
        }
        let cleaned = OverlapFixer.resolve(s.paths, trustWinding: s.text != nil).paths.filter(\.closed)
        let placedClean = s.transform.isIdentity ? cleaned : cleaned.transformed(s.transform)
        var fill: CGPath = OverlapFixer.filledPath(OverlapFixer.orientedByNesting(placedClean)).normalized(using: .winding)
        let open = placed.filter { !$0.closed && $0.points.count > 1 }
        if !open.isEmpty {
            let band = OverlapFixer.filledPath(open).copy(strokingWithWidth: hairline, lineCap: .round, lineJoin: .round, miterLimit: 4)
            fill = fill.union(band, using: .winding)
        }
        return fill
    }

    /// Grows the area by `distance` mm (a spread), or shrinks it when negative (a choke). Exact, with
    /// sharp corners kept sharp.
    public static func spread(_ path: CGPath, by distance: Double) -> CGPath {
        guard abs(distance) > 1e-6, !path.isEmpty else { return path }
        let band = path.copy(strokingWithWidth: abs(distance) * 2, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
        return distance > 0 ? path.union(band, using: .winding) : path.subtracting(band, using: .winding)
    }

    /// Halftone dots for an image shape, in bed coordinates. Dark areas get big dots, light areas small
    /// ones, on a grid of `lpi` lines per inch turned by `angle` degrees.
    public static func halftone(_ art: Artwork, invert: Bool = false, lpi: Double, angle: Double,
                                shape: HalftoneDotShape) -> CGPath {
        let out = CGMutablePath()
        guard let img = art.image else { return out }
        let frame = art.localFrame
        let b = art.bounds
        guard frame.width > 0, frame.height > 0, !b.isEmpty else { return out }
        let cell = 25.4 / min(300, max(5, lpi))
        let theta = angle * .pi / 180
        let toBed = Affine.rotation(theta)
        let toGrid = Affine.rotation(-theta)
        var g = Rect2.empty
        for c in [Vec2(b.minX, b.minY), Vec2(b.maxX, b.minY), Vec2(b.minX, b.maxY), Vec2(b.maxX, b.maxY)] {
            g.include(toGrid.apply(c))
        }
        // Keep huge images at low line counts from making millions of dots.
        guard (g.width / cell) * (g.height / cell) < 4_000_000 else { return out }
        let toLocal = art.transform.inverted
        let i0 = Int((g.minX / cell).rounded(.down)), i1 = Int((g.maxX / cell).rounded(.up))
        let j0 = Int((g.minY / cell).rounded(.down)), j1 = Int((g.maxY / cell).rounded(.up))
        let ux = toBed.apply(Vec2(1, 0)), uy = toBed.apply(Vec2(0, 1))
        func quad(_ c: Vec2, _ hx: Double, _ hy: Double) {
            let ax = ux * hx, ay = uy * hy
            out.addLines(between: [c - ax - ay, c + ax - ay, c + ax + ay, c - ax + ay].map { CGPoint(x: $0.x, y: $0.y) })
            out.closeSubpath()
        }
        for j in j0...j1 {
            for i in i0...i1 {
                let center = toBed.apply(Vec2((Double(i) + 0.5) * cell, (Double(j) + 0.5) * cell))
                let l = toLocal.apply(center)
                guard let bright = img.brightness(u: (l.x - frame.minX) / frame.width, v: (l.y - frame.minY) / frame.height)
                else { continue }
                let ink = min(1, max(0, invert ? bright : 1 - bright))
                guard ink >= 0.02 else { continue }
                if ink >= 0.97 {
                    // Solid: a full cell, a touch oversized so neighbours join without hairline gaps.
                    quad(center, cell * 0.51, cell * 0.51)
                    continue
                }
                switch shape {
                case .round:
                    let r = cell * (ink / .pi).squareRoot()
                    out.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                case .square:
                    let h = cell * ink.squareRoot() / 2
                    quad(center, h, h)
                case .line:
                    quad(center, cell * 0.51, cell * ink / 2)
                }
            }
        }
        return out
    }

    /// Centres of four registration targets: above, below, left and right of `frame`, on its centre lines,
    /// so the corners stay free and a sideways film is easy to spot.
    public static func markCenters(around frame: Rect2, margin: Double, size: Double) -> [Vec2] {
        let d = margin + size / 2
        let c = frame.center
        return [Vec2(c.x, frame.minY - d), Vec2(frame.maxX + d, c.y), Vec2(c.x, frame.maxY + d), Vec2(frame.minX - d, c.y)]
    }

    /// A registration target (a ring with a cross through it) as a filled outline.
    public static func target(at c: Vec2, size: Double) -> CGPath {
        let h = size / 2, r = size * 0.32
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        p.move(to: CGPoint(x: c.x - h, y: c.y))
        p.addLine(to: CGPoint(x: c.x + h, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y - h))
        p.addLine(to: CGPoint(x: c.x, y: c.y + h))
        return p.copy(strokingWithWidth: markLine, lineCap: .butt, lineJoin: .miter, miterLimit: 4)
    }

    // MARK: Negatives and stencils

    /// A rectangle `margin` mm around the shapes with the shapes cut out of it, as cut lines:
    /// the outer frame plus every outline of the artwork. Weed the artwork and keep the frame for a stencil.
    public static func negative(of shapes: [Artwork], margin: Double) -> [Polyline] {
        negative(area: area(of: shapes), margin: margin)
    }

    public static func negative(area: CGPath, margin: Double) -> [Polyline] {
        guard !area.isEmpty else { return [] }
        let r = rect(area.boundingBoxOfPath).insetBy(-max(0.1, margin))
        let frame = CGPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height), transform: nil)
        return OverlapFixer.polylines(frame.subtracting(area, using: .winding), step: 0.1)
            .filter { $0.points.count > 2 && abs($0.signedArea) > 1e-4 }
    }

    /// The outlines of a film to cut as a vinyl stencil mask: its artwork, plus the frame on a negative.
    /// Halftone dots are left out; they are too small to weed.
    public static func cutLines(_ index: Int, of set: FilmSet) -> [Polyline] {
        let film = set.films[index]
        guard !film.areas.isEmpty else { return [] }
        let art = OverlapFixer.polylines(film.areas, step: 0.1).filter { $0.points.count > 2 && abs($0.signedArea) > 1e-4 }
        guard set.options.invert, !set.frame.isEmpty else { return art }
        let f = set.frame
        return [Polyline([Vec2(f.minX, f.minY), Vec2(f.maxX, f.minY), Vec2(f.maxX, f.maxY), Vec2(f.minX, f.maxY)], closed: true)] + art
    }

    // MARK: Drawing

    /// Draws one film into a context set up in bed coordinates (mm, y down): solid black artwork,
    /// or clear artwork on a black frame for a negative, with the marks and label.
    public static func draw(_ index: Int, of set: FilmSet, in ctx: CGContext) {
        let film = set.films[index]
        let black = CGColor(gray: 0, alpha: 1), white = CGColor(gray: 1, alpha: 1)
        ctx.saveGState()
        ctx.concatenate(cg(set.mirror))
        if set.options.invert, !set.frame.isEmpty {
            ctx.setFillColor(black)
            ctx.fill(cgRect(set.frame))
            fill(film, color: white, in: ctx)
        } else {
            fill(film, color: black, in: ctx)
        }
        if !set.marks.isEmpty {
            ctx.addPath(set.marks)
            ctx.setFillColor(black)
            ctx.fillPath(using: .winding)
        }
        ctx.restoreGState()
        if set.options.labels, !set.frame.isEmpty {
            let y = set.registrationBottom + 2 + labelHeight
            drawText(set.label(for: index), at: Vec2(set.frame.minX, y), height: labelHeight, in: ctx)
        }
    }

    /// Draws every film in its ink colour, in print order, the way the finished print looks.
    public static func drawComposite(_ set: FilmSet, in ctx: CGContext) {
        for film in set.films {
            fill(film, color: cgColor(hex: film.colorHex), in: ctx)
        }
    }

    static func fill(_ film: Film, color: CGColor, in ctx: CGContext) {
        ctx.setFillColor(color)
        if !film.areas.isEmpty {
            ctx.addPath(film.areas)
            ctx.fillPath(using: .winding)
        }
        if !film.dots.isEmpty {
            ctx.addPath(film.dots)
            ctx.fillPath(using: .winding)
        }
    }

    static func drawText(_ text: String, at p: Vec2, height: Double, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, height * 1.35, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Helpers

    static func rect(_ r: CGRect) -> Rect2 {
        guard !r.isNull, !r.isInfinite, r.width >= 0 else { return .empty }
        return Rect2(minX: Double(r.minX), minY: Double(r.minY), maxX: Double(r.maxX), maxY: Double(r.maxY))
    }

    static func cgRect(_ r: Rect2) -> CGRect { CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height) }

    static func cg(_ t: Affine) -> CGAffineTransform { CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty) }

    static func cgColor(hex: String) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return CGColor(srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                       blue: Double(v & 0xFF) / 255, alpha: 1)
    }

    final class Cache: @unchecked Sendable {
        private var store: [Int: FilmSet] = [:]
        private let lock = NSLock()

        func get(_ k: Int) -> FilmSet? {
            lock.lock(); defer { lock.unlock() }
            return store[k]
        }

        func set(_ k: Int, _ v: FilmSet) {
            lock.lock(); defer { lock.unlock() }
            if store.count > 8 { store.removeAll() }
            store[k] = v
        }
    }

    static let cache = Cache()
}

extension FilmSet {
    /// The lowest point of the frame and marks, where the label goes underneath.
    var registrationBottom: Double {
        guard options.registrationMarks, !markCenters.isEmpty else { return frame.maxY }
        return max(frame.maxY, markCenters.map(\.y).max()! + max(1, options.markSize) / 2)
    }
}
