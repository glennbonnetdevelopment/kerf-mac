import Foundation

/// What a cutter job will actually do, read back from the HPGL or GP-GL that is sent, so the preview
/// shows the cut after mirroring, placement, blade offset, overcut and weeding exactly as the cutter gets it.
public struct CutterPreview: Hashable, Sendable {
    public struct Stroke: Hashable, Sendable {
        /// Points in mm.
        public var points: [Vec2]
        /// True for a knife-down cut, false for a knife-up move between cuts.
        public var isCut: Bool

        public init(points: [Vec2], isCut: Bool) {
            self.points = points
            self.isCut = isCut
        }
    }

    /// In cutter mm from the cutter's origin, in the order they run.
    public var strokes: [Stroke]

    public init(strokes: [Stroke] = []) {
        self.strokes = strokes
    }

    public var isEmpty: Bool { !strokes.contains { $0.isCut } }

    /// Bounds of the cuts only.
    public var cutBounds: Rect2 {
        var r = Rect2.empty
        for s in strokes where s.isCut { for p in s.points { r.include(p) } }
        return r
    }

    public var cutLength: Double { length(cut: true) }
    public var travelLength: Double { length(cut: false) }

    private func length(cut: Bool) -> Double {
        strokes.filter { $0.isCut == cut }.reduce(0) { total, s in
            zip(s.points, s.points.dropFirst()).reduce(total) { $0 + $1.0.distance(to: $1.1) }
        }
    }

    /// The same strokes with every point moved by `f`.
    public func mapped(_ f: (Vec2) -> Vec2) -> CutterPreview {
        CutterPreview(strokes: strokes.map { Stroke(points: $0.points.map(f), isCut: $0.isCut) })
    }

    /// The strokes on the canvas's own layout (mm, y down, the front of the cutter at the bottom),
    /// with the cutter's origin at its corner of the work area.
    public func inDesignSpace(_ profile: DeviceProfile) -> CutterPreview {
        mapped(profile.fromMachine)
    }

    /// Reads HPGL or GP-GL made by `PlotterGenerator` (other commands such as speed, force and the
    /// GCC optical-mark command are skipped). The knife starts up at the origin.
    public static func parse(_ text: String, profile: DeviceProfile) -> CutterPreview {
        let k = profile.unitsPerMM > 0 ? profile.unitsPerMM : 1
        var strokes: [Stroke] = []
        var pen = Vec2.zero
        var current: [Vec2] = []

        func flush() {
            if current.count > 1 { strokes.append(Stroke(points: current, isCut: true)) }
            current = []
        }
        func numbers(_ s: Substring) -> [Vec2] {
            let n = s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
            return stride(from: 0, to: n.count - 1, by: 2).map { Vec2(n[$0] / k, n[$0 + 1] / k) }
        }
        func moveTo(_ p: Vec2) {
            flush()
            if p.distance(to: pen) > 1e-9 { strokes.append(Stroke(points: [pen, p], isCut: false)) }
            pen = p
        }
        func cutTo(_ pts: [Vec2]) {
            if current.isEmpty { current = [pen] }
            current += pts
            if let l = pts.last { pen = l }
        }

        switch profile.language {
        case .hpgl:
            // Drop escape-prefixed device commands (ESC . … :), which contain semicolons of their own.
            var cleaned = ""
            var inEscape = false
            for ch in text {
                if ch == "\u{1B}" { inEscape = true; continue }
                if inEscape { if ch == ":" { inEscape = false }; continue }
                cleaned.append(ch)
            }
            for raw in cleaned.split(whereSeparator: { $0 == ";" || $0 == "\n" || $0 == "\r" }) {
                let cmd = raw.trimmingCharacters(in: .whitespaces)
                guard cmd.count >= 2 else { continue }
                let op = cmd.prefix(2).uppercased()
                let args = cmd.dropFirst(2)
                switch op {
                case "PU":
                    let pts = numbers(args[...])
                    if pts.isEmpty { flush() }
                    for p in pts { moveTo(p) }
                case "PD":
                    let pts = numbers(args[...])
                    if !pts.isEmpty { cutTo(pts) }
                case "IN":
                    flush()
                default:
                    continue
                }
            }
        case .gpgl:
            for raw in text.split(separator: "\u{03}") {
                let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let first = cmd.first else { continue }
                let args = cmd.dropFirst()
                switch first {
                case "M":
                    for p in numbers(args[...]) { moveTo(p) }
                case "D":
                    let pts = numbers(args[...])
                    if !pts.isEmpty { cutTo(pts) }
                case "H":
                    moveTo(.zero)
                default:
                    continue
                }
            }
        case .svgFile:
            break
        }
        flush()
        return CutterPreview(strokes: strokes)
    }
}
