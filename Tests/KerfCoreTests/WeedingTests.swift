import XCTest
@testable import KerfCore

final class WeedingTests: XCTestCase {
    private func square(_ x: Double, _ y: Double, _ s: Double) -> [Vec2] {
        [Vec2(x, y), Vec2(x + s, y), Vec2(x + s, y + s), Vec2(x, y + s), Vec2(x, y)]
    }

    func testOffByDefault() {
        XCTAssertTrue(Weeding.cuts(for: [square(0, 0, 10)], options: WeedingOptions()).isEmpty)
    }

    func testBoxAroundJobUsesMargin() {
        let cuts = Weeding.cuts(for: [square(0, 0, 10), square(50, 0, 10)],
                                options: WeedingOptions(box: .job, margin: 3))
        XCTAssertEqual(cuts.boxes.count, 1)
        XCTAssertTrue(cuts.lines.isEmpty)
        XCTAssertEqual(cuts.boxes[0], [Vec2(-3, -3), Vec2(63, -3), Vec2(63, 13), Vec2(-3, 13), Vec2(-3, -3)])
    }

    func testBoxPerDesignMergesOnlyShapesThatTouch() {
        // Two squares 4 mm apart share a box with a 3 mm margin; the far one gets its own.
        let paths = [square(0, 0, 10), square(14, 0, 10), square(100, 0, 10)]
        let regions = Weeding.designRegions(paths, margin: 3)
        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions.contains(Rect2(minX: -3, minY: -3, maxX: 27, maxY: 13)))
        XCTAssertTrue(regions.contains(Rect2(minX: 97, minY: -3, maxX: 113, maxY: 13)))
        let cuts = Weeding.cuts(for: paths, options: WeedingOptions(box: .eachDesign, margin: 3))
        XCTAssertEqual(cuts.boxes.count, 2)
    }

    func testHorizontalLinesStopShortOfDesign() {
        // A 10 mm square in a 40 mm box: lines run from the box edge to 0.5 mm from the square.
        let paths = [square(15, 15, 10)]
        let cuts = Weeding.cuts(for: paths, options: WeedingOptions(box: .job, margin: 15, lines: .horizontal,
                                                                    spacing: 10, clearance: 0.5))
        // Height 40, spacing 10: three lines at y = 10, 20, 30.
        let ys = Set(cuts.lines.map { $0[0].y })
        XCTAssertEqual(ys, [10, 20, 30])
        // Lines clear of the square span the box.
        let top = cuts.lines.filter { $0[0].y == 10 }
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(Set(top[0].map(\.x)), [0, 40])
        // The middle line is split either side of the square.
        let middle = cuts.lines.filter { $0[0].y == 20 }
        XCTAssertEqual(middle.count, 2)
        let xs = middle.flatMap { $0.map(\.x) }.sorted()
        XCTAssertEqual(xs[0], 0, accuracy: 1e-9)
        XCTAssertEqual(xs[1], 14.5, accuracy: 1e-9)
        XCTAssertEqual(xs[2], 25.5, accuracy: 1e-9)
        XCTAssertEqual(xs[3], 40, accuracy: 1e-9)
        // Every line stays clear of the square.
        for line in cuts.lines {
            for p in line {
                XCTAssertFalse(Rect2(minX: 14.6, minY: 14.6, maxX: 25.4, maxY: 25.4).contains(p))
            }
        }
    }

    func testLinesAlternateDirection() {
        let cuts = Weeding.cuts(for: [square(0, 0, 1)],
                                options: WeedingOptions(box: .job, margin: 20, lines: .horizontal, spacing: 5))
        let full = cuts.lines.filter { abs($0[0].x - $0[1].x) > 40 }
        XCTAssertGreaterThan(full.count, 2)
        XCTAssertNotEqual(full[0][0].x < full[0][1].x, full[1][0].x < full[1][1].x)
    }

    func testVerticalLinesAndGrid() {
        let paths = [square(15, 15, 10)]
        let vertical = Weeding.cuts(for: paths, options: WeedingOptions(box: .job, margin: 15, lines: .vertical, spacing: 10))
        XCTAssertFalse(vertical.lines.isEmpty)
        XCTAssertTrue(vertical.lines.allSatisfy { $0[0].x == $0[1].x })
        let grid = Weeding.cuts(for: paths, options: WeedingOptions(box: .job, margin: 15, lines: .grid, spacing: 10))
        XCTAssertEqual(grid.lines.count, vertical.lines.count * 2)
    }

    func testLinesDoNotCrossLetterCounters() {
        // An "O": outer ring and inner ring. The counter stays whole.
        let paths = [square(10, 10, 20), square(15, 15, 10)]
        let cuts = Weeding.cuts(for: paths, options: WeedingOptions(box: .job, margin: 10, lines: .horizontal,
                                                                    spacing: 10, clearance: 0))
        for line in cuts.lines where line[0].y > 10 && line[0].y < 30 {
            for p in line { XCTAssertFalse(p.x > 10 + 1e-9 && p.x < 30 - 1e-9, "line enters the letter at \(p)") }
        }
    }

    func testOpenPathsBreakLines() {
        let cuts = Weeding.cuts(for: [[Vec2(20, 0), Vec2(20, 40)]],
                                options: WeedingOptions(box: .job, margin: 10, lines: .horizontal, spacing: 20, clearance: 1))
        let xs = cuts.lines.flatMap { $0.map(\.x) }
        XCTAssertFalse(xs.contains { $0 > 19 && $0 < 21 })
        XCTAssertEqual(cuts.lines.count, 4)
    }

    func testCapsuleSpan() {
        let span = Weeding.capsuleSpan(Vec2(0, 0), Vec2(10, 0), y: 0.6, radius: 1)
        XCTAssertNotNil(span)
        XCTAssertEqual(span!.0, -0.8, accuracy: 1e-9)
        XCTAssertEqual(span!.1, 10.8, accuracy: 1e-9)
        XCTAssertNil(Weeding.capsuleSpan(Vec2(0, 0), Vec2(10, 0), y: 1.5, radius: 1))
        let diagonal = Weeding.capsuleSpan(Vec2(0, 0), Vec2(10, 10), y: 5, radius: 1)!
        XCTAssertEqual(diagonal.0, 5 - 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(diagonal.1, 5 + 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testPlotterCutsLinesThenBoxAfterDesign() {
        var profile = DeviceProfile.defaultCutter
        profile.bladeOffset = 0
        profile.overcut = 0
        profile.sendSpeedAndForce = false
        profile.origin = .topLeft
        profile.unitsPerMM = 1
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .cut)
        doc.shapes.append(Artwork(layerID: layer, name: "s", paths: [Polyline(square(10, 10, 10))]))
        let tp = Planner.plan(doc, for: .vinylCutter)
        let options = CutterJobOptions(weeding: WeedingOptions(box: .job, margin: 10, lines: .horizontal, spacing: 20))
        let hpgl = PlotterGenerator.generate(tp, profile: profile, options: options)
        let strokes = hpgl.split(separator: "\n").map(String.init).filter { $0.hasPrefix("PU") && $0.contains("PD") }
        // Design, then the one line (split in two by the square), then the box.
        XCTAssertEqual(strokes.count, 4)
        XCTAssertTrue(strokes[1].hasPrefix("PU0,20;") || strokes[1].hasPrefix("PU40,20;"))
        XCTAssertEqual(strokes[3], "PU0,0;PD40,0,40,40,0,40,0,0;")
        // The old border option still works.
        let border = PlotterGenerator.generate(tp, profile: profile, options: CutterJobOptions(weedBorder: 10))
        XCTAssertTrue(border.contains("PU0,0;PD40,0,40,40,0,40,0,0;"))
    }

    func testOptionsDecodeWithMissingKeys() throws {
        let w = try JSONDecoder().decode(WeedingOptions.self, from: Data(#"{"box":"job"}"#.utf8))
        XCTAssertEqual(w.box, .job)
        XCTAssertEqual(w.margin, 3)
        XCTAssertEqual(w.lines, .none)
    }
}
