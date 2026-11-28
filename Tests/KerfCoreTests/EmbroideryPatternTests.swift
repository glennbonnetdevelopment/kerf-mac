import XCTest
@testable import KerfCore

final class EmbroideryPatternTests: XCTestCase {
    private let square = Polyline([Vec2(0, 0), Vec2(40, 0), Vec2(40, 40), Vec2(0, 40)], closed: true)

    private func fillSettings(_ pattern: FillPattern) -> EmbroiderySettings {
        EmbroiderySettings(stitchType: .fill, underlay: false, pullCompensation: 0, fillPattern: pattern).sanitized
    }

    private func assertInside(_ runs: [[Vec2]], _ lo: Double, _ hi: Double, slack: Double = 0.05,
                              file: StaticString = #filePath, line: UInt = #line) {
        for p in runs.flatMap({ $0 }) {
            XCTAssertTrue(p.x > lo - slack && p.x < hi + slack && p.y > lo - slack && p.y < hi + slack, "\(p)",
                          file: file, line: line)
        }
    }

    private func longestStitch(_ runs: [[Vec2]]) -> Double {
        var m = 0.0
        for run in runs { for i in run.indices.dropFirst() { m = max(m, run[i].distance(to: run[i - 1])) } }
        return m
    }

    func testEveryFillPatternSewsInsideTheShape() {
        for pattern in FillPattern.allCases {
            let runs = EmbroideryPlanner.patternFill([square], settings: fillSettings(pattern), from: .zero)
            XCTAssertFalse(runs.isEmpty, pattern.rawValue)
            assertInside(runs, 0, 40, slack: 0.3)
            XCTAssertLessThanOrEqual(longestStitch(runs), 7.01, pattern.rawValue)
        }
    }

    func testWaveRowsBend() {
        var s = fillSettings(.waves)
        s.fillAngle = 0
        s.patternSize = 8
        let runs = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
        // Stitches along a wavy row change height; plain rows keep one height each.
        let ys = Set(runs.flatMap { $0 }.map { ($0.y * 10).rounded() })
        let plain = EmbroideryPlanner.patternFill([square], settings: fillSettings(.tatami).with { $0.fillAngle = 0 }, from: .zero)
        let plainYs = Set(plain.flatMap { $0 }.map { ($0.y * 10).rounded() })
        XCTAssertGreaterThan(ys.count, plainYs.count * 2)
    }

    func testZigzagHolesLandOnThePoints() {
        var s = fillSettings(.zigzag)
        s.fillAngle = 0
        s.patternSize = 8
        let runs = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
        // Peaks are at x = 2, 10, 18…: stitches land there.
        let xs = Set(runs.flatMap { $0 }.map { ($0.x * 100).rounded() })
        XCTAssertTrue(xs.contains(200) && xs.contains(1000) && xs.contains(1800))
    }

    func testOpenLinesAreSpacedApart() {
        var s = fillSettings(.lines)
        s.fillAngle = 0
        s.patternSpacing = 4
        let runs = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
        let rows = Set(runs.flatMap { $0 }.map { ($0.y * 100).rounded() })
        // Ten rows 4 mm apart, plus the short links between them at the edges.
        let rowYs = rows.filter { y in runs.flatMap { $0 }.filter { ($0.y * 100).rounded() == y }.count > 5 }
        XCTAssertEqual(rowYs.count, 10)
    }

    func testCrosshatchSewsTwoDirections() {
        var s = fillSettings(.crosshatch)
        s.fillAngle = 0
        let runs = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
        var horizontal = 0, vertical = 0
        for run in runs {
            for i in run.indices.dropFirst() {
                let d = run[i] - run[i - 1]
                if abs(d.y) < 1e-6 && abs(d.x) > 0.5 { horizontal += 1 }
                if abs(d.x) < 1e-6 && abs(d.y) > 0.5 { vertical += 1 }
            }
        }
        XCTAssertGreaterThan(horizontal, 50)
        XCTAssertGreaterThan(vertical, 50)
    }

    func testMotifsAreWholeAndJoinedInRows() {
        var s = fillSettings(.stars)
        s.patternSize = 8
        s.patternSpacing = 2
        let runs = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
        assertInside(runs, 0, 40)
        // Rows are joined, so far fewer runs (trims) than stars.
        let stitches = runs.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(stitches, 200)
        XCTAssertLessThan(runs.count, 4)
    }

    func testMotifsSkipHoles() {
        let hole = Polyline([Vec2(10, 10), Vec2(30, 10), Vec2(30, 30), Vec2(10, 30)], closed: true)
        var s = fillSettings(.circles)
        s.patternSize = 5
        let runs = EmbroideryPlanner.patternFill([square, hole], settings: s, from: .zero)
        XCTAssertFalse(runs.isEmpty)
        // Links may cross the hole's edge only if they stay inside, so nothing is sewn deep inside the hole.
        XCTAssertFalse(runs.flatMap { $0 }.contains { $0.x > 10.5 && $0.x < 29.5 && $0.y > 10.5 && $0.y < 29.5 })
    }

    func testTinyShapeWithMotifsIsOutlined() {
        let small = Polyline([Vec2(0, 0), Vec2(3, 0), Vec2(3, 3), Vec2(0, 3)], closed: true)
        let runs = EmbroideryPlanner.patternFill([small], settings: fillSettings(.hearts), from: .zero)
        XCTAssertEqual(runs.count, 1)
    }

    func testEveryLineStyleFollowsTheLine() {
        let line = [Vec2(0, 0), Vec2(30, 0)]
        let s = EmbroiderySettings(stitchType: .running, satinWidth: 3, underlay: false).sanitized
        for style in LineStyle.allCases {
            let runs = EmbroideryPlanner.styledLine(line, style: style, width: 3, settings: s)
            XCTAssertEqual(runs.count, 1, style.rawValue)
            let pts = runs[0]
            XCTAssertGreaterThan(pts.count, 5, style.rawValue)
            for p in pts {
                XCTAssertTrue(p.x > -0.01 && p.x < 30.01, "\(style) \(p)")
                // Blanket teeth stand on one side, the full width; the others are centred.
                XCTAssertLessThanOrEqual(abs(p.y), style == .blanket ? 3.01 : 1.51, "\(style) \(p)")
            }
            XCTAssertLessThanOrEqual(longestStitch(runs), 7.01)
            XCTAssertGreaterThan(pts.last!.x, 27, "\(style) should reach the end")
        }
    }

    func testRopeStitchesSlant() {
        let s = EmbroiderySettings(stitchType: .satin, satinWidth: 3, density: 0.4, underlay: false).sanitized
        let pts = EmbroideryPlanner.styledLine([Vec2(0, 0), Vec2(30, 0)], style: .rope, width: 3, settings: s)[0]
        // Stitches from the left side to the right side lean forward by about the column width.
        var leans: [Double] = []
        for i in pts.indices.dropFirst() where pts[i - 1].y > 0 && pts[i].y < 0 && pts[i].x < 25 {
            leans.append(pts[i].x - pts[i - 1].x)
        }
        XCTAssertGreaterThan(leans.count, 20)
        XCTAssertGreaterThan(leans.reduce(0, +) / Double(leans.count), 2)
    }

    func testTripleStyleSewsEachStitchThreeTimes() {
        let s = EmbroiderySettings(stitchType: .bean).sanitized
        let single = EmbroideryPlanner.styledLine([Vec2(0, 0), Vec2(20, 0)], style: .zigzag, width: 3, settings: s)[0]
        let triple = EmbroideryPlanner.styledLine([Vec2(0, 0), Vec2(20, 0)], style: .zigzag, width: 3, settings: s, triple: true)[0]
        XCTAssertEqual(triple.count, (single.count - 1) * 3 + 1)
    }

    func testLayerWithPatternAndStyleIsPlanned() {
        var d = KerfDocument()
        var fillLayer = Layer(name: "F", colorHex: "#FF0000", mode: .fill)
        fillLayer.embroidery = EmbroiderySettings(stitchType: .fill, fillPattern: .hearts)
        var lineLayer = Layer(name: "L", colorHex: "#0000FF", mode: .line)
        lineLayer.embroidery = EmbroiderySettings(stitchType: .running, lineStyle: .chain)
        d.layers = [fillLayer, lineLayer]
        d.shapes = [Artwork(layerID: fillLayer.id, name: "f", paths: [square]),
                    Artwork(layerID: lineLayer.id, name: "l", paths: [square])]
        let plan = EmbroideryPlanner.plan(d)
        XCTAssertEqual(plan.blocks.count, 2)
        XCTAssertFalse(plan.blocks[0].runs.isEmpty)
        XCTAssertFalse(plan.blocks[1].runs.isEmpty)
    }

    func testPatternSettingsSaveAndOldSettingsOpen() throws {
        let s = EmbroiderySettings(stitchType: .fill, fillPattern: .flowers, lineStyle: .rope, patternSize: 9, patternSpacing: 3)
        let back = try JSONDecoder().decode(EmbroiderySettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let old = try JSONDecoder().decode(EmbroiderySettings.self, from: Data(#"{"stitchType":"fill"}"#.utf8))
        XCTAssertEqual(old.fillPattern, .tatami)
        XCTAssertEqual(old.lineStyle, .plain)
        let future = try JSONDecoder().decode(EmbroiderySettings.self,
                                              from: Data(#"{"stitchType":"fill","fillPattern":"unicorns"}"#.utf8))
        XCTAssertEqual(future.fillPattern, .tatami)
    }
}

private extension EmbroiderySettings {
    func with(_ change: (inout EmbroiderySettings) -> Void) -> EmbroiderySettings {
        var s = self
        change(&s)
        return s
    }
}
