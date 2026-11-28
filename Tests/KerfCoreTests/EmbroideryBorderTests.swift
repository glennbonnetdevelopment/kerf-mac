import XCTest
@testable import KerfCore

final class EmbroideryBorderTests: XCTestCase {
    private let square = Polyline([Vec2(0, 0), Vec2(40, 0), Vec2(40, 40), Vec2(0, 40)], closed: true)

    private func runs(_ s: EmbroiderySettings, paths: [Polyline]? = nil) -> [[Vec2]] {
        var cursor = Vec2.zero
        let shape = Artwork(layerID: UUID(), name: "s", paths: paths ?? [square])
        return EmbroideryPlanner.layerRuns([shape], settings: s.sanitized, cursor: &cursor)
    }

    /// Distance from a point to the square's outline.
    private func edgeDistance(_ p: Vec2) -> Double {
        min(abs(p.x), abs(p.x - 40), abs(p.y), abs(p.y - 40))
    }

    func testFillWithBorderSewsBothFillFirst() {
        let fillOnly = EmbroiderySettings(stitchType: .fill)
        var both = fillOnly
        both.border = EmbroideryBorder(stitch: .satin, width: 3)
        let a = runs(fillOnly), b = runs(both)
        XCTAssertGreaterThan(b.count, a.count)
        // The fill comes first, unchanged, then the border hugs the outline.
        XCTAssertEqual(Array(b.prefix(a.count)), a)
        let border = b.dropFirst(a.count).flatMap { $0 }
        XCTAssertFalse(border.isEmpty)
        XCTAssertTrue(border.allSatisfy { edgeDistance($0) < 2.5 }, "border strays from the outline")
    }

    func testEveryBorderStitchWorksWithEveryFill() {
        let fills: [EmbroiderySettings] = [
            EmbroiderySettings(stitchType: .auto),
            EmbroiderySettings(stitchType: .satinColumns),
        ] + FillType.allCases.map { EmbroiderySettings(stitchType: .fill).withFillType($0) }
        for base in fills {
            let plain = runs(base).flatMap { $0 }.count
            for stitch in BorderStitch.allCases {
                var s = base
                s.border = EmbroideryBorder(stitch: stitch)
                XCTAssertGreaterThan(runs(s).flatMap { $0 }.count, plain, "\(base.summary) \(stitch)")
            }
        }
    }

    func testBorderSewsOpenLinesThatFillSkips() {
        let open = Polyline([Vec2(0, 0), Vec2(30, 10)], closed: false)
        var s = EmbroiderySettings(stitchType: .fill)
        XCTAssertTrue(runs(s, paths: [open]).isEmpty)
        s.border = EmbroideryBorder(stitch: .running)
        XCTAssertFalse(runs(s, paths: [open]).isEmpty)
    }

    func testLineStitchesHaveNoSeparateBorder() {
        var s = EmbroiderySettings(stitchType: .running)
        s.border = EmbroideryBorder()
        XCTAssertFalse(s.hasFill)
        XCTAssertNil(s.sanitized.border)
        XCTAssertEqual(runs(s), runs(EmbroiderySettings(stitchType: .running)))
    }

    func testBorderSavesAndOldFilesHaveNone() throws {
        var s = EmbroiderySettings(stitchType: .fill).withFillType(.satin)
        s.border = EmbroideryBorder(stitch: .bean, stitchLength: 2, width: 4, lineStyle: .chain)
        let back = try JSONDecoder().decode(EmbroiderySettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let old = try JSONDecoder().decode(EmbroiderySettings.self, from: Data(#"{"stitchType":"fill"}"#.utf8))
        XCTAssertNil(old.border)
        let partial = try JSONDecoder().decode(EmbroiderySettings.self,
                                               from: Data(#"{"stitchType":"fill","border":{"stitch":"running"}}"#.utf8))
        XCTAssertEqual(partial.border?.stitch, .running)
        XCTAssertEqual(partial.border?.stitchLength, 2.5)
    }

    func testBorderConvertsToAndFromLineSettings() {
        let b = EmbroideryBorder(stitch: .satin, stitchLength: 2, width: 3.5, density: 0.35, lineStyle: .rope,
                                 underlay: false, pullCompensation: 0.3)
        XCTAssertEqual(b.settings.stitchType, .satin)
        XCTAssertEqual(EmbroideryBorder(settings: b.settings), b)
        XCTAssertEqual(EmbroideryBorder(settings: EmbroiderySettings(stitchType: .fill)).stitch, .satin)
    }

    func testSummaryNamesTheBorder() {
        var s = EmbroiderySettings(stitchType: .fill)
        s.border = EmbroideryBorder(stitch: .satin)
        XCTAssertEqual(s.summary, "Tatami fill + satin border")
    }
}
