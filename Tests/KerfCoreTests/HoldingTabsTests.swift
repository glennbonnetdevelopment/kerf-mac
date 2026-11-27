import XCTest
@testable import KerfCore

final class HoldingTabsTests: XCTestCase {
    private func square(_ x: Double, _ y: Double, _ size: Double) -> Polyline {
        Polyline([Vec2(x, y), Vec2(x + size, y), Vec2(x + size, y + size), Vec2(x, y + size)], closed: true)
    }

    private func laserDoc(_ shapes: [[Polyline]], count: Int = 4, width: Double = 1) -> KerfDocument {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .line)
        doc.layers[0].tabsEnabled = true
        doc.layers[0].tabCount = count
        doc.layers[0].laserTabWidth = width
        for (i, paths) in shapes.enumerated() {
            doc.shapes.append(Artwork(layerID: layer, name: "s\(i)", paths: paths))
        }
        return doc
    }

    private func length(_ path: [Vec2]) -> Double { HoldingTabs.cumulative(path).last ?? 0 }

    func testLaserLeavesGapsInParts() {
        let doc = laserDoc([[square(10, 10, 100)]])
        let tp = Planner.plan(doc, for: .grblLaser)
        let layer = tp.layers[0]
        XCTAssertEqual(layer.paths.count, 4) // pieces either side of the start are joined
        XCTAssertEqual(layer.paths.reduce(0) { $0 + length($1) }, 396, accuracy: 1e-6)
        XCTAssertEqual(layer.tabMarks.count, 4)
        XCTAssertTrue(layer.tabMarks.allSatisfy { $0.manualIndex == nil })
    }

    func testLaserGCodeTravelsOverTabs() {
        let tp = Planner.plan(laserDoc([[square(10, 10, 100)]]), for: .grblLaser)
        let lines = GCodeGenerator.generate(tp, profile: .defaultLaser)
        // One rapid to start each of the four cut pieces: the laser is off over every tab.
        XCTAssertEqual(lines.filter { $0.hasPrefix("G0 X") }.count, 4)
    }

    func testHolesGetNoAutomaticTabs() {
        let doc = laserDoc([[square(0, 0, 100)], [square(40, 40, 20)]])
        let tp = Planner.plan(doc, for: .grblLaser)
        // The hole is cut first in one piece, then the part in four.
        XCTAssertEqual(tp.layers[0].paths.count, 5)
        XCTAssertEqual(length(tp.layers[0].paths[0]), 80, accuracy: 1e-6)
        XCTAssertEqual(tp.layers[0].tabMarks.count, 4)
    }

    func testTabsOffLeavesOutlinesWhole() {
        var doc = laserDoc([[square(10, 10, 100)]])
        doc.layers[0].tabsEnabled = false
        doc.shapes[0].tabs = [Vec2(50, 0)]
        let tp = Planner.plan(doc, for: .grblLaser)
        XCTAssertEqual(tp.layers[0].paths.count, 1)
        XCTAssertTrue(tp.tabMarks.isEmpty)
    }

    func testVinylCutterNeverGetsTabs() {
        var doc = laserDoc([[square(10, 10, 100)]])
        doc.layers[0].mode = .cut
        let tp = Planner.plan(doc, for: .vinylCutter)
        XCTAssertEqual(tp.layers[0].paths.count, 1)
    }

    func testSpacingPlacement() {
        var doc = laserDoc([[square(0, 0, 100)]])
        doc.layers[0].tabPlacement = .spacing
        doc.layers[0].tabSpacing = 50
        XCTAssertEqual(Planner.plan(doc, for: .grblLaser).tabMarks.count, 8)
        doc.layers[0].tabSpacing = 200
        XCTAssertEqual(Planner.plan(doc, for: .grblLaser).tabMarks.count, 2)
    }

    func testSmallShapesGetFewerTabs() {
        // A 4 mm square has 16 mm of outline: with 2 mm tabs only two fit.
        let path = square(0, 0, 4).drawnPoints
        XCTAssertEqual(HoldingTabs.autoCenters(path, placement: .count, count: 10, spacing: 0, width: 2).count, 2)
        XCTAssertTrue(HoldingTabs.autoCenters(path, placement: .count, count: 4, spacing: 0, width: 6).isEmpty)
    }

    func testAutomaticTabsStayOffCorners() {
        // Three tabs on a square: even spacing would put the middle one right on a corner.
        let path = square(0, 0, 100).drawnPoints
        let width = 4.0
        let centers = HoldingTabs.autoCenters(path, placement: .count, count: 3, spacing: 0, width: width)
        XCTAssertEqual(centers.count, 3)
        for c in centers {
            let toCorner = [0.0, 100, 200, 300, 400].map { abs($0 - c) }.min()!
            XCTAssertGreaterThan(toCorner, width, "tab at \(c) sits on a corner")
        }
    }

    func testHandPlacedTabsSnapToOutline() {
        var doc = laserDoc([[square(0, 0, 100)]], width: 2)
        doc.shapes[0].transform = .translation(10, 10)
        // Just inside the top edge, in the shape's own coordinates.
        doc.shapes[0].tabs = [Vec2(30, 1.5)]
        let tp = Planner.plan(doc, for: .grblLaser)
        let marks = tp.tabMarks
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].manualIndex, 0)
        XCTAssertEqual(marks[0].point.x, 40, accuracy: 1e-6)
        XCTAssertEqual(marks[0].point.y, 10, accuracy: 1e-6)
        XCTAssertEqual(abs(marks[0].direction.x), 1, accuracy: 1e-6)
        XCTAssertEqual(tp.layers[0].paths.count, 1) // one gap leaves one open piece
        XCTAssertEqual(length(tp.layers[0].paths[0]), 398, accuracy: 1e-6)
    }

    func testEmptyTabListMeansNoTabs() {
        var doc = laserDoc([[square(0, 0, 100)], [square(200, 0, 100)]])
        doc.shapes[0].tabs = []
        let tp = Planner.plan(doc, for: .grblLaser)
        XCTAssertEqual(Set(tp.tabMarks.map(\.shapeID)), [doc.shapes[1].id])
    }

    func testHandPlacedTabOnHoleForLaser() {
        var doc = laserDoc([[square(0, 0, 100), square(40, 40, 20)]])
        doc.shapes[0].tabs = [Vec2(50, 41)] // on the inner square's top edge
        let tp = Planner.plan(doc, for: .grblLaser)
        XCTAssertEqual(tp.tabMarks.count, 1)
        XCTAssertEqual(tp.tabMarks[0].point.y, 40, accuracy: 1e-6)
        // The outer outline has no tab now that this shape's tabs are placed by hand.
        XCTAssertTrue(tp.layers[0].paths.contains { abs(length($0) - 400) < 1e-6 })
    }

    func testIntervalsWrapAroundStart() {
        let r = HoldingTabs.intervals(centers: [0.5], width: 2, total: 100)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].lowerBound, 0)
        XCTAssertEqual(r[0].upperBound, 1.5, accuracy: 1e-9)
        XCTAssertEqual(r[1].lowerBound, 99.5, accuracy: 1e-9)
        XCTAssertEqual(r[1].upperBound, 100)
    }

    func testSplitAcrossStartJoinsPieces() {
        let path = square(0, 0, 10).drawnPoints
        let pieces = HoldingTabs.split(path, tabs: [10...12, 25...27])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.reduce(0) { $0 + length($1) }, 36, accuracy: 1e-9)
    }

    // MARK: - CNC

    private func cncProfile() -> DeviceProfile {
        DeviceProfile.presets.first { $0.kind == .cncRouter }!
    }

    private func cncDoc() -> KerfDocument {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].cutDepth = 6
        doc.layers[0].stepDown = 3
        doc.layers[0].tabsEnabled = true
        doc.layers[0].tabCount = 4
        doc.layers[0].tabHeight = 2
        doc.shapes.append(Artwork(layerID: layer, name: "p", paths: [square(10, 10, 60), square(30, 30, 20)]))
        return doc
    }

    func testCNCTabsOnPartsOnly() {
        let tp = Planner.plan(cncDoc(), for: .cncRouter)
        let l = tp.layers[0]
        XCTAssertEqual(l.cuts, [.hole, .part])
        XCTAssertTrue(l.tabs(at: 0).isEmpty)
        XCTAssertEqual(l.tabs(at: 1).count, 4)
        XCTAssertEqual(l.tabMarks.count, 4)
        // Bridge plus tool diameter.
        let width = l.tabs(at: 1)[0].upperBound - l.tabs(at: 1)[0].lowerBound
        XCTAssertEqual(width, 5 + 3.175, accuracy: 1e-6)
    }

    func testCNCHandPlacedTabOnHoleLiftsTool() {
        var doc = cncDoc()
        doc.shapes[0].tabs = [Vec2(40, 30)] // top edge of the hole
        let tp = Planner.plan(doc, for: .cncRouter)
        XCTAssertEqual(tp.layers[0].tabs(at: 0).count, 1)
        XCTAssertTrue(tp.layers[0].tabs(at: 1).isEmpty)
        let lines = GCodeGenerator.generate(tp, profile: cncProfile())
        XCTAssertTrue(lines.contains { $0.hasPrefix("G1 X") && $0.hasSuffix("Z-4") })
    }

    func testCNCTabsFollowReversedPath() {
        // Whichever way the contour is cut, the lifted stretches sit at the same places on the bed.
        var doc = cncDoc()
        doc.shapes[0].paths = [square(10, 10, 60)]
        doc.shapes[0].tabs = [Vec2(40, 10)]
        func liftedPoints(_ style: MillStyle) -> [Vec2] {
            doc.layers[0].millStyle = style
            let lines = GCodeGenerator.generate(Planner.plan(doc, for: .cncRouter), profile: cncProfile())
            return lines.filter { $0.hasPrefix("G1 X") && $0.hasSuffix("Z-4") }.compactMap { line in
                let parts = line.split(separator: " ")
                guard let x = Double(parts[1].dropFirst()), let y = Double(parts[2].dropFirst()) else { return nil }
                return Vec2(x, y)
            }
        }
        let climb = liftedPoints(.climb), conventional = liftedPoints(.conventional)
        XCTAssertFalse(climb.isEmpty)
        let cx = climb.map(\.x).reduce(0, +) / Double(climb.count)
        let vx = conventional.map(\.x).reduce(0, +) / Double(conventional.count)
        XCTAssertEqual(cx, vx, accuracy: 0.01)
    }

    // MARK: - Files

    func testTabSettingsRoundTrip() throws {
        var doc = laserDoc([[square(0, 0, 50)]])
        doc.layers[0].tabPlacement = .spacing
        doc.layers[0].tabSpacing = 75
        doc.layers[0].laserTabWidth = 0.8
        doc.shapes[0].tabs = [Vec2(1, 2)]
        let back = try KerfDocument.decode(doc.encoded())
        XCTAssertEqual(back.layers[0].tabPlacement, .spacing)
        XCTAssertEqual(back.layers[0].tabSpacing, 75)
        XCTAssertEqual(back.layers[0].laserTabWidth, 0.8)
        XCTAssertEqual(back.shapes[0].tabs, [Vec2(1, 2)])
    }

    func testOldLayersDecodeWithTabDefaults() throws {
        let json = #"{"id":"6F1C2A3E-0000-4000-8000-000000000001","name":"L","colorHex":"#000000","tabsEnabled":true}"#
        let layer = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        XCTAssertTrue(layer.tabsEnabled)
        XCTAssertEqual(layer.tabPlacement, .count)
        XCTAssertEqual(layer.laserTabWidth, 0.5)
    }
}
