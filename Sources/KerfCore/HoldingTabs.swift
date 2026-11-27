import Foundation

/// How automatic holding tabs are spread around a part.
public enum TabPlacement: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A fixed number of tabs on every part.
    case count
    /// One tab every so many millimetres of outline.
    case spacing

    public var id: String { rawValue }
    public var title: String { self == .count ? "Tabs per part" : "Tab every…" }
}

/// One holding tab in a planned job, for showing and editing on the canvas.
public struct TabMark: Sendable, Equatable {
    /// The shape the tab holds.
    public var shapeID: UUID
    /// Index into the shape's hand-placed `tabs`, or nil for a tab placed automatically.
    public var manualIndex: Int?
    /// Centre of the tab on the toolpath, in bed coordinates.
    public var point: Vec2
    /// Unit direction of travel at the tab.
    public var direction: Vec2
    /// Length of the tab along the path, in mm.
    public var length: Double

    public init(shapeID: UUID, manualIndex: Int?, point: Vec2, direction: Vec2, length: Double) {
        self.shapeID = shapeID
        self.manualIndex = manualIndex
        self.point = point
        self.direction = direction
        self.length = length
    }
}

/// Holding tabs (bridges): short stretches of a cut that are left uncut, or cut shallower on a CNC,
/// so parts stay attached to the sheet until the job is finished.
public enum HoldingTabs {
    // MARK: - Path measuring

    /// Running arc length at each point of `path`.
    public static func cumulative(_ path: [Vec2]) -> [Double] {
        var cum = [0.0]
        cum.reserveCapacity(path.count)
        for i in path.indices.dropFirst() { cum.append(cum[i - 1] + path[i].distance(to: path[i - 1])) }
        return cum
    }

    /// True when the path ends where it starts.
    public static func isClosed(_ path: [Vec2]) -> Bool {
        guard path.count > 2, let f = path.first, let l = path.last else { return false }
        return f.distance(to: l) < 1e-6
    }

    /// The point at arc length `s` (clamped to the path).
    public static func point(on path: [Vec2], cum: [Double], at s: Double) -> Vec2 {
        guard path.count > 1, let total = cum.last else { return path.first ?? .zero }
        let t = min(max(0, s), total)
        var lo = 1, hi = cum.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cum[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        let k = lo
        let seg = cum[k] - cum[k - 1]
        guard seg > 1e-12 else { return path[k] }
        return path[k - 1] + (path[k] - path[k - 1]) * ((t - cum[k - 1]) / seg)
    }

    /// Unit direction of travel at arc length `s`.
    public static func direction(on path: [Vec2], cum: [Double], at s: Double) -> Vec2 {
        guard path.count > 1 else { return Vec2(1, 0) }
        var k = 1
        while k < cum.count - 1, cum[k] < s { k += 1 }
        // Skip zero-length segments.
        var a = k
        while a < path.count, path[a].distance(to: path[a - 1]) < 1e-9 { a += 1 }
        if a >= path.count { return Vec2(1, 0) }
        return (path[a] - path[a - 1]).normalized
    }

    /// Arc length of the point on `path` nearest to `p`, and its distance from `p`.
    public static func project(_ p: Vec2, onto path: [Vec2], cum: [Double]) -> (s: Double, distance: Double) {
        var best = (s: 0.0, distance: Double.infinity)
        for i in path.indices.dropFirst() {
            let a = path[i - 1], b = path[i]
            let ab = b - a
            let len2 = ab.dot(ab)
            let t = len2 > 0 ? max(0, min(1, (p - a).dot(ab) / len2)) : 0
            let d = p.distance(to: a + ab * t)
            if d < best.distance { best = (cum[i - 1] + t * (cum[i] - cum[i - 1]), d) }
        }
        return best
    }

    // MARK: - Automatic placement

    /// How many automatic tabs a closed outline of length `total` gets.
    public static func autoCount(total: Double, placement: TabPlacement, count: Int, spacing: Double, width: Double) -> Int {
        guard total > 0, width > 0 else { return 0 }
        var n: Int
        switch placement {
        case .count: n = max(1, count)
        case .spacing: n = max(1, Int((total / max(1, spacing)).rounded()))
        }
        // Leave at least twice the tab width of cut between tabs, so small shapes aren't all tab.
        n = min(n, Int(total / (width * 3)))
        return max(0, n)
    }

    /// Tab centres (arc lengths) for a closed path: evenly spread, each nudged along the outline
    /// away from corners so tabs sit on straight or gently curved stretches, which are easier to snap off.
    public static func autoCenters(_ path: [Vec2], placement: TabPlacement, count: Int, spacing: Double,
                                   width: Double) -> [Double] {
        guard isClosed(path) else { return [] }
        let cum = cumulative(path)
        let total = cum.last ?? 0
        let n = autoCount(total: total, placement: placement, count: count, spacing: spacing, width: width)
        guard n > 0 else { return [] }

        // How sharply the path turns at each vertex (the closing vertex is at both ends).
        var turns: [(s: Double, angle: Double)] = []
        let m = path.count - 1 // distinct points
        for i in 0..<m {
            let prev = path[(i - 1 + m) % m], cur = path[i], next = path[(i + 1) % m]
            let d0 = cur - prev, d1 = next - cur
            guard d0.length > 1e-9, d1.length > 1e-9 else { continue }
            let angle = abs(atan2(d0.cross(d1), d0.dot(d1)))
            if angle > 1e-4 { turns.append((cum[i], angle)) }
        }
        func wrapped(_ s: Double) -> Double {
            var v = s.truncatingRemainder(dividingBy: total)
            if v < 0 { v += total }
            return v
        }
        /// Total turning within `half` of `c`, measured around the loop.
        func turning(at c: Double, half: Double) -> Double {
            turns.reduce(0) { sum, t in
                var d = abs(t.s - c).truncatingRemainder(dividingBy: total)
                d = min(d, total - d)
                return d <= half ? sum + t.angle : sum
            }
        }

        let pitch = total / Double(n)
        let reach = pitch * 0.35
        let steps = 12
        let half = width / 2 + max(width * 0.5, 1)
        return (0..<n).map { i in
            let nominal = (Double(i) + 0.5) * pitch
            var best = nominal, bestScore = Double.infinity
            for k in -steps...steps {
                let c = nominal + reach * Double(k) / Double(steps)
                // A little cost for drifting from even spacing, so ties stay evenly spread.
                let score = turning(at: wrapped(c), half: half) + 0.002 * Double(abs(k))
                if score < bestScore - 1e-9 { bestScore = score; best = c }
            }
            return wrapped(best)
        }
    }

    // MARK: - Intervals and splitting

    /// Arc-length ranges covered by tabs of `width` centred at `centers`, kept inside 0…total.
    /// A tab that crosses the start of a closed path is split in two.
    public static func intervals(centers: [Double], width: Double, total: Double) -> [ClosedRange<Double>] {
        guard total > 0, width > 0 else { return [] }
        var out: [ClosedRange<Double>] = []
        let w = min(width, total / 2)
        for c in centers {
            let lo = c - w / 2, hi = c + w / 2
            if lo < 0 {
                out.append(0...hi)
                out.append((total + lo)...total)
            } else if hi > total {
                out.append(lo...total)
                out.append(0...(hi - total))
            } else {
                out.append(lo...hi)
            }
        }
        // Merge overlaps.
        out.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in out {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// The stretch of `path` between arc lengths `a` and `b`.
    public static func subpath(_ path: [Vec2], cum: [Double], from a: Double, to b: Double) -> [Vec2] {
        var out = [point(on: path, cum: cum, at: a)]
        for (i, s) in cum.enumerated() where s > a + 1e-9 && s < b - 1e-9 { out.append(path[i]) }
        out.append(point(on: path, cum: cum, at: b))
        return out
    }

    /// The pieces of a closed path that are still cut once the tab ranges are left out (for lasers,
    /// which simply switch off over a tab). Pieces on either side of the path's start are joined,
    /// so the laser doesn't stop and restart there.
    public static func split(_ path: [Vec2], tabs: [ClosedRange<Double>]) -> [[Vec2]] {
        guard !tabs.isEmpty, path.count > 1 else { return [path] }
        let cum = cumulative(path)
        let total = cum.last ?? 0
        var pieces: [(Double, Double)] = []
        var cursor = 0.0
        for t in tabs.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if t.lowerBound > cursor + 1e-6 { pieces.append((cursor, t.lowerBound)) }
            cursor = max(cursor, t.upperBound)
        }
        if cursor < total - 1e-6 { pieces.append((cursor, total)) }
        var out = pieces.map { subpath(path, cum: cum, from: $0.0, to: $0.1) }
        if out.count > 1, let first = pieces.first, let last = pieces.last,
           first.0 < 1e-6, last.1 > total - 1e-6, isClosed(path) {
            out[out.count - 1] += out[0].dropFirst()
            out.removeFirst()
        }
        return out.filter { $0.count > 1 }
    }

    // MARK: - Planning

    /// A tab on one planned path: its centre as an arc length, and which of the owner's hand-placed
    /// tabs it is (nil when placed automatically).
    public struct Placed: Sendable, Equatable {
        public var s: Double
        public var manualIndex: Int?
    }

    /// Tabs for each planned path of a layer.
    /// - Parameters:
    ///   - paths: the planned paths, closed ones repeating their first point.
    ///   - owners: the shape each path came from.
    ///   - autoEligible: whether each path gets automatic tabs (parts).
    ///   - manualEligible: whether hand-placed tabs may land on each path.
    ///   - width: tab length along the path, used to limit how many automatic tabs fit.
    public static func place(paths: [[Vec2]], owners: [Artwork], autoEligible: [Bool], manualEligible: [Bool],
                             layer: Layer, width: Double) -> [[Placed]] {
        var result = [[Placed]](repeating: [], count: paths.count)
        guard layer.tabsEnabled else { return result }
        for i in paths.indices where owners[i].tabs == nil && autoEligible[i] {
            result[i] = autoCenters(paths[i], placement: layer.tabPlacement, count: layer.tabCount,
                                    spacing: layer.tabSpacing, width: width).map { Placed(s: $0, manualIndex: nil) }
        }
        // Hand-placed tabs go on the nearest outline of their own shape.
        var byShape: [UUID: [Int]] = [:]
        for i in paths.indices where owners[i].tabs != nil && manualEligible[i] && isClosed(paths[i]) {
            byShape[owners[i].id, default: []].append(i)
        }
        var cums: [Int: [Double]] = [:]
        var seen = Set<UUID>()
        for owner in owners where !seen.contains(owner.id) {
            seen.insert(owner.id)
            guard let tabs = owner.tabs, let candidates = byShape[owner.id] else { continue }
            for (k, local) in tabs.enumerated() {
                let p = owner.transform.apply(local)
                var best: (i: Int, s: Double, d: Double)?
                for i in candidates {
                    if cums[i] == nil { cums[i] = cumulative(paths[i]) }
                    let hit = project(p, onto: paths[i], cum: cums[i]!)
                    if best == nil || hit.distance < best!.d { best = (i, hit.s, hit.distance) }
                }
                if let b = best { result[b.i].append(Placed(s: b.s, manualIndex: k)) }
            }
        }
        return result
    }

    /// Canvas marks for the tabs placed on `path`.
    public static func marks(on path: [Vec2], placed: [Placed], owner: UUID, width: Double) -> [TabMark] {
        guard !placed.isEmpty else { return [] }
        let cum = cumulative(path)
        return placed.map {
            TabMark(shapeID: owner, manualIndex: $0.manualIndex, point: point(on: path, cum: cum, at: $0.s),
                    direction: direction(on: path, cum: cum, at: $0.s), length: width)
        }
    }
}
