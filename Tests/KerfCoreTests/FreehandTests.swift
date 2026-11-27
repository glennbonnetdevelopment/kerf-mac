import XCTest
@testable import KerfCore

final class FreehandTests: XCTestCase {
    /// A wobbly left-to-right line, 0…`length` mm along x with ±`wobble` mm of jitter.
    private func wobblyLine(length: Double = 50, wobble: Double = 0.15) -> [Vec2] {
        (0...200).map { i in
            let x = length * Double(i) / 200
            return Vec2(x, (i % 2 == 0 ? 1 : -1) * wobble)
        }
    }

    func testPenSmoothsWobbleAndKeepsEnds() {
        let raw = wobblyLine()
        let line = Freehand.smooth(raw, tolerance: 0.5)
        XCTAssertFalse(line.closed)
        XCTAssertLessThan(line.points.count, 20, "jitter is simplified away")
        XCTAssertEqual(line.points.first!.distance(to: Vec2(0, 0.15)), 0, accuracy: 1e-9)
        XCTAssertEqual(line.points.last!.distance(to: raw.last!), 0, accuracy: 1e-9)
        for p in line.points { XCTAssertLessThan(abs(p.y), 0.3) }
    }

    func testPenFollowsACurve() {
        // A half circle of radius 20, drawn by hand.
        let raw = (0...180).map { d -> Vec2 in
            let a = Double(d) * .pi / 180
            return Vec2(20 * cos(a), 20 * sin(a))
        }
        let line = Freehand.smooth(raw, tolerance: 0.2)
        XCTAssertGreaterThan(line.points.count, 10)
        for p in line.points { XCTAssertEqual(p.length, 20, accuracy: 0.3) }
    }

    func testPenClosesWhenEndingNearTheStart() {
        let raw = (0...100).map { i -> Vec2 in
            let a = Double(i) / 100 * 2 * .pi * 0.98
            return Vec2(30 * cos(a), 30 * sin(a))
        }
        let loop = Freehand.smooth(raw, tolerance: 0.3, closeDistance: 5)
        XCTAssertTrue(loop.closed)
        XCTAssertEqual(loop.bounds.width, 60, accuracy: 1.5)
        let open = Freehand.smooth(raw, tolerance: 0.3, closeDistance: 1)
        XCTAssertFalse(open.closed)
    }

    func testBrushStrokeIsAClosedOutlineOfTheRightWidth() {
        let samples = (0...100).map { StrokeSample(Vec2(Double($0) * 0.4, 0), time: Double($0) * 0.01) }
        let outline = Freehand.brushOutline(samples, options: BrushOptions(width: 4, thinning: 0, taper: false), tolerance: 0.1)
        XCTAssertEqual(outline.count, 1)
        XCTAssertTrue(outline[0].closed)
        XCTAssertEqual(outline[0].bounds.height, 4, accuracy: 0.1)
        XCTAssertEqual(outline[0].bounds.width, 44, accuracy: 0.2, "round caps add half the width at each end")
        XCTAssertEqual(abs(outline[0].signedArea), 40 * 4 + .pi * 4, accuracy: 1.5)
    }

    func testBrushTaperNarrowsTheEnds() {
        let samples = (0...100).map { StrokeSample(Vec2(Double($0) * 0.4, 0), time: Double($0) * 0.01) }
        let plain = Freehand.brushOutline(samples, options: BrushOptions(width: 4, thinning: 0, taper: false), tolerance: 0.1)[0]
        let tapered = Freehand.brushOutline(samples, options: BrushOptions(width: 4, thinning: 0, taper: true), tolerance: 0.1)[0]
        XCTAssertLessThan(abs(tapered.signedArea), abs(plain.signedArea) * 0.95)
        // Near the start the tapered stroke is much thinner than full width.
        let nearStart = tapered.points.filter { $0.x > 0.5 && $0.x < 1.5 }.map { abs($0.y) }.max() ?? 0
        XCTAssertLessThan(nearStart, 1)
        XCTAssertEqual(tapered.bounds.height, 4, accuracy: 0.1, "full width in the middle")
    }

    func testPressureChangesWidth() {
        let soft = (0...100).map { StrokeSample(Vec2(Double($0) * 0.4, 0), pressure: $0 < 50 ? 0.2 : 1, time: Double($0) * 0.01) }
        let outline = Freehand.brushOutline(soft, options: BrushOptions(width: 4, thinning: 1, taper: false), tolerance: 0.1)[0]
        let lightHalf = outline.points.filter { $0.x > 5 && $0.x < 15 }.map { abs($0.y) }.max() ?? 0
        let firmHalf = outline.points.filter { $0.x > 25 && $0.x < 35 }.map { abs($0.y) }.max() ?? 0
        XCTAssertLessThan(lightHalf, 1)
        XCTAssertEqual(firmHalf, 2, accuracy: 0.1)
    }

    func testFastStrokesAreThinnerWithoutPressure() {
        func stroke(speed: Double) -> Polyline {
            let samples = (0...100).map { StrokeSample(Vec2(Double($0) * 0.4, 0), time: Double($0) * 0.4 / speed) }
            return Freehand.brushOutline(samples, options: BrushOptions(width: 4, thinning: 1, taper: false),
                                         tolerance: 0.1, speedReference: 100)[0]
        }
        XCTAssertLessThan(stroke(speed: 1000).bounds.height, stroke(speed: 10).bounds.height * 0.5)
    }

    func testBrushClickMakesADot() {
        let outline = Freehand.brushOutline([StrokeSample(Vec2(5, 5))], options: BrushOptions(width: 6), tolerance: 0.1)
        XCTAssertEqual(outline.count, 1)
        XCTAssertEqual(outline[0].bounds.width, 6, accuracy: 0.05)
        XCTAssertEqual(outline[0].bounds.center.x, 5, accuracy: 0.05)
    }

    func testClosedBrushStrokeIsARing() {
        let samples = (0...120).map { i -> StrokeSample in
            let a = Double(i) / 120 * 2 * .pi * 0.99
            return StrokeSample(Vec2(30 * cos(a), 30 * sin(a)), time: Double(i) * 0.01)
        }
        let rings = Freehand.brushOutline(samples, options: BrushOptions(width: 4, thinning: 0), tolerance: 0.2, closeDistance: 5)
        XCTAssertEqual(rings.count, 2)
        let widths = rings.map(\.bounds.width).sorted()
        XCTAssertEqual(widths[0], 56, accuracy: 1.5)
        XCTAssertEqual(widths[1], 64, accuracy: 1.5)
    }

    // MARK: - Eraser

    func testEraserSplitsALine() {
        let line = Polyline([Vec2(0, 0), Vec2(10, 0)])
        let pieces = Eraser.split([line], trail: [Vec2(5, -3), Vec2(5, 3)], radius: 1)
        XCTAssertEqual(pieces.count, 2)
        let sorted = pieces.sorted { $0.bounds.minX < $1.bounds.minX }
        XCTAssertEqual(sorted[0].bounds.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(sorted[0].bounds.maxX, 4, accuracy: 0.01)
        XCTAssertEqual(sorted[1].bounds.minX, 6, accuracy: 0.01)
        XCTAssertEqual(sorted[1].bounds.maxX, 10, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(sorted[0].points.count, 3, "straight lines stay light")
    }

    func testEraserCatchesAFastSwipeBetweenSamples() {
        // The two trail points are far from the line, but the swipe between them crosses it.
        let line = Polyline([Vec2(0, 0), Vec2(10, 0)])
        XCTAssertTrue(Eraser.touches(line, trail: [Vec2(5, -20), Vec2(5, 20)], radius: 0.5))
        XCTAssertEqual(Eraser.split([line], trail: [Vec2(5, -20), Vec2(5, 20)], radius: 0.5).count, 2)
    }

    func testEraserOpensAClosedShapeIntoOnePiece() {
        let square = Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)], closed: true)
        // Rub across the middle of the top edge.
        let pieces = Eraser.split([square], trail: [Vec2(5, -2), Vec2(5, 2)], radius: 1)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertFalse(pieces[0].closed)
        XCTAssertEqual(pieces[0].length, 40 - 2, accuracy: 0.05)
        // Rubbing a corner, which is the loop's starting point, also leaves one piece.
        let corner = Eraser.split([square], trail: [Vec2(0, 0)], radius: 1)
        XCTAssertEqual(corner.count, 1)
        XCTAssertEqual(corner[0].length, 38, accuracy: 0.05)
    }

    func testEraserLeavesUntouchedPathsAlone() {
        let a = Polyline([Vec2(0, 0), Vec2(10, 0)])
        let b = Polyline([Vec2(0, 20), Vec2(10, 20)])
        let out = Eraser.split([a, b], trail: [Vec2(5, 19), Vec2(5, 21)], radius: 0.5)
        XCTAssertEqual(out.first, a)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(Eraser.removeTouched([a, b], trail: [Vec2(5, 19)], radius: 1.5), [a])
    }

    func testEraserRemovesShortBitsEntirely() {
        let tiny = Polyline([Vec2(0, 0), Vec2(1, 0)])
        XCTAssertTrue(Eraser.split([tiny], trail: [Vec2(0.5, 0)], radius: 2).isEmpty)
    }

    func testSweptAreaCoversTheTrail() {
        let area = Eraser.sweptArea([Vec2(0, 0), Vec2(20, 0)], radius: 2)
        XCTAssertEqual(area.count, 1)
        XCTAssertEqual(area[0].bounds.width, 24, accuracy: 0.2)
        XCTAssertEqual(area[0].bounds.height, 4, accuracy: 0.1)
    }
}
