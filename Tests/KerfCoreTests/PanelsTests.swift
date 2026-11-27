import XCTest
@testable import KerfCore

final class PanelsTests: XCTestCase {
    private let cutter = DeviceProfile(name: "Test cutter", kind: .vinylCutter, bedWidth: 600, bedHeight: 1000,
                                       origin: .bottomRight, baudRate: 9600)

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Vec2] {
        [Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h), Vec2(x, y)]
    }

    private func job(_ paths: [[Vec2]]) -> Toolpath {
        Toolpath(layers: [ToolpathLayer(layer: Layer(name: "Cut", colorHex: "#000000", mode: .cut), paths: paths)])
    }

    private func length(_ paths: [[Vec2]]) -> Double { paths.reduce(0) { $0 + Panels.length($1) } }

    func testJobThatFitsIsOnePanel() {
        let layout = Panels.layout(for: job([rect(10, 10, 500, 800)]), profile: cutter, options: PanelOptions(enabled: true))
        XCTAssertEqual(layout.panels.count, 1)
        XCTAssertFalse(layout.isSplit)
        XCTAssertTrue(layout.marks.isEmpty)
    }

    func testWideSignSplitsIntoEqualOverlappingPanels() {
        let options = PanelOptions(enabled: true, overlap: 12, marks: false)
        let layout = Panels.layout(for: job([rect(0, 0, 1500, 500)]), profile: cutter, options: options)
        // (1500 - 12) / (600 - 12) = 2.53, so 3 columns of (1488 / 3) + 12 = 508 mm.
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.panels.map(\.name), ["A1", "A2", "A3"])
        for p in layout.panels { XCTAssertEqual(p.rect.width, 508, accuracy: 1e-9) }
        XCTAssertEqual(layout.panels[0].rect.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.panels[2].rect.maxX, 1500, accuracy: 1e-9)
        // Neighbours share exactly the overlap.
        XCTAssertEqual(layout.panels[0].rect.maxX - layout.panels[1].rect.minX, 12, accuracy: 1e-9)
    }

    func testPanelSizeLimitAndGridNames() {
        let options = PanelOptions(enabled: true, maxWidth: 400, maxHeight: 300, overlap: 10, marks: false)
        let layout = Panels.layout(for: job([rect(0, 0, 700, 500)]), profile: cutter, options: options)
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.panels.map(\.name), ["A1", "A2", "B1", "B2"])
        for p in layout.panels {
            XCTAssertLessThanOrEqual(p.rect.width, 400 + 1e-9)
            XCTAssertLessThanOrEqual(p.rect.height, 300 + 1e-9)
        }
        // Width can't exceed the bed even if asked.
        XCTAssertEqual(PanelOptions(maxWidth: 900).panelWidth(for: cutter), 600)
    }

    func testClipSplitsClosedShapeAndJoinsAroundItsStart() {
        // Starts inside on the left, crosses the right edge at x = 50 and comes back.
        let square = rect(0, 0, 100, 40)
        let left = Panels.clip(square, to: Rect2(minX: -1, minY: -1, maxX: 50, maxY: 41))
        XCTAssertEqual(left.count, 1, "the piece through the start is joined into one cut")
        XCTAssertEqual(Panels.length(left), 50 + 40 + 50, accuracy: 1e-9)
        let right = Panels.clip(square, to: Rect2(minX: 50, minY: -1, maxX: 101, maxY: 41))
        XCTAssertEqual(right.count, 1)
        XCTAssertEqual(Panels.length(right), 50 + 40 + 50, accuracy: 1e-9)
        // Wholly inside: unchanged and still closed.
        XCTAssertEqual(Panels.clip(square, to: Rect2(minX: -5, minY: -5, maxX: 200, maxY: 200)), [square])
        // Wholly outside: nothing.
        XCTAssertTrue(Panels.clip(square, to: Rect2(minX: 300, minY: 0, maxX: 400, maxY: 40)).isEmpty)
    }

    func testPanelsCoverTheWholeDesignAndFitTheBed() {
        let design = [rect(0, 0, 1500, 500), rect(100, 100, 1300, 50)]
        let tp = job(design)
        let options = PanelOptions(enabled: true, overlap: 12, marks: false)
        let layout = Panels.layout(for: tp, profile: cutter, options: options)
        var total = 0.0
        for p in layout.panels {
            let out = Panels.toolpath(tp, panel: p, layout: layout, profile: cutter)
            let b = out.bounds
            XCTAssertGreaterThanOrEqual(b.minX, -1e-9)
            XCTAssertGreaterThanOrEqual(b.minY, -1e-9)
            XCTAssertLessThanOrEqual(b.maxX, cutter.bedWidth + 1e-9)
            XCTAssertLessThanOrEqual(b.maxY, cutter.bedHeight + 1e-9)
            total += length(out.layers.flatMap(\.paths))
        }
        // Everything is cut once, plus the horizontal lines again inside the two overlaps.
        let overlapExtra = 2.0 * (12 * 2 + 12 * 2)
        XCTAssertEqual(total, length(design) + overlapExtra, accuracy: 1e-6)
    }

    func testPanelIsMovedToTheOriginCorner() {
        let tp = job([rect(0, 0, 1500, 500)])
        let layout = Panels.layout(for: tp, profile: cutter, options: PanelOptions(enabled: true, marks: false))
        // Bottom-right origin: the panel's bottom-right corner lands on the bed's bottom-right corner.
        let out = Panels.toolpath(tp, panel: layout.panels[1], layout: layout, profile: cutter)
        XCTAssertEqual(out.bounds.maxX, 600, accuracy: 1e-9)
        XCTAssertEqual(out.bounds.maxY, 1000, accuracy: 1e-9)
        let inset = Panels.toolpath(tp, panel: layout.panels[1], layout: layout, profile: cutter, inset: 5)
        XCTAssertEqual(inset.bounds.maxX, 595, accuracy: 1e-9)
        XCTAssertEqual(inset.bounds.maxY, 995, accuracy: 1e-9)
    }

    func testAlignmentMarksSitInOverlapsClearOfArt() {
        // Two bands of lettering with a gap between them: marks at both ends of each seam and one in the gap.
        let design = [rect(0, 0, 1500, 100), rect(0, 300, 1500, 100)]
        let tp = job(design)
        let options = PanelOptions(enabled: true, overlap: 20, marks: true, markSize: 10)
        let layout = Panels.layout(for: tp, profile: cutter, options: options)
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.unmarkedSeams, 0)
        let segments = design.flatMap { p in (1..<p.count).map { (p[$0 - 1], p[$0]) } }
        for m in layout.marks {
            XCTAssertTrue(Panels.isClear(m, of: segments, by: Panels.markClearance(10)), "mark at \(m) touches the art")
            // Each mark is on two neighbouring panels.
            XCTAssertEqual(layout.panels.filter { layout.marks(in: $0).contains(m) }.count, 2)
        }
        for c in 0..<(layout.columns - 1) {
            let seamX = (layout.panels[c].rect.maxX + layout.panels[c + 1].rect.minX) / 2
            let onSeam = layout.marks.filter { abs($0.x - seamX) < 1e-6 }
            XCTAssertTrue(onSeam.contains { $0.y < 0 }, "mark above the sign")
            XCTAssertTrue(onSeam.contains { $0.y > 400 }, "mark below the sign")
            XCTAssertTrue(onSeam.contains { $0.y > 100 && $0.y < 300 }, "mark in the gap")
        }
        // The marks are cut on each panel, last.
        let out = Panels.toolpath(tp, panel: layout.panels[0], layout: layout, profile: cutter)
        XCTAssertEqual(out.layers.last?.layer.name, "Panel marks")
        XCTAssertEqual(out.layers.last?.paths.count, layout.marks(in: layout.panels[0]).count * 2)
    }

    func testNoMarksInsideShapes() {
        // A filled panel of vinyl (one closed outline) spanning the seams: marks only outside it.
        let tp = job([rect(0, 0, 1500, 400)])
        let layout = Panels.layout(for: tp, profile: cutter, options: PanelOptions(enabled: true, overlap: 20))
        XCTAssertFalse(layout.marks.isEmpty)
        for m in layout.marks { XCTAssertTrue(m.y < 0 || m.y > 400, "mark at \(m) is inside the shape") }
    }

    func testMirroredPanelFlipsWithinItself() {
        let tp = job([rect(0, 0, 1500, 500), [Vec2(10, 10), Vec2(20, 10)]])
        let layout = Panels.layout(for: tp, profile: cutter, options: PanelOptions(enabled: true, marks: false))
        let plain = Panels.toolpath(tp, panel: layout.panels[0], layout: layout, profile: cutter)
        let flipped = Panels.toolpath(tp, panel: layout.panels[0], layout: layout, profile: cutter, mirror: .horizontal)
        XCTAssertEqual(plain.bounds, flipped.bounds)
        XCTAssertNotEqual(plain.layers[0].paths, flipped.layers[0].paths)
    }

    func testOptionsDecodeWithDefaults() throws {
        let decoded = try JSONDecoder().decode(PanelOptions.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.overlap, PanelOptions().overlap)
        XCTAssertTrue(decoded.marks)
    }

    func testHelpHasPanelTopic() {
        XCTAssertTrue(HelpLibrary.search("overlap panels").contains { $0.id == "panels" })
    }
}
