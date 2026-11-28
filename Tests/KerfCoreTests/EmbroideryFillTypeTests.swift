import XCTest
@testable import KerfCore

final class EmbroideryFillTypeTests: XCTestCase {
    private let square = Polyline([Vec2(0, 0), Vec2(40, 0), Vec2(40, 40), Vec2(0, 40)], closed: true)

    private func settings(_ type: FillType, angle: Double = 0) -> EmbroiderySettings {
        var s = EmbroiderySettings(stitchType: .fill, fillAngle: angle, underlay: false, pullCompensation: 0)
            .withFillType(type)
        s.fillStitchLength = 3.5
        return s.sanitized
    }

    private func stitches(_ runs: [[Vec2]]) -> [Double] {
        runs.flatMap { run in run.indices.dropFirst().map { run[$0].distance(to: run[$0 - 1]) } }
    }

    func testEveryFillTypeSewsInsideTheShape() {
        for type in FillType.allCases {
            for pattern in type.patterns {
                var s = settings(type, angle: 30)
                s.fillPattern = pattern
                let runs = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
                XCTAssertFalse(runs.isEmpty, "\(type) \(pattern)")
                for p in runs.flatMap({ $0 }) {
                    XCTAssertTrue(p.x > -0.3 && p.x < 40.3 && p.y > -0.3 && p.y < 40.3, "\(type) \(pattern) \(p)")
                }
                XCTAssertLessThanOrEqual(stitches(runs).max() ?? 0, 7.01, "\(type) \(pattern)")
            }
        }
        for pattern in EmbossPattern.allCases {
            var s = settings(.embossed, angle: 45)
            s.embossPattern = pattern
            let runs = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
            XCTAssertFalse(runs.isEmpty, pattern.rawValue)
            XCTAssertLessThanOrEqual(stitches(runs).max() ?? 0, 3.51, pattern.rawValue)
        }
    }

    func testPlainTatamiSewsAsBefore() {
        // The default fill must not change for existing designs.
        let s = EmbroiderySettings(stitchType: .fill).sanitized
        let now = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
        var before = EmbroideryPlanner.fill([square], angle: 45 + 90, spacing: max(1.5, 0.4 * 5), stitchLength: 3.5,
                                            extend: -0.6, from: .zero)
        before += EmbroideryPlanner.fill([square], angle: 45, spacing: 0.4, stitchLength: 3.5, extend: 0.1,
                                         from: before.last?.last ?? .zero)
        XCTAssertEqual(now, before.filter { $0.count >= 2 })
    }

    func testSatinFillSplitsWideRowsWithStaggeredSplits() {
        var s = settings(.satin)
        s.satinSplitLength = 7
        let runs = EmbroideryPlanner.patternFill([square], settings: s, from: .zero)
        let lengths = stitches(runs)
        XCTAssertLessThanOrEqual(lengths.max() ?? 0, 7.01)
        // 40 mm rows in six pieces of about 6.7 mm, except the short end pieces of shifted rows.
        XCTAssertGreaterThan(lengths.filter { $0 > 5 }.count, lengths.count / 3)

        // Split points of neighbouring rows don't line up.
        let a = EmbroideryPlanner.satinRow(from: 0, to: 40, y: 0, row: 0, split: 7).map(\.x)
        let b = EmbroideryPlanner.satinRow(from: 0, to: 40, y: 0.4, row: 1, split: 7).map(\.x)
        let innerA = Set(a.dropFirst().dropLast().map { ($0 * 10).rounded() })
        let innerB = Set(b.dropFirst().dropLast().map { ($0 * 10).rounded() })
        XCTAssertFalse(innerA.isEmpty)
        XCTAssertTrue(innerA.isDisjoint(with: innerB))
    }

    func testNarrowSatinIsOneStitchPerRow() {
        let narrow = Polyline([Vec2(0, 0), Vec2(5, 0), Vec2(5, 30), Vec2(0, 30)], closed: true)
        let runs = EmbroideryPlanner.patternFill([narrow], settings: settings(.satin), from: .zero)
        let row = EmbroideryPlanner.satinRow(from: 0, to: 5, y: 0, row: 2, split: 7)
        XCTAssertEqual(row.count, 2)
        XCTAssertGreaterThan(stitches(runs).filter { $0 > 4.9 }.count, 50)
    }

    func testEmbossedFillHasGrooves() {
        let plain = stitches(EmbroideryPlanner.patternFill([square], settings: settings(.tatami, angle: 45), from: .zero))
        var s = settings(.embossed, angle: 45)
        s.embossPattern = .diamonds
        s.patternSize = 6
        let embossed = stitches(EmbroideryPlanner.patternFill([square], settings: s, from: .zero))
        let shortPlain = plain.filter { $0 < 0.8 }.count, shortEmbossed = embossed.filter { $0 < 0.8 }.count
        XCTAssertGreaterThan(shortEmbossed, shortPlain + 200)
    }

    func testTatamiOffsets() {
        XCTAssertEqual(TatamiOffset.half.fraction(0), 0)
        XCTAssertEqual(TatamiOffset.half.fraction(1), 0.5)
        XCTAssertEqual(TatamiOffset.half.fraction(2), 0)
        XCTAssertEqual(TatamiOffset.quarter.fraction(3), 0.75)
        XCTAssertEqual(TatamiOffset.third.fraction(-1), 2.0 / 3)
        let random = (0..<50).map { TatamiOffset.random.fraction($0) }
        XCTAssertTrue(random.allSatisfy { $0 >= 0.1 && $0 < 0.9 })
        XCTAssertGreaterThan(Set(random).count, 30)
        XCTAssertEqual(random, (0..<50).map { TatamiOffset.random.fraction($0) })

        // A brick offset puts every other row's holes halfway between.
        let r0 = EmbroideryPlanner.tatamiRow(from: 0, to: 30, y: 0, row: 0, length: 4, offset: .half).map(\.x)
        let r1 = EmbroideryPlanner.tatamiRow(from: 0, to: 30, y: 0, row: 1, length: 4, offset: .half).map(\.x)
        XCTAssertTrue(r0.contains(8) && r1.contains(10))
    }

    func testFillTypesSaveAndOldFilesOpen() throws {
        var s = EmbroiderySettings(stitchType: .fill).withFillType(.embossed)
        s.embossPattern = .rings
        s.tatamiOffset = .random
        s.satinSplitLength = 5
        let back = try JSONDecoder().decode(EmbroiderySettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)

        let hearts = try JSONDecoder().decode(EmbroiderySettings.self,
                                              from: Data(#"{"stitchType":"fill","fillPattern":"hearts"}"#.utf8))
        XCTAssertEqual(hearts.fillType, .motif)
        let waves = try JSONDecoder().decode(EmbroiderySettings.self,
                                             from: Data(#"{"stitchType":"fill","fillPattern":"waves"}"#.utf8))
        XCTAssertEqual(waves.fillType, .tatami)
        XCTAssertEqual(waves.tatamiOffset, .third)
    }

    func testSwitchingTypeKeepsPatternsThatFit() {
        let tatami = EmbroiderySettings(stitchType: .fill, fillPattern: .waves)
        XCTAssertEqual(tatami.fillType, .tatami)
        XCTAssertEqual(tatami.withFillType(.motif).fillPattern, .stars)
        XCTAssertEqual(tatami.withFillType(.satin).fillPattern, .tatami)
        let hearts = EmbroiderySettings(stitchType: .fill, fillPattern: .hearts)
        XCTAssertEqual(hearts.withFillType(.motif).fillPattern, .hearts)
        var odd = hearts
        odd.fillType = .tatami
        XCTAssertEqual(odd.sanitized.fillPattern, .tatami)
    }

    func testSummary() {
        XCTAssertEqual(EmbroiderySettings(stitchType: .fill).summary, "Tatami fill")
        XCTAssertEqual(EmbroiderySettings(stitchType: .fill, fillPattern: .hearts).summary, "Motif fill, hearts")
        XCTAssertEqual(EmbroiderySettings(stitchType: .fill).withFillType(.satin).summary, "Satin fill")
        XCTAssertEqual(EmbroiderySettings(stitchType: .running, lineStyle: .rope).summary, "Running stitch · Rope")
    }
}
