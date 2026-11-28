import Foundation

// MARK: - Monogram templates

/// How the initials are set.
public enum MonogramLetters: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Three initials with the middle one larger (traditionally first, LAST, middle).
    case classic
    /// Three initials the same size, side by side.
    case block
    /// The initials stretched together into a circle, outer letters following the curve.
    case circle
    /// The initials stretched together into a diamond, outer letters tapering to its points.
    case diamond
    /// One large initial.
    case single
    /// A name arched over a large initial.
    case arched

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic: return "Classic (larger middle)"
        case .block: return "Three in a row"
        case .circle: return "Circle letters"
        case .diamond: return "Diamond letters"
        case .single: return "Single initial"
        case .arched: return "Name over initial"
        }
    }

    /// True when the letters are reshaped, so they're plain outlines rather than editable text.
    public var reshapesLetters: Bool { self == .circle || self == .diamond }
}

/// The border around the initials.
public enum MonogramFrame: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, circle, doubleCircle, diamond, square, scallop, vine

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "No frame"
        case .circle: return "Ring"
        case .doubleCircle: return "Double ring"
        case .diamond: return "Diamond"
        case .square: return "Rounded square"
        case .scallop: return "Scalloped"
        case .vine: return "Vine wreath"
        }
    }
}

/// Everything a monogram is built from. Sizes in mm.
public struct MonogramOptions: Codable, Hashable, Sendable {
    public var letters: MonogramLetters
    public var frame: MonogramFrame
    public var left: String
    public var center: String
    public var right: String
    /// The name arched over the initial (Name over initial only).
    public var name: String
    public var fontName: String
    /// Overall width of the monogram, frame included.
    public var size: Double
    /// Width of the frame's band.
    public var frameWidth: Double
    /// Side initials' height as a fraction of the middle one's (Classic only).
    public var sideScale: Double

    public init(letters: MonogramLetters = .classic, frame: MonogramFrame = .none, left: String = "A",
                center: String = "B", right: String = "C", name: String = "Name", fontName: String = "Didot-Bold",
                size: Double = 80, frameWidth: Double = 3, sideScale: Double = 0.72) {
        self.letters = letters
        self.frame = frame
        self.left = left
        self.center = center
        self.right = right
        self.name = name
        self.fontName = fontName
        self.size = size
        self.frameWidth = frameWidth
        self.sideScale = sideScale
    }

    public var sanitized: MonogramOptions {
        var o = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite ? min(hi, max(lo, v)) : fallback
        }
        o.size = clamp(size, 10, 1000, 80)
        o.frameWidth = clamp(frameWidth, 0.5, o.size * 0.1, 3)
        o.sideScale = clamp(sideScale, 0.4, 1, 0.72)
        o.left = String(left.trimmingCharacters(in: .whitespaces).prefix(1))
        o.center = String(center.trimmingCharacters(in: .whitespaces).prefix(1))
        o.right = String(right.trimmingCharacters(in: .whitespaces).prefix(1))
        o.name = name.trimmingCharacters(in: .whitespaces)
        return o
    }

    /// The initials in order, leaving out empty ones.
    public var initials: [String] {
        switch letters {
        case .single, .arched: return [center.isEmpty ? (left.isEmpty ? right : left) : center].filter { !$0.isEmpty }
        default: return [left, center, right].filter { !$0.isEmpty }
        }
    }
}

/// A ready-made combination of letters, frame and font.
public struct MonogramTemplate: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var letters: MonogramLetters
    public var frame: MonogramFrame
    public var fontName: String

    public init(_ id: String, _ title: String, letters: MonogramLetters, frame: MonogramFrame, fontName: String) {
        self.id = id
        self.title = title
        self.letters = letters
        self.frame = frame
        self.fontName = fontName
    }

    /// The options with this template's letters, frame and font, keeping the initials and size.
    public func applied(to o: MonogramOptions) -> MonogramOptions {
        var o = o
        o.letters = letters
        o.frame = frame
        o.fontName = fontName
        return o
    }

    public static let all: [MonogramTemplate] = [
        MonogramTemplate("classic", "Classic", letters: .classic, frame: .none, fontName: "Didot-Bold"),
        MonogramTemplate("circle", "Circle", letters: .circle, frame: .circle, fontName: "Futura-Bold"),
        MonogramTemplate("circle-plain", "Circle, no frame", letters: .circle, frame: .none, fontName: "Futura-Bold"),
        MonogramTemplate("diamond", "Diamond", letters: .diamond, frame: .diamond, fontName: "Futura-Bold"),
        MonogramTemplate("diamond-plain", "Diamond, no frame", letters: .diamond, frame: .none, fontName: "Futura-Bold"),
        MonogramTemplate("vine", "Vine wreath", letters: .classic, frame: .vine, fontName: "SnellRoundhand-Black"),
        MonogramTemplate("scallop", "Scalloped initial", letters: .single, frame: .scallop, fontName: "Baskerville-Bold"),
        MonogramTemplate("double-ring", "Double ring", letters: .block, frame: .doubleCircle, fontName: "Copperplate-Bold"),
        MonogramTemplate("framed", "Framed initial", letters: .single, frame: .square, fontName: "Georgia-Bold"),
        MonogramTemplate("arched", "Name over initial", letters: .arched, frame: .circle, fontName: "Baskerville-Bold"),
    ]
}

/// One shape of a monogram, centred with the rest on (0, 0).
public struct MonogramPiece: Hashable, Sendable {
    public enum Role: Hashable, Sendable { case letters, frame }

    public var role: Role
    public var name: String
    /// Outlines in the piece's own coordinates; `transform` places them.
    public var paths: [Polyline]
    public var transform: Affine
    /// Set for editable text: `paths` are this text's outlines.
    public var text: TextSpec?
    /// The outlines overlap and should be welded into one outline (the vine's stem and leaves).
    public var weld: Bool

    public init(role: Role, name: String, paths: [Polyline], transform: Affine = .identity, text: TextSpec? = nil, weld: Bool = false) {
        self.role = role
        self.name = name
        self.paths = paths
        self.transform = transform
        self.text = text
        self.weld = weld
    }

    public var placedPaths: [Polyline] { paths.transformed(transform) }
}

public enum Monogram {
    /// Where the letters may go inside the frame, centred on (0, 0).
    public enum Region: Hashable, Sendable {
        case circle(Double)
        /// Half-width and half-height of the diamond.
        case diamond(Double, Double)
        case box(Double, Double)

        /// The largest circle radius that fits.
        var radius: Double {
            switch self {
            case .circle(let r): return r
            case .diamond(let a, let b): return a * b / (a * a + b * b).squareRoot()
            case .box(let w, let h): return min(w, h) / 2
            }
        }
    }

    /// Height text is outlined at before being scaled to fit.
    static let referenceHeight = 20.0

    /// Builds the monogram. `outline` turns text into outlines (y down), as the text tool does.
    public static func build(_ raw: MonogramOptions, outline: (TextSpec) -> [Polyline]) -> [MonogramPiece] {
        let o = raw.sanitized
        let (framePieces, region) = frame(o)
        return letterPieces(o, region: region, outline: outline) + framePieces
    }

    // MARK: Frames

    /// The frame's pieces and the region left for the letters.
    public static func frame(_ o: MonogramOptions) -> ([MonogramPiece], Region) {
        let s = o.size, r = s / 2, w = o.frameWidth, pad = max(1, s * 0.04)
        func piece(_ paths: [Polyline], weld: Bool = false) -> [MonogramPiece] {
            [MonogramPiece(role: .frame, name: "Monogram frame: \(o.frame.title)", paths: paths, weld: weld)]
        }
        switch o.frame {
        case .none:
            switch o.letters {
            case .circle, .arched: return ([], .circle(r))
            case .diamond: return ([], .diamond(r, r * 0.8))
            case .single: return ([], .box(s, s))
            case .classic, .block: return ([], .box(s, s * 0.5))
            }
        case .circle:
            return (piece([circle(r), circle(r - w)]), .circle(r - w - pad))
        case .doubleCircle:
            let gap = max(1, w * 0.8), thin = max(0.8, w * 0.45)
            let inner = r - w - gap
            return (piece([circle(r), circle(r - w), circle(inner), circle(inner - thin)]), .circle(inner - thin - pad))
        case .diamond:
            let a = r, b = r * 0.8
            let d = a * b / (a * a + b * b).squareRoot()
            let outer = rhombus(a, b), f = max(0.1, (d - w) / d), fi = max(0.1, (d - w - pad) / d)
            return (piece([outer, rhombus(a * f, b * f)]), .diamond(a * fi, b * fi))
        case .square:
            let corner = s * 0.12
            return (piece([roundedSquare(s, corner: corner), roundedSquare(s - 2 * w, corner: max(0, corner - w))]),
                    .box(s - 2 * w - 2 * pad, s - 2 * w - 2 * pad))
        case .scallop:
            let n = 16, depth = s * 0.05
            var pts: [Vec2] = []
            let count = 720
            for k in 0..<count {
                let t = Double(k) / Double(count) * 2 * .pi
                let rr = r - depth + depth * abs(sin(Double(n) * t / 2))
                pts.append(Vec2(rr * cos(t), rr * sin(t)))
            }
            let inner = r - depth - w
            return (piece([Polyline(pts, closed: true), circle(inner)]), .circle(inner - pad))
        case .vine:
            let leaf = s * 0.1
            let stem = r - leaf * 0.95
            return (piece(vine(radius: stem, band: max(0.8, w * 0.5), leaf: leaf), weld: true), .circle(stem - leaf * 0.85 - pad))
        }
    }

    public static func circle(_ r: Double, center c: Vec2 = .zero) -> Polyline {
        let n = max(48, Int((2 * .pi * r / 0.5).rounded()))
        return Polyline((0..<n).map { k in
            let t = Double(k) / Double(n) * 2 * .pi
            return Vec2(c.x + r * cos(t), c.y + r * sin(t))
        }, closed: true)
    }

    static func rhombus(_ a: Double, _ b: Double) -> Polyline {
        Polyline([Vec2(0, -b), Vec2(a, 0), Vec2(0, b), Vec2(-a, 0)], closed: true)
    }

    static func roundedSquare(_ side: Double, corner: Double) -> Polyline {
        let h = side / 2, c = min(corner, h)
        guard c > 0.01 else { return Polyline([Vec2(-h, -h), Vec2(h, -h), Vec2(h, h), Vec2(-h, h)], closed: true) }
        var pts: [Vec2] = []
        let centres = [Vec2(h - c, -h + c), Vec2(h - c, h - c), Vec2(-h + c, h - c), Vec2(-h + c, -h + c)]
        let starts = [-Double.pi / 2, 0, Double.pi / 2, Double.pi]
        let steps = max(6, Int(c * 2))
        for (cc, a0) in zip(centres, starts) {
            for k in 0...steps {
                let t = a0 + Double(k) / Double(steps) * .pi / 2
                pts.append(Vec2(cc.x + c * cos(t), cc.y + c * sin(t)))
            }
        }
        return Polyline(pts, closed: true)
    }

    /// A wreath: a stem arching round from the top on both sides, with leaves along it, open at the top.
    /// The pieces overlap, so weld them for cutting.
    static func vine(radius rs: Double, band: Double, leaf: Double) -> [Polyline] {
        // y is down, so the top is at -90°. The stem runs clockwise from just right of the top round to just left.
        let opening = 28.0 * .pi / 180
        let a0 = -Double.pi / 2 + opening, a1 = 3 * Double.pi / 2 - opening
        let n = max(60, Int((rs * (a1 - a0) / 0.6).rounded()))
        var outer: [Vec2] = [], inner: [Vec2] = []
        for k in 0...n {
            let t = a0 + (a1 - a0) * Double(k) / Double(n)
            outer.append(Vec2((rs + band / 2) * cos(t), (rs + band / 2) * sin(t)))
            inner.append(Vec2((rs - band / 2) * cos(t), (rs - band / 2) * sin(t)))
        }
        var out = [Polyline(outer + inner.reversed(), closed: true)]
        // Leaves on each branch, from the bottom up, alternating outside and inside, leaning toward the top.
        let bottom = Double.pi / 2
        let perBranch = 7
        for branch in [-1.0, 1.0] {
            // The right branch runs from the bottom back toward a0 (decreasing angle), the left toward a1.
            let end = branch < 0 ? a0 : a1
            for k in 0..<perBranch {
                let f = (Double(k) + 0.6) / Double(perBranch)
                let t = bottom + (end - bottom) * f
                let p = Vec2(rs * cos(t), rs * sin(t))
                // Direction of growth along the stem (toward the branch's end) and outward.
                let tangent = Vec2(-sin(t), cos(t)) * (end > bottom ? 1 : -1)
                let outward = Vec2(cos(t), sin(t))
                let side = k % 2 == 0 ? 1.0 : -1.0
                let dir = (tangent * cos(0.75) + outward * (side * sin(0.75))).normalized
                out.append(almond(base: p - dir * (band * 0.5), direction: dir, length: leaf, width: leaf * 0.42))
            }
            // A leaf at the tip, pointing on along the stem.
            let p = Vec2(rs * cos(end), rs * sin(end))
            let tangent = Vec2(-sin(end), cos(end)) * (end > bottom ? 1 : -1)
            out.append(almond(base: p - tangent * band, direction: tangent, length: leaf * 0.9, width: leaf * 0.38))
        }
        return out
    }

    /// A pointed leaf from `base` along `direction`.
    static func almond(base: Vec2, direction d: Vec2, length: Double, width: Double) -> Polyline {
        let n = Vec2(-d.y, d.x)
        let steps = 16
        var left: [Vec2] = [], right: [Vec2] = []
        for k in 0...steps {
            let u = Double(k) / Double(steps)
            let half = width / 2 * pow(sin(.pi * u), 0.85) * (1 - 0.25 * u)
            let c = base + d * (length * u)
            left.append(c + n * half)
            right.append(c - n * half)
        }
        return Polyline(left + right.reversed().dropFirst().dropLast(), closed: true)
    }

    // MARK: Letters

    static func letterPieces(_ o: MonogramOptions, region: Region, outline: (TextSpec) -> [Polyline]) -> [MonogramPiece] {
        let initials = o.initials
        func glyph(_ text: String, height: Double = referenceHeight, curve: Double? = nil) -> (spec: TextSpec, paths: [Polyline], bounds: Rect2)? {
            let spec = TextSpec(text: text, fontName: o.fontName, height: height, curve: curve)
            let p = outline(spec)
            let b = p.bounds
            guard !b.isEmpty, b.width > 1e-6, b.height > 1e-6 else { return nil }
            return (spec, p, b)
        }
        /// Editable text scaled so its outline is `height` tall, centred on `center`.
        func textPiece(_ text: String, height: Double, center: Vec2, curve: Double? = nil) -> MonogramPiece? {
            guard let ref = glyph(text, curve: curve) else { return nil }
            let k = height / ref.bounds.height
            guard let g = glyph(text, height: referenceHeight * k, curve: curve) else { return nil }
            let c = g.bounds.center
            return MonogramPiece(role: .letters, name: "Monogram \(text)", paths: g.paths,
                                 transform: .translation(center.x - c.x, center.y - c.y), text: g.spec)
        }

        switch o.letters {
        case .classic, .block:
            let glyphs = initials.compactMap { glyph($0) }
            guard !glyphs.isEmpty else { return [] }
            let middle = glyphs.count == 3 ? 1 : (glyphs.count == 1 ? 0 : -1)
            let side = o.letters == .classic && glyphs.count > 1 ? o.sideScale : 1
            // Heights relative to the largest letter, then widths from each letter's shape.
            let rel = glyphs.indices.map { $0 == middle || side == 1 ? 1.0 : side }
            let widths = glyphs.indices.map { glyphs[$0].bounds.width / glyphs[$0].bounds.height * rel[$0] }
            let gap = o.letters == .classic ? 0.06 : 0.12
            let total = widths.reduce(0, +) + gap * Double(glyphs.count - 1)
            let box = letterBox(region, count: glyphs.count)
            let h = min(box.w / total, box.h)
            var x = -total * h / 2
            var out: [MonogramPiece] = []
            for i in glyphs.indices {
                let w = widths[i] * h
                if let p = textPiece(glyphs[i].spec.text, height: rel[i] * h, center: Vec2(x + w / 2, 0)) { out.append(p) }
                x += w + gap * h
            }
            return out
        case .single:
            guard let text = initials.first, let g = glyph(text) else { return [] }
            let box = letterBox(region, count: 1)
            let h = min(box.h, box.w * g.bounds.height / g.bounds.width)
            return [textPiece(text, height: h, center: .zero)].compactMap { $0 }
        case .arched:
            let r = region.radius
            var out: [MonogramPiece] = []
            let hasName = !o.name.isEmpty
            if let text = initials.first, let g = glyph(text) {
                let boxW = r * (hasName ? 1.0 : 1.3), boxH = r * (hasName ? 0.85 : 1.3)
                let h = min(boxH, boxW * g.bounds.height / g.bounds.width)
                if let p = textPiece(text, height: h, center: Vec2(0, hasName ? r * 0.2 : 0)) { out.append(p) }
            }
            if hasName, let straight = glyph(o.name) {
                // The name's tops follow just inside the circle; shrink it if it would wrap past 150°.
                var capH = r * 0.2
                var width = straight.bounds.width * capH / straight.bounds.height
                var radius = r * 0.95 - capH
                let maxAngle = 150.0 * .pi / 180
                if width / radius > maxAngle {
                    // width = c·capH, radius = 0.95r − capH; solve c·capH = maxAngle·(0.95r − capH).
                    let c = straight.bounds.width / straight.bounds.height
                    capH = maxAngle * 0.95 * r / (c + maxAngle)
                    width = c * capH
                    radius = r * 0.95 - capH
                }
                let degrees = width / radius * 180 / .pi
                if let g = glyph(o.name, height: referenceHeight * capH / straight.bounds.height, curve: degrees) {
                    // Put the top of the arch just inside the circle.
                    let b = g.bounds
                    out.append(MonogramPiece(role: .letters, name: "Monogram \(o.name)", paths: g.paths,
                                             transform: .translation(-b.center.x, -r * 0.95 - b.minY), text: g.spec))
                }
            }
            return out
        case .circle, .diamond:
            let glyphs = initials.compactMap { glyph($0) }
            guard !glyphs.isEmpty else { return [] }
            // Letters side by side at the same height, then stretched to the shape.
            var paths: [Polyline] = []
            var x = 0.0
            let gap = referenceHeight * 0.1
            for (i, g) in glyphs.enumerated() {
                let middle = glyphs.count == 3 && i == 1
                let sx = middle ? 1.15 : 1.0
                let k = referenceHeight / g.bounds.height
                let t = Affine(a: k * sx, b: 0, c: 0, d: k, tx: x - g.bounds.minX * k * sx, ty: -g.bounds.minY * k)
                paths += g.paths.transformed(t)
                x += g.bounds.width * k * sx + gap
            }
            let warped: [Polyline]
            if o.letters == .circle {
                let r = region.radius
                warped = warp(paths, halfWidth: r * 0.97) { X in max((r * r - X * X).squareRoot(), r * 0.2) }
            } else {
                let (a, b): (Double, Double)
                switch region {
                case .diamond(let da, let db): (a, b) = (da, db)
                case .circle(let r): (a, b) = (r, r * 0.8)
                case .box(let w, let h): (a, b) = (w / 2, h / 2)
                }
                warped = warp(paths, halfWidth: a * 0.97) { X in max(b * (1 - abs(X) / a), b * 0.16) }
            }
            return [MonogramPiece(role: .letters, name: "Monogram \(initials.joined())", paths: warped)]
        }
    }

    /// Room for the letters inside the region, as a box.
    static func letterBox(_ region: Region, count: Int) -> (w: Double, h: Double) {
        switch region {
        case .circle(let r): return count == 1 ? (r * 1.3, r * 1.3) : (r * 1.55, r * 0.95)
        case .diamond(let a, let b): return (a, b)
        case .box(let w, let h): return (w, h)
        }
    }

    /// Stretches outlines across `-halfWidth…halfWidth`, each point's height scaled so the letters fill
    /// `±profile(x)` at that x. Paths are first split into short pieces so straight edges bend with the shape.
    public static func warp(_ paths: [Polyline], halfWidth: Double, profile: (Double) -> Double) -> [Polyline] {
        let b = paths.bounds
        guard !b.isEmpty, b.width > 0, b.height > 0 else { return [] }
        let step = b.width / 400
        let mid = b.center
        return paths.map { p in
            let dense = resample(p, step: step)
            return Polyline(dense.map { q in
                let X = (q.x - mid.x) / (b.width / 2) * halfWidth
                let Y = (q.y - mid.y) / (b.height / 2) * profile(X)
                return Vec2(X, Y)
            }, closed: p.closed)
        }
    }

    /// The polyline's points with extra points so no segment is longer than `step`.
    static func resample(_ p: Polyline, step: Double) -> [Vec2] {
        let pts = p.drawnPoints
        guard pts.count >= 2, step > 0 else { return p.points }
        var out: [Vec2] = [pts[0]]
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let n = max(1, Int((a.distance(to: b) / step).rounded(.up)))
            for k in 1...n { out.append(a + (b - a) * (Double(k) / Double(n))) }
        }
        if p.closed { out.removeLast() }
        return out
    }
}
