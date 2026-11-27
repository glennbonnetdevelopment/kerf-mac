import Foundation

// MARK: - Printing

/// Paper sizes offered in the print preview, in mm (portrait).
public enum PaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case letter, legal, tabloid, a4, a3, superB
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .letter: return "US Letter (8.5 × 11 in)"
        case .legal: return "US Legal (8.5 × 14 in)"
        case .tabloid: return "Tabloid (11 × 17 in)"
        case .a4: return "A4 (210 × 297 mm)"
        case .a3: return "A3 (297 × 420 mm)"
        case .superB: return "Super B / A3+ (13 × 19 in)"
        }
    }
    /// Width and height in mm, portrait.
    public var size: Vec2 {
        switch self {
        case .letter: return Vec2(215.9, 279.4)
        case .legal: return Vec2(215.9, 355.6)
        case .tabloid: return Vec2(279.4, 431.8)
        case .a4: return Vec2(210, 297)
        case .a3: return Vec2(297, 420)
        case .superB: return Vec2(330.2, 482.6)
        }
    }
}

/// Where the artwork goes on the printed page.
public enum PrintPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case center, topLeft, asOnBed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .center: return "Centre on page"
        case .topLeft: return "Top left, inside margin"
        case .asOnBed: return "Same place as on the bed"
        }
    }
}

/// Settings for the print preview and printing, remembered between launches.
public struct PrintSettings: Codable, Hashable, Sendable {
    public var paper: PaperSize = .letter
    public var landscape = false
    public var placement: PrintPlacement = .center
    /// Page margin in mm for top-left placement and for the fit check.
    public var margin = 10.0
    /// Draw cut lines in the preview (never printed unless `printCutLines`).
    public var showCutLines = true
    /// Print cut lines as thin lines too, for checking the alignment on a test sheet.
    public var printCutLines = false

    public init() {}

    private static let key = "printSettings"

    public static func load(_ defaults: UserDefaults = .standard) -> PrintSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(PrintSettings.self, from: data) else {
            return PrintSettings()
        }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// Page width and height in mm for the chosen paper and orientation.
    public var pageSize: Vec2 {
        let s = paper.size
        return landscape ? Vec2(s.y, s.x) : s
    }
}

public enum PrintLayout {
    /// The translation (in mm) from design space to page space that places `content` on the page.
    public static func offset(content: Rect2, page: Vec2, placement: PrintPlacement, margin: Double) -> Vec2 {
        guard !content.isEmpty else { return .zero }
        switch placement {
        case .center:
            return Vec2((page.x - content.width) / 2 - content.minX, (page.y - content.height) / 2 - content.minY)
        case .topLeft:
            return Vec2(margin - content.minX, margin - content.minY)
        case .asOnBed:
            return .zero
        }
    }

    /// True when `content`, moved by `offset`, lies inside the page less `margin` on every side.
    public static func fits(content: Rect2, offset: Vec2, page: Vec2, margin: Double) -> Bool {
        guard !content.isEmpty else { return true }
        let area = Rect2(minX: margin, minY: margin, maxX: page.x - margin, maxY: page.y - margin)
        let moved = Rect2(minX: content.minX + offset.x, minY: content.minY + offset.y,
                          maxX: content.maxX + offset.x, maxY: content.maxY + offset.y)
        return area.contains(moved, tolerance: 1e-6)
    }
}

// MARK: - GCC AAS II optical registration

/// Units the cutter expects for the mark distances in the AAS command.
/// GCC's manuals don't say, so this is a device setting.
public enum AASDistanceUnits: String, Codable, CaseIterable, Identifiable, Sendable {
    case plotterUnits, tenthMM, mm
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .plotterUnits: return "Plotter units (like the cut data)"
        case .tenthMM: return "0.1 mm"
        case .mm: return "mm"
        }
    }
}

/// GCC's Accu-Aligning System II, on the Expert II 24 LX, Expert 24 LX and similar GCC cutters.
///
/// The cutter reads four black L-shaped marks at the corners of the printed job with an optical sensor,
/// then cuts relative to the first (origin) mark, correcting for skew and stretch. The host starts it
/// with `Esc.D1;XDist;YDist:` (4-point), sent before the HPGL cut data.
public enum GCCAAS {
    /// GCC's suggested mark length, line thickness and gap to the artwork, in mm.
    public static let defaultLength = 25.0
    public static let defaultThickness = 1.0
    public static let defaultMargin = 5.0
    /// GCC's allowed ranges, in mm.
    public static let lengthRange = 5.0...50.0
    public static let thicknessRange = 1.0...2.0
    public static let marginRange = 1.0...50.0

    /// Outside corners of the four marks around `bounds`: top-left, top-right, bottom-left, bottom-right
    /// (design space, y down). Each L's arms run along the artwork, `margin` away from it.
    public static func markCorners(around bounds: Rect2, margin: Double, thickness: Double) -> [Vec2] {
        let r = bounds.insetBy(-(margin + thickness))
        return [Vec2(r.minX, r.minY), Vec2(r.maxX, r.minY), Vec2(r.minX, r.maxY), Vec2(r.maxX, r.maxY)]
    }

    /// Which of the four corners (in `markCorners` order) is nearest the cutter's origin, so it holds the origin mark.
    public static func originIndex(for profile: DeviceProfile, corners: [Vec2]) -> Int {
        guard !corners.isEmpty else { return 0 }
        let m = corners.map(profile.toMachine)
        return m.indices.min { m[$0].x + m[$0].y < m[$1].x + m[$1].y } ?? 0
    }

    /// One L mark with its outside corner at (0, 0) and arms toward the artwork. `corner` says which corner of the
    /// job it sits at (x and y are -1 or +1). The origin mark is drawn twice as thick (up to GCC's 2 mm limit)
    /// so the cutter can tell which way round the sheet is.
    public static func mark(length: Double, thickness: Double, corner: Vec2, isOrigin: Bool) -> [Polyline] {
        let t = isOrigin ? min(thicknessRange.upperBound, thickness * 2) : thickness
        return [Registration.bracket(arm: length, width: t, corner: corner)]
    }

    /// The marks' positions as the cutter sees them.
    public struct Job: Equatable, Sendable {
        /// Design-space point of the origin mark's outside corner; machine (0, 0) for the cut.
        public var origin: Vec2
        /// Distances in mm from the origin mark to the far marks, along the cutter's X and Y.
        public var xDistance: Double
        public var yDistance: Double
    }

    /// Works out the job from the four marks' registration points (design space).
    /// Returns nil unless there are four marks spanning a real rectangle.
    public static func job(marks: [Vec2], profile: DeviceProfile) -> Job? {
        guard marks.count == 4 else { return nil }
        let i = originIndex(for: profile, corners: marks)
        let o = profile.toMachine(marks[i])
        let rel = marks.map { profile.toMachine($0) - o }
        let x = rel.map(\.x).max() ?? 0, y = rel.map(\.y).max() ?? 0
        guard x > 1, y > 1, rel.allSatisfy({ $0.x > -0.5 && $0.y > -0.5 }) else { return nil }
        return Job(origin: marks[i], xDistance: x, yDistance: y)
    }

    /// The 4-point AAS command: ESC, then `.D1;XDist;YDist:`.
    public static func command(_ job: Job, units: AASDistanceUnits, unitsPerMM: Double) -> String {
        func v(_ mm: Double) -> Int {
            switch units {
            case .plotterUnits: return Int((mm * unitsPerMM).rounded())
            case .tenthMM: return Int((mm * 10).rounded())
            case .mm: return Int(mm.rounded())
            }
        }
        return "\u{1B}.D1;\(v(job.xDistance));\(v(job.yDistance)):"
    }

    /// A job that only reads the marks and returns to the origin mark, to check the sensor finds them.
    public static func scanOnly(_ job: Job, units: AASDistanceUnits, unitsPerMM: Double) -> String {
        "IN;" + command(job, units: units, unitsPerMM: unitsPerMM) + "PU0,0;\n"
    }

    /// Checks GCC's layout guidance for a sheet: marks inside the page with GCC's suggested side, top and bottom
    /// margins (30, 20 and 50 mm). Returns plain-language problems, empty when fine.
    public static func layoutWarnings(marks: Rect2, page: Vec2, offset: Vec2) -> [String] {
        guard !marks.isEmpty else { return [] }
        var out: [String] = []
        let left = marks.minX + offset.x, right = page.x - (marks.maxX + offset.x)
        let top = marks.minY + offset.y, bottom = page.y - (marks.maxY + offset.y)
        if min(left, right) < 30 { out.append("GCC suggests 30 mm between the marks and the left and right edges of the sheet.") }
        if top < 20 { out.append("GCC suggests 20 mm above the top marks.") }
        if bottom < 50 { out.append("GCC suggests at least 50 mm below the bottom marks.") }
        return out
    }
}
