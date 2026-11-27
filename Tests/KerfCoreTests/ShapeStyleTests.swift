import XCTest
@testable import KerfCore

final class ShapeStyleTests: XCTestCase {
    private let square = Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)], closed: true)

    func testStrokeBandHasOuterAndInnerEdges() {
        let loops = StyleGeometry.stroke([square], width: 2)
        XCTAssertEqual(loops.count, 2)
        let outer = loops.max { $0.bounds.width < $1.bounds.width }!.bounds
        let inner = loops.min { $0.bounds.width < $1.bounds.width }!.bounds
        XCTAssertEqual(outer.width, 12, accuracy: 0.4)
        XCTAssertEqual(inner.width, 8, accuracy: 0.4)
    }

    func testStrokeOnOpenLineIsOneLoop() {
        let loops = StyleGeometry.stroke([Polyline([Vec2(0, 0), Vec2(20, 0)])], width: 3)
        XCTAssertEqual(loops.count, 1)
        XCTAssertEqual(loops[0].bounds.height, 3, accuracy: 0.3)
        XCTAssertEqual(loops[0].bounds.width, 23, accuracy: 0.4)
    }

    func testOffsetGrowsAndShrinks() {
        let grown = StyleGeometry.offset([square], by: 2)
        XCTAssertEqual(grown.count, 1)
        XCTAssertEqual(grown[0].bounds.width, 14, accuracy: 0.4)
        let shrunk = StyleGeometry.offset([square], by: -2)
        XCTAssertEqual(shrunk.count, 1)
        XCTAssertEqual(shrunk[0].bounds.width, 6, accuracy: 0.4)
        XCTAssertTrue(StyleGeometry.offset([square], by: -6).isEmpty, "shrinking past the middle leaves nothing")
    }

    private func styledDocument(outline: Bool = true) -> (KerfDocument, UUID, UUID) {
        var doc = KerfDocument()
        let cut = doc.addLayer(mode: .line)
        let engrave = doc.addLayer(mode: .fill)
        var shape = Artwork(layerID: cut, name: "Box", paths: [square], transform: .translation(50, 50))
        shape.style = ArtworkStyle(parts: [StylePart(kind: .stroke, layerID: engrave, amount: 1)], outlineEnabled: outline)
        doc.shapes = [shape]
        return (doc, cut, engrave)
    }

    func testStyleShapesLandOnTheirOwnLayer() {
        let (doc, cut, engrave) = styledDocument()
        let shapes = doc.machineShapes()
        XCTAssertEqual(shapes.count, 2)
        XCTAssertEqual(shapes[1].layerID, engrave)
        XCTAssertEqual(shapes[1].id, Artwork.partID(doc.shapes[0].id, .stroke))
        XCTAssertNotEqual(shapes[1].id, doc.shapes[0].id)
        XCTAssertEqual(shapes[1].bounds.minX, 49.5, accuracy: 0.3, "placed like the shape")
        XCTAssertEqual(doc.itemCount(onLayer: cut), 1)
        XCTAssertEqual(doc.itemCount(onLayer: engrave), 1)
        XCTAssertEqual(doc.styleOwner(ofLayer: engrave)?.kind, .stroke)

        let tp = Planner.plan(doc, for: .grblLaser)
        XCTAssertTrue(tp.layers.contains { $0.layer.id == engrave && !$0.paths.isEmpty }, "the stroke band is engraved")
        XCTAssertTrue(tp.layers.contains { $0.layer.id == cut })
    }

    func testOutlineCanBeLeftOut() {
        let (doc, cut, engrave) = styledDocument(outline: false)
        let tp = Planner.plan(doc, for: .grblLaser)
        XCTAssertFalse(tp.layers.contains { $0.layer.id == cut })
        XCTAssertTrue(tp.layers.contains { $0.layer.id == engrave })
        XCTAssertEqual(doc.itemCount(onLayer: cut), 0)
    }

    func testEmbroideryKeepsStrokeAsALineWithWidth() {
        let (doc, _, engrave) = styledDocument()
        let stroke = doc.machineShapes(embroidery: true).first { $0.layerID == engrave }
        XCTAssertEqual(stroke?.strokeWidth ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(stroke?.paths, [square])
        let plan = EmbroideryPlanner.plan(doc)
        XCTAssertEqual(plan.blocks.count, 2, "outline and stroke are sewn in their own colours")
    }

    func testDisabledPartsAndRemovedLayersAreSkipped() {
        var (doc, _, engrave) = styledDocument()
        doc.shapes[0].style?.parts[0].enabled = false
        XCTAssertEqual(doc.machineShapes().count, 1)
        doc.shapes[0].style?.parts[0].enabled = true
        doc.layers.removeAll { $0.id == engrave }
        XCTAssertEqual(doc.machineShapes().count, 1)
        doc.pruneStyleParts()
        XCTAssertNil(doc.shapes[0].style)
    }

    func testStyleSurvivesSaving() throws {
        let (doc, _, _) = styledDocument()
        let back = try KerfDocument.decode(doc.encoded())
        XCTAssertEqual(back.shapes[0].style, doc.shapes[0].style)
    }

    func testFillPartPocketsOnCNC() {
        var doc = KerfDocument()
        let a = doc.addLayer(mode: .mill), b = doc.addLayer(mode: .mill)
        var shape = Artwork(layerID: a, name: "Box", paths: [square])
        shape.style = ArtworkStyle(parts: [StylePart(kind: .fill, layerID: b)])
        doc.shapes = [shape]
        XCTAssertEqual(doc.machineShapes().last?.millRole, .pocket)
    }

    func testCornerRadiusRoundsSharpCorners() {
        let r = Fillet.round(square, radius: 2)
        XCTAssertGreaterThan(r.points.count, 8)
        XCTAssertEqual(r.bounds.width, 10, accuracy: 1e-6, "sides stay where they were")
        let nearest = r.points.map { $0.length }.min()!
        XCTAssertEqual(nearest, 2 * (2.0.squareRoot() - 1), accuracy: 0.05, "the corner is cut by the arc")
        // A radius too big for the sides is limited to half of each side.
        let big = Fillet.round(square, radius: 50)
        XCTAssertEqual(big.bounds.width, 10, accuracy: 1e-6)
        XCTAssertEqual(big.points.map { $0.distance(to: Vec2(5, 5)) }.max()!, 5, accuracy: 0.05)
        // Open paths keep their ends.
        let open = Fillet.round(Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)]), radius: 2)
        XCTAssertEqual(open.points.first, Vec2(0, 0))
        XCTAssertEqual(open.points.last, Vec2(10, 10))
    }

    func testCornerRadiusAppliesToOutlineAndStyles() {
        var (doc, cut, engrave) = styledDocument()
        doc.shapes[0].style?.cornerRadius = 3
        let shapes = doc.machineShapes()
        let outline = shapes.first { $0.layerID == cut }!
        XCTAssertGreaterThan(outline.paths[0].points.count, 4)
        XCTAssertEqual(doc.shapes[0].paths, [square], "the shape itself is unchanged, so the radius can be edited")
        XCTAssertNotNil(shapes.first { $0.layerID == engrave })
        // Radius alone (no parts) keeps a style.
        var plain = KerfDocument()
        let l = plain.addLayer(mode: .line)
        var s = Artwork(layerID: l, name: "Box", paths: [square])
        s.style = ArtworkStyle(cornerRadius: 1)
        plain.shapes = [s]
        plain.pruneStyleParts()
        XCTAssertNotNil(plain.shapes[0].style)
        XCTAssertGreaterThan(plain.machineShapes()[0].paths[0].points.count, 4)
    }
}
