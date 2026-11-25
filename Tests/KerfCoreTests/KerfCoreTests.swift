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

final class Phase2Tests: XCTestCase {
    func testAffineInverse() {
        let t = Affine.translation(5, -3).then(.rotation(0.7)).then(.scale(2, 3))
        let p = Vec2(1.5, -4)
        let back = t.inverted.apply(t.apply(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
    }

    func testDitherKeepsAverageBrightness() {
        let gray = [Double](repeating: 0.5, count: 100 * 100)
        let out = Raster.dither(gray, width: 100, height: 100, mode: .floydSteinberg)
        let burned = out.filter { $0 == 255 }.count
        XCTAssertEqual(Double(burned) / Double(out.count), 0.5, accuracy: 0.05)
        XCTAssertEqual(Raster.dither([0.2, 0.8], width: 2, height: 1, mode: .threshold), [255, 0])
    }

    func testImageRowsAndGCode() {
        var doc = KerfDocument()
        let layerID = doc.layer(forMode: .image, name: "Image", colorHex: "#444444")
        doc.layers[0].fillInterval = 1
        doc.layers[0].dither = .threshold
        doc.layers[0].overscan = 2
        // 2×2 image: left column black, right column white; 10×10 mm at (5, 5).
        let img = RasterImage(width: 2, height: 2, pixels: Data([0, 255, 0, 255]))
        let frame = Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)], closed: true)
        doc.shapes.append(Artwork(layerID: layerID, name: "img", paths: [frame], transform: .translation(5, 5), image: img))
        let tp = Planner.plan(doc, for: .grblLaser)
        XCTAssertEqual(tp.layers.count, 1)
        let rows = tp.layers[0].rasters
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows[0].x0, 5, accuracy: 1e-9)
        XCTAssertEqual(rows[0].x1, 10, accuracy: 1e-9)
        var profile = DeviceProfile.defaultLaser
        profile.origin = .topLeft
        let lines = GCodeGenerator.generate(tp, profile: profile)
        XCTAssertTrue(lines.contains("G0 X3 Y5.5")) // overscan lead-in
        XCTAssertTrue(lines.contains { $0.hasPrefix("G1 X10 Y5.5 S400") })
        // Image layers are never sent to a vinyl cutter.
        XCTAssertTrue(Planner.plan(doc, for: .vinylCutter).isEmpty)
    }

    func testOffsetGrowsAndShrinksSquare() {
        let sq = Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)], closed: true)
        let out = PathOffset.offset(sq, by: 1).bounds
        XCTAssertEqual(out.width, 12, accuracy: 1e-9)
        let inner = PathOffset.offset(sq.reversed, by: -1).bounds
        XCTAssertEqual(inner.width, 8, accuracy: 1e-9)
    }

    func testCNCStepsDown() {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].cutDepth = 2.5
        doc.layers[0].stepDown = 1
        doc.shapes.append(Artwork(layerID: layer, name: "l", paths: [Polyline([Vec2(0, 0), Vec2(10, 0)])]))
        var profile = DeviceProfile.presets.first { $0.kind == .cncRouter }!
        profile.origin = .topLeft
        let lines = GCodeGenerator.generate(Planner.plan(doc, for: .cncRouter), profile: profile)
        XCTAssertEqual(lines.filter { $0.hasPrefix("G1 Z-") }, ["G1 Z-1 F300", "G1 Z-2 F300", "G1 Z-2.5 F300"])
        XCTAssertTrue(lines.contains("M3 S1000"))
        // Second pass of an open path runs back the other way.
        XCTAssertTrue(lines.contains("G1 X0 Y0 F1000"))
    }

    private func square(_ x: Double, _ y: Double, _ size: Double) -> Polyline {
        Polyline([Vec2(x, y), Vec2(x + size, y), Vec2(x + size, y + size), Vec2(x, y + size)], closed: true)
    }

    private func cncProfile() -> DeviceProfile {
        DeviceProfile.presets.first { $0.kind == .cncRouter }!
    }

    func testCNCAutoPartsAndHolesOffsetByToolRadius() {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].toolDiameter = 4
        // A 40 mm plate with a 10 mm hole drawn as a separate shape.
        doc.shapes.append(Artwork(layerID: layer, name: "plate", paths: [square(0, 0, 40)]))
        doc.shapes.append(Artwork(layerID: layer, name: "hole", paths: [square(15, 15, 10)]))
        let tl = Planner.plan(doc, for: .cncRouter).layers[0]
        XCTAssertEqual(tl.cuts, [.hole, .part]) // hole first so the part is still held
        let hole = Polyline(tl.paths[0], closed: true).bounds, part = Polyline(tl.paths[1], closed: true).bounds
        XCTAssertEqual(hole.width, 6, accuracy: 1e-6)
        XCTAssertEqual(part.width, 44, accuracy: 1e-6)
    }

    func testTextInsideAnOutlineStillCutsAsParts() {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].toolDiameter = 2
        doc.shapes.append(Artwork(layerID: layer, name: "frame", paths: [square(0, 0, 100)]))
        // Two "letters": one inside the frame, one crossing its edge.
        doc.shapes.append(Artwork(layerID: layer, name: "text", paths: [square(40, 40, 10), square(95, 40, 10)],
                                  text: TextSpec(text: "II", fontName: "Helvetica", height: 10)))
        let tl = Planner.plan(doc, for: .cncRouter).layers[0]
        XCTAssertEqual(tl.cuts.filter { $0 == .part }.count, 3) // frame and both letters
    }

    func testCNCShapeRoleOverridesAndDrill() {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].toolDiameter = 2
        var online = Artwork(layerID: layer, name: "a", paths: [square(0, 0, 20)])
        online.millRole = .onLine
        var drill = Artwork(layerID: layer, name: "b", paths: [square(50, 50, 4)])
        drill.millRole = .drill
        doc.shapes = [online, drill]
        let tl = Planner.plan(doc, for: .cncRouter).layers[0]
        XCTAssertEqual(tl.cuts, [.drill, .onLine])
        XCTAssertEqual(tl.paths[0], [Vec2(52, 52)])
        XCTAssertEqual(Polyline(tl.paths[1], closed: true).bounds.width, 20, accuracy: 1e-6)
    }

    /// Signed area of the first closed contour cut in the G-code, in machine coordinates.
    private func firstContourArea(_ lines: [String]) -> Double {
        var pts: [Vec2] = []
        for l in lines where l.hasPrefix("G1 X") && l.contains(" Z") {
            let w = l.split(separator: " ")
            let x = Double(w.first { $0.hasPrefix("X") }!.dropFirst())!, y = Double(w.first { $0.hasPrefix("Y") }!.dropFirst())!
            pts.append(Vec2(x, y))
            if pts.count > 3, pts.last!.distance(to: pts[0]) < 1e-6 { break }
        }
        return Polyline(pts, closed: true).signedArea
    }

    func testClimbAndConventionalDirection() {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].cutDepth = 1
        doc.layers[0].stepDown = 1
        doc.shapes.append(Artwork(layerID: layer, name: "p", paths: [square(10, 10, 20)]))
        let climb = GCodeGenerator.generate(Planner.plan(doc, for: .cncRouter), profile: cncProfile())
        XCTAssertLessThan(firstContourArea(climb), 0) // clockwise around a part
        doc.layers[0].millStyle = .conventional
        let conventional = GCodeGenerator.generate(Planner.plan(doc, for: .cncRouter), profile: cncProfile())
        XCTAssertGreaterThan(firstContourArea(conventional), 0)
    }

    func testTabsLiftToTabHeightOnLastPass() {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].cutDepth = 6
        doc.layers[0].stepDown = 3
        doc.layers[0].tabsEnabled = true
        doc.layers[0].tabCount = 4
        doc.layers[0].tabHeight = 2
        doc.shapes.append(Artwork(layerID: layer, name: "p", paths: [square(10, 10, 60)]))
        let lines = GCodeGenerator.generate(Planner.plan(doc, for: .cncRouter), profile: cncProfile())
        let tabMoves = lines.filter { $0.hasPrefix("G1 X") && $0.hasSuffix("Z-4") }
        XCTAssertGreaterThanOrEqual(tabMoves.count, 8) // over and off each of 4 tabs
        XCTAssertTrue(lines.contains { $0.hasPrefix("G1 X") && $0.contains("Z-6") })
    }

    func testRampEntryStartsAtPreviousDepth() {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].cutDepth = 2
        doc.layers[0].stepDown = 2
        doc.layers[0].rampLength = 10
        doc.shapes.append(Artwork(layerID: layer, name: "p", paths: [square(10, 10, 30)]))
        let lines = GCodeGenerator.generate(Planner.plan(doc, for: .cncRouter), profile: cncProfile())
        XCTAssertTrue(lines.contains("G1 Z0 F300"))
        XCTAssertFalse(lines.contains("G1 Z-2 F300")) // no straight plunge
    }

    func testPocketClearsInsideBeforeContour() {
        var doc = KerfDocument()
        let layer = doc.addLayer(mode: .mill)
        doc.layers[0].toolDiameter = 3
        var pocket = Artwork(layerID: layer, name: "p", paths: [square(0, 0, 30)])
        pocket.millRole = .pocket
        doc.shapes = [pocket]
        let tl = Planner.plan(doc, for: .cncRouter).layers[0]
        XCTAssertEqual(tl.cuts.last, .hole)
        XCTAssertTrue(tl.cuts.dropLast().allSatisfy { $0 == .pocketClear })
        XCTAssertFalse(tl.cuts.dropLast().isEmpty)
        // Rows stay inside the tool-compensated boundary.
        for p in tl.paths.dropLast() { for q in p { XCTAssert(q.x >= 1.5 - 1e-6 && q.x <= 28.5 + 1e-6) } }
    }

    func testMillSimulatorCutsToDepth() {
        let lines = ["G0 Z5", "; Layer x: tool 4 mm", "G0 X0 Y0", "G1 Z-3 F100", "G1 X20 Y0", "G0 Z5"]
        let moves = MillSimulator.moves(from: lines)
        XCTAssertEqual(moves.first { $0.feed }?.toolDiameter, 4)
        var sim = MillSimulator(moves: moves, margin: 5, maxCells: 400)
        sim.run(moves)
        XCTAssertEqual(Double(sim.height(x: 10, y: 0)), -3, accuracy: 1e-6)
        XCTAssertEqual(Double(sim.height(x: 10, y: 1.5)), -3, accuracy: 1e-6)
        XCTAssertEqual(Double(sim.height(x: 10, y: 3)), 0, accuracy: 1e-6)
    }

    func testPathTextFollowsCircle() {
        let circle = Flatten.ellipse(center: Vec2(0, 0), rx: 50, ry: 50, step: 0.2)
        let guide = PathText.outsideGuide(circle)
        XCTAssertEqual(guide[0].y, -50, accuracy: 0.5) // starts at the top
        var spec = PathTextSpec(guide: guide, closed: true, offset: 0, gap: 0)
        // A small square standing on the baseline, 4 mm tall, 20 mm along the path.
        let letter = Polyline([Vec2(20, 0), Vec2(22, 0), Vec2(22, -4), Vec2(20, -4)], closed: true)
        let placed = PathText.place([letter], spec: spec)[0]
        for p in placed.points {
            let r = p.length
            XCTAssertTrue(r > 50 - 1e-3 && r < 54.1, "radius \(r)") // outside the circle
        }
        XCTAssertGreaterThan(placed.points.count, 4) // edges were subdivided so they bend
        spec.offset = 10
        XCTAssertEqual(PathText.nearestOffset(on: spec, to: PathText.point(on: spec, at: 30)!), 30, accuracy: 0.05)
    }

    func testShapeLibraryFillsBox() {
        let box = Rect2(minX: 10, minY: 20, maxX: 70, maxY: 60)
        for kind in ShapeKind.allCases {
            let polys = ShapeLibrary.make(kind, in: box)
            XCTAssertFalse(polys.isEmpty, kind.title)
            let b = polys.bounds
            XCTAssertTrue(box.insetBy(-0.01).contains(b), "\(kind.title) spills out of its box")
            XCTAssertGreaterThan(b.width, box.width * 0.85, kind.title)
        }
        var o = ShapeOptions()
        o.points = 7
        XCTAssertEqual(ShapeLibrary.make(.star, in: box, options: o)[0].points.count, 14)
        o.sides = 8
        XCTAssertEqual(ShapeLibrary.make(.polygon, in: box, options: o)[0].points.count, 8)
    }

    func testRegistrationStylesAndFourMarks() {
        let art = Rect2(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let centers = Registration.markCenters(around: art, margin: 8, size: 5, count: 4)
        XCTAssertEqual(centers.count, 4)
        XCTAssertEqual(centers[3], Vec2(110.5, 60.5))
        for style in RegistrationStyle.allCases {
            let m = Registration.mark(style: style, size: 5, index: 1, corner: Vec2(1, -1))
            XCTAssertFalse(m.isEmpty, style.title)
            XCTAssertTrue(m.bounds.insetBy(-1e-6).contains(.zero), style.title) // registration point is the origin
        }
        // A top-right bracket opens toward the artwork: arms go left and down.
        let bracket = Registration.mark(style: .corners, size: 5, index: 1, corner: Vec2(1, -1))[0].bounds
        XCTAssertEqual(bracket.maxX, 0, accuracy: 1e-9)
        XCTAssertEqual(bracket.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(bracket.minX, -10, accuracy: 1e-9)
    }

    func testWorkpieceRoundTripsAndOldFilesLoad() throws {
        var doc = KerfDocument()
        doc.workpiece = Workpiece(kind: .mat, name: "Mat", x: 5, y: 6, width: 304.8, height: 609.6, thickness: 0.3)
        let back = try KerfDocument.decode(doc.encoded())
        XCTAssertEqual(back.workpiece, doc.workpiece)
        let old = try KerfDocument.decode(Data(#"{"version":2,"document":{"layers":[],"shapes":[]}}"#.utf8))
        XCTAssertNil(old.workpiece)
    }

    func testMillSimulatorRegionMatchesStock() {
        let sim = MillSimulator(region: Rect2(minX: 0, minY: 0, maxX: 300, maxY: 150), maxCells: 300)
        XCTAssertEqual(sim.cell, 1, accuracy: 1e-9)
        XCTAssertEqual(sim.columns, 300)
        XCTAssertEqual(sim.rows, 150)
    }

    func testLightBurnImportShapesLayersAndGroups() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <LightBurnProject AppVersion="1.2.04" FormatVersion="1">
            <CutSetting type="Cut"><index Value="1"/><name Value="Outline"/><maxPower Value="70"/><speed Value="20"/><numPasses Value="2"/></CutSetting>
            <CutSetting type="Scan"><index Value="2"/><name Value="Fill"/><interval Value="0.1"/></CutSetting>
            <Shape Type="Rect" CutIndex="1" W="20" H="10" Cr="0"><XForm>1 0 0 1 50 50</XForm></Shape>
            <Shape Type="Group" CutIndex="0"><XForm>1 0 0 1 100 0</XForm><Children>
                <Shape Type="Path" CutIndex="2" VertID="7" PrimID="7"><XForm>1 0 0 1 0 0</XForm>
                    <VertList>V0 0c0x0c0y5V10 0V10 10c1x10c1y5</VertList><PrimList>L0 1B1 2L2 0</PrimList></Shape>
                <Shape Type="Path" CutIndex="2" VertID="7" PrimID="7"><XForm>1 0 0 1 0 100</XForm></Shape>
            </Children></Shape>
            <Shape Type="Ellipse" CutIndex="1" Rx="5" Ry="5"><XForm>1 0 0 1 0 0</XForm></Shape>
        </LightBurnProject>
        """
        let r = try LightBurnImporter.parse(Data(xml.utf8), bedHeight: 400)
        XCTAssertEqual(r.layers[1]?.name, "Outline")
        XCTAssertEqual(r.layers[1]?.speed, 1200) // 20 mm/s
        XCTAssertEqual(r.layers[1]?.passes, 2)
        XCTAssertEqual(r.layers[1]?.colorHex, "#0000FF")
        XCTAssertEqual(r.layers[2]?.mode, .fill)
        XCTAssertEqual(r.shapes.count, 4)
        // The rectangle is centred on (50, 50) measured up from the bed's bottom.
        let rect = r.shapes[0].paths.bounds
        XCTAssertEqual(rect.minX, 40, accuracy: 1e-6)
        XCTAssertEqual(rect.maxX, 60, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, 345, accuracy: 1e-6)
        XCTAssertEqual(rect.maxY, 355, accuracy: 1e-6)
        // The grouped path is closed, curved, moved by the group, and its copy reuses the shared points.
        let tri = r.shapes[1].paths[0]
        XCTAssertTrue(tri.closed)
        XCTAssertGreaterThan(tri.points.count, 4)
        XCTAssertEqual(tri.bounds.minX, 100, accuracy: 1e-6)
        XCTAssertEqual(r.shapes[2].paths[0].bounds.maxY, 300, accuracy: 1e-6)
        XCTAssertEqual(r.shapes[3].paths.bounds.width, 10, accuracy: 0.01)
    }

    func testLightBurnMirrorYMeasuresFromTheTop() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <LightBurnProject AppVersion="1.2.04" FormatVersion="1" MirrorX="False" MirrorY="True">
            <Shape Type="Rect" CutIndex="0" W="20" H="10"><XForm>1 0 0 1 50 50</XForm></Shape>
            <Shape Type="Bitmap" CutIndex="0" W="40" H="20" Data="iVBORw0KGgo="><XForm>1 0 0 1 100 100</XForm></Shape>
        </LightBurnProject>
        """
        let r = try LightBurnImporter.parse(Data(xml.utf8), bedHeight: 400)
        XCTAssertEqual(r.shapes[0].paths.bounds.minY, 45, accuracy: 1e-6)
        // The picture's top row stays at the top.
        XCTAssertEqual(r.images[0].transform.apply(Vec2(0, -10)).y, 90, accuracy: 1e-6)
    }

    func testLightBurnImportImageAndText() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <LightBurnProject AppVersion="1.2.04" FormatVersion="1">
            <CutSetting_Img type="Image"><index Value="0"/><name Value="C00"/><speed Value="55"/><interval Value="0.08"/></CutSetting_Img>
            <Shape Type="Bitmap" CutIndex="0" W="40" H="20" File="//mac/logo.jpg" Data="iVBORw0KGgo="><XForm>0 1 -1 0 100 100</XForm></Shape>
            <Shape Type="Text" CutIndex="3" Str="Hi" Font="Arial,-1,100,5,50,0,0,0,0,0" H="12" AH="1"><XForm>1 0 0 1 10 20</XForm></Shape>
        </LightBurnProject>
        """
        let r = try LightBurnImporter.parse(Data(xml.utf8), bedHeight: 300)
        XCTAssertEqual(r.layers[0]?.mode, .image)
        XCTAssertEqual(r.layers[0]?.fillInterval, 0.08)
        XCTAssertEqual(r.images.count, 1)
        XCTAssertEqual(r.images[0].name, "logo.jpg")
        // Turned a quarter turn: 40 × 20 becomes 20 wide and 40 tall, centred at (100, 200).
        let placed = [Polyline([Vec2(-20, -10), Vec2(20, -10), Vec2(20, 10), Vec2(-20, 10)], closed: true)].transformed(r.images[0].transform).bounds
        XCTAssertEqual(placed.width, 20, accuracy: 1e-6)
        XCTAssertEqual(placed.height, 40, accuracy: 1e-6)
        XCTAssertEqual(placed.center.y, 200, accuracy: 1e-6)
        XCTAssertEqual(r.texts.first?.text, "Hi")
        XCTAssertEqual(r.texts.first?.fontFamily, "Arial")
        XCTAssertEqual(r.texts.first?.alignment, 1)
        XCTAssertNotNil(r.layers[3]) // text layer without a settings block still gets a layer
        // Baseline at y = 20 up from the bottom, so 280 down from the top; letters rise above it.
        let t = r.texts[0].transform
        XCTAssertEqual(t.apply(Vec2(0, 0)).y, 280, accuracy: 1e-6)
        XCTAssertLessThan(t.apply(Vec2(0, -10)).y, 280)
    }

    func testEasyCutImportReadsMatAndPictures() throws {
        let text = """
        <xml version="1.0" encoding="UTF-8">
        <sure_cuts_alot version_major="5" version_minor="107" product="easysigncutpro">
        <scal5_data mat_wu="11000" mat_hu="8500" mat_orientation="vertical" mat_units="in" cut_machine="Janome">
        <pages current="0"><page id="1"><objects>
        <group id="1"><transform a="1" b="0" c="0" d="0" e="1" f="0" g="0" h="0" i="1" /><objects>
        <image img_src2="/x/logo.png" img_w="3300" img_h="2550" img_dpix="300" img_dpiy="300" img_data="iVBORw0KGgo=">
        <transform a="0" b="-0.32" c="0" d="0.32" e="0" f="0" g="0" h="0" i="1" />
        <path_list><pth i="1" t="u" s="1" pts="Mp:1,2 Lp:3,4 Z;"/></path_list></image>
        </objects></group></objects></page></pages></scal5_data>
        </sure_cuts_alot>
        </xml>
        """
        let r = try EasyCutImporter.parse(Data(text.utf8))
        XCTAssertEqual(r.workpiece?.width ?? 0, 215.9, accuracy: 1e-6)
        XCTAssertEqual(r.workpiece?.height ?? 0, 279.4, accuracy: 1e-6)
        XCTAssertEqual(r.images.count, 1)
        XCTAssertEqual(r.images[0].name, "logo.png")
        // 11 × 8.5 in picture turned upright to fit the 8.5 × 11 in mat.
        let placed = [Polyline([Vec2(r.images[0].frame.minX, r.images[0].frame.minY), Vec2(r.images[0].frame.maxX, r.images[0].frame.maxY)])]
            .transformed(r.images[0].transform).bounds
        XCTAssertLessThanOrEqual(placed.width, 215.9)
        XCTAssertLessThanOrEqual(placed.height, 279.4)
        XCTAssertGreaterThan(placed.height, placed.width)
        XCTAssertTrue(r.warnings.contains { $0.contains("SVG") })
    }

    func testNestingFitsRowsAndRejectsOversize() {
        let area = Rect2(minX: 0, minY: 0, maxX: 100, maxY: 100)
        let placed = Nester.pack(sizes: [Vec2(60, 40), Vec2(30, 50), Vec2(200, 10)], in: area, spacing: 2, allowRotation: true)
        XCTAssertNotNil(placed[0])
        XCTAssertNotNil(placed[1])
        XCTAssertNil(placed[2])
        XCTAssertEqual(placed[1]!.rotated, true) // 30×50 turned to 50×30
    }

    func testAlignmentFromTwoPoints() {
        let t = Registration.alignment(design: Vec2(0, 0), Vec2(100, 0), measured: Vec2(10, 10), Vec2(10, 110))!
        let p = t.apply(Vec2(50, 0))
        XCTAssertEqual(p.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p.y, 60, accuracy: 1e-9)
    }

    func testRotaryScalesY() {
        var p = DeviceProfile.defaultLaser
        p.origin = .topLeft
        p.rotaryEnabled = true
        p.rotaryType = .chuck
        p.rotaryObjectDiameter = 100 / Double.pi
        p.rotaryMMPerRotation = 50
        // One turn (100 mm of design height) = 50 mm of controller Y travel.
        XCTAssertEqual(p.toMachine(Vec2(3, 100)).y, 50, accuracy: 1e-9)
        XCTAssertEqual(p.fromMachine(Vec2(3, 50)).y, 100, accuracy: 1e-9)
    }

    func testOldLayerJSONStillDecodes() throws {
        let json = ##"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"L","colorHex":"#000000","mode":"line","enabled":true,"passes":1,"speed":900,"power":20,"airAssist":false,"fillInterval":0.1,"fillAngle":0,"fillBidirectional":true,"cutSpeed":20,"cutForce":80}"##
        let layer = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        XCTAssertEqual(layer.speed, 900)
        XCTAssertEqual(layer.dither, .floydSteinberg)
    }

    // MARK: - Curved text and contour cut

    func testArcGuideArchesUpAndKeepsLength() {
        let up = PathText.arcGuide(width: 100, degrees: 90)
        XCTAssertEqual(up.length, 100, accuracy: 0.5)
        // Middle of the arch is the top (y = 0); the ends drop below it (y down).
        let mid = PathText.point(on: up, at: 50)!
        XCTAssertEqual(mid.x, 50, accuracy: 0.1)
        XCTAssertEqual(mid.y, 0, accuracy: 0.1)
        XCTAssertGreaterThan(up.guide.first!.y, 5)
        XCTAssertGreaterThan(up.guide.last!.y, 5)

        let down = PathText.arcGuide(width: 100, degrees: -90)
        XCTAssertLessThan(down.guide.first!.y, -5)
        XCTAssertLessThan(down.guide.last!.y, -5)
        XCTAssertLessThan(down.guide.first!.x, down.guide.last!.x)

        // A letter standing on the arch leans outward: a box above the baseline at the left end
        // ends up left of and below the middle.
        let box = Polyline([Vec2(0, -10), Vec2(5, -10), Vec2(5, 0), Vec2(0, 0)], closed: true)
        let placed = PathText.place([box], spec: up)[0]
        XCTAssertLessThan(placed.bounds.maxY, 40)
        XCTAssertLessThan(placed.bounds.minX, 15)
    }

    func testContourGrowsASquareAndFillsHoles() {
        // A 20 mm ring-shaped square (with a 10 mm hole) on a 0.5 mm grid.
        let bounds = Rect2(minX: 0, minY: 0, maxX: 20, maxY: 20)
        var mask = Contour.grid(for: bounds, margin: 3, maxCells: 400, finest: 0.5)
        XCTAssertEqual(mask.cell, 0.5, accuracy: 1e-9)
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let px = mask.origin.x + (Double(x) + 0.5) * mask.cell, py = mask.origin.y + (Double(y) + 0.5) * mask.cell
                let inOuter = px > 0 && px < 20 && py > 0 && py < 20
                let inHole = px > 5 && px < 15 && py > 5 && py < 15
                mask[x, y] = inOuter && !inHole
            }
        }
        let loops = Contour.outline(mask, offset: 2)
        XCTAssertEqual(loops.count, 1, "the hole is filled, leaving one outer loop")
        let b = loops[0].bounds
        XCTAssertEqual(b.minX, -2, accuracy: 0.6)
        XCTAssertEqual(b.maxX, 22, accuracy: 0.6)
        XCTAssertEqual(b.minY, -2, accuracy: 0.6)
        XCTAssertEqual(b.maxY, 22, accuracy: 0.6)
        // Corners are rounded, so the outline stays inside the grown square's corners.
        XCTAssertFalse(loops[0].points.contains { $0.distance(to: Vec2(-2, -2)) < 0.3 })
        XCTAssertLessThan(loops[0].points.count, 200)
    }

    func testContourKeepsSeparatePiecesApart() {
        let bounds = Rect2(minX: 0, minY: 0, maxX: 60, maxY: 10)
        var mask = Contour.grid(for: bounds, margin: 1, maxCells: 400, finest: 0.5)
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let px = mask.origin.x + (Double(x) + 0.5) * mask.cell, py = mask.origin.y + (Double(y) + 0.5) * mask.cell
                mask[x, y] = py > 0 && py < 10 && ((px > 0 && px < 10) || (px > 50 && px < 60))
            }
        }
        XCTAssertEqual(Contour.outline(mask, offset: 1).count, 2)
        XCTAssertEqual(Contour.outline(mask, offset: 25).count, 1, "a large offset merges them")
    }

    func testCurvedTextSpecDecodesWithoutCurve() throws {
        let json = #"{"text":"Hi","fontName":"Helvetica","height":10}"#
        let spec = try JSONDecoder().decode(TextSpec.self, from: Data(json.utf8))
        XCTAssertNil(spec.curve)
        XCTAssertFalse(spec.isCurved)
    }

    // MARK: - Material library

    func testMaterialAppliesSettingsButKeepsLayerIdentity() {
        var source = Layer(name: "Cut", colorHex: "#E5222D", mode: .line, passes: 3, speed: 300, power: 95)
        source.airAssist = true
        var m = CutMaterial(name: "Birch plywood", thickness: 3, operation: "Cut", kind: .grblLaser, settings: source)
        m.capture(source)
        XCTAssertEqual(m.title, "Birch plywood · 3 mm · Cut")

        var target = Layer(name: "Layer 2", colorHex: "#0050FF", mode: .fill, enabled: false, passes: 1, speed: 3000, power: 20)
        let id = target.id
        m.apply(to: &target)
        XCTAssertEqual(target.id, id)
        XCTAssertEqual(target.name, "Layer 2")
        XCTAssertEqual(target.colorHex, "#0050FF")
        XCTAssertFalse(target.enabled)
        XCTAssertEqual(target.mode, .line)
        XCTAssertEqual(target.passes, 3)
        XCTAssertEqual(target.speed, 300)
        XCTAssertEqual(target.power, 95)
        XCTAssertTrue(target.airAssist)
        XCTAssertEqual(target.materialID, m.id)
    }

    func testMaterialLibraryFiltersSortsAndRoundTrips() throws {
        var lib = MaterialLibrary()
        let layer = Layer(name: "", colorHex: "#000000")
        lib.upsert(CutMaterial(name: "Walnut", thickness: 6, kind: .grblLaser, settings: layer))
        lib.upsert(CutMaterial(name: "acrylic", thickness: 3, kind: .grblLaser, settings: layer))
        lib.upsert(CutMaterial(name: "Acrylic", thickness: 2, kind: .grblLaser, settings: layer))
        lib.upsert(CutMaterial(name: "Oracal 651", kind: .vinylCutter, settings: Layer(name: "", colorHex: "#000000", mode: .cut)))
        XCTAssertEqual(lib.materials(for: .grblLaser).map(\.thickness), [2, 3, 6])
        XCTAssertEqual(lib.materials(for: .vinylCutter).count, 1)
        XCTAssertEqual(lib.materials(for: .cncRouter).count, 0)

        let back = try MaterialLibrary.decode(lib.encoded())
        XCTAssertEqual(back.materials.count, 4)
        XCTAssertEqual(back.materials.map(\.id), lib.materials.map(\.id))

        // Merging adds new ones and only replaces older copies.
        var other = MaterialLibrary()
        var newer = lib.materials[0]
        newer.notes = "Mask both sides"
        newer.modified = lib.materials[0].modified.addingTimeInterval(60)
        other.upsert(newer)
        other.upsert(CutMaterial(name: "Cardstock", kind: .vinylCutter, settings: layer))
        XCTAssertEqual(lib.merge(other), 2)
        XCTAssertEqual(lib.materials.count, 5)
        XCTAssertEqual(lib.material(newer.id)?.notes, "Mask both sides")
    }

    func testLayerWithoutMaterialIDStillDecodes() throws {
        let layer = try JSONDecoder().decode(Layer.self, from: Data(##"{"name":"A","colorHex":"#000000"}"##.utf8))
        XCTAssertNil(layer.materialID)
    }
}
