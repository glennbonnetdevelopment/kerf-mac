import Foundation
import XCTest
@testable import KerfCore

final class PrintAndCutTests: XCTestCase {
    private var expertLX: DeviceProfile {
        DeviceProfile.presets.first { $0.name.hasPrefix("GCC Expert II 24 LX") }!
    }

    func testCentredPlacement() {
        let content = Rect2(minX: 100, minY: 50, maxX: 200, maxY: 150)
        let page = Vec2(210, 297)
        let off = PrintLayout.offset(content: content, page: page, placement: .center, margin: 10)
        XCTAssertEqual(content.minX + off.x, 55, accuracy: 1e-9)
        XCTAssertEqual(content.minY + off.y, 98.5, accuracy: 1e-9)
        XCTAssertTrue(PrintLayout.fits(content: content, offset: off, page: page, margin: 10))
    }

    func testTopLeftPlacementAndFit() {
        let content = Rect2(minX: 300, minY: 300, maxX: 520, maxY: 400)
        let page = PaperSize.letter.size
        let off = PrintLayout.offset(content: content, page: page, placement: .topLeft, margin: 10)
        XCTAssertEqual(content.minX + off.x, 10, accuracy: 1e-9)
        XCTAssertEqual(content.minY + off.y, 10, accuracy: 1e-9)
        // 220 mm wide doesn't fit portrait Letter, but fits landscape.
        XCTAssertFalse(PrintLayout.fits(content: content, offset: off, page: page, margin: 10))
        var s = PrintSettings()
        s.landscape = true
        XCTAssertTrue(PrintLayout.fits(content: content, offset: off, page: s.pageSize, margin: 10))
    }

    func testPrintSettingsRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PrintAndCutTests"))
        defaults.removePersistentDomain(forName: "PrintAndCutTests")
        var s = PrintSettings()
        s.paper = .a3
        s.landscape = true
        s.printCutLines = true
        s.save(defaults)
        XCTAssertEqual(PrintSettings.load(defaults), s)
    }

    func testAASMarkCornersSitOutsideTheArtwork() {
        let art = Rect2(minX: 50, minY: 40, maxX: 150, maxY: 100)
        let c = GCCAAS.markCorners(around: art, margin: 5, thickness: 1)
        XCTAssertEqual(c, [Vec2(44, 34), Vec2(156, 34), Vec2(44, 106), Vec2(156, 106)])
    }

    func testOriginMarkIsNearestTheCutterOrigin() {
        let c = GCCAAS.markCorners(around: Rect2(minX: 50, minY: 40, maxX: 150, maxY: 100), margin: 5, thickness: 1)
        // The Expert II's origin is front right, which is the bottom-right of the design.
        XCTAssertEqual(GCCAAS.originIndex(for: expertLX, corners: c), 3)
        var p = expertLX
        p.origin = .topLeft
        XCTAssertEqual(GCCAAS.originIndex(for: p, corners: c), 0)
    }

    func testOriginMarkIsThicker() throws {
        let normal = GCCAAS.mark(length: 25, thickness: 1, corner: Vec2(-1, -1), isOrigin: false)
        let origin = GCCAAS.mark(length: 25, thickness: 1, corner: Vec2(-1, -1), isOrigin: true)
        let nb = normal[0].bounds, ob = origin[0].bounds
        XCTAssertEqual(nb.width, 25, accuracy: 1e-9)
        XCTAssertEqual(ob.width, 25, accuracy: 1e-9)
        // The outside corner is the mark's origin and the arms run toward the artwork.
        XCTAssertEqual(nb.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(nb.minY, 0, accuracy: 1e-9)
        XCTAssertTrue(normal[0].points.contains(Vec2(1, 1)))
        XCTAssertTrue(origin[0].points.contains(Vec2(2, 2)))
    }

    func testJobDistancesAndCommand() throws {
        let marks = [Vec2(156, 106), Vec2(44, 34), Vec2(156, 34), Vec2(44, 106)]
        let job = try XCTUnwrap(GCCAAS.job(marks: marks, profile: expertLX))
        XCTAssertEqual(job.origin, Vec2(156, 106))
        XCTAssertEqual(job.xDistance, 112, accuracy: 1e-9)
        XCTAssertEqual(job.yDistance, 72, accuracy: 1e-9)
        XCTAssertEqual(GCCAAS.command(job, units: .plotterUnits, unitsPerMM: 40), "\u{1B}.D1;4480;2880:")
        XCTAssertEqual(GCCAAS.command(job, units: .tenthMM, unitsPerMM: 40), "\u{1B}.D1;1120;720:")
        XCTAssertEqual(GCCAAS.command(job, units: .mm, unitsPerMM: 40), "\u{1B}.D1;112;72:")
        XCTAssertNil(GCCAAS.job(marks: Array(marks.prefix(3)), profile: expertLX))
        XCTAssertNil(GCCAAS.job(marks: [Vec2(1, 1), Vec2(1, 1), Vec2(1, 1), Vec2(1, 1)], profile: expertLX))
    }

    func testCutIsPlacedFromTheOriginMark() throws {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .cut)
        doc.shapes = [Artwork(layerID: layer, name: "Square",
                              paths: [Polyline([Vec2(100, 60), Vec2(140, 60), Vec2(140, 90), Vec2(100, 90)], closed: true)],
                              transform: .identity)]
        var profile = expertLX
        profile.bladeOffset = 0
        profile.overcut = 0
        profile.sendSpeedAndForce = false
        let tp = Planner.plan(doc, for: .vinylCutter)
        let job = try XCTUnwrap(GCCAAS.job(marks: [Vec2(156, 106), Vec2(44, 34), Vec2(156, 34), Vec2(44, 106)], profile: profile))
        let cmd = GCCAAS.command(job, units: .plotterUnits, unitsPerMM: 40)
        let text = PlotterGenerator.generate(tp, profile: profile, options: CutterJobOptions(origin: job.origin, preamble: cmd))
        XCTAssertTrue(text.hasPrefix("IN;" + cmd), text)
        // Front-right origin: X runs left from the origin mark and Y runs up (toward the back).
        // The corner at (140, 90) is 16 mm left of and 16 mm above the origin mark at (156, 106).
        XCTAssertTrue(text.contains("640,640"), text)
        XCTAssertFalse(text.contains("-"), "No negative coordinates: \(text)")
    }

    func testScanOnlyReturnsToTheOriginMark() throws {
        let job = GCCAAS.Job(origin: .zero, xDistance: 100, yDistance: 50)
        XCTAssertEqual(GCCAAS.scanOnly(job, units: .plotterUnits, unitsPerMM: 40), "IN;\u{1B}.D1;4000;2000:PU0,0;\n")
    }

    func testLayoutWarnings() {
        let marks = Rect2(minX: 10, minY: 10, maxX: 200, maxY: 280)
        let w = GCCAAS.layoutWarnings(marks: marks, page: PaperSize.letter.size, offset: .zero)
        XCTAssertEqual(w.count, 3)
        let ok = Rect2(minX: 40, minY: 30, maxX: 170, maxY: 200)
        XCTAssertTrue(GCCAAS.layoutWarnings(marks: ok, page: PaperSize.letter.size, offset: .zero).isEmpty)
    }

    func testOldProfilesDecodeWithoutAAS() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expertLX)) as! [String: Any]
        json.removeValue(forKey: "aasEnabled")
        json.removeValue(forKey: "aasUnits")
        let p = try JSONDecoder().decode(DeviceProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(p.aasEnabled)
        XCTAssertEqual(p.aasUnits, .plotterUnits)
        XCTAssertTrue(expertLX.aasEnabled)
    }
}
