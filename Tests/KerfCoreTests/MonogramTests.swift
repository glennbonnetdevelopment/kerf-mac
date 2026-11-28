import XCTest
@testable import KerfCore

final class MonogramTests: XCTestCase {
    /// Stand-in for the font outliner: each character is a box 0.7 × 1 of the height, side by side; curved text
    /// is just offset so it differs.
    func outline(_ spec: TextSpec) -> [Polyline] {
        var out: [Polyline] = []
        let h = spec.height, w = h * 0.7
        for (i, _) in spec.text.enumerated() {
            let x = Double(i) * w * 1.1
            out.append(Polyline([Vec2(x, 0), Vec2(x + w, 0), Vec2(x + w, h), Vec2(x, h)], closed: true))
        }
        return out
    }

    func testEveryTemplateBuildsCentredWithinSize() {
        for t in MonogramTemplate.all {
            let o = t.applied(to: MonogramOptions(left: "A", center: "B", right: "C", name: "Smith", size: 80))
            let pieces = Monogram.build(o, outline: outline)
            XCTAssertTrue(pieces.contains { $0.role == .letters }, t.id)
            XCTAssertEqual(pieces.contains { $0.role == .frame }, t.frame != .none, t.id)
            let b = pieces.flatMap(\.placedPaths).bounds
            XCTAssertLessThanOrEqual(b.width, 80.5, t.id)
            XCTAssertLessThanOrEqual(b.height, 80.5, t.id)
            XCTAssertEqual(b.center.x, 0, accuracy: 2, t.id)
        }
    }

    func testLettersFitInsideFrame() {
        for frame in MonogramFrame.allCases where frame != .none {
            for letters in MonogramLetters.allCases where letters != .arched {
                let o = MonogramOptions(letters: letters, frame: frame, size: 100, frameWidth: 4)
                let pieces = Monogram.build(o, outline: outline)
                let lb = pieces.filter { $0.role == .letters }.flatMap(\.placedPaths).bounds
                // Letters stay within the frame's inner circle radius (the frame band is outside it).
                if frame == .square {
                    XCTAssertLessThan(max(abs(lb.minX), abs(lb.maxX), abs(lb.minY), abs(lb.maxY)), 50 - 4, "\(letters) in \(frame)")
                } else {
                    let far = pieces.filter { $0.role == .letters }.flatMap(\.placedPaths).flatMap(\.points).map(\.length).max() ?? 0
                    XCTAssertLessThan(far, 50 - 4, "\(letters) in \(frame)")
                }
                XCTAssertFalse(lb.isEmpty)
            }
        }
    }

    func testClassicMiddleLetterIsLarger() {
        let o = MonogramOptions(letters: .classic, frame: .none, sideScale: 0.6)
        let letters = Monogram.build(o, outline: outline).filter { $0.role == .letters }
        XCTAssertEqual(letters.count, 3)
        let heights = letters.map { $0.placedPaths.bounds.height }
        XCTAssertEqual(heights[0] / heights[1], 0.6, accuracy: 0.01)
        XCTAssertEqual(heights[2] / heights[1], 0.6, accuracy: 0.01)
        // Kept as editable text, left to right.
        XCTAssertEqual(letters.map { $0.text?.text }, ["A", "B", "C"])
        XCTAssertLessThan(letters[0].placedPaths.bounds.maxX, letters[1].placedPaths.bounds.minX)
    }

    func testCircleLettersFollowTheCircle() {
        let o = MonogramOptions(letters: .circle, frame: .none, size: 60)
        let pieces = Monogram.build(o, outline: outline)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertNil(pieces[0].text)
        for p in pieces[0].placedPaths.flatMap(\.points) {
            XCTAssertLessThanOrEqual(p.length, 30.01)
        }
    }

    func testDiamondLettersTaper() {
        let o = MonogramOptions(letters: .diamond, frame: .none, size: 60)
        let pts = Monogram.build(o, outline: outline)[0].placedPaths.flatMap(\.points)
        let centreHeight = pts.filter { abs($0.x) < 2 }.map { abs($0.y) }.max() ?? 0
        let edgeHeight = pts.filter { abs($0.x) > 25 }.map { abs($0.y) }.max() ?? 0
        XCTAssertGreaterThan(centreHeight, edgeHeight * 2)
    }

    func testFramesAreBands() {
        let ring = Monogram.frame(MonogramOptions(frame: .circle, size: 50, frameWidth: 3)).0
        XCTAssertEqual(ring.first?.paths.count, 2)
        let r = ring[0].paths.map { $0.bounds.width / 2 }
        XCTAssertEqual(r[0] - r[1], 3, accuracy: 0.05)
        let vine = Monogram.frame(MonogramOptions(frame: .vine, size: 50)).0
        XCTAssertTrue(vine[0].weld)
        XCTAssertGreaterThan(vine[0].paths.count, 10)
        XCTAssertTrue(vine[0].paths.allSatisfy(\.closed))
    }

    func testArchedNameSitsAboveInitial() {
        let o = MonogramOptions(letters: .arched, frame: .circle, center: "S", name: "Smith", size: 80)
        let letters = Monogram.build(o, outline: outline).filter { $0.role == .letters }
        XCTAssertEqual(letters.count, 2)
        let initial = letters[0].placedPaths.bounds, name = letters[1].placedPaths.bounds
        XCTAssertLessThan(name.center.y, initial.center.y)
        XCTAssertNotNil(letters[1].text?.curve)
    }

    func testSanitizedKeepsOneLetterPerSlot() {
        let o = MonogramOptions(left: " ab", center: "", right: "C").sanitized
        XCTAssertEqual(o.left, "a")
        XCTAssertEqual(o.initials, ["a", "C"])
    }
}
