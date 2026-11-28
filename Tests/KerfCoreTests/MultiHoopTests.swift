import XCTest
@testable import KerfCore

final class MultiHoopTests: XCTestCase {
    let hoop = EmbroideryHoop("Test 100 × 100", brand: "Test", width: 100, height: 100)

    /// A plan of horizontal running-stitch rows filling a w × h rectangle.
    func rows(width w: Double, height h: Double, spacing: Double = 5) -> EmbroideryPlan {
        var runs: [[Vec2]] = []
        var y = 0.0
        while y <= h {
            runs.append(EmbroideryPlanner.running([Vec2(0, y), Vec2(w, y)], length: 2.5))
            y += spacing
        }
        return EmbroideryPlan(blocks: [StitchBlock(color: ThreadColor(hex: "#000000"), name: "Black", runs: runs)])
    }

    func testCountAlongOneSide() {
        XCTAssertEqual(MultiHoop.count(length: 80, usable: 90, overlap: 10), 1)
        XCTAssertEqual(MultiHoop.count(length: 170, usable: 90, overlap: 10), 2)
        XCTAssertEqual(MultiHoop.count(length: 171, usable: 90, overlap: 10), 3)
        XCTAssertEqual(MultiHoop.count(length: 250, usable: 90, overlap: 10), 3)
    }

    func testSmallDesignIsOneHooping() {
        let layout = MultiHoop.split(rows(width: 60, height: 40), hoop: hoop, options: MultiHoopOptions())
        XCTAssertEqual(layout.count, 1)
        XCTAssertTrue(layout.hoopings[0].marks.isEmpty)
        XCTAssertEqual(layout.sewnHoopings.count, 1)
    }

    func testWideDesignSplitsIntoOverlappingHoopings() {
        let plan = rows(width: 250, height: 60)
        let o = MultiHoopOptions(overlap: 10, margin: 5)
        let layout = MultiHoop.split(plan, hoop: hoop, options: o)
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.rows, 1)
        for h in layout.hoopings {
            XCTAssertEqual(h.area.width, 90, accuracy: 1e-9)
            // Every stitch of every hooping lies inside its sewing area.
            for block in h.plan.blocks {
                for run in block.runs {
                    for p in run { XCTAssertTrue(h.area.contains(Rect2(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y), tolerance: 1e-6)) }
                }
            }
            // Each machine pattern fits the hoop once centred on it.
            let size = MultiHoop.pattern(h, name: "t").extent
            XCTAssertLessThanOrEqual(Double(max(abs(size.minX), abs(size.maxX))), 500)
            XCTAssertLessThanOrEqual(Double(max(abs(size.minY), abs(size.maxY))), 500)
        }
        // Neighbours overlap by the set amount and the areas cover the design.
        XCTAssertEqual(layout.hoopings[0].area.maxX - layout.hoopings[1].area.minX, 10, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(layout.hoopings[0].area.minX, plan.bounds.minX)
        XCTAssertGreaterThanOrEqual(layout.hoopings[2].area.maxX, plan.bounds.maxX)
    }

    func testSplitKeepsEveryStitch() {
        let plan = rows(width: 250, height: 60)
        let layout = MultiHoop.split(plan, hoop: hoop, options: MultiHoopOptions(alignmentMarks: false))
        // Every original stitch point turns up in some hooping.
        let sewn = Set(layout.hoopings.flatMap { $0.plan.blocks.flatMap { $0.runs.flatMap { $0 } } })
        for run in plan.blocks[0].runs {
            for p in run { XCTAssertTrue(sewn.contains(p), "missing \(p)") }
        }
    }

    func testSmallShapesStayWhole() {
        // Two short runs straddling where a seam would be cut, each small enough for one hooping.
        let a = EmbroideryPlanner.running([Vec2(0, 0), Vec2(30, 0)], length: 2)
        let wide = EmbroideryPlanner.running([Vec2(0, 20), Vec2(250, 20)], length: 2)
        let plan = EmbroideryPlan(blocks: [StitchBlock(color: ThreadColor(hex: "#FF0000"), name: "Red", runs: [a, wide])])
        let layout = MultiHoop.split(plan, hoop: hoop, options: MultiHoopOptions(alignmentMarks: false))
        let holders = layout.hoopings.filter { h in h.plan.blocks.contains { $0.runs.contains(a) } }
        XCTAssertEqual(holders.count, 1)
    }

    func testAlignmentMarksAreSharedByNeighbours() {
        let layout = MultiHoop.split(rows(width: 170, height: 170), hoop: hoop, options: MultiHoopOptions(overlap: 10, margin: 5))
        XCTAssertEqual(layout.count, 4)
        // A 2 × 2 grid has 4 shared edges with 2 marks each; every hooping touches 2 edges.
        for h in layout.hoopings {
            XCTAssertEqual(h.marks.count, 4)
            XCTAssertEqual(h.plan.blocks.first?.name, MultiHoop.marksBlockName)
            for m in h.marks { XCTAssertTrue(h.area.contains(m)) }
        }
        XCTAssertEqual(Set(layout.hoopings[0].marks).intersection(layout.hoopings[1].marks).count, 2)
        XCTAssertEqual(Set(layout.hoopings[0].marks).intersection(layout.hoopings[2].marks).count, 2)
        XCTAssertTrue(Set(layout.hoopings[0].marks).isDisjoint(with: layout.hoopings[3].marks))
    }

    func testAutoOrientationTurnsHoopWhenItSavesHoopings() {
        let tall = EmbroideryHoop("Tall", brand: "Test", width: 130, height: 180)
        let plan = rows(width: 300, height: 100)
        let auto = MultiHoop.split(plan, hoop: tall, options: MultiHoopOptions(orientation: .auto))
        let upright = MultiHoop.split(plan, hoop: tall, options: MultiHoopOptions(orientation: .upright))
        XCTAssertTrue(auto.turned)
        XCTAssertLessThan(auto.count, upright.count)
        XCTAssertEqual(auto.hoopWidth, 180)
    }

    func testBastingAndEmptyHoopings() {
        // An L shape: the bottom-right hooping of a 2 × 2 grid has nothing of the design in it.
        let top = EmbroideryPlanner.running([Vec2(0, 0), Vec2(170, 0)], length: 2)
        let left = EmbroideryPlanner.running([Vec2(0, 0), Vec2(0, 170)], length: 2)
        let plan = EmbroideryPlan(blocks: [StitchBlock(color: ThreadColor(hex: "#000000"), name: "Black", runs: [top, left])])
        let layout = MultiHoop.split(plan, hoop: hoop, options: MultiHoopOptions(basting: true))
        XCTAssertEqual(layout.count, 4)
        XCTAssertEqual(layout.sewnHoopings.count, 3)
        XCTAssertEqual(layout.hoopings[0].plan.blocks.first?.name, MultiHoop.bastingBlockName)
    }

    func testPatternIsCentredOnHoop() {
        let plan = EmbroideryPlan(blocks: [StitchBlock(color: ThreadColor(hex: "#000000"), name: "Black",
                                                      runs: [[Vec2(10, 10), Vec2(20, 10)]])])
        let p = StitchPattern(plan: plan, name: "t", center: Vec2(0, 0))
        let firstStitch = p.entries.first { $0.command == .stitch || $0.command == .jump }
        XCTAssertEqual(firstStitch?.x, 100)
        XCTAssertEqual(firstStitch?.y, 100)
    }

    func testGuideListsEachHooping() {
        let layout = MultiHoop.split(rows(width: 250, height: 60), hoop: hoop, options: MultiHoopOptions())
        let names = Dictionary(uniqueKeysWithValues: layout.sewnHoopings.enumerated().map { ($1.index, "D \($0 + 1) of 3.pes") })
        let text = MultiHoop.guide(layout, name: "D", fileNames: names, hoop: hoop, options: MultiHoopOptions())
        XCTAssertTrue(text.contains("D 1 of 3.pes"))
        XCTAssertTrue(text.contains("D 3 of 3.pes"))
        XCTAssertTrue(text.contains("alignment crosses"))
    }

    func testClipStopsAtArea() {
        let r = Rect2(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let p = MultiHoop.clip(from: Vec2(5, 5), to: Vec2(15, 5), in: r)
        XCTAssertEqual(p.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p.y, 5, accuracy: 1e-9)
    }
}
