@testable import KerfCore
import XCTest

final class WorkpieceTests: XCTestCase {
    func testColourRoundTripsAndOldWorkpiecesHaveNone() throws {
        var doc = KerfDocument()
        doc.workpiece = Workpiece(kind: .hoop, name: "Tee", width: 130, height: 180, thickness: 1, colorHex: "#1F2A44")
        let back = try KerfDocument.decode(doc.encoded())
        XCTAssertEqual(back.workpiece?.colorHex, "#1F2A44")
        let old = try KerfDocument.decode(Data(#"""
        {"version":2,"document":{"layers":[],"shapes":[],"workpiece":{"kind":"mat","name":"Mat","x":0,"y":0,"width":300,"height":300,"thickness":0.3}}}
        """#.utf8))
        XCTAssertNotNil(old.workpiece)
        XCTAssertNil(old.workpiece?.colorHex)
    }

    func testLibrarySavesReplacesAndRemoves() {
        var lib = WorkpieceLibrary()
        let w = Workpiece(kind: .sheet, name: "x", x: 40, y: 50, width: 250, height: 400, thickness: 0.1, colorHex: "#B3202A")
        XCTAssertFalse(lib.save(w, as: "   "))
        XCTAssertTrue(lib.save(w, as: " Red vinyl roll "))
        XCTAssertEqual(lib.items.count, 1)
        XCTAssertEqual(lib.items[0].name, "Red vinyl roll")
        XCTAssertEqual(lib.items[0].x, 0)
        XCTAssertEqual(lib.items[0].y, 0)
        XCTAssertEqual(lib.items[0].colorHex, "#B3202A")
        var wider = w
        wider.width = 300
        lib.save(wider, as: "red VINYL roll")
        XCTAssertEqual(lib.items.count, 1)
        XCTAssertEqual(lib.items[0].width, 300)
        XCTAssertTrue(lib.contains(named: "Red Vinyl Roll"))
        lib.remove(named: "red VINYL roll")
        XCTAssertTrue(lib.items.isEmpty)
        let data = try! JSONEncoder().encode(lib)
        XCTAssertEqual(try! JSONDecoder().decode(WorkpieceLibrary.self, from: data), lib)
    }

    func testResizedLikeKeepsPlace() {
        let w = Workpiece(kind: .stock, name: "a", x: 12, y: 34, width: 100, height: 100)
        let p = Workpiece(kind: .hoop, name: "Hoop", width: 130, height: 180, thickness: 1, colorHex: "#FFFFFF")
        let n = w.resized(like: p)
        XCTAssertEqual(n.x, 12)
        XCTAssertEqual(n.y, 34)
        XCTAssertEqual(n.width, 130)
        XCTAssertEqual(n.kind, .hoop)
        XCTAssertEqual(n.colorHex, "#FFFFFF")
    }

    func testEdgeColourContrastsWithMaterial() {
        let dark = Workpiece(kind: .hoop, width: 1, height: 1, colorHex: "#1C1C1E")
        let light = Workpiece(kind: .hoop, width: 1, height: 1, colorHex: "#FFFFFF")
        XCTAssertGreaterThan(dark.edgeColor.luminance, ThreadColor(hex: "#1C1C1E").luminance)
        XCTAssertLessThan(light.edgeColor.luminance, 1)
        XCTAssertEqual(ThreadColor(hex: "#808080").darkened(by: 1), ThreadColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(ThreadColor(hex: "#808080").lightened(by: 1), ThreadColor(red: 255, green: 255, blue: 255))
        XCTAssertEqual(ThreadColor(hex: "#808080").darkened(by: 0), ThreadColor(hex: "#808080"))
        for s in Workpiece.colorSwatches { XCTAssertEqual(ThreadColor(hex: s.hex).hex, s.hex) }
    }
}
