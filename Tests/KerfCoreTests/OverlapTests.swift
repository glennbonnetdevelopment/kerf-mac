import XCTest
@testable import KerfCore

final class OverlapTests: XCTestCase {
    /// Counter-clockwise (y-up) rectangle; `reversed` for clockwise.
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, ccw: Bool = true) -> Polyline {
        let p = Polyline([Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h)], closed: true)
        return ccw ? p : p.reversed
    }

    func area(_ paths: [Polyline]) -> Double {
        abs(paths.reduce(0) { $0 + $1.signedArea })
    }

    func testOverlappingOutlinesBecomeOneOutline() {
        let r = OverlapFixer.resolve([rect(0, 0, 10, 10), rect(5, 5, 10, 10)], trustWinding: false)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.paths.count, 1)
        XCTAssertEqual(r.removedLength, 20, accuracy: 0.01)
        XCTAssertEqual(abs(r.paths[0].signedArea), 175, accuracy: 0.01)
    }

    func testCrossingStrokesFillInsteadOfPunchingAHole() {
        // A plus sign drawn as two bars running opposite ways: even-odd would make the middle a hole.
        let bars = [rect(0, 4, 12, 4), rect(4, 0, 4, 12, ccw: false)]
        let r = OverlapFixer.resolve(bars, trustWinding: false)
        XCTAssertEqual(r.paths.count, 1)
        XCTAssertEqual(abs(r.paths[0].signedArea), 80, accuracy: 0.01)
    }

    func testHolesStayAndCleanShapesAreLeftAlone() {
        // Same direction for both, as some SVG files draw them: the inner one is still a hole.
        let ring = [rect(0, 0, 20, 20), rect(5, 5, 10, 10)]
        let r = OverlapFixer.resolve(ring, trustWinding: false)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.paths, ring)
    }

    func testFontWindingDecidesHolesAndOverlaps() {
        // Like an "o": the counter runs the other way, so it stays a hole.
        let o = [rect(0, 0, 20, 20), rect(5, 5, 10, 10, ccw: false)]
        XCTAssertFalse(OverlapFixer.resolve(o, trustWinding: true).changed)
        // Like a script loop: a stroke running the same way over the letter is merged into it, not cut out.
        let loop = [rect(0, 0, 20, 20), rect(5, 5, 10, 30)]
        let r = OverlapFixer.resolve(loop, trustWinding: true)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.paths.count, 1)
        XCTAssertEqual(area(r.paths), 400 + 10 * 15, accuracy: 0.01)
    }

    func testOpenPathsAreKept() {
        let line = Polyline([Vec2(0, 0), Vec2(30, 0)], closed: false)
        let r = OverlapFixer.resolve([rect(0, 0, 10, 10), rect(5, 5, 10, 10), line], trustWinding: false)
        XCTAssertEqual(r.paths.filter { !$0.closed }, [line])
    }

    func testNestingOrientation() {
        let paths = OverlapFixer.orientedByNesting([rect(0, 0, 30, 30, ccw: false), rect(5, 5, 20, 20), rect(10, 10, 10, 10)])
        XCTAssertGreaterThan(paths[0].signedArea, 0)
        XCTAssertLessThan(paths[1].signedArea, 0)
        XCTAssertGreaterThan(paths[2].signedArea, 0)
    }

    func testOverlappingShapesOnOneLayerAreWelded() {
        let layer = UUID(), other = UUID()
        let a = Artwork(layerID: layer, name: "A", paths: [rect(0, 0, 10, 10)])
        let b = Artwork(layerID: layer, name: "B", paths: [rect(0, 0, 10, 10)], transform: .translation(5, 0))
        let c = Artwork(layerID: other, name: "C", paths: [rect(2, 2, 4, 4)])
        let d = Artwork(layerID: layer, name: "D", paths: [rect(50, 50, 4, 4)])
        let groups = OverlapFixer.fix([a, b, c, d])
        XCTAssertEqual(groups.map(\.members), [[0, 1], [2], [3]])
        XCTAssertTrue(groups[0].changed)
        XCTAssertEqual(groups[0].paths.count, 1)
        XCTAssertEqual(groups[0].paths.bounds.maxX, 15, accuracy: 0.01)
        XCTAssertEqual(groups[0].removedLength, 20, accuracy: 0.01)
        XCTAssertFalse(groups[1].changed)
        XCTAssertFalse(groups[2].changed)
    }

    func testFixedSingleShapeKeepsItsOwnCoordinates() {
        let s = Artwork(layerID: UUID(), name: "S", paths: [rect(0, 0, 10, 10), rect(5, 5, 10, 10)],
                        transform: .translation(100, 100))
        let g = OverlapFixer.fix([s])
        XCTAssertEqual(g.count, 1)
        XCTAssertTrue(g[0].changed)
        XCTAssertEqual(g[0].paths.bounds.minX, 0, accuracy: 0.01)
    }
}
