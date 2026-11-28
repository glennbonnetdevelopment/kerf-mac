import Foundation
import XCTest
@testable import KerfCore

final class ManualRegistrationTests: XCTestCase {
    private func assertClose(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: tol, file: file, line: line)
    }

    private let design = [Vec2(0, 0), Vec2(200, 0), Vec2(0, 150), Vec2(200, 150)]

    func testOneMarkMovesOnly() throws {
        let t = try XCTUnwrap(ManualRegistration.fit(design: [Vec2(10, 20)], measured: [Vec2(13, 18)]))
        assertClose(t.apply(Vec2(100, 100)), Vec2(103, 98))
    }

    func testTwoMarksRotateAndMove() throws {
        let truth = Affine.rotation(0.01).then(.translation(5, -3))
        let measured = design.prefix(2).map(truth.apply)
        let t = try XCTUnwrap(ManualRegistration.fit(design: Array(design.prefix(2)), measured: measured))
        assertClose(t.apply(Vec2(0, 150)), truth.apply(Vec2(0, 150)))
    }

    func testFourMarksRecoverStretchAndSkew() throws {
        let truth = Affine(a: 1.004, b: 0.002, c: -0.003, d: 0.997, tx: 12.5, ty: -4)
        let measured = design.map(truth.apply)
        let t = try XCTUnwrap(ManualRegistration.fit(design: design, measured: measured))
        for p in [Vec2(50, 75), Vec2(180, 10)] { assertClose(t.apply(p), truth.apply(p)) }
        XCTAssertEqual(ManualRegistration.maxResidual(t, design: design, measured: measured), 0, accuracy: 1e-6)
        let s = ManualRegistration.axisScales(t)
        XCTAssertEqual(s.x, (1.004 * 1.004 + 0.002 * 0.002).squareRoot(), accuracy: 1e-9)
    }

    func testResidualShowsAMisplacedMark() throws {
        var measured = design
        measured[3] = measured[3] + Vec2(2, 0)
        let t = try XCTUnwrap(ManualRegistration.fit(design: design, measured: measured))
        XCTAssertGreaterThan(ManualRegistration.maxResidual(t, design: design, measured: measured), 0.3)
    }

    func testCollinearMarksFallBackToTwoPointFit() throws {
        let line = [Vec2(0, 0), Vec2(100, 0), Vec2(200, 0)]
        let measured = line.map { $0 + Vec2(1, 2) }
        let t = try XCTUnwrap(ManualRegistration.fit(design: line, measured: measured))
        assertClose(t.apply(Vec2(50, 50)), Vec2(51, 52))
    }

    func testPredictionFromConfirmedMarks() throws {
        XCTAssertNil(ManualRegistration.predicted(mark: 1, design: design, confirmed: [:]))
        let shift = Vec2(3, 4)
        let p = try XCTUnwrap(ManualRegistration.predicted(mark: 3, design: design, confirmed: [0: design[0] + shift]))
        assertClose(p, design[3] + shift)
    }

    func testLaserOffsetRoundTrip() {
        let offset = Vec2(-21.5, 8)
        let mark = Vec2(100, 50)
        let head = ManualRegistration.headPosition(pointerAt: mark, offset: offset)
        assertClose(ManualRegistration.markPosition(head: head, offset: offset), mark)
        // The blade cut a cross at (40, 40); the pointer is on it with the head at (61.5, 32).
        assertClose(ManualRegistration.calibratedOffset(cut: Vec2(40, 40), head: Vec2(61.5, 32)), offset)
    }

    func testProfileLaserOffsetIsZeroWithoutPointerAndDecodesOldProfiles() throws {
        var p = DeviceProfile.defaultCutter
        p.laserOffset = Vec2(5, 6)
        XCTAssertEqual(p.laserOffset, .zero)
        p.hasLaserPointer = true
        XCTAssertEqual(p.laserOffset, Vec2(5, 6))
        let round = try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round, p)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DeviceProfile.defaultCutter)) as? [String: Any])
        for k in ["hasLaserPointer", "laserOffsetX", "laserOffsetY"] { json.removeValue(forKey: k) }
        let old = try JSONDecoder().decode(DeviceProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.hasLaserPointer)
        XCTAssertEqual(old.laserOffsetX, 0)
    }

    func testMoveAndCrossCommands() {
        var p = DeviceProfile.defaultCutter
        XCTAssertEqual(ManualRegistration.moveCommand(to: Vec2(10, 2.5), profile: p), "PU400,100;\n")
        XCTAssertEqual(ManualRegistration.calibrationCross(at: Vec2(10, 10), profile: p),
                       "PU280,400;PD520,400;PU400,280;PD400,520;PU400,400;\n")
        p.language = .gpgl
        p.unitsPerMM = 20
        XCTAssertEqual(ManualRegistration.moveCommand(to: Vec2(1, 2), profile: p), "M20,40\u{03}")
        p.language = .svgFile
        XCTAssertNil(ManualRegistration.moveCommand(to: .zero, profile: p))
    }

    func testJogFollowsTheCanvas() {
        // Front-right origin: canvas right is cutter -X, canvas down is cutter -Y.
        let gcc = DeviceProfile.presets.first { $0.name.hasPrefix("GCC Expert II 24 LX") }!
        assertClose(ManualRegistration.jogDelta(Vec2(1, 0), step: 5, profile: gcc), Vec2(-5, 0))
        assertClose(ManualRegistration.jogDelta(Vec2(0, 1), step: 5, profile: gcc), Vec2(0, -5))
    }

    func testCutIsPlacedOnTheMeasuredMarks() throws {
        let p = DeviceProfile.defaultCutter
        let layer = Layer(name: "Cut", colorHex: "#000000", mode: .cut)
        var noComp = p
        noComp.bladeOffset = 0
        noComp.overcut = 0
        noComp.sendSpeedAndForce = false
        let tp = Toolpath(layers: [ToolpathLayer(layer: layer, paths: [[Vec2(10, 10), Vec2(20, 10)]])])
        var options = CutterJobOptions()
        options.alignment = .translation(1, 2)
        let text = PlotterGenerator.generate(tp, profile: noComp, options: options)
        let m0 = p.toMachine(Vec2(10, 10)) + Vec2(1, 2), m1 = p.toMachine(Vec2(20, 10)) + Vec2(1, 2)
        XCTAssertTrue(text.contains("PU\(Int(m0.x * 40)),\(Int(m0.y * 40));PD\(Int(m1.x * 40)),\(Int(m1.y * 40));"), text)
    }
}
