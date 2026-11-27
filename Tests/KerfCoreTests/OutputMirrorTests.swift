import XCTest
@testable import KerfCore

final class OutputMirrorTests: XCTestCase {
    /// An "L": a tall bar on the left with a foot to the right, so a mirror is easy to spot.
    private func lDocument() -> KerfDocument {
        let layer = Layer(name: "Cut", colorHex: "#000000", mode: .cut)
        let bar = Polyline([Vec2(10, 10), Vec2(12, 10), Vec2(12, 30), Vec2(10, 30)], closed: true)
        let foot = Polyline([Vec2(12, 28), Vec2(20, 28), Vec2(20, 30), Vec2(12, 30)], closed: true)
        return KerfDocument(layers: [layer], shapes: [
            Artwork(layerID: layer.id, name: "bar", paths: [bar]),
            Artwork(layerID: layer.id, name: "foot", paths: [foot]),
        ])
    }

    func testOffLeavesDocumentAlone() {
        let doc = lDocument()
        XCTAssertEqual(doc.mirrored(.none), doc)
    }

    func testHorizontalMirrorKeepsPlaceAndFlipsLeftToRight() {
        let doc = lDocument()
        let m = doc.mirrored(.horizontal)
        XCTAssertEqual(m.bounds, doc.bounds)
        // The bar moves to the right-hand side; the foot now points left.
        let bar = m.shapes[0].bounds
        XCTAssertEqual(bar.minX, 18, accuracy: 1e-9)
        XCTAssertEqual(bar.maxX, 20, accuracy: 1e-9)
        XCTAssertEqual(bar.minY, 10, accuracy: 1e-9)
        let foot = m.shapes[1].bounds
        XCTAssertEqual(foot.minX, 10, accuracy: 1e-9)
        XCTAssertEqual(foot.maxX, 18, accuracy: 1e-9)
        // The original design is unchanged.
        XCTAssertEqual(doc.shapes[0].bounds.minX, 10, accuracy: 1e-9)
    }

    func testVerticalMirrorFlipsTopToBottom() {
        let m = lDocument().mirrored(.vertical)
        let foot = m.shapes[1].bounds
        XCTAssertEqual(foot.minY, 10, accuracy: 1e-9)
        XCTAssertEqual(foot.maxY, 12, accuracy: 1e-9)
        XCTAssertEqual(m.shapes[0].bounds.minX, 10, accuracy: 1e-9)
    }

    func testMirroredToolpathCoversSameAreaWithFlippedPoints() {
        let doc = lDocument()
        let plain = Planner.plan(doc, for: .vinylCutter)
        let mirrored = Planner.plan(doc.mirrored(.horizontal, about: plain.bounds.center), for: .vinylCutter)
        XCTAssertFalse(mirrored.isEmpty)
        XCTAssertEqual(mirrored.bounds.minX, plain.bounds.minX, accuracy: 1e-6)
        XCTAssertEqual(mirrored.bounds.maxX, plain.bounds.maxX, accuracy: 1e-6)
        // Every cut point of the plain job has its mirror image in the mirrored job.
        let cx = plain.bounds.center.x
        let mirroredPoints = mirrored.layers.flatMap(\.paths).flatMap { $0 }
        for p in plain.layers.flatMap(\.paths).flatMap({ $0 }) {
            let want = Vec2(2 * cx - p.x, p.y)
            XCTAssertTrue(mirroredPoints.contains { $0.distance(to: want) < 1e-6 }, "missing mirror of \(p)")
        }
    }
}
