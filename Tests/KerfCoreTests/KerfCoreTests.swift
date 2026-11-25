import XCTest
@testable import KerfCore

final class GeometryTests: XCTestCase {
    func testAffineComposition() {
        let t = Affine.translation(10, 0).then(.scale(2, 2))
        let p = t.apply(Vec2(1, 1))
        XCTAssertEqual(p.x, 22, accuracy: 1e-9)
        XCTAssertEqual(p.y, 2, accuracy: 1e-9)
    }

    func testJoinLooseSegmentsIntoClosedSquare() {
        let segs = [
            Polyline([Vec2(0, 0), Vec2(10, 0)]),
            Polyline([Vec2(10, 10), Vec2(10, 0)]),
            Polyline([Vec2(10, 10), Vec2(0, 10)]),
            Polyline([Vec2(0, 10), Vec2(0, 0)]),
        ]
        let joined = PathJoiner.join(segs)
        XCTAssertEqual(joined.count, 1)
        XCTAssertTrue(joined[0].closed)
        XCTAssertEqual(joined[0].points.count, 4)
    }
}

final class SVGTests: XCTestCase {
    func testRectInMillimetres() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="50mm" viewBox="0 0 200 100">
          <rect x="20" y="10" width="40" height="20" stroke="#ff0000" fill="none"/>
        </svg>
        """
        let groups = try SVGImporter.importData(Data(svg.utf8))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].colorHex, "#FF0000")
        let b = groups[0].paths.bounds
        XCTAssertEqual(b.minX, 10, accuracy: 1e-6)
        XCTAssertEqual(b.minY, 5, accuracy: 1e-6)
        XCTAssertEqual(b.width, 20, accuracy: 1e-6)
        XCTAssertEqual(b.height, 10, accuracy: 1e-6)
    }

    func testPathCommandsAndPackedNumbers() {
        let paths = SVGPathParser.parse("M0,0h10v10H0z m20,0 l5-5.5.5.5", step: 0.5)
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].closed)
        XCTAssertEqual(paths[0].points.count, 4)
        XCTAssertEqual(paths[1].points.count, 3)
        XCTAssertEqual(paths[1].points[1].x, 25, accuracy: 1e-9)
        XCTAssertEqual(paths[1].points[1].y, -5.5, accuracy: 1e-9)
        XCTAssertEqual(paths[1].points[2].x, 25.5, accuracy: 1e-9)
    }

    func testArcFlagsWithoutSeparators() {
        let paths = SVGPathParser.parse("M0 0a5 5 0 0110 0", step: 0.5)
        XCTAssertEqual(paths.count, 1)
        let last = paths[0].points.last!
        XCTAssertEqual(last.x, 10, accuracy: 1e-9)
        XCTAssertEqual(last.y, 0, accuracy: 1e-9)
        // The sweep-flag=1 arc bulges toward negative y in SVG space.
        XCTAssertLessThan(paths[0].bounds.minY, -4.9)
    }

    func testGroupTransform() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
          <g transform="translate(96,0) scale(-1,1)"><line x1="0" y1="0" x2="48" y2="0" stroke="black"/></g>
        </svg>
        """
        let groups = try SVGImporter.importData(Data(svg.utf8))
        let b = groups[0].paths.bounds
        XCTAssertEqual(b.minX, 12.7, accuracy: 1e-6)
        XCTAssertEqual(b.maxX, 25.4, accuracy: 1e-6)
    }
}

final class DXFTests: XCTestCase {
    func testLinesAndCircle() throws {
        let dxf = """
        0
        SECTION
        2
        HEADER
        9
        $INSUNITS
        70
        4
        0
        ENDSEC
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        8
        0
        10
        0
        20
        0
        11
        20
        21
        0
        0
        CIRCLE
        8
        0
        10
        10
        20
        10
        40
        5
        0
        ENDSEC
        0
        EOF
        """
        let groups = try DXFImporter.importText(dxf)
        let paths = groups.flatMap(\.paths)
        XCTAssertEqual(paths.count, 2)
        let b = paths.bounds
        XCTAssertEqual(b.width, 20, accuracy: 0.01)
        XCTAssertEqual(b.height, 15, accuracy: 0.01)
        XCTAssertEqual(b.minX, 10, accuracy: 1e-6)
    }

    func testBulgeSemicircle() {
        let p = DXFImporter.bulgePolyline([(Vec2(0, 0), 1), (Vec2(10, 0), 0)], closed: false, step: 0.2)
        XCTAssertEqual(p.points.last!.x, 10, accuracy: 1e-9)
        // Positive bulge = counter-clockwise, so in y-up space the arc dips below the chord.
        XCTAssertEqual(p.bounds.minY, -5, accuracy: 0.01)
    }
}

final class PlannerTests: XCTestCase {
    func makeDoc(mode: LayerMode) -> KerfDocument {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: mode)
        let outer = Polyline([Vec2(0, 0), Vec2(50, 0), Vec2(50, 50), Vec2(0, 50)], closed: true)
        let inner = Polyline([Vec2(20, 20), Vec2(30, 20), Vec2(30, 30), Vec2(20, 30)], closed: true)
        doc.shapes.append(Artwork(layerID: layer, name: "box", paths: [outer, inner]))
        return doc
    }

    func testInnerShapesCutFirst() {
        let tp = Planner.plan(makeDoc(mode: .line), for: .grblLaser)
        XCTAssertEqual(tp.layers.count, 1)
        let first = tp.layers[0].paths[0]
        XCTAssertEqual(first.count, 5) // closed square repeats its start point
        XCTAssertTrue(first.allSatisfy { $0.x >= 20 && $0.x <= 30 })
    }

    func testFillSkipsHole() {
        var doc = makeDoc(mode: .fill)
        doc.layers[0].fillInterval = 1
        let tp = Planner.plan(doc, for: .grblLaser)
        let rows = tp.layers[0].paths
        // Rows through the hole are split into two segments.
        let at25 = rows.filter { abs($0[0].y - 25.5) < 1e-6 }
        XCTAssertEqual(at25.count, 2)
        XCTAssertEqual(rows.count, 50 + 10)
    }

    func testGCodeUsesMachineCoordinatesAndPower() {
        var doc = makeDoc(mode: .line)
        doc.layers[0].power = 40
        doc.layers[0].speed = 1200
        let profile = DeviceProfile.defaultLaser
        let lines = GCodeGenerator.generate(Planner.plan(doc, for: .grblLaser), profile: profile)
        XCTAssertTrue(lines.contains("M4 S0"))
        // Design y=20 maps to machine y=380 on a 400 mm bed with a front-left origin.
        XCTAssertTrue(lines.contains("G0 X20 Y380"))
        XCTAssertTrue(lines.contains { $0.contains("S400 F1200") })
        XCTAssertEqual(lines.last, "M5")
    }

    func testHPGLOutput() {
        var profile = DeviceProfile.defaultCutter
        profile.bladeOffset = 0
        profile.overcut = 0
        profile.sendSpeedAndForce = false
        profile.origin = .topLeft
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .cut)
        doc.shapes.append(Artwork(layerID: layer, name: "l", paths: [Polyline([Vec2(1, 2), Vec2(3, 4)])]))
        let hpgl = PlotterGenerator.generate(Planner.plan(doc, for: .vinylCutter), profile: profile)
        XCTAssertEqual(hpgl, "IN;PU40,80;PD120,160;\nPU;\n")
    }

    func testOvercutAndBladeOffset() {
        let square = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10), Vec2(0, 0)]
        let over = PlotterGenerator.addOvercut(square, distance: 2)
        XCTAssertEqual(over.last!, Vec2(2, 0))
        let comp = PlotterGenerator.bladeCompensate(square, offset: 0.5)
        XCTAssertEqual(comp.first!, Vec2(0.5, 0))
        // Each 90° corner adds a swivel arc.
        XCTAssertGreaterThan(comp.count, square.count + 6)
    }
}

final class GRBLTests: XCTestCase {
    func testStatusParsing() {
        guard case .status(let s) = GRBLResponse.parse("<Run|MPos:10.000,20.500,0.000|FS:1200,500|WCO:1.000,2.000,0.000>") else {
            return XCTFail("not a status")
        }
        XCTAssertEqual(s.state, "Run")
        XCTAssertEqual(s.machinePosition, Vec2(10, 20.5))
        XCTAssertEqual(s.workOffset, Vec2(1, 2))
        XCTAssertEqual(s.feed, 1200)
        XCTAssertEqual(GRBLResponse.parse("error:22"), .error(22))
        XCTAssertEqual(GRBLResponse.parse("ALARM:1"), .alarm(1))
        XCTAssertEqual(GRBLResponse.parse("ok\r"), .ok)
    }

    func testCharacterCountingNeverOverflows() {
        var s = GRBLStreamer(bufferSize: 20)
        s.enqueue(["G1 X1 Y1 ; comment", "G1 X2 Y2", "", "(note)", "G1 X3 Y3", "G1 X4 Y4"])
        XCTAssertEqual(s.total, 4)
        let first = s.takeSendable()
        XCTAssertEqual(first, ["G1 X1 Y1", "G1 X2 Y2"]) // 9 + 9 = 18 bytes
        XCTAssertLessThanOrEqual(s.bufferUsed, 20)
        XCTAssertTrue(s.takeSendable().isEmpty)
        s.acknowledge()
        XCTAssertEqual(s.takeSendable(), ["G1 X3 Y3"])
        s.acknowledge(errorCode: 2)
        s.acknowledge()
        XCTAssertEqual(s.takeSendable(), ["G1 X4 Y4"])
        s.acknowledge()
        XCTAssertTrue(s.isIdle)
        XCTAssertEqual(s.errors.count, 1)
        XCTAssertEqual(s.errors[0].line, "G1 X2 Y2")
    }
}
