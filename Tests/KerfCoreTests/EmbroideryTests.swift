import XCTest
@testable import KerfCore

final class EmbroideryTests: XCTestCase {
    private func doc(_ layers: [(String, StitchType, [Polyline])]) -> KerfDocument {
        var d = KerfDocument()
        for (color, type, paths) in layers {
            var layer = Layer(name: color, colorHex: color, mode: type == .fill ? .fill : .line)
            layer.embroidery = EmbroiderySettings(stitchType: type)
            d.layers.append(layer)
            d.shapes.append(Artwork(layerID: layer.id, name: "s", paths: paths))
        }
        return d
    }

    private let square = Polyline([Vec2(0, 0), Vec2(20, 0), Vec2(20, 20), Vec2(0, 20)], closed: true)

    // MARK: Stitch generation

    func testRunningStitchSpacing() {
        let pts = EmbroideryPlanner.running([Vec2(0, 0), Vec2(10, 0)], length: 2.5)
        XCTAssertEqual(pts.count, 5)
        for i in 1..<pts.count { XCTAssertEqual(pts[i].distance(to: pts[i - 1]), 2.5, accuracy: 1e-9) }
    }

    func testRunningStitchKeepsCorners() {
        let pts = EmbroideryPlanner.running([Vec2(0, 0), Vec2(9, 0), Vec2(9, 9)], length: 4)
        XCTAssertTrue(pts.contains { $0.distance(to: Vec2(9, 0)) < 1e-9 })
        XCTAssertEqual(pts.last!.distance(to: Vec2(9, 9)), 0, accuracy: 1e-9)
    }

    func testBeanTriplesEachStitch() {
        let pts = EmbroideryPlanner.bean([Vec2(0, 0), Vec2(1, 0), Vec2(2, 0)])
        XCTAssertEqual(pts, [Vec2(0, 0), Vec2(1, 0), Vec2(0, 0), Vec2(1, 0), Vec2(2, 0), Vec2(1, 0), Vec2(2, 0)])
    }

    func testSatinStaysWithinColumnWidth() {
        var s = EmbroiderySettings(stitchType: .satin, satinWidth: 4, density: 0.5, underlay: false, pullCompensation: 0)
        s = s.sanitized
        let runs = EmbroideryPlanner.satin([Vec2(0, 0), Vec2(20, 0)], settings: s)
        XCTAssertEqual(runs.count, 1)
        let pts = runs[0]
        XCTAssertEqual(pts.count, 41)
        for p in pts { XCTAssertEqual(abs(p.y), 2, accuracy: 1e-6) }
        // Zig-zags alternate sides.
        XCTAssertLessThan(pts[0].y * pts[1].y, 0)
    }

    func testFillCoversSquareAndStaysInside() {
        let runs = EmbroideryPlanner.fill([square], angle: 0, spacing: 0.5, stitchLength: 3, extend: 0, from: .zero)
        XCTAssertFalse(runs.isEmpty)
        let all = runs.flatMap { $0 }
        for p in all {
            XCTAssertGreaterThanOrEqual(p.x, -1e-6)
            XCTAssertLessThanOrEqual(p.x, 20 + 1e-6)
            XCTAssertGreaterThanOrEqual(p.y, -1e-6)
            XCTAssertLessThanOrEqual(p.y, 20 + 1e-6)
        }
        // 40 rows of 0.5 mm, all in one back-and-forth run.
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(Set(all.map { ($0.y * 100).rounded() }).count, 40)
        // No stitch is longer than the stitch length.
        for i in 1..<runs[0].count { XCTAssertLessThanOrEqual(runs[0][i].distance(to: runs[0][i - 1]), 3 + 1e-6) }
    }

    func testFillLeavesHolesOpen() {
        let hole = Polyline([Vec2(5, 5), Vec2(15, 5), Vec2(15, 15), Vec2(5, 15)], closed: true)
        let runs = EmbroideryPlanner.fill([square, hole], angle: 0, spacing: 0.5, stitchLength: 3, extend: 0, from: .zero)
        let all = runs.flatMap { $0 }
        XCTAssertFalse(all.contains { $0.x > 5.2 && $0.x < 14.8 && $0.y > 5.2 && $0.y < 14.8 })
    }

    func testRotatedFillStaysInside() {
        let runs = EmbroideryPlanner.fill([square], angle: 45, spacing: 0.4, stitchLength: 3.5, extend: 0, from: .zero)
        for p in runs.flatMap({ $0 }) {
            XCTAssertTrue(p.x > -0.01 && p.x < 20.01 && p.y > -0.01 && p.y < 20.01, "\(p)")
        }
    }

    func testPlanGroupsLayersByColour() {
        let d = doc([("#FF0000", .running, [square]), ("#FF0000", .running, [square]), ("#0000FF", .fill, [square])])
        let plan = EmbroideryPlanner.plan(d)
        XCTAssertEqual(plan.blocks.count, 2)
        XCTAssertEqual(plan.blocks[0].color, ThreadColor(hex: "#FF0000"))
        XCTAssertEqual(plan.blocks[1].color, ThreadColor(hex: "#0000FF"))
    }

    func testPrintAndImageLayersAreNotSewn() {
        var d = doc([("#FF0000", .running, [square])])
        d.layers[0].mode = .print
        XCTAssertTrue(EmbroideryPlanner.plan(d).isEmpty)
    }

    // MARK: Machine pattern

    func testPatternIsCentredWithColourChangeAndEnd() {
        let d = doc([("#FF0000", .running, [square]), ("#0000FF", .running, [Polyline([Vec2(0, 30), Vec2(20, 30)])])])
        let p = StitchPattern(plan: EmbroideryPlanner.plan(d), name: "Test")
        XCTAssertEqual(p.threads.count, 2)
        XCTAssertEqual(p.colorChangeCount, 1)
        XCTAssertEqual(p.entries.last?.command, .end)
        let e = p.extent
        XCTAssertLessThanOrEqual(abs(e.minX + e.maxX), 1)
        XCTAssertLessThanOrEqual(abs(e.minY + e.maxY), 1)
        XCTAssertEqual(p.size.width, 20, accuracy: 0.11)
        XCTAssertEqual(p.size.height, 30, accuracy: 0.11)
        // The first move is a jump from the hoop centre to the first stitch.
        XCTAssertEqual(p.entries.first?.command, .jump)
    }

    func testExpandedSplitsLongMoves() {
        let p = StitchPattern(entries: [.init(1000, -500, .jump), .init(1000, 0, .stitch), .init(1000, 0, .end)],
                              threads: [ThreadColor(rgb: 0)], name: "x")
        let e = p.expanded(maxStep: 121)
        var x = 0, y = 0
        for en in e where en.command != .end {
            XCTAssertLessThanOrEqual(abs(en.x - x), 121)
            XCTAssertLessThanOrEqual(abs(en.y - y), 121)
            x = en.x
            y = en.y
        }
        XCTAssertEqual(x, 1000)
        XCTAssertEqual(y, 0)
    }

    private func samplePattern() -> StitchPattern {
        let circle = Flatten.ellipse(center: Vec2(30, 30), rx: 25, ry: 25, step: 0.5)
        let d = doc([("#E5222D", .fill, [circle]), ("#000000", .satin, [Polyline([Vec2(0, 70), Vec2(60, 70)])]),
                     ("#16A34A", .bean, [square])])
        return StitchPattern(plan: EmbroideryPlanner.plan(d), name: "Sample")
    }

    /// Absolute positions of the moves (stitches and jumps) in `entries`.
    private func moves(_ entries: [StitchPattern.Entry]) -> [(Int, Int)] {
        entries.filter { $0.command == .stitch || $0.command == .jump }.map { ($0.x, $0.y) }
    }

    // MARK: DST

    /// Decodes one DST record to (dx, dy-down, flags byte).
    private func decodeDST(_ b: [UInt8]) -> (Int, Int, UInt8) {
        func bit(_ v: UInt8, _ n: Int) -> Int { Int((v >> n) & 1) }
        var x = 0, y = 0
        x += bit(b[0], 0) - bit(b[0], 1) + 9 * (bit(b[0], 2) - bit(b[0], 3))
        x += 3 * (bit(b[1], 0) - bit(b[1], 1)) + 27 * (bit(b[1], 2) - bit(b[1], 3))
        x += 81 * (bit(b[2], 2) - bit(b[2], 3))
        y += bit(b[0], 7) - bit(b[0], 6) + 9 * (bit(b[0], 5) - bit(b[0], 4))
        y += 3 * (bit(b[1], 7) - bit(b[1], 6)) + 27 * (bit(b[1], 5) - bit(b[1], 4))
        y += 81 * (bit(b[2], 5) - bit(b[2], 4))
        return (x, -y, b[2])
    }

    func testDSTRecordRoundTrip() {
        for dx in stride(from: -121, through: 121, by: 11) {
            for dy in stride(from: -121, through: 121, by: 13) {
                let r = DSTWriter.record(dx, dy, jump: false)
                let (x, y, f) = decodeDST(r)
                XCTAssertEqual(x, dx)
                XCTAssertEqual(y, dy)
                XCTAssertEqual(f & 0xC3, 0x03)
            }
        }
        XCTAssertEqual(DSTWriter.record(0, 0, jump: true)[2], 0x83)
    }

    func testDSTFile() {
        let p = samplePattern()
        let data = [UInt8](DSTWriter.data(p))
        XCTAssertEqual(data.count % 3, 512 % 3)
        let header = String(decoding: data[0..<125], as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("LA:Sample          \r"))
        XCTAssertTrue(header.contains("CO:  2\r"))
        XCTAssertEqual(data[511], 0x20)
        XCTAssertEqual(Array(data.suffix(3)), [0, 0, 0xF3])
        // Sum the moves: the decoded path must reach every needle position.
        var x = 0, y = 0
        var positions: [(Int, Int)] = []
        var i = 512
        while i + 3 <= data.count {
            let r = Array(data[i..<(i + 3)])
            i += 3
            if r[2] == 0xF3 || r[2] == 0xC3 { continue }
            let (dx, dy, _) = decodeDST(r)
            x += dx
            y += dy
            positions.append((x, y))
        }
        let expected = moves(p.expanded(maxStep: 121))
        // Trims add three net-zero jumps each.
        XCTAssertEqual(positions.count, expected.count + 3 * p.trimCount)
        XCTAssertEqual(positions.last?.0, expected.last?.0)
        XCTAssertEqual(positions.last?.1, expected.last?.1)
    }

    // MARK: JEF

    func testJEFFile() {
        let p = samplePattern()
        let data = [UInt8](JEFWriter.data(p, date: Date(timeIntervalSince1970: 0)))
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        let colors = u32(24)
        XCTAssertEqual(colors, 3)
        XCTAssertEqual(u32(0), 0x74 + colors * 8)
        XCTAssertEqual(String(decoding: data[8..<22], as: UTF8.self), "19700101000000")
        // Black maps to Janome 002 (index 1).
        XCTAssertEqual(u32(0x74 + 4), 1)
        XCTAssertEqual(Array(data.suffix(2)), [0x80, 0x10])
        var x = 0, y = 0, points = 1, i = u32(0)
        var positions: [(Int, Int)] = []
        while i < data.count - 2 {
            var isMove = true
            if data[i] == 0x80 {
                if data[i + 1] == 0x01 { isMove = false }
                i += 2
                points += 1
            }
            let dx = Int(Int8(bitPattern: data[i])), dy = -Int(Int8(bitPattern: data[i + 1]))
            i += 2
            points += 1
            x += dx
            y += dy
            if isMove { positions.append((x, y)) }
        }
        XCTAssertEqual(points, u32(28))
        let expected = moves(p.expanded(maxStep: 127))
        XCTAssertEqual(positions.count, expected.count)
        XCTAssertEqual(positions.last?.0, expected.last?.0)
        XCTAssertEqual(positions.last?.1, expected.last?.1)
    }

    // MARK: PES

    func testPESFile() {
        let p = samplePattern()
        let data = [UInt8](PESWriter.data(p))
        XCTAssertEqual(String(decoding: data[0..<8], as: UTF8.self), "#PES0001")
        let pec = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
        XCTAssertEqual(String(decoding: data[pec..<(pec + 3)], as: UTF8.self), "LA:")
        // Colour list: count - 1, then one Brother code per thread, all different.
        XCTAssertEqual(Int(data[pec + 48]), 2)
        let codes = Array(data[(pec + 49)..<(pec + 52)])
        XCTAssertEqual(Set(codes).count, 3)
        XCTAssertEqual(codes[1], 20) // black
        // Stitch block.
        let block = pec + 512
        let length = Int(data[block + 2]) | Int(data[block + 3]) << 8 | Int(data[block + 4]) << 16
        XCTAssertEqual(data[block + length - 1], 0xFF)
        // Thumbnails: the whole design plus one per thread.
        XCTAssertEqual(data.count - (block + length), 228 * 4)

        // Decode the PEC stitches and check they reach the last needle position.
        var i = block + 16, x = 0, y = 0
        var colorChanges = 0
        func read() -> Int {
            let b0 = Int(data[i])
            if b0 & 0x80 != 0 {
                var v = (b0 & 0x0F) << 8 | Int(data[i + 1])
                if v & 0x800 != 0 { v -= 0x1000 }
                i += 2
                return v
            }
            i += 1
            return b0 & 0x40 != 0 ? b0 - 0x80 : b0
        }
        while data[i] != 0xFF {
            if data[i] == 0xFE && data[i + 1] == 0xB0 {
                i += 3
                colorChanges += 1
                continue
            }
            x += read()
            y += read()
        }
        XCTAssertEqual(colorChanges, 2)
        let expected = moves(p.expanded(maxStep: 2047))
        XCTAssertEqual(x, expected.last?.0)
        XCTAssertEqual(y, expected.last?.1)
    }

    func testPESWithNoStitches() {
        let p = StitchPattern(plan: EmbroideryPlan(), name: "Empty")
        let data = PESWriter.data(p)
        XCTAssertGreaterThan(data.count, 512)
    }

    // MARK: Threads and files

    func testThreadMatching() {
        XCTAssertEqual(ThreadChart.brotherCodes(for: [ThreadColor(hex: "#000000")]), [20])
        XCTAssertEqual(ThreadChart.janomeCodes(for: [ThreadColor(hex: "#FFFFFF")]), [2])
        // Two near-identical reds in a row get different Janome codes.
        let codes = ThreadChart.janomeCodes(for: [ThreadColor(hex: "#FF0000"), ThreadColor(hex: "#FE0101")])
        XCTAssertNotEqual(codes[0], codes[1])
    }

    func testLayerEmbroiderySettingsSaveAndOldFilesOpen() throws {
        var d = KerfDocument()
        var layer = Layer(name: "L", colorHex: "#000000", mode: .fill)
        XCTAssertEqual(layer.embroiderySettings.stitchType, .fill)
        layer.embroidery = EmbroiderySettings(stitchType: .satin, satinWidth: 5)
        d.layers = [layer]
        let back = try KerfDocument.decode(d.encoded())
        XCTAssertEqual(back.layers[0].embroidery?.stitchType, .satin)
        XCTAssertEqual(back.layers[0].embroidery?.satinWidth, 5)

        let old = #"{"version":2,"document":{"layers":[{"name":"Old","colorHex":"#000000","mode":"line"}],"shapes":[]}}"#
        let opened = try KerfDocument.decode(Data(old.utf8))
        XCTAssertNil(opened.layers[0].embroidery)
        XCTAssertEqual(opened.layers[0].embroiderySettings.stitchType, .running)
    }

    func testHoopFit() {
        let h = EmbroideryHoop.brother[1] // 130 × 180
        XCTAssertTrue(h.fits(width: 120, height: 170))
        XCTAssertTrue(h.fits(width: 170, height: 120))
        XCTAssertFalse(h.fitsUpright(width: 170, height: 120))
        XCTAssertFalse(h.fits(width: 140, height: 190))
    }
}
