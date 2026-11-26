import Foundation

// MARK: - Machine pattern

/// A design ready for an embroidery machine: needle positions in 0.1 mm steps, centred on the hoop (y down),
/// with jumps, trims and colour changes between the stitches.
public struct StitchPattern: Hashable, Sendable {
    public enum Command: Hashable, Sendable {
        case stitch, jump, trim, colorChange, end
    }

    public struct Entry: Hashable, Sendable {
        public var x: Int
        public var y: Int
        public var command: Command

        public init(_ x: Int, _ y: Int, _ command: Command) {
            self.x = x
            self.y = y
            self.command = command
        }
    }

    public var entries: [Entry]
    /// One thread per colour block, in sewing order.
    public var threads: [ThreadColor]
    public var name: String

    public init(entries: [Entry], threads: [ThreadColor], name: String) {
        self.entries = entries
        self.threads = threads
        self.name = name
    }

    /// Builds the machine pattern. Runs closer than `connectGap` mm are joined with a stitch; further apart the
    /// thread is tied off, trimmed and jumped. Every run starts and ends with small tie (lock) stitches.
    public init(plan: EmbroideryPlan, name: String = "Design", connectGap: Double = 1, tieLength: Double = 0.5) {
        self.name = name
        threads = []
        entries = []
        let b = plan.bounds
        let c = b.isEmpty ? Vec2.zero : b.center
        func unit(_ p: Vec2) -> (Int, Int) {
            (Int(((p.x - c.x) * 10).rounded()), Int(((p.y - c.y) * 10).rounded()))
        }
        let gapUnits = connectGap * 10, tieUnits = tieLength * 10
        var cx = 0, cy = 0
        var out: [Entry] = []
        func add(_ x: Int, _ y: Int, _ cmd: Command) {
            out.append(Entry(x, y, cmd))
            cx = x
            cy = y
        }
        func dist(_ a: (Int, Int), _ b: (Int, Int)) -> Double {
            Double((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)).squareRoot()
        }
        /// Back and forth beside `p`, toward `q`, ending on `p`.
        func tie(at p: (Int, Int), toward q: (Int, Int)) {
            let d = dist(p, q)
            guard d > 0.5 else { return }
            let s = min(tieUnits, d) / d
            let t = (p.0 + Int((Double(q.0 - p.0) * s).rounded()), p.1 + Int((Double(q.1 - p.1) * s).rounded()))
            add(t.0, t.1, .stitch)
            add(p.0, p.1, .stitch)
            add(t.0, t.1, .stitch)
            add(p.0, p.1, .stitch)
        }

        var prev: (Int, Int)?
        var last: (Int, Int)?
        func tieOffAndTrim() {
            if let l = last, let p = prev { tie(at: l, toward: p) }
            add(cx, cy, .trim)
            last = nil
            prev = nil
        }

        for block in plan.blocks {
            var pts: [[(Int, Int)]] = []
            for run in block.runs {
                var r: [(Int, Int)] = []
                for p in run {
                    let q = unit(p)
                    if let l = r.last, l == q { continue }
                    r.append(q)
                }
                if r.count >= 2 { pts.append(r) }
            }
            guard !pts.isEmpty else { continue }
            if !threads.isEmpty { add(cx, cy, .colorChange) }
            threads.append(block.color)
            for run in pts {
                if let l = last, dist(l, run[0]) <= gapUnits {
                    for p in run where !(p.0 == cx && p.1 == cy) { add(p.0, p.1, .stitch) }
                } else {
                    if last != nil { tieOffAndTrim() }
                    if run[0].0 != cx || run[0].1 != cy { add(run[0].0, run[0].1, .jump) }
                    tie(at: run[0], toward: run[1])
                    for p in run.dropFirst() { add(p.0, p.1, .stitch) }
                }
                last = run[run.count - 1]
                prev = run[run.count - 2]
            }
            tieOffAndTrim()
        }
        add(cx, cy, .end)
        entries = out
    }

    /// Moves longer than `maxStep` (0.1 mm) split into equal shorter ones of the same kind.
    public func expanded(maxStep: Int) -> [Entry] {
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        var x = 0, y = 0
        for e in entries {
            switch e.command {
            case .stitch, .jump:
                let dx = e.x - x, dy = e.y - y
                let steps = max(1, Int((Double(max(abs(dx), abs(dy))) / Double(maxStep)).rounded(.up)))
                for k in 1...steps {
                    let f = Double(k) / Double(steps)
                    out.append(Entry(x + Int((Double(dx) * f).rounded()), y + Int((Double(dy) * f).rounded()), e.command))
                }
                x = e.x
                y = e.y
            default:
                out.append(Entry(x, y, e.command))
            }
        }
        return out
    }

    public var stitchCount: Int { entries.filter { $0.command == .stitch }.count }
    public var trimCount: Int { entries.filter { $0.command == .trim }.count }
    public var colorChangeCount: Int { entries.filter { $0.command == .colorChange }.count }

    /// Extent of all needle positions, in 0.1 mm.
    public var extent: (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        Self.extent(entries)
    }

    static func extent(_ entries: [Entry]) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        guard let f = entries.first else { return (0, 0, 0, 0) }
        var r = (minX: f.x, minY: f.y, maxX: f.x, maxY: f.y)
        for e in entries {
            r.minX = min(r.minX, e.x)
            r.minY = min(r.minY, e.y)
            r.maxX = max(r.maxX, e.x)
            r.maxY = max(r.maxY, e.y)
        }
        return r
    }

    /// Design size in mm.
    public var size: (width: Double, height: Double) {
        let e = extent
        return (Double(e.maxX - e.minX) / 10, Double(e.maxY - e.minY) / 10)
    }

    /// Rough sewing time: stitches at `stitchesPerMinute`, plus a pause for each trim and thread change.
    public func estimatedMinutes(stitchesPerMinute: Double = 600) -> Double {
        Double(stitchCount) / stitchesPerMinute + Double(trimCount) * 4 / 60 + Double(colorChangeCount) * 0.5
    }
}

// MARK: - File formats

public enum EmbroideryFormat: String, CaseIterable, Identifiable, Sendable {
    /// Brother, Baby Lock and Bernette machines.
    case pes
    /// Janome, Elna and Kenmore machines.
    case jef
    /// Tajima DST, read by most machines and digitizing software.
    case dst

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var title: String {
        switch self {
        case .pes: return "Brother (PES)"
        case .jef: return "Janome (JEF)"
        case .dst: return "Tajima (DST)"
        }
    }

    public var hoops: [EmbroideryHoop] {
        switch self {
        case .pes: return EmbroideryHoop.brother
        case .jef: return EmbroideryHoop.janome
        case .dst: return EmbroideryHoop.all
        }
    }

    /// The thread chart the file's colours are matched to, if it stores chart codes.
    public var threadChart: [ThreadChartEntry?]? {
        switch self {
        case .pes: return ThreadChart.brother
        case .jef: return ThreadChart.janome
        case .dst: return nil
        }
    }

    public func data(_ pattern: StitchPattern, date: Date = Date()) -> Data {
        switch self {
        case .pes: return PESWriter.data(pattern)
        case .jef: return JEFWriter.data(pattern, date: date)
        case .dst: return DSTWriter.data(pattern)
        }
    }
}

/// Little-endian byte writer.
struct ByteBuffer {
    var data = Data()

    var count: Int { data.count }

    mutating func u8(_ v: Int) { data.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) {
        u8(v)
        u8(v >> 8)
    }
    mutating func u24(_ v: Int) {
        u16(v)
        u8(v >> 16)
    }
    mutating func u32(_ v: Int) {
        u16(v)
        u16(v >> 16)
    }
    mutating func f32(_ v: Double) { u32(Int(Float(v).bitPattern)) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }

    mutating func patch(at offset: Int, u16 v: Int) {
        data[data.startIndex + offset] = UInt8(truncatingIfNeeded: v)
        data[data.startIndex + offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    mutating func patch(at offset: Int, u24 v: Int) {
        patch(at: offset, u16: v)
        data[data.startIndex + offset + 2] = UInt8(truncatingIfNeeded: v >> 16)
    }
    mutating func patch(at offset: Int, u32 v: Int) {
        patch(at: offset, u16: v)
        patch(at: offset + 2, u16: v >> 16)
    }
}

/// A design name safe for a fixed-width ASCII header field.
func headerName(_ name: String, length: Int) -> String {
    let ascii = String(name.unicodeScalars.filter { $0.isASCII && $0.value >= 32 && $0 != "\r" }.map(Character.init))
    let trimmed = String((ascii.isEmpty ? "Design" : ascii).prefix(length))
    return trimmed.padding(toLength: length, withPad: " ", startingAt: 0)
}

// MARK: Tajima DST

public enum DSTWriter {
    static let maxStep = 121

    public static func data(_ pattern: StitchPattern) -> Data {
        let entries = pattern.expanded(maxStep: maxStep)
        let e = StitchPattern.extent(entries)
        var b = ByteBuffer()
        b.ascii("LA:" + headerName(pattern.name, length: 16) + "\r")
        b.ascii(String(format: "ST:%7ld\r", entries.count))
        b.ascii(String(format: "CO:%3ld\r", entries.filter { $0.command == .colorChange }.count))
        // DST is y up, so the design's top (smallest y here) is +Y.
        b.ascii(String(format: "+X:%5ld\r", abs(e.maxX)))
        b.ascii(String(format: "-X:%5ld\r", abs(e.minX)))
        b.ascii(String(format: "+Y:%5ld\r", abs(e.minY)))
        b.ascii(String(format: "-Y:%5ld\r", abs(e.maxY)))
        let ax = entries.last?.x ?? 0, ay = -(entries.last?.y ?? 0)
        b.ascii("AX:" + (ax >= 0 ? "+" : "-") + String(format: "%5ld\r", abs(ax)))
        b.ascii("AY:" + (ay >= 0 ? "+" : "-") + String(format: "%5ld\r", abs(ay)))
        b.ascii(String(format: "MX:+%5ld\r", 0))
        b.ascii(String(format: "MY:+%5ld\r", 0))
        b.ascii("PD:******\r")
        b.u8(0x1A)
        while b.count < 512 { b.u8(0x20) }

        var x = 0, y = 0
        for en in entries {
            switch en.command {
            case .stitch, .jump:
                b.bytes(record(en.x - x, en.y - y, jump: en.command == .jump))
                x = en.x
                y = en.y
            case .trim:
                // Tajima machines trim on three jumps in a row; these end where they started.
                b.bytes(record(2, 2, jump: true))
                b.bytes(record(-4, -4, jump: true))
                b.bytes(record(2, 2, jump: true))
            case .colorChange:
                b.bytes([0, 0, 0xC3])
            case .end:
                b.bytes([0, 0, 0xF3])
            }
        }
        return b.data
    }

    /// One 3-byte DST record (balanced ternary). `dy` is y down; DST stores y up.
    static func record(_ dxIn: Int, _ dyIn: Int, jump: Bool) -> [UInt8] {
        var x = dxIn, y = -dyIn
        var b0 = 0, b1 = 0, b2 = 0x03
        if jump { b2 |= 0x80 }
        if x > 40 { b2 |= 1 << 2; x -= 81 }
        if x < -40 { b2 |= 1 << 3; x += 81 }
        if x > 13 { b1 |= 1 << 2; x -= 27 }
        if x < -13 { b1 |= 1 << 3; x += 27 }
        if x > 4 { b0 |= 1 << 2; x -= 9 }
        if x < -4 { b0 |= 1 << 3; x += 9 }
        if x > 1 { b1 |= 1 << 0; x -= 3 }
        if x < -1 { b1 |= 1 << 1; x += 3 }
        if x > 0 { b0 |= 1 << 0; x -= 1 }
        if x < 0 { b0 |= 1 << 1; x += 1 }
        if y > 40 { b2 |= 1 << 5; y -= 81 }
        if y < -40 { b2 |= 1 << 4; y += 81 }
        if y > 13 { b1 |= 1 << 5; y -= 27 }
        if y < -13 { b1 |= 1 << 4; y += 27 }
        if y > 4 { b0 |= 1 << 5; y -= 9 }
        if y < -4 { b0 |= 1 << 4; y += 9 }
        if y > 1 { b1 |= 1 << 7; y -= 3 }
        if y < -1 { b1 |= 1 << 6; y += 3 }
        if y > 0 { b0 |= 1 << 7; y -= 1 }
        if y < 0 { b0 |= 1 << 6; y += 1 }
        precondition(x == 0 && y == 0, "DST move too long")
        return [UInt8(b0), UInt8(b1), UInt8(b2)]
    }
}

// MARK: Janome JEF

public enum JEFWriter {
    static let maxStep = 127

    public static func data(_ pattern: StitchPattern, date: Date = Date()) -> Data {
        let entries = pattern.expanded(maxStep: maxStep)
        let codes = ThreadChart.janomeCodes(for: pattern.threads)
        let colorCount = max(1, codes.count)
        let palette = codes.isEmpty ? [1] : codes
        var b = ByteBuffer()
        b.u32(0x74 + colorCount * 8)
        b.u32(0x14)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        b.ascii(f.string(from: date))
        b.u8(0)
        b.u8(0)
        b.u32(colorCount)
        var points = 1 // the end command
        for e in entries {
            switch e.command {
            case .stitch: points += 1
            case .jump, .colorChange: points += 2
            case .trim, .end: break
            }
        }
        b.u32(points)
        let ext = StitchPattern.extent(entries)
        let w = ext.maxX - ext.minX, h = ext.maxY - ext.minY
        b.u32(hoopCode(width: w, height: h))
        let hw = Int((Double(w) / 2).rounded()), hh = Int((Double(h) / 2).rounded())
        b.u32(hw)
        b.u32(hh)
        b.u32(hw)
        b.u32(hh)
        // Distance from the design to the edges of the 110 × 110, 50 × 50 and 140 × 200 hoops (and a custom one).
        for (hx, hy) in [(550, 550), (250, 250), (700, 1000), (700, 1000)] {
            let ex = hx - hw, ey = hy - hh
            for v in (min(ex, ey) >= 0 ? [ex, ey, ex, ey] : [-1, -1, -1, -1]) { b.u32(v) }
        }
        for code in palette { b.u32(code) }
        for _ in 0..<colorCount { b.u32(0x0D) }

        var x = 0, y = 0
        for e in entries {
            let dx = e.x - x, dy = e.y - y
            x = e.x
            y = e.y
            switch e.command {
            case .stitch:
                b.u8(dx)
                b.u8(-dy)
            case .colorChange:
                b.bytes([0x80, 0x01])
                b.u8(dx)
                b.u8(-dy)
            case .jump:
                b.bytes([0x80, 0x02])
                b.u8(dx)
                b.u8(-dy)
            case .trim, .end:
                // No trim code is written; machines that trim do so on jumps.
                break
            }
        }
        b.bytes([0x80, 0x10])
        return b.data
    }

    static func hoopCode(width: Int, height: Int) -> Int {
        if width < 500 && height < 500 { return 1 }      // 50 × 50
        if width < 1260 && height < 1100 { return 3 }    // 126 × 110
        if width < 1400 && height < 2000 { return 2 }    // 140 × 200
        if width < 2000 && height < 2000 { return 4 }    // 200 × 200
        return 0                                          // 110 × 110
    }
}

// MARK: Brother PES / PEC

public enum PESWriter {
    static let maxStep = 2047

    public static func data(_ pattern: StitchPattern) -> Data {
        let entries = pattern.expanded(maxStep: maxStep)
        let codes = ThreadChart.brotherCodes(for: pattern.threads)
        let ext = StitchPattern.extent(entries)
        var b = ByteBuffer()
        b.ascii("#PES0001")
        let pecOffset = b.count
        b.u32(0)
        let hasStitches = entries.contains { $0.command == .stitch }
        b.u16(1) // scale to fit
        b.u16(1) // hoop: 130 × 180
        b.u16(hasStitches ? 1 : 0)
        if hasStitches {
            b.u16(0xFFFF)
            b.u16(0)
            writeBlocks(&b, entries: entries, codes: codes, extent: ext)
        } else {
            b.u16(0)
            b.u16(0)
        }
        b.patch(at: pecOffset, u32: b.count)
        PECWriter.write(&b, entries: entries, codes: codes, name: pattern.name, extent: ext)
        return b.data
    }

    static func string16(_ b: inout ByteBuffer, _ s: String) {
        b.u16(s.utf8.count)
        b.ascii(s)
    }

    static func writeBlocks(_ b: inout ByteBuffer, entries: [StitchPattern.Entry], codes: [Int],
                            extent e: (minX: Int, minY: Int, maxX: Int, maxY: Int)) {
        let width = Double(e.maxX - e.minX), height = Double(e.maxY - e.minY)
        string16(&b, "CEmbOne")
        for _ in 0..<8 { b.u16(0) }
        // Placement on Brother's 130 × 180 design page.
        b.f32(1); b.f32(0); b.f32(0); b.f32(1)
        b.f32(350 + 1300 / 2 - width / 2)
        b.f32(100 + height + 1800 / 2 - height / 2)
        b.u16(1); b.u16(0); b.u16(0)
        b.u16(Int(width))
        b.u16(Int(height))
        b.bytes([UInt8](repeating: 0, count: 8))
        let sectionCountAt = b.count
        b.u16(0)
        b.u16(0xFFFF)
        b.u16(0)
        string16(&b, "CSewSeg")

        // Segments: runs of stitches, and jumps between them, each tagged with its thread code.
        let adjustX = e.minX, adjustY = e.maxY
        var colorIndex = 0
        var code = codes.first ?? 20
        var stitched = (0, 0)
        var section = 0
        var colorLog: [(Int, Int)] = []
        var previousCode = -1
        var i = 0
        while i < entries.count {
            let cmd = entries[i].command
            var j = i
            while j < entries.count && entries[j].command == cmd { j += 1 }
            let group = entries[i..<j]
            i = j
            var points: [(Int, Int)] = []
            let flag: Int
            switch cmd {
            case .jump:
                points = [(stitched.0 - adjustX, stitched.1 - adjustY), (group.last!.x - adjustX, group.last!.y - adjustY)]
                flag = 1
            case .colorChange:
                colorIndex += group.count
                code = colorIndex < codes.count ? codes[colorIndex] : code
                continue
            case .stitch:
                for s in group { points.append((s.x - adjustX, s.y - adjustY)) }
                stitched = (group.last!.x, group.last!.y)
                flag = 0
            default:
                continue
            }
            if section > 0 { b.u16(0x8003) }
            if previousCode != code {
                colorLog.append((section, code))
                previousCode = code
            }
            b.u16(flag)
            b.u16(code)
            b.u16(points.count)
            for p in points {
                b.u16(p.0)
                b.u16(p.1)
            }
            section += 1
        }
        b.u16(colorLog.count)
        for (s, c) in colorLog {
            b.u16(s)
            b.u16(c)
        }
        b.patch(at: sectionCountAt, u16: section)
        b.u16(0)
        b.u16(0)
    }
}

/// The PEC section of a PES file: what Brother machines actually sew from, plus the thumbnails they show.
enum PECWriter {
    static let iconWidth = 48, iconHeight = 38

    static func write(_ b: inout ByteBuffer, entries: [StitchPattern.Entry], codes: [Int], name: String,
                      extent e: (minX: Int, minY: Int, maxX: Int, maxY: Int)) {
        // Header (512 bytes).
        b.ascii("LA:" + headerName(name, length: 8).padding(toLength: 16, withPad: " ", startingAt: 0) + "\r")
        b.bytes([UInt8](repeating: 0x20, count: 12) + [0xFF, 0x00])
        b.u8(iconWidth / 8)
        b.u8(iconHeight)
        if codes.isEmpty {
            b.bytes([0x20, 0x20, 0x20, 0x20, 0x64, 0x20, 0x00, 0x20, 0x00, 0x20, 0x20, 0x20, 0xFF])
        } else {
            b.bytes([UInt8](repeating: 0x20, count: 12))
            b.u8(codes.count - 1)
            for c in codes { b.u8(c) }
        }
        for _ in min(codes.count, 463)..<463 { b.u8(0x20) }

        // Stitch block.
        let start = b.count
        b.bytes([0x00, 0x00])
        b.u24(0)
        b.bytes([0x31, 0xFF, 0xF0])
        b.u16(e.maxX - e.minX)
        b.u16(e.maxY - e.minY)
        b.u16(0x1E0)
        b.u16(0x1B0)
        encode(&b, entries)
        b.patch(at: start + 2, u24: b.count - start)

        // Thumbnails: the whole design, then one per thread.
        var all = blankIcon()
        var colorIcons: [[UInt8]] = [blankIcon()]
        for en in entries {
            if en.command == .stitch {
                draw(&all, en, extent: e, buffer: 4)
                draw(&colorIcons[colorIcons.count - 1], en, extent: e, buffer: 5)
            } else if en.command == .colorChange {
                colorIcons.append(blankIcon())
            }
        }
        b.bytes(all)
        for icon in colorIcons { b.bytes(icon) }
    }

    static func encode(_ b: inout ByteBuffer, _ entries: [StitchPattern.Entry]) {
        func value(_ v: Int, long: Bool = false, flag: Int = 0) {
            if !long && v > -64 && v < 63 {
                b.u8(v & 0x7F)
            } else {
                let w = (v & 0x0FFF) | 0x8000 | (flag << 8)
                b.u8(w >> 8)
                b.u8(w)
            }
        }
        var colorTwo = true, jumping = true, first = true
        var x = 0, y = 0
        for en in entries {
            let dx = en.x - x, dy = en.y - y
            x = en.x
            y = en.y
            switch en.command {
            case .stitch:
                if jumping {
                    if dx != 0 && dy != 0 { value(0); value(0) }
                    jumping = false
                }
                value(dx)
                value(dy)
            case .jump:
                jumping = true
                // The first move only travels; later ones also trim.
                let flag = first ? 0x10 : 0x20
                value(dx, long: true, flag: flag)
                value(dy, long: true, flag: flag)
            case .colorChange:
                if jumping {
                    value(0)
                    value(0)
                    jumping = false
                }
                b.bytes([0xFE, 0xB0, colorTwo ? 0x02 : 0x01])
                colorTwo.toggle()
            case .trim:
                break
            case .end:
                b.u8(0xFF)
            }
            first = false
        }
    }

    /// An empty 48 × 38 thumbnail with Brother's rounded frame.
    static func blankIcon() -> [UInt8] {
        var rows: [[UInt8]] = [[0, 0, 0, 0, 0, 0], [0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F],
                               [0x08, 0, 0, 0, 0, 0x10], [0x04, 0, 0, 0, 0, 0x20]]
        rows += [[UInt8]](repeating: [0x02, 0, 0, 0, 0, 0x40], count: iconHeight - 8)
        rows += [[0x04, 0, 0, 0, 0, 0x20], [0x08, 0, 0, 0, 0, 0x10], [0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F], [0, 0, 0, 0, 0, 0]]
        return rows.flatMap { $0 }
    }

    static func draw(_ icon: inout [UInt8], _ p: StitchPattern.Entry,
                     extent e: (minX: Int, minY: Int, maxX: Int, maxY: Int), buffer: Int) {
        let w = Double(max(1, e.maxX - e.minX)), h = Double(max(1, e.maxY - e.minY))
        let scale = min(Double(iconWidth - buffer) / w, Double(iconHeight - buffer) / h)
        let cx = Double(e.maxX + e.minX) / 2, cy = Double(e.maxY + e.minY) / 2
        let x = Int(floor(Double(p.x) * scale - cx * scale + Double(iconWidth) / 2))
        let y = Int(floor(Double(p.y) * scale - cy * scale + Double(iconHeight) / 2))
        guard x >= 0, y >= 0, x < iconWidth, y < iconHeight else { return }
        icon[y * (iconWidth / 8) + x / 8] |= UInt8(1 << (x % 8))
    }
}

// MARK: - Thread charts

public struct ThreadChartEntry: Hashable, Sendable {
    public var color: ThreadColor
    public var name: String
    public var code: String

    public init(_ rgb: UInt32, _ name: String, _ code: String) {
        color = ThreadColor(rgb: rgb)
        self.name = name
        self.code = code
    }
}

public enum ThreadChart {
    /// Perceptual colour distance ("red mean", from compuphase.com/cmetric.htm).
    public static func distance(_ a: ThreadColor, _ b: ThreadColor) -> Int {
        let rMean = (Int(a.red) + Int(b.red) + 1) / 2
        let r = Int(a.red) - Int(b.red), g = Int(a.green) - Int(b.green), bl = Int(a.blue) - Int(b.blue)
        return (((512 + rMean) * r * r) >> 8) + 4 * g * g + (((767 - rMean) * bl * bl) >> 8)
    }

    /// Index of the nearest chart colour, skipping unused slots and `excluded` indices.
    public static func nearest(_ c: ThreadColor, in chart: [ThreadChartEntry?], excluding excluded: Set<Int> = []) -> Int? {
        var best: Int?
        var bestDistance = Int.max
        for (i, entry) in chart.enumerated() {
            guard let entry, !excluded.contains(i) else { continue }
            let d = distance(c, entry.color)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    /// Brother codes for each thread. Different colours get different codes, so the machine shows them apart.
    public static func brotherCodes(for threads: [ThreadColor]) -> [Int] {
        var assigned: [ThreadColor: Int] = [:]
        var used: Set<Int> = []
        for t in threads where assigned[t] == nil {
            let i = nearest(t, in: brother, excluding: used) ?? nearest(t, in: brother) ?? 20
            assigned[t] = i
            used.insert(i)
        }
        return threads.map { assigned[$0] ?? 20 }
    }

    /// Janome codes for each thread. Two different colours in a row never share a code.
    public static func janomeCodes(for threads: [ThreadColor]) -> [Int] {
        var out: [Int] = []
        var last: (ThreadColor, Int)?
        for t in threads {
            var i = nearest(t, in: janome) ?? 1
            if case let (lt, li)? = last, li == i, lt != t {
                i = nearest(t, in: janome, excluding: [i]) ?? i
            }
            out.append(i)
            last = (t, i)
        }
        return out
    }

    /// Brother PEC thread chart; index 0 is unused, so a thread's PEC code is its index here.
    public static let brother: [ThreadChartEntry?] = [
        nil,
        ThreadChartEntry(0x0E1F7C, "Prussian Blue", "1"),
        ThreadChartEntry(0x0A55A3, "Blue", "2"),
        ThreadChartEntry(0x008777, "Teal Green", "3"),
        ThreadChartEntry(0x4B6BAF, "Cornflower Blue", "4"),
        ThreadChartEntry(0xED171F, "Red", "5"),
        ThreadChartEntry(0xD15C00, "Reddish Brown", "6"),
        ThreadChartEntry(0x913697, "Magenta", "7"),
        ThreadChartEntry(0xE49ACB, "Light Lilac", "8"),
        ThreadChartEntry(0x915FAC, "Lilac", "9"),
        ThreadChartEntry(0x9ED67D, "Mint Green", "10"),
        ThreadChartEntry(0xE8A900, "Deep Gold", "11"),
        ThreadChartEntry(0xFEBA35, "Orange", "12"),
        ThreadChartEntry(0xFFFF00, "Yellow", "13"),
        ThreadChartEntry(0x70BC1F, "Lime Green", "14"),
        ThreadChartEntry(0xBA9800, "Brass", "15"),
        ThreadChartEntry(0xA8A8A8, "Silver", "16"),
        ThreadChartEntry(0x7D6F00, "Russet Brown", "17"),
        ThreadChartEntry(0xFFFFB3, "Cream Brown", "18"),
        ThreadChartEntry(0x4F5556, "Pewter", "19"),
        ThreadChartEntry(0x000000, "Black", "20"),
        ThreadChartEntry(0x0B3D91, "Ultramarine", "21"),
        ThreadChartEntry(0x770176, "Royal Purple", "22"),
        ThreadChartEntry(0x293133, "Dark Gray", "23"),
        ThreadChartEntry(0x2A1301, "Dark Brown", "24"),
        ThreadChartEntry(0xF64A8A, "Deep Rose", "25"),
        ThreadChartEntry(0xB27624, "Light Brown", "26"),
        ThreadChartEntry(0xFCBBC5, "Salmon Pink", "27"),
        ThreadChartEntry(0xFE370F, "Vermilion", "28"),
        ThreadChartEntry(0xF0F0F0, "White", "29"),
        ThreadChartEntry(0x6A1C8A, "Violet", "30"),
        ThreadChartEntry(0xA8DDC4, "Seacrest", "31"),
        ThreadChartEntry(0x2584BB, "Sky Blue", "32"),
        ThreadChartEntry(0xFEB343, "Pumpkin", "33"),
        ThreadChartEntry(0xFFF36B, "Cream Yellow", "34"),
        ThreadChartEntry(0xD0A660, "Khaki", "35"),
        ThreadChartEntry(0xD15400, "Clay Brown", "36"),
        ThreadChartEntry(0x66BA49, "Leaf Green", "37"),
        ThreadChartEntry(0x134A46, "Peacock Blue", "38"),
        ThreadChartEntry(0x878787, "Gray", "39"),
        ThreadChartEntry(0xD8CCC6, "Warm Gray", "40"),
        ThreadChartEntry(0x435607, "Dark Olive", "41"),
        ThreadChartEntry(0xFDD9DE, "Flesh Pink", "42"),
        ThreadChartEntry(0xF993BC, "Pink", "43"),
        ThreadChartEntry(0x003822, "Deep Green", "44"),
        ThreadChartEntry(0xB2AFD4, "Lavender", "45"),
        ThreadChartEntry(0x686AB0, "Wisteria Violet", "46"),
        ThreadChartEntry(0xEFE3B9, "Beige", "47"),
        ThreadChartEntry(0xF73866, "Carmine", "48"),
        ThreadChartEntry(0xB54B64, "Amber Red", "49"),
        ThreadChartEntry(0x132B1A, "Olive Green", "50"),
        ThreadChartEntry(0xC70156, "Dark Fuchsia", "51"),
        ThreadChartEntry(0xFE9E32, "Tangerine", "52"),
        ThreadChartEntry(0xA8DEEB, "Light Blue", "53"),
        ThreadChartEntry(0x00673E, "Emerald Green", "54"),
        ThreadChartEntry(0x4E2990, "Purple", "55"),
        ThreadChartEntry(0x2F7E20, "Moss Green", "56"),
        ThreadChartEntry(0xFFCCCC, "Flesh Pink", "57"),
        ThreadChartEntry(0xFFD911, "Harvest Gold", "58"),
        ThreadChartEntry(0x095BA6, "Electric Blue", "59"),
        ThreadChartEntry(0xF0F970, "Lemon Yellow", "60"),
        ThreadChartEntry(0xE3F35B, "Fresh Green", "61"),
        ThreadChartEntry(0xFF9900, "Orange", "62"),
        ThreadChartEntry(0xFFF08D, "Cream Yellow", "63"),
        ThreadChartEntry(0xFFC8C8, "Applique", "64"),
    ]

    /// Janome JEF thread chart; index 0 is unused, so a thread's JEF code is its index here.
    public static let janome: [ThreadChartEntry?] = [
        nil,
        ThreadChartEntry(0x000000, "Black", "002"),
        ThreadChartEntry(0xFFFFFF, "White", "001"),
        ThreadChartEntry(0xFFFF17, "Yellow", "204"),
        ThreadChartEntry(0xFF6600, "Orange", "203"),
        ThreadChartEntry(0x2F5933, "Olive Green", "219"),
        ThreadChartEntry(0x237336, "Green", "226"),
        ThreadChartEntry(0x65C2C8, "Sky", "217"),
        ThreadChartEntry(0xAB5A96, "Purple", "208"),
        ThreadChartEntry(0xF669A0, "Pink", "201"),
        ThreadChartEntry(0xFF0000, "Red", "225"),
        ThreadChartEntry(0xB1704E, "Brown", "214"),
        ThreadChartEntry(0x0B2F84, "Blue", "207"),
        ThreadChartEntry(0xE4C35D, "Gold", "003"),
        ThreadChartEntry(0x481A05, "Dark Brown", "205"),
        ThreadChartEntry(0xAC9CC7, "Pale Violet", "209"),
        ThreadChartEntry(0xFCF294, "Pale Yellow", "210"),
        ThreadChartEntry(0xF999B7, "Pale Pink", "211"),
        ThreadChartEntry(0xFAB381, "Peach", "212"),
        ThreadChartEntry(0xC9A480, "Beige", "213"),
        ThreadChartEntry(0x970533, "Wine Red", "215"),
        ThreadChartEntry(0xA0B8CC, "Pale Sky", "216"),
        ThreadChartEntry(0x7FC21C, "Yellow Green", "218"),
        ThreadChartEntry(0xE5E5E5, "Silver Gray", "220"),
        ThreadChartEntry(0x889B9B, "Gray", "221"),
        ThreadChartEntry(0x98D6BD, "Pale Aqua", "227"),
        ThreadChartEntry(0xB2E1E3, "Baby Blue", "228"),
        ThreadChartEntry(0x368BA0, "Powder Blue", "229"),
        ThreadChartEntry(0x4F83AB, "Bright Blue", "230"),
        ThreadChartEntry(0x386A91, "Slate Blue", "231"),
        ThreadChartEntry(0x071650, "Navy Blue", "232"),
        ThreadChartEntry(0xF999A2, "Salmon Pink", "233"),
        ThreadChartEntry(0xF9676B, "Coral", "234"),
        ThreadChartEntry(0xE3311F, "Burnt Orange", "235"),
        ThreadChartEntry(0xE2A188, "Cinnamon", "236"),
        ThreadChartEntry(0xB59474, "Umber", "237"),
        ThreadChartEntry(0xE4CF99, "Blond", "238"),
        ThreadChartEntry(0xFFCB00, "Sunflower", "239"),
        ThreadChartEntry(0xE1ADD4, "Orchid Pink", "240"),
        ThreadChartEntry(0xC3007E, "Peony Purple", "241"),
        ThreadChartEntry(0x80004B, "Burgundy", "242"),
        ThreadChartEntry(0x540571, "Royal Purple", "243"),
        ThreadChartEntry(0xB10525, "Cardinal Red", "244"),
        ThreadChartEntry(0xCAE0C0, "Opal Green", "245"),
        ThreadChartEntry(0x899856, "Moss Green", "246"),
        ThreadChartEntry(0x5C941A, "Meadow Green", "247"),
        ThreadChartEntry(0x003114, "Dark Green", "248"),
        ThreadChartEntry(0x5DAE94, "Aquamarine", "249"),
        ThreadChartEntry(0x4CBF8F, "Emerald Green", "250"),
        ThreadChartEntry(0x007772, "Peacock Green", "251"),
        ThreadChartEntry(0x595B61, "Dark Gray", "252"),
        ThreadChartEntry(0xFFFFF2, "Ivory White", "253"),
        ThreadChartEntry(0xB15818, "Hazel", "254"),
        ThreadChartEntry(0xCB8A07, "Toast", "255"),
        ThreadChartEntry(0x986C80, "Salmon", "256"),
        ThreadChartEntry(0x98692D, "Cocoa Brown", "257"),
        ThreadChartEntry(0x4D3419, "Sienna", "258"),
        ThreadChartEntry(0x4C330B, "Sepia", "259"),
        ThreadChartEntry(0x33200A, "Dark Sepia", "260"),
        ThreadChartEntry(0x523A97, "Violet Blue", "261"),
        ThreadChartEntry(0x0D217E, "Blue Ink", "262"),
        ThreadChartEntry(0x1E77AC, "Sola Blue", "263"),
        ThreadChartEntry(0xB2DD53, "Green Dust", "264"),
        ThreadChartEntry(0xF33689, "Crimson", "265"),
        ThreadChartEntry(0xDE649E, "Floral Pink", "266"),
        ThreadChartEntry(0x984161, "Wine", "267"),
        ThreadChartEntry(0x4C5612, "Olive Drab", "268"),
        ThreadChartEntry(0x4C881F, "Meadow", "269"),
        ThreadChartEntry(0xE4DE79, "Mustard", "270"),
        ThreadChartEntry(0xCB8A1A, "Yellow Ocher", "271"),
        ThreadChartEntry(0xCBA21C, "Old Gold", "272"),
        ThreadChartEntry(0xFF9805, "Honey Dew", "273"),
        ThreadChartEntry(0xFCB257, "Tangerine", "274"),
        ThreadChartEntry(0xFFE505, "Canary Yellow", "275"),
        ThreadChartEntry(0xF0331F, "Vermilion", "202"),
        ThreadChartEntry(0x1A842D, "Bright Green", "206"),
        ThreadChartEntry(0x386CAE, "Ocean Blue", "222"),
        ThreadChartEntry(0xE3C4B4, "Beige Gray", "223"),
        ThreadChartEntry(0xE3AC81, "Bamboo", "224"),
    ]
}
