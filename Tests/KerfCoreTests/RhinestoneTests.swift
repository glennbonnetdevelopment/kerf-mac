import Foundation
import XCTest
@testable import KerfCore

final class RhinestoneTests: XCTestCase {
    private func square(_ x: Double, _ y: Double, _ size: Double) -> Polyline {
        Polyline([Vec2(x, y), Vec2(x + size, y), Vec2(x + size, y + size), Vec2(x, y + size)], closed: true)
    }

    private func circle(_ c: Vec2, _ r: Double) -> Polyline {
        Polyline((0..<180).map { k in
            let a = 2 * Double.pi * Double(k) / 180
            return Vec2(c.x + r * cos(a), c.y + r * sin(a))
        }, closed: true)
    }

    /// The closest any two stones come, edge to edge.
    private func closestGap(_ stones: [Stone]) -> Double {
        var best = Double.infinity
        for i in stones.indices {
            for j in stones.indices where j > i {
                let d = stones[i].center.distance(to: stones[j].center) - stones[i].radius - stones[j].radius
                best = min(best, d)
            }
        }
        return best
    }

    func testSizesRunFromSS6ToSS20() {
        XCTAssertEqual(StoneSize.all.first?.name, "SS6")
        XCTAssertEqual(StoneSize.all.last?.name, "SS20")
        let d = StoneSize.all.map(\.diameter)
        XCTAssertEqual(d, d.sorted())
        XCTAssertEqual(Set(StoneSize.all.map(\.name)).count, StoneSize.all.count)
        XCTAssertEqual(Set(StoneColor.palette.map(\.name)).count, StoneColor.palette.count)
    }

    func testOutlineOnlySquareIsEvenAndInside() {
        let o = RhinestoneOptions(outline: true, outlineSize: .ss10, fill: .none, spacing: 1)
        let stones = Rhinestone.layout([square(0, 0, 50)], options: o)
        // Inset square side ≈ 47.2 mm, perimeter ≈ 189 mm, pitch 3.8 mm → about 49 stones.
        XCTAssertGreaterThan(stones.count, 40)
        XCTAssertLessThanOrEqual(stones.count, 52)
        XCTAssertTrue(stones.allSatisfy { $0.role == .outline && $0.size == .ss10 })
        XCTAssertGreaterThanOrEqual(closestGap(stones), 1 * Rhinestone.minimumGapFraction - 1e-5)
        for s in stones {
            XCTAssertGreaterThanOrEqual(s.center.x - s.radius, -0.5)
            XCTAssertLessThanOrEqual(s.center.x + s.radius, 50.5)
            XCTAssertGreaterThanOrEqual(s.center.y - s.radius, -0.5)
            XCTAssertLessThanOrEqual(s.center.y + s.radius, 50.5)
        }
        // Loops start at their sharpest corner, so at least one corner gets a stone.
        let corners = [Vec2(1.4, 1.4), Vec2(48.6, 1.4), Vec2(48.6, 48.6), Vec2(1.4, 48.6)]
        XCTAssertTrue(corners.contains { c in stones.contains { $0.center.distance(to: c) < 1.0 } })
    }

    func testHoneycombFillStaysInsideWithoutOverlaps() {
        let o = RhinestoneOptions(outline: false, fill: .honeycomb, fillSize: .ss12, spacing: 1)
        let c = Vec2(30, 30)
        let stones = Rhinestone.layout([circle(c, 20)], options: o)
        // Area 1257 mm², about 14.6 mm² per stone at this pitch.
        XCTAssertGreaterThan(stones.count, 55)
        XCTAssertLessThan(stones.count, 95)
        for s in stones { XCTAssertLessThanOrEqual(s.center.distance(to: c) + s.radius, 20.01) }
        XCTAssertGreaterThanOrEqual(closestGap(stones), 0.6 - 1e-5)
    }

    func testHolesInShapesStayEmpty() {
        let ring = [square(0, 0, 60), square(20, 20, 20)]
        for fill in [RhinestoneFill.honeycomb, .grid, .contour] {
            let o = RhinestoneOptions(outline: true, fill: fill, spacing: 1)
            let stones = Rhinestone.layout(ring, options: o)
            XCTAssertGreaterThan(stones.count, 50, "\(fill)")
            for s in stones {
                let inHole = s.center.x > 20 + 0.1 && s.center.x < 40 - 0.1 && s.center.y > 20 + 0.1 && s.center.y < 40 - 0.1
                XCTAssertFalse(inHole, "\(fill) stone at \(s.center)")
            }
            XCTAssertGreaterThanOrEqual(closestGap(stones), 0.6 - 1e-5, "\(fill)")
        }
    }

    func testOutlineAndFillCanUseDifferentStones() {
        let o = RhinestoneOptions(outline: true, outlineSize: .ss16, outlineColor: .jet,
                                  fill: .honeycomb, fillSize: .ss8, fillColor: .crystal, spacing: 1)
        let stones = Rhinestone.layout([square(0, 0, 40)], options: o)
        let groups = Rhinestone.groups(stones)
        XCTAssertEqual(groups.map(\.title), ["SS16 Jet", "SS8 Crystal"])
        XCTAssertTrue(groups[0].stones.allSatisfy { $0.role == .outline })
        XCTAssertTrue(groups[1].stones.allSatisfy { $0.role == .fill })
        XCTAssertGreaterThanOrEqual(closestGap(stones), 0.6 - 1e-5)
    }

    func testGapFillAddsSmallStones() {
        let base = RhinestoneOptions(outline: true, outlineSize: .ss20, fill: .grid, fillSize: .ss20, spacing: 1)
        var withGaps = base
        withGaps.gapFill = true
        withGaps.gapFillSize = .ss6
        let shape = [circle(Vec2(25, 25), 22)]
        let plain = Rhinestone.layout(shape, options: base)
        let filled = Rhinestone.layout(shape, options: withGaps)
        let small = filled.filter { $0.role == .gap }
        XCTAssertFalse(small.isEmpty)
        XCTAssertTrue(small.allSatisfy { $0.size == .ss6 })
        XCTAssertEqual(filled.count - small.count, plain.count)
        XCTAssertGreaterThanOrEqual(closestGap(filled), 0.6 - 1e-5)
    }

    func testOpenLineGetsStonesEndToEnd() {
        let o = RhinestoneOptions(outline: true, outlineSize: .ss10, fill: .honeycomb, spacing: 1)
        let line = Polyline([Vec2(0, 0), Vec2(38, 0)])
        let stones = Rhinestone.layout([line], options: o)
        XCTAssertEqual(stones.count, 11)
        XCTAssertEqual(stones.first?.center.x ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(stones.last?.center.x ?? -1, 38, accuracy: 1e-6)
    }

    func testTinyLoopGetsOneStone() {
        // Like the dot of an i: too small for a ring of stones.
        let o = RhinestoneOptions(outline: true, outlineSize: .ss10, fill: .none, spacing: 1)
        let stones = Rhinestone.layout([circle(Vec2(5, 5), 2)], options: o)
        XCTAssertEqual(stones.count, 1)
        XCTAssertEqual(stones[0].center.distance(to: Vec2(5, 5)), 0, accuracy: 0.05)
    }

    func testHolesAreClosedCirclesWithClearance() {
        let stones = [Stone(center: Vec2(10, 10), size: .ss10, color: .crystal, role: .fill),
                      Stone(center: Vec2(20, 10), size: .ss20, color: .jet, role: .outline)]
        let holes = Rhinestone.holes(stones, clearance: 0.2)
        XCTAssertEqual(holes.count, 2)
        XCTAssertTrue(holes.allSatisfy(\.closed))
        XCTAssertEqual(holes[0].bounds.width, 3.0, accuracy: 0.02)
        XCTAssertEqual(holes[1].bounds.width, 4.9, accuracy: 0.02)
        XCTAssertEqual(holes[0].bounds.center.distance(to: Vec2(10, 10)), 0, accuracy: 0.01)
    }

    func testOptionsDecodeWithMissingKeys() throws {
        let decoded = try JSONDecoder().decode(RhinestoneOptions.self, from: Data(#"{"fill":"grid","spacing":1.5}"#.utf8))
        XCTAssertEqual(decoded.fill, .grid)
        XCTAssertEqual(decoded.spacing, 1.5)
        XCTAssertEqual(decoded.outlineSize, .ss10)
        let round = try JSONDecoder().decode(RhinestoneOptions.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(round, decoded)
    }

    func testEmptyInputGivesNoStones() {
        XCTAssertTrue(Rhinestone.layout([], options: RhinestoneOptions()).isEmpty)
        XCTAssertTrue(Rhinestone.layout([Polyline([Vec2(1, 1)])], options: RhinestoneOptions()).isEmpty)
    }
}
