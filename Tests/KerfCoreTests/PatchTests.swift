import XCTest
@testable import KerfCore

final class PatchTests: XCTestCase {
    private let design = Rect2(minX: 40, minY: 30, maxX: 100, maxY: 60)

    private func corners(_ r: Rect2) -> [Vec2] {
        [Vec2(r.minX, r.minY), Vec2(r.maxX, r.minY), Vec2(r.maxX, r.maxY), Vec2(r.minX, r.maxY)]
    }

    func testEveryShapeHoldsTheDesignInsideTheBorder() {
        let o = PatchOptions(margin: 3, borderWidth: 4)
        for shape in PatchShape.allCases where shape != .contour {
            let edge = Patch.edge(shape, around: design, options: o)
            XCTAssertTrue(edge.closed, shape.rawValue)
            let inner = PathOffset.offset(edge, by: -o.borderReach)
            for p in corners(design.insetBy(-o.margin)) {
                XCTAssertTrue(Planner.contains(inner, p), "\(shape.rawValue) cuts into the design at \(p)")
            }
            // Snug: not much bigger than needed.
            XCTAssertLessThan(edge.bounds.width, design.width * 2.2 + 30, shape.rawValue)
        }
    }

    func testCircleIsRound() {
        let edge = Patch.edge(.circle, around: design, options: PatchOptions())
        XCTAssertEqual(edge.bounds.width, edge.bounds.height, accuracy: 0.5)
    }

    func testFixedSizeEdge() {
        let r = Rect2(minX: 0, minY: 0, maxX: 76.2, maxY: 50)
        let edge = Patch.edge(.roundedRectangle, in: r, cornerRadius: 8)
        XCTAssertEqual(edge.bounds.width, 76.2, accuracy: 0.01)
        XCTAssertEqual(edge.bounds.height, 50, accuracy: 0.01)
    }

    func testFabricPatchPartsAndOrder() {
        let o = PatchOptions(backing: .fabric, placementLine: true, cutFabricPiece: true, cutOutPatch: true)
        let edge = Patch.edge(.circle, in: Rect2(minX: 0, minY: 0, maxX: 80, maxY: 80), cornerRadius: 0)
        let parts = Patch.parts(edge: edge, options: o, cutMode: .line)
        XCTAssertEqual(parts.map(\.kind), [.placement, .tackdown, .border, .fabricCut, .outerCut])
        XCTAssertTrue(parts[0].layer.embroideryStop)
        XCTAssertTrue(parts[1].layer.embroideryStop)
        XCTAssertFalse(parts[2].layer.embroideryStop)
        XCTAssertEqual(parts[2].layer.embroidery?.stitchType, .satin)
        XCTAssertEqual(parts[2].layer.embroidery?.satinWidth, 4)
        for p in parts where !p.kind.isCut { XCTAssertEqual(p.layer.output, .embroidery) }
        for p in parts where p.kind.isCut {
            XCTAssertEqual(p.layer.output, .machines)
            XCTAssertEqual(p.layer.mode, .line)
        }
        // Sizes from the edge in: cut-out line > edge > fabric piece > border middle > tackdown.
        func radius(_ k: PatchPartKind) -> Double { parts.first { $0.kind == k }!.paths[0].bounds.width / 2 }
        XCTAssertEqual(radius(.outerCut), 40.5, accuracy: 0.1)
        XCTAssertEqual(radius(.border), 38, accuracy: 0.1)
        XCTAssertEqual(radius(.placement), 38, accuracy: 0.1)
        XCTAssertEqual(radius(.fabricCut), 39, accuracy: 0.1)
        XCTAssertLessThan(radius(.tackdown), 38)
        XCTAssertGreaterThan(radius(.tackdown), 36)
    }

    func testFillBackingRunsUnderTheBorder() {
        let o = PatchOptions(border: .satin, borderWidth: 5, backing: .fill, cutFabricPiece: true)
        let edge = Patch.edge(.circle, in: Rect2(minX: 0, minY: 0, maxX: 80, maxY: 80), cornerRadius: 0)
        let parts = Patch.parts(edge: edge, options: o, cutMode: .cut)
        // No fabric, so no fabric piece to cut.
        XCTAssertEqual(parts.map(\.kind), [.backingFill, .border])
        let fill = parts[0].paths[0].bounds.width / 2
        // Border inner edge is at 35; the fill reaches 1 mm under it.
        XCTAssertEqual(fill, 36, accuracy: 0.1)
        XCTAssertEqual(parts[0].layer.embroidery?.stitchType, .fill)
    }

    func testApplyOrdersLayersAroundTheDesign() {
        var doc = KerfDocument()
        let art = Layer(name: "Art", colorHex: "#FF0000")
        doc.layers = [art]
        doc.shapes = [Artwork(layerID: art.id, name: "Star", paths: [Polyline([Vec2(30, 30), Vec2(50, 30), Vec2(40, 50)], closed: true)])]
        let edge = Patch.edge(.circle, around: doc.bounds, options: PatchOptions())
        let parts = Patch.parts(edge: edge, options: PatchOptions(cutOutPatch: true), cutMode: .cut)
        let ids = Patch.apply(parts, to: &doc)
        XCTAssertEqual(ids.count, parts.count)
        XCTAssertEqual(doc.layers.map(\.name), ["Patch placement line", "Patch tackdown", "Art", "Patch border", "Patch cut-out line"])
    }

    func testStopsKeepAppliqueStepsApartAndOffTheLaser() {
        var doc = KerfDocument()
        let art = Layer(name: "Art", colorHex: "#1F2937")
        doc.layers = [art]
        doc.shapes = [Artwork(layerID: art.id, name: "Box", paths: [Polyline([Vec2(30, 30), Vec2(50, 30), Vec2(50, 50), Vec2(30, 50)], closed: true)])]
        // Fabric and border share the design's thread colour, which would normally merge.
        let o = PatchOptions(borderColorHex: "#1F2937", backgroundColorHex: "#1F2937", cutOutPatch: true)
        let edge = Patch.edge(.circle, around: doc.bounds, options: o)
        Patch.apply(Patch.parts(edge: edge, options: o, cutMode: .line), to: &doc)

        let plan = EmbroideryPlanner.plan(doc)
        // Placement, stop, tackdown, stop, then the design and border together. The cut line isn't sewn.
        XCTAssertEqual(plan.blocks.map(\.name), ["Patch placement line", "Patch tackdown", "Art"])
        let pattern = StitchPattern(plan: plan)
        XCTAssertEqual(pattern.colorChangeCount, 2)

        // The laser only sees the design and the cut line, not the sewing layers.
        let tp = Planner.plan(doc, for: .grblLaser)
        XCTAssertEqual(Set(tp.layers.map(\.layer.name)), ["Art", "Patch cut-out line"])
    }

    func testLayerOutputSurvivesCoding() throws {
        var layer = Layer(name: "x", colorHex: "#000000")
        layer.output = .embroidery
        layer.embroideryStop = true
        let back = try JSONDecoder().decode(Layer.self, from: JSONEncoder().encode(layer))
        XCTAssertEqual(back.output, .embroidery)
        XCTAssertTrue(back.embroideryStop)
        // Older files without the keys.
        let old = try JSONDecoder().decode(Layer.self, from: Data(##"{"name":"a","colorHex":"#000000"}"##.utf8))
        XCTAssertEqual(old.output, .all)
        XCTAssertFalse(old.embroideryStop)
    }

    func testOptionsDecodeWithMissingKeys() throws {
        let o = try JSONDecoder().decode(PatchOptions.self, from: Data(#"{"shape":"shield"}"#.utf8))
        XCTAssertEqual(o.shape, .shield)
        XCTAssertEqual(o.borderWidth, PatchOptions().borderWidth)
    }

    func testContourEdgePicksLargestLoop() {
        let small = Polyline([Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)], closed: true)
        let big = Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)], closed: true)
        XCTAssertEqual(Patch.contourEdge([small, big]), big)
    }
}
