import XCTest
@testable import KerfCore

final class SendToCutterTests: XCTestCase {
    private func plainCutter(_ origin: OriginCorner) -> DeviceProfile {
        var p = DeviceProfile.defaultCutter
        p.bladeOffset = 0
        p.overcut = 0
        p.sendSpeedAndForce = false
        p.origin = origin
        return p
    }

    /// A 10 mm square with its top-left corner at (x, y) on the canvas.
    private func square(at x: Double, _ y: Double) -> Toolpath {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .cut)
        doc.shapes.append(Artwork(layerID: layer, name: "s", paths: [Polyline(
            [Vec2(x, y), Vec2(x + 10, y), Vec2(x + 10, y + 10), Vec2(x, y + 10)], closed: true)]))
        return Planner.plan(doc, for: .vinylCutter)
    }

    func testAsPlacedKeepsCanvasPosition() {
        let profile = plainCutter(.topLeft)
        let text = PlotterGenerator.generate(square(at: 100, 200), profile: profile)
        let bounds = CutterPreview.parse(text, profile: profile).cutBounds
        XCTAssertEqual(bounds.minX, 100, accuracy: 0.05)
        XCTAssertEqual(bounds.minY, 200, accuracy: 0.05)
    }

    func testHomeCornerMovesJobToOrigin() {
        let profile = plainCutter(.topLeft)
        let options = CutterJobOptions(placement: .homeCorner, homeMargin: 5)
        let text = PlotterGenerator.generate(square(at: 100, 200), profile: profile, options: options)
        let bounds = CutterPreview.parse(text, profile: profile).cutBounds
        XCTAssertEqual(bounds.minX, 5, accuracy: 0.05)
        XCTAssertEqual(bounds.minY, 5, accuracy: 0.05)
        XCTAssertEqual(bounds.width, 10, accuracy: 0.05)
    }

    func testHomeCornerWithFrontRightOrigin() {
        // GCC-style: origin at the front right. The square's front-right corner goes to the origin.
        let profile = plainCutter(.bottomRight)
        let options = CutterJobOptions(placement: .homeCorner)
        let text = PlotterGenerator.generate(square(at: 100, 200), profile: profile, options: options)
        let preview = CutterPreview.parse(text, profile: profile)
        XCTAssertEqual(preview.cutBounds.minX, 0, accuracy: 0.05)
        XCTAssertEqual(preview.cutBounds.minY, 0, accuracy: 0.05)
        // On the canvas layout that is the front-right corner of the work area.
        let design = preview.inDesignSpace(profile).cutBounds
        XCTAssertEqual(design.maxX, profile.bedWidth, accuracy: 0.05)
        XCTAssertEqual(design.maxY, profile.bedHeight, accuracy: 0.05)
    }

    func testHomeCornerIncludesWeedingBox() {
        let profile = plainCutter(.topLeft)
        var options = CutterJobOptions(weedBorder: 3)
        options.placement = .homeCorner
        let text = PlotterGenerator.generate(square(at: 100, 200), profile: profile, options: options)
        let bounds = CutterPreview.parse(text, profile: profile).cutBounds
        // The box is 3 mm outside the square and now sits at the origin.
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.05)
        XCTAssertEqual(bounds.width, 16, accuracy: 0.05)
    }

    func testHomeCornerIgnoredWhenOriginGiven() {
        let profile = plainCutter(.topLeft)
        let options = CutterJobOptions(origin: Vec2(50, 50), placement: .homeCorner)
        let text = PlotterGenerator.generate(square(at: 100, 200), profile: profile, options: options)
        XCTAssertEqual(CutterPreview.parse(text, profile: profile).cutBounds.minX, 50, accuracy: 0.05)
    }

    func testParseHPGL() {
        let profile = plainCutter(.topLeft)
        let preview = CutterPreview.parse("IN;VS30;FS80;PU40,80;PD120,160,200,160;\nPU;\n", profile: profile)
        XCTAssertEqual(preview.strokes.count, 2)
        XCTAssertFalse(preview.strokes[0].isCut)
        XCTAssertEqual(preview.strokes[0].points, [Vec2(0, 0), Vec2(1, 2)])
        XCTAssertTrue(preview.strokes[1].isCut)
        XCTAssertEqual(preview.strokes[1].points, [Vec2(1, 2), Vec2(3, 4), Vec2(5, 4)])
        XCTAssertEqual(preview.travelLength, Vec2(1, 2).length, accuracy: 1e-9)
    }

    func testParseSkipsOpticalMarkCommand() {
        let profile = plainCutter(.topLeft)
        let preview = CutterPreview.parse("IN;\u{1B}.D1;8000;4000:PU40,40;PD80,40;PU;\n", profile: profile)
        let cuts = preview.strokes.filter(\.isCut)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].points, [Vec2(1, 1), Vec2(2, 1)])
    }

    func testParseGPGL() {
        var profile = plainCutter(.topLeft)
        profile.language = .gpgl
        profile.unitsPerMM = 20
        let text = PlotterGenerator.generate(square(at: 10, 20), profile: profile)
        let preview = CutterPreview.parse(text, profile: profile)
        XCTAssertEqual(preview.cutBounds.minX, 10, accuracy: 0.05)
        XCTAssertEqual(preview.cutBounds.minY, 20, accuracy: 0.05)
        XCTAssertEqual(preview.cutLength, 40, accuracy: 0.1)
    }

    func testPreviewShowsMirroredOutput() {
        let profile = plainCutter(.topLeft)
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .cut)
        // An L: a long arm along x from (0,0) and a short one down from it.
        doc.shapes.append(Artwork(layerID: layer, name: "l", paths: [Polyline([Vec2(10, 10), Vec2(40, 10), Vec2(40, 20)])]))
        let plain = CutterPreview.parse(PlotterGenerator.generate(Planner.plan(doc, for: .vinylCutter), profile: profile), profile: profile)
        let flipped = CutterPreview.parse(PlotterGenerator.generate(
            Planner.plan(doc.mirrored(.horizontal, about: Vec2(25, 15)), for: .vinylCutter), profile: profile), profile: profile)
        XCTAssertEqual(plain.cutBounds, flipped.cutBounds)
        let plainCorner = plain.strokes.first(where: \.isCut)!.points[1]
        let flippedCorner = flipped.strokes.first(where: \.isCut)!.points[1]
        XCTAssertNotEqual(plainCorner.x, flippedCorner.x, accuracy: 1)
    }
}
