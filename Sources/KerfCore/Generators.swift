import Foundation

/// Formats a coordinate with up to 3 decimals and no trailing zeros.
@inline(__always)
func fmt(_ v: Double) -> String {
    var s = String(format: "%.3f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    if s == "-0" { s = "0" }
    return s
}

// MARK: - GRBL G-code

public enum GCodeGenerator {
    /// Generates G-code for a GRBL laser in laser mode ($32=1).
    /// - Parameter offset: added to every machine coordinate (used to run a job relative to the current position).
    public static func generate(_ tp: Toolpath, profile: DeviceProfile, offset: Vec2 = .zero) -> [String] {
        var out: [String] = ["; Kerf job", "G90", "G21", "M5"]
        func m(_ p: Vec2) -> Vec2 { profile.toMachine(p) + offset }
        for tl in tp.layers {
            let layer = tl.layer
            let s = max(0, min(100, layer.power)) / 100 * profile.sMax
            let feed = max(1, layer.speed)
            out.append("; Layer \(layer.name): \(layer.mode.title), \(fmt(feed)) mm/min, \(fmt(layer.power))%")
            out.append(layer.airAssist ? "M8" : "M9")
            // Dynamic power: GRBL scales power with actual speed, so corners don't over-burn.
            out.append("M4 S0")
            for _ in 0..<max(1, layer.passes) {
                for path in tl.paths where path.count > 1 {
                    let p0 = m(path[0])
                    out.append("G0 X\(fmt(p0.x)) Y\(fmt(p0.y))")
                    for (i, p) in path.dropFirst().enumerated() {
                        let q = m(p)
                        if i == 0 {
                            out.append("G1 X\(fmt(q.x)) Y\(fmt(q.y)) S\(fmt(s)) F\(fmt(feed))")
                        } else {
                            out.append("G1 X\(fmt(q.x)) Y\(fmt(q.y))")
                        }
                    }
                }
            }
            out.append("M5")
        }
        out.append("M9")
        out.append("M5")
        return out
    }

    /// Jog commands that trace the job's bounding box with the laser off.
    public static func frame(_ bounds: Rect2, profile: DeviceProfile, offset: Vec2 = .zero, feed: Double) -> [String] {
        guard !bounds.isEmpty else { return [] }
        let corners = [Vec2(bounds.minX, bounds.minY), Vec2(bounds.maxX, bounds.minY),
                       Vec2(bounds.maxX, bounds.maxY), Vec2(bounds.minX, bounds.maxY), Vec2(bounds.minX, bounds.minY)]
        return corners.map {
            let q = profile.toMachine($0) + offset
            return "$J=G90 G21 X\(fmt(q.x)) Y\(fmt(q.y)) F\(fmt(feed))"
        }
    }
}

// MARK: - Vinyl cutters (HPGL / GP-GL)

public struct CutterJobOptions: Sendable {
    /// Margin of a weeding border around the job, or nil for none.
    public var weedBorder: Double?

    public init(weedBorder: Double? = nil) {
        self.weedBorder = weedBorder
    }
}

public enum PlotterGenerator {
    public static func generate(_ tp: Toolpath, profile: DeviceProfile, options: CutterJobOptions = .init()) -> String {
        var jobs: [(Layer, [[Vec2]])] = []
        for tl in tp.layers where tl.layer.mode != .fill {
            let prepared = tl.paths.map { path -> [Vec2] in
                var p = path
                if let f = p.first, let l = p.last, p.count > 2, f.distance(to: l) < 1e-6, profile.overcut > 0 {
                    p = addOvercut(p, distance: profile.overcut)
                }
                return profile.bladeOffset > 0 ? bladeCompensate(p, offset: profile.bladeOffset) : p
            }
            jobs.append((tl.layer, prepared))
        }
        if let margin = options.weedBorder, let last = jobs.last?.0 {
            let b = tp.bounds
            if !b.isEmpty {
                let r = b.insetBy(-margin)
                var box = [Vec2(r.minX, r.minY), Vec2(r.maxX, r.minY), Vec2(r.maxX, r.maxY), Vec2(r.minX, r.maxY), Vec2(r.minX, r.minY)]
                if profile.overcut > 0 { box = addOvercut(box, distance: profile.overcut) }
                if profile.bladeOffset > 0 { box = bladeCompensate(box, offset: profile.bladeOffset) }
                jobs.append((last, [box]))
            }
        }

        if profile.language == .svgFile {
            return svg(jobs: jobs, profile: profile)
        }

        func u(_ p: Vec2) -> (Int, Int) {
            let q = profile.toMachine(p)
            return (Int((q.x * profile.unitsPerMM).rounded()), Int((q.y * profile.unitsPerMM).rounded()))
        }

        switch profile.language {
        case .hpgl:
            var out = "IN;"
            for (layer, paths) in jobs {
                if profile.sendSpeedAndForce {
                    out += "VS\(max(1, layer.cutSpeed));FS\(max(1, layer.cutForce));"
                }
                for _ in 0..<max(1, layer.passes) {
                    for path in paths where path.count > 1 {
                        let s = u(path[0])
                        out += "PU\(s.0),\(s.1);"
                        let rest = path.dropFirst().map(u)
                        var i = 0
                        while i < rest.count {
                            let chunk = rest[i..<min(i + 64, rest.count)]
                            out += "PD" + chunk.map { "\($0.0),\($0.1)" }.joined(separator: ",") + ";"
                            i += 64
                        }
                        out += "\n"
                    }
                }
            }
            out += "PU;\n"
            return out
        case .gpgl:
            let etx = "\u{03}"
            var out = ""
            for (layer, paths) in jobs {
                if profile.sendSpeedAndForce {
                    out += "!\(max(1, min(10, layer.cutSpeed)))" + etx
                    out += "FX\(max(1, min(31, layer.cutForce / 10)))" + etx
                }
                for _ in 0..<max(1, layer.passes) {
                    for path in paths where path.count > 1 {
                        let s = u(path[0])
                        out += "M\(s.0),\(s.1)" + etx
                        let rest = path.dropFirst().map(u)
                        var i = 0
                        while i < rest.count {
                            let chunk = rest[i..<min(i + 64, rest.count)]
                            out += "D" + chunk.map { "\($0.0),\($0.1)" }.joined(separator: ",") + etx
                            i += 64
                        }
                    }
                }
            }
            out += "H" + etx
            return out
        case .svgFile:
            return ""
        }
    }

    /// An SVG cut file in mm, one group per layer, for cutters that only take files (e.g. ScanNCut).
    static func svg(jobs: [(Layer, [[Vec2]])], profile: DeviceProfile) -> String {
        let w = fmt(profile.bedWidth), h = fmt(profile.bedHeight)
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)mm\" height=\"\(h)mm\" viewBox=\"0 0 \(w) \(h)\">\n"
        for (layer, paths) in jobs {
            out += "  <g id=\"\(layer.name.replacingOccurrences(of: "\"", with: ""))\" fill=\"none\" stroke=\"\(layer.colorHex)\" stroke-width=\"0.1\">\n"
            for p in paths where p.count > 1 {
                var d = "M\(fmt(p[0].x)),\(fmt(p[0].y))"
                for q in p.dropFirst() { d += " L\(fmt(q.x)),\(fmt(q.y))" }
                if let f = p.first, let l = p.last, f.distance(to: l) < 1e-6 { d += " Z" }
                out += "    <path d=\"\(d)\"/>\n"
            }
            out += "  </g>\n"
        }
        out += "</svg>\n"
        return out
    }

    /// Extends a closed path along its start for `distance` mm, so the cut overlaps where it began.
    public static func addOvercut(_ path: [Vec2], distance: Double) -> [Vec2] {
        guard path.count > 2, distance > 0 else { return path }
        var out = path
        var left = distance
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let seg = a.distance(to: b)
            if seg <= 0 { continue }
            if seg >= left {
                out.append(a + (b - a) * (left / seg))
                return out
            }
            out.append(b)
            left -= seg
        }
        return out
    }

    /// Drag-knife compensation: moves the knife pivot ahead of the tip by `offset`,
    /// and swivels around corners sharper than `thresholdDegrees` so the tip turns on the spot.
    public static func bladeCompensate(_ input: [Vec2], offset r: Double, thresholdDegrees: Double = 8) -> [Vec2] {
        var pts: [Vec2] = []
        for p in input where pts.last.map({ $0.distance(to: p) > 1e-6 }) ?? true { pts.append(p) }
        guard pts.count > 1, r > 0 else { return pts }
        let dirs = (0..<(pts.count - 1)).map { (pts[$0 + 1] - pts[$0]).normalized }
        var out = [pts[0] + dirs[0] * r]
        let threshold = thresholdDegrees * .pi / 180
        for i in 0..<dirs.count {
            let d = dirs[i]
            out.append(pts[i + 1] + d * r)
            guard i + 1 < dirs.count else { break }
            let next = dirs[i + 1]
            let a0 = atan2(d.y, d.x)
            var sweep = atan2(next.y, next.x) - a0
            while sweep > .pi { sweep -= 2 * .pi }
            while sweep < -.pi { sweep += 2 * .pi }
            if abs(sweep) > threshold {
                let steps = max(2, Int((abs(sweep) / (10 * .pi / 180)).rounded(.up)))
                for s in 1...steps {
                    let a = a0 + sweep * Double(s) / Double(steps)
                    out.append(pts[i + 1] + Vec2(cos(a), sin(a)) * r)
                }
            }
        }
        return out
    }
}
