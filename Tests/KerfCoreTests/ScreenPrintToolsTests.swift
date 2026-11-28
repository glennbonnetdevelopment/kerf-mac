import CoreGraphics
import XCTest
@testable import KerfCore

final class ScreenPrintToolsTests: XCTestCase {
    /// A picture: left half red, right half blue, bottom row white, last pixel clear.
    private func picture() -> ColorImage {
        let w = 20, h = 10
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let c: [UInt8] = y == h - 1 ? [255, 255, 255] : (x < w / 2 ? [220, 20, 30] : [20, 40, 200])
                px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255
            }
        }
        px[(w * h - 1) * 4 + 3] = 0
        return ColorImage(width: w, height: h, rgba: px)
    }

    func testPaletteFindsTheInksAndLeavesTheGarment() {
        let inks = PhotoSeparation.palette(picture(), count: 2, garment: InkColor(1, 1, 1))
        XCTAssertEqual(inks.count, 2)
        let red = InkColor(hex: "#DC141E"), blue = InkColor(hex: "#1428C8")
        XCTAssertTrue(inks.contains { $0.distance2(red) < 0.01 }, "\(inks.map(\.hex))")
        XCTAssertTrue(inks.contains { $0.distance2(blue) < 0.01 }, "\(inks.map(\.hex))")
        XCTAssertGreaterThanOrEqual(inks[0].luminance, inks[1].luminance, "lightest first")
        // Without a garment, white needs an ink of its own.
        let three = PhotoSeparation.palette(picture(), count: 3)
        XCTAssertTrue(three.contains { $0.distance2(InkColor(1, 1, 1)) < 0.01 })
    }

    func testHardSeparationGivesEachPixelOneInk() {
        let img = picture()
        let inks = [InkColor(hex: "#DC141E"), InkColor(hex: "#1428C8")]
        let planes = PhotoSeparation.separate(img, inks: inks, garment: InkColor(1, 1, 1), smoothing: 0)
        XCTAssertEqual(planes.count, 2)
        func at(_ p: RasterImage, _ x: Int, _ y: Int) -> UInt8 { p.pixels[y * p.width + x] }
        XCTAssertEqual(at(planes[0], 2, 2), 0, "red prints on the left")
        XCTAssertEqual(at(planes[0], 15, 2), 255)
        XCTAssertEqual(at(planes[1], 15, 2), 0, "blue prints on the right")
        XCTAssertEqual(at(planes[0], 2, 9), 255, "white garment gets no ink")
        XCTAssertEqual(at(planes[1], 2, 9), 255)
        XCTAssertEqual(at(planes[0], 19, 9), 255, "clear pixels print nothing")
    }

    func testSmoothSeparationBlendsInBetweenColours() {
        let purple = ColorImage(width: 1, height: 1, rgba: [120, 30, 115, 255])
        let inks = [InkColor(hex: "#DC141E"), InkColor(hex: "#1428C8")]
        let soft = PhotoSeparation.separate(purple, inks: inks, smoothing: 1)
        let a = 255 - Int(soft[0].pixels[0]), b = 255 - Int(soft[1].pixels[0])
        XCTAssertGreaterThan(a, 60)
        XCTAssertGreaterThan(b, 60)
        XCTAssertEqual(a + b, 255, accuracy: 2, "the shares add up to full ink")
        let preview = PhotoSeparation.preview(purple, inks: inks, garment: nil, smoothing: 1)
        XCTAssertEqual(preview.count, 4)
        XCTAssertGreaterThan(preview[0], 60)
        XCTAssertGreaterThan(preview[2], 60)
    }

    func testInkColorHexRoundTrip() {
        XCTAssertEqual(InkColor(hex: "#1A2B3C").hex, "#1A2B3C")
        XCTAssertEqual(InkColor(hex: "ff0000").hex, "#FF0000")
    }

    func testMeshPresets() {
        XCTAssertEqual(MeshPreset.preset(230)?.lpi, 55)
        XCTAssertNil(MeshPreset.preset(999))
        XCTAssertEqual(MeshPreset.recommendedLPI(mesh: 180), 40)
        let lpis = MeshPreset.all.map(\.lpi)
        XCTAssertEqual(lpis, lpis.sorted(), "finer mesh holds more lines")
    }

    func testLayerHalftoneAngleOverridesTheFilms() throws {
        let layer = Layer(name: "Photo", colorHex: "#000000", mode: .image)
        var doc = KerfDocument(layers: [layer])
        let img = RasterImage(width: 1, height: 1, pixels: Data([128]))
        let square = Polyline([Vec2(0, 0), Vec2(20, 0), Vec2(20, 20), Vec2(0, 20)], closed: true)
        doc.shapes = [Artwork(layerID: layer.id, name: "img", paths: [square], image: img)]
        var o = ScreenPrintOptions()
        o.halftoneAngle = 0
        let flat = ScreenPrint.films(for: doc, options: o).films[0].dots
        doc.layers[0].screenAngle = 45
        let turned = ScreenPrint.films(for: doc, options: o).films[0].dots
        XCTAssertNotEqual(flat.boundingBoxOfPath, turned.boundingBoxOfPath)
        let a = ScreenPrint.halftone(doc.shapes[0], lpi: o.halftoneLPI, angle: 45, shape: o.dotShape).boundingBoxOfPath
        XCTAssertEqual(turned.boundingBoxOfPath, a)

        let back = try JSONDecoder().decode(Layer.self, from: JSONEncoder().encode(doc.layers[0]))
        XCTAssertEqual(back.screenAngle, 45)
    }

    func testExposureTestTimesAndFilm() {
        XCTAssertEqual(ExposureTest.times(steps: 4, base: 60, step: 30), [60, 90, 120, 150])
        XCTAssertEqual(ExposureTest.clock(90), "1:30")
        XCTAssertEqual(ExposureTest.clock(5), "0:05")
        var o = ScreenPrintOptions()
        o.testSteps = 5
        let set = ExposureTest.films(options: o)
        XCTAssertEqual(set.films.count, 1)
        XCTAssertFalse(set.films[0].areas.isEmpty)
        XCTAssertFalse(set.films[0].dots.isEmpty, "halftone patches")
        XCTAssertTrue(set.marks.isEmpty)
        XCTAssertGreaterThanOrEqual(set.content.width, 5 * 30 + 4 * 3 - 0.01)
        XCTAssertTrue(set.fitsPage, "five columns fit on letter paper")
        // Column headers are black with the time knocked out.
        XCTAssertTrue(set.films[0].areas.contains(CGPoint(x: 2 * 33 + 29, y: 1), using: .winding))
    }

    func testTextBecomesOutlines() {
        let p = ExposureTest.text("Hi", height: 4, at: Vec2(10, 20))
        let b = p.boundingBoxOfPath
        XCTAssertFalse(p.isEmpty)
        XCTAssertGreaterThan(b.minX, 9.5)
        XCTAssertLessThanOrEqual(b.maxY, 20.5, "sits on the baseline")
        XCTAssertEqual(b.height, 4, accuracy: 1.2)
    }

    func testOptionsDecodeWithoutNewKeys() throws {
        let o = try JSONDecoder().decode(ScreenPrintOptions.self, from: Data(#"{"trap":0.5}"#.utf8))
        XCTAssertNil(o.mesh)
        XCTAssertEqual(o.testSteps, 6)
    }
}
