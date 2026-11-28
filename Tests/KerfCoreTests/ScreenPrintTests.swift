import CoreGraphics
import XCTest
@testable import KerfCore

final class ScreenPrintTests: XCTestCase {
    private func square(_ x: Double, _ y: Double, _ size: Double) -> Polyline {
        Polyline([Vec2(x, y), Vec2(x + size, y), Vec2(x + size, y + size), Vec2(x, y + size)], closed: true)
    }

    /// Two layers: red square 0…20 printed first, blue square 10…30 on top.
    private func twoColours() -> (KerfDocument, Layer, Layer) {
        let red = Layer(name: "Red", colorHex: "#E5222D", mode: .print)
        let blue = Layer(name: "Blue", colorHex: "#0050FF", mode: .print)
        var doc = KerfDocument(layers: [red, blue])
        doc.shapes = [
            Artwork(layerID: red.id, name: "R", paths: [square(0, 0, 20)]),
            Artwork(layerID: blue.id, name: "B", paths: [square(10, 10, 20)]),
        ]
        return (doc, red, blue)
    }

    private func assertRect(_ a: Rect2, _ b: Rect2, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.maxX, b.maxX), (a.maxY, b.maxY)] {
            XCTAssertEqual(x, y, accuracy: 0.001, file: file, line: line)
        }
    }

    private func contains(_ p: CGPath, _ x: Double, _ y: Double) -> Bool {
        p.contains(CGPoint(x: x, y: y), using: .winding)
    }

    /// Renders a film to a grey bitmap at `ppm` pixels per mm; returns a lookup for bed coordinates.
    private func render(_ set: FilmSet, film: Int, ppm: Double = 4, area: Rect2? = nil) -> (Double, Double) -> UInt8 {
        // A film with nothing on it has no extent, so a test can name the area to draw.
        let e = area ?? set.extent.insetBy(-2)
        let w = Int((e.width * ppm).rounded(.up)), h = Int((e.height * ppm).rounded(.up))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: ppm, y: -ppm)
        ctx.translateBy(x: -e.minX, y: -e.minY)
        ScreenPrint.draw(film, of: set, in: ctx)
        // Copy the pixels out: the context's own buffer is freed when it goes away.
        let data = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h))
        return { x, y in
            let px = min(w - 1, max(0, Int((x - e.minX) * ppm))), py = min(h - 1, max(0, Int((y - e.minY) * ppm)))
            return data[py * w + px]
        }
    }

    func testOneFilmPerColourInLayerOrderWithoutRegistrationMarks() {
        var (doc, red, blue) = twoColours()
        let reg = Layer(name: "Registration", colorHex: "#000000", mode: .print)
        let off = Layer(name: "Off", colorHex: "#16A34A", mode: .print, enabled: false)
        var sewn = Layer(name: "Sewn", colorHex: "#9333EA", mode: .line)
        sewn.output = .embroidery
        let empty = Layer(name: "Empty", colorHex: "#F59E0B")
        doc.layers += [reg, off, sewn, empty]
        doc.shapes.append(Artwork(layerID: reg.id, name: "Mark 1", paths: [square(-20, -20, 5)]))
        doc.shapes.append(Artwork(layerID: off.id, name: "O", paths: [square(0, 0, 5)]))
        doc.shapes.append(Artwork(layerID: sewn.id, name: "S", paths: [square(0, 0, 5)]))
        XCTAssertEqual(ScreenPrint.separationLayers(doc).map(\.id), [red.id, blue.id])

        var o = ScreenPrintOptions()
        o.excludedLayers = [blue.id]
        XCTAssertEqual(ScreenPrint.films(for: doc, options: o).films.map(\.name), ["Red"])
    }

    func testKnockoutWithTrap() {
        let (doc, _, _) = twoColours()
        var o = ScreenPrintOptions()
        o.trap = 0
        var films = ScreenPrint.films(for: doc, options: o).films
        XCTAssertTrue(contains(films[0].areas, 5, 5))
        XCTAssertFalse(contains(films[0].areas, 15, 15), "red is knocked out under blue")
        XCTAssertTrue(contains(films[1].areas, 15, 15), "the top colour is untouched")

        o.trap = 1
        films = ScreenPrint.films(for: doc, options: o).films
        XCTAssertTrue(contains(films[0].areas, 10.5, 15), "red runs 1 mm under blue's edge")
        XCTAssertFalse(contains(films[0].areas, 12, 15))

        o.knockout = false
        films = ScreenPrint.films(for: doc, options: o).films
        XCTAssertTrue(contains(films[0].areas, 15, 15))
    }

    func testSpreadAndChokeKeepSharpCorners() {
        let a = ScreenPrint.area(of: [Artwork(layerID: UUID(), name: "s", paths: [square(0, 0, 10)])])
        let grown = ScreenPrint.spread(a, by: 1).boundingBoxOfPath
        XCTAssertEqual(grown.width, 12, accuracy: 0.01)
        XCTAssertTrue(contains(ScreenPrint.spread(a, by: 1), -0.9, -0.9), "mitred corner stays square")
        let shrunk = ScreenPrint.spread(a, by: -1)
        XCTAssertEqual(shrunk.boundingBoxOfPath.width, 8, accuracy: 0.01)
        XCTAssertFalse(contains(shrunk, 0.5, 5))
        XCTAssertTrue(contains(shrunk, 1.2, 1.2))
    }

    func testLayerSpreadIsUsedOnItsFilm() {
        var (doc, red, _) = twoColours()
        doc.layers[0].screenSpread = -2
        var o = ScreenPrintOptions()
        o.knockout = false
        let film = ScreenPrint.films(for: doc, options: o).films.first { $0.id == red.id }!
        XCTAssertEqual(film.areas.boundingBoxOfPath.width, 16, accuracy: 0.01)
    }

    func testUnderbaseComesFirstAndIsChoked() {
        let (doc, _, _) = twoColours()
        var o = ScreenPrintOptions()
        o.underbase = true
        o.underbaseChoke = 0.5
        let films = ScreenPrint.films(for: doc, options: o).films
        XCTAssertEqual(films.count, 3)
        XCTAssertTrue(films[0].isUnderbase)
        let b = films[0].areas.boundingBoxOfPath
        XCTAssertEqual(b.minX, 0.5, accuracy: 0.01)
        XCTAssertEqual(b.maxX, 29.5, accuracy: 0.01)
        XCTAssertTrue(contains(films[0].areas, 15, 15))
    }

    func testFilmsShareRegistrationMarksAndFrame() {
        let (doc, _, _) = twoColours()
        var o = ScreenPrintOptions()
        o.markMargin = 5
        o.markSize = 10
        let set = ScreenPrint.films(for: doc, options: o)
        assertRect(set.content, Rect2(minX: 0, minY: 0, maxX: 30, maxY: 30))
        let expected = [Vec2(15, -10), Vec2(40, 15), Vec2(15, 40), Vec2(-10, 15)]
        XCTAssertEqual(set.markCenters.count, 4)
        for (m, e) in zip(set.markCenters, expected) { XCTAssertLessThan(m.distance(to: e), 0.001) }
        XCTAssertTrue(set.extent.insetBy(-0.01).contains(Vec2(-15, -15)))
        // Every film draws its marks in the same place.
        for i in set.films.indices {
            let px = render(set, film: i, ppm: 20)
            XCTAssertLessThan(px(15, -10), 128, "mark centre is black on film \(i)")
        }
    }

    func testPositiveIsBlackAndNegativeIsInverted() {
        let (doc, _, _) = twoColours()
        var o = ScreenPrintOptions()
        o.registrationMarks = false
        o.labels = false
        var set = ScreenPrint.films(for: doc, options: o)
        var px = render(set, film: 1)
        XCTAssertEqual(px(20, 20), 0, "blue prints solid black")
        XCTAssertEqual(px(5, 5), 255)

        o.invert = true
        o.negativeMargin = 5
        set = ScreenPrint.films(for: doc, options: o)
        assertRect(set.frame, Rect2(minX: -5, minY: -5, maxX: 35, maxY: 35))
        px = render(set, film: 1)
        XCTAssertEqual(px(20, 20), 255, "artwork is clear on a negative")
        XCTAssertEqual(px(5, 5), 0, "the frame is black")
        XCTAssertEqual(px(-3, 20), 0)
        XCTAssertEqual(px(-8, 20), 255, "outside the frame stays clear")
    }

    func testMirrorFlipsAboutTheFrame() {
        let red = Layer(name: "Red", colorHex: "#E5222D", mode: .print)
        var doc = KerfDocument(layers: [red])
        doc.shapes = [Artwork(layerID: red.id, name: "L", paths: [square(0, 0, 10), square(30, 0, 2)])]
        var o = ScreenPrintOptions()
        o.registrationMarks = false
        o.labels = false
        o.mirror = true
        let px = render(ScreenPrint.films(for: doc, options: o), film: 0)
        XCTAssertEqual(px(27, 5), 0, "the big square moves to the right")
        XCTAssertEqual(px(5, 5), 255)
        XCTAssertEqual(px(1, 1), 0, "the small square moves to the left")
    }

    func testHalftoneCoverageFollowsGrey() {
        for (grey, expected) in [(UInt8(128), 0.5), (UInt8(64), 0.75), (UInt8(255), 0.0)] {
            let layer = Layer(name: "Photo", colorHex: "#000000", mode: .image)
            var doc = KerfDocument(layers: [layer])
            let img = RasterImage(width: 4, height: 4, pixels: Data(repeating: grey, count: 16))
            doc.shapes = [Artwork(layerID: layer.id, name: "img", paths: [square(0, 0, 40)], image: img)]
            for shape in HalftoneDotShape.allCases {
                var o = ScreenPrintOptions()
                o.registrationMarks = false
                o.labels = false
                o.dotShape = shape
                o.halftoneLPI = 30
                let set = ScreenPrint.films(for: doc, options: o)
                let px = render(set, film: 0, ppm: 20, area: Rect2(minX: -2, minY: -2, maxX: 42, maxY: 42))
                var black = 0, total = 0
                var y = 5.0
                while y < 35 {
                    var x = 5.0
                    while x < 35 {
                        if px(x, y) < 128 { black += 1 }
                        total += 1
                        x += 0.05
                    }
                    y += 0.05
                }
                XCTAssertEqual(Double(black) / Double(total), expected, accuracy: 0.06, "\(shape) at grey \(grey)")
            }
        }
    }

    func testHalftoneStaysInsideTheImage() {
        let layer = Layer(name: "Photo", colorHex: "#000000", mode: .image)
        let img = RasterImage(width: 2, height: 2, pixels: Data(repeating: 0, count: 4))
        let art = Artwork(layerID: layer.id, name: "img", paths: [square(0, 0, 20)],
                          transform: .translation(50, 50), image: img)
        let b = ScreenPrint.halftone(art, lpi: 40, angle: 22.5, shape: .round).boundingBoxOfPath
        XCTAssertGreaterThan(b.minX, 49)
        XCTAssertLessThan(b.maxX, 71)
    }

    func testNegativeOfShapesIsFrameWithHoles() {
        let s = Artwork(layerID: UUID(), name: "s", paths: [square(0, 0, 10)])
        let paths = ScreenPrint.negative(of: [s], margin: 5)
        XCTAssertEqual(paths.count, 2)
        assertRect(paths.bounds, Rect2(minX: -5, minY: -5, maxX: 15, maxY: 15))
        let filled = OverlapFixer.filledPath(paths)
        XCTAssertFalse(filled.contains(CGPoint(x: 5, y: 5), using: .evenOdd))
        XCTAssertTrue(filled.contains(CGPoint(x: -2, y: 5), using: .evenOdd))
    }

    func testStencilCutLinesIncludeFrameOnNegative() {
        let (doc, _, _) = twoColours()
        var o = ScreenPrintOptions()
        o.trap = 0
        var set = ScreenPrint.films(for: doc, options: o)
        // Red with blue knocked out is one L-shaped outline.
        XCTAssertEqual(ScreenPrint.cutLines(0, of: set).count, 1)
        o.invert = true
        set = ScreenPrint.films(for: doc, options: o)
        XCTAssertEqual(ScreenPrint.cutLines(0, of: set).count, 2)
        assertRect(ScreenPrint.cutLines(0, of: set)[0].bounds, set.frame)
    }

    func testLabelsAndPageLayout() {
        let (doc, _, _) = twoColours()
        var o = ScreenPrintOptions()
        o.invert = true
        o.mirror = true
        o.fitToArtwork = true
        o.pageMargin = 10
        let set = ScreenPrint.films(for: doc, options: o)
        XCTAssertEqual(set.label(for: 1), "2 of 2 · Blue #0050FF · negative · mirrored")
        XCTAssertEqual(set.pageSize.x, set.extent.width + 20, accuracy: 1e-9)
        XCTAssertTrue(set.fitsPage)
        o.fitToArtwork = false
        XCTAssertTrue(ScreenPrint.films(for: doc, options: o).fitsPage)
    }

    func testOptionsAndLayerDecodeOldData() throws {
        let o = try JSONDecoder().decode(ScreenPrintOptions.self, from: Data(#"{"trap":0.5}"#.utf8))
        XCTAssertEqual(o.trap, 0.5)
        XCTAssertTrue(o.knockout)
        XCTAssertEqual(o.paper, .letter)
        XCTAssertFalse(o.fitToArtwork)
        let layer = try JSONDecoder().decode(Layer.self, from: Data(##"{"name":"A","colorHex":"#000000"}"##.utf8))
        XCTAssertEqual(layer.screenSpread, 0)
        var l2 = layer
        l2.screenSpread = -0.3
        let back = try JSONDecoder().decode(Layer.self, from: JSONEncoder().encode(l2))
        XCTAssertEqual(back.screenSpread, -0.3)
    }
}
