import Foundation

// MARK: - Manual registration on a vinyl cutter

/// Print and cut without an optical sensor: the user moves the cutter head from the software until the
/// laser pointer (or the blade tip) sits on each printed registration mark, confirms it, and the cut is fitted
/// to the measured marks.
///
/// Positions are in cutter mm, measured from the origin set on the cutter (machine axes, as `DeviceProfile.toMachine`).
/// The head position is where the blade is; the laser pointer is the blade position plus `DeviceProfile.laserOffset`.
public enum ManualRegistration {
    /// Jog step sizes offered in the UI, mm.
    public static let stepSizes: [Double] = [0.1, 0.5, 1, 5, 10, 50]

    /// Where a confirmed mark is: the pointer position when the user confirmed it.
    /// - Parameters:
    ///   - head: the blade position the head was sent to.
    ///   - offset: the pointer's offset from the blade, or zero when sighting with the blade tip.
    public static func markPosition(head: Vec2, offset: Vec2) -> Vec2 { head + offset }

    /// The blade position that puts the pointer on `target`.
    public static func headPosition(pointerAt target: Vec2, offset: Vec2) -> Vec2 { target - offset }

    /// The laser offset from a calibration cross: the blade cut a cross at `cut`, then the user moved the head
    /// to `head` so the pointer sits on the cross.
    public static func calibratedOffset(cut: Vec2, head: Vec2) -> Vec2 { cut - head }

    /// The transform from design machine coordinates (`DeviceProfile.toMachine` of the design) onto the measured
    /// mark positions. One pair moves the job; two also rotate and scale it evenly; three or more fit a full affine
    /// (separate X and Y stretch and skew) by least squares. Nil when the points are too close or in a line.
    public static func fit(design: [Vec2], measured: [Vec2]) -> Affine? {
        let n = min(design.count, measured.count)
        guard n > 0 else { return nil }
        if n == 1 {
            let d = measured[0] - design[0]
            return .translation(d.x, d.y)
        }
        if n == 2 {
            return Registration.alignment(design: design[0], design[1], measured: measured[0], measured[1])
        }
        // Least squares for [a c tx] and [b d ty], centred for stability.
        let dc = design.prefix(n).reduce(Vec2.zero, +) / Double(n)
        let mc = measured.prefix(n).reduce(Vec2.zero, +) / Double(n)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        var ux = 0.0, uy = 0.0, vx = 0.0, vy = 0.0
        for i in 0..<n {
            let p = design[i] - dc, q = measured[i] - mc
            sxx += p.x * p.x
            sxy += p.x * p.y
            syy += p.y * p.y
            ux += p.x * q.x
            uy += p.y * q.x
            vx += p.x * q.y
            vy += p.y * q.y
        }
        let det = sxx * syy - sxy * sxy
        // Points in a line (or on top of each other) can't fix the second axis.
        guard det > 1e-6 * max(1, sxx * syy) else {
            return Registration.alignment(design: design[0], design[1], measured: measured[0], measured[1])
        }
        let a = (ux * syy - uy * sxy) / det
        let c = (uy * sxx - ux * sxy) / det
        let b = (vx * syy - vy * sxy) / det
        let d = (vy * sxx - vx * sxy) / det
        let tx = mc.x - (a * dc.x + c * dc.y)
        let ty = mc.y - (b * dc.x + d * dc.y)
        return Affine(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// The largest distance between a fitted design mark and where it was measured, mm.
    /// Zero for one or two marks, which always fit exactly.
    public static func maxResidual(_ t: Affine, design: [Vec2], measured: [Vec2]) -> Double {
        zip(design, measured).map { t.apply($0).distance(to: $1) }.max() ?? 0
    }

    /// Where a mark is expected to be, from the marks confirmed so far (`confirmed` maps mark index to position).
    /// With none confirmed there is no guess.
    public static func predicted(mark index: Int, design: [Vec2], confirmed: [Int: Vec2]) -> Vec2? {
        guard design.indices.contains(index) else { return nil }
        let known = confirmed.keys.sorted().filter { design.indices.contains($0) && $0 != index }
        guard !known.isEmpty else { return nil }
        guard let t = fit(design: known.map { design[$0] }, measured: known.map { confirmed[$0]! }) else { return nil }
        return t.apply(design[index])
    }

    /// Per-axis stretch of a fitted transform (how long a design mm along X and along Y becomes on the cutter).
    public static func axisScales(_ t: Affine) -> Vec2 {
        Vec2((t.a * t.a + t.b * t.b).squareRoot(), (t.c * t.c + t.d * t.d).squareRoot())
    }

    // MARK: Cutter commands

    /// Moves the head (blade up) to `head`, in cutter mm from the origin. Nil for cutters with no live connection.
    public static func moveCommand(to head: Vec2, profile: DeviceProfile) -> String? {
        let x = Int((head.x * profile.unitsPerMM).rounded()), y = Int((head.y * profile.unitsPerMM).rounded())
        switch profile.language {
        case .hpgl: return "PU\(x),\(y);\n"
        case .gpgl: return "M\(x),\(y)\u{03}"
        case .svgFile: return nil
        }
    }

    /// Cuts a small plus at `center` and lifts back to it, for calibrating the laser offset on scrap media.
    public static func calibrationCross(at center: Vec2, size: Double = 6, profile: DeviceProfile) -> String? {
        let h = size / 2
        func u(_ p: Vec2) -> String {
            "\(Int((p.x * profile.unitsPerMM).rounded())),\(Int((p.y * profile.unitsPerMM).rounded()))"
        }
        let c = center
        let l = Vec2(c.x - h, c.y), r = Vec2(c.x + h, c.y), t = Vec2(c.x, c.y - h), b = Vec2(c.x, c.y + h)
        switch profile.language {
        case .hpgl: return "PU\(u(l));PD\(u(r));PU\(u(t));PD\(u(b));PU\(u(c));\n"
        case .gpgl:
            let e = "\u{03}"
            return "M\(u(l))\(e)D\(u(r))\(e)M\(u(t))\(e)D\(u(b))\(e)M\(u(c))\(e)"
        case .svgFile: return nil
        }
    }

    /// The cutter-axis step for moving `step` mm in a screen direction (`dir` with x right and y down, as on the
    /// canvas), so the arrow keys move the pointer the way the sheet is drawn.
    public static func jogDelta(_ dir: Vec2, step: Double, profile: DeviceProfile) -> Vec2 {
        let base = Vec2(profile.bedWidth / 2, profile.bedHeight / 2)
        return profile.toMachine(base + dir * step) - profile.toMachine(base)
    }
}
