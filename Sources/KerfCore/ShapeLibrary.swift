import Foundation

/// Built-in shapes that can be drawn by dragging out a box.
public enum ShapeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case star, polygon, roundedRectangle, triangle, diamond, heart, arrow, cross, burst, gear, crescent, ring

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .star: return "Star"
        case .polygon: return "Polygon"
        case .roundedRectangle: return "Rounded rectangle"
        case .triangle: return "Triangle"
        case .diamond: return "Diamond"
        case .heart: return "Heart"
        case .arrow: return "Arrow"
        case .cross: return "Cross"
        case .burst: return "Starburst"
        case .gear: return "Gear"
        case .crescent: return "Crescent"
        case .ring: return "Ring"
        }
    }

    /// An SF Symbol for the shape picker.
    public var symbol: String {
        switch self {
        case .star: return "star"
        case .polygon: return "hexagon"
        case .roundedRectangle: return "app"
        case .triangle: return "triangle"
        case .diamond: return "diamond"
        case .heart: return "heart"
        case .arrow: return "arrow.right"
        case .cross: return "plus"
        case .burst: return "seal"
        case .gear: return "gearshape"
        case .crescent: return "moon"
        case .ring: return "circle.circle"
        }
    }
}

/// Settings for the adjustable shapes.
public struct ShapeOptions: Codable, Hashable, Sendable {
    /// Points on a star or starburst.
    public var points: Int = 5
    /// Inner radius of a star as a fraction of the outer radius.
    public var innerRatio: Double = 0.45
    /// Sides of a polygon.
    public var sides: Int = 6
    /// Corner radius of a rounded rectangle, in mm.
    public var cornerRadius: Double = 5
    /// Teeth on a gear.
    public var teeth: Int = 12

    public init() {}
}

public enum ShapeLibrary {
    /// Outlines for `kind` filling `rect` (mm, y down).
    public static func make(_ kind: ShapeKind, in rect: Rect2, options o: ShapeOptions = ShapeOptions()) -> [Polyline] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let c = rect.center, rx = rect.width / 2, ry = rect.height / 2
        /// Points around the box's ellipse, starting at the top, with a radius factor per point.
        func radial(_ count: Int, radius: (Int) -> Double) -> Polyline {
            let pts = (0..<count).map { i -> Vec2 in
                let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(count)
                let r = radius(i)
                return Vec2(c.x + cos(a) * rx * r, c.y + sin(a) * ry * r)
            }
            return Polyline(pts, closed: true)
        }
        /// Points given in a 0…1 box.
        func unit(_ pts: [(Double, Double)]) -> Polyline {
            Polyline(pts.map { Vec2(rect.minX + $0.0 * rect.width, rect.minY + $0.1 * rect.height) }, closed: true)
        }

        switch kind {
        case .star:
            let n = max(3, o.points), inner = max(0.05, min(0.95, o.innerRatio))
            return [radial(n * 2, radius: { $0 % 2 == 0 ? 1 : inner })]
        case .burst:
            let n = max(6, o.points * 3)
            return [radial(n * 2, radius: { $0 % 2 == 0 ? 1 : 0.8 })]
        case .polygon:
            return [radial(max(3, o.sides), radius: { _ in 1 })]
        case .triangle:
            return [unit([(0.5, 0), (1, 1), (0, 1)])]
        case .diamond:
            return [unit([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])]
        case .cross:
            let a = 1.0 / 3, b = 2.0 / 3
            return [unit([(a, 0), (b, 0), (b, a), (1, a), (1, b), (b, b), (b, 1), (a, 1), (a, b), (0, b), (0, a), (a, a)])]
        case .arrow:
            return [unit([(0, 0.32), (0.6, 0.32), (0.6, 0), (1, 0.5), (0.6, 1), (0.6, 0.68), (0, 0.68)])]
        case .roundedRectangle:
            return [roundedRect(rect, radius: o.cornerRadius)]
        case .heart:
            let raw = (0..<240).map { i -> Vec2 in
                let t = 2 * Double.pi * Double(i) / 240
                let x = 16 * pow(sin(t), 3)
                let y = -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))
                return Vec2(x, y)
            }
            return [fit(Polyline(raw, closed: true), into: rect)]
        case .gear:
            let teeth = max(4, o.teeth)
            let pts = (0..<(teeth * 4)).map { i -> Vec2 in
                let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(teeth * 4)
                let r = (i % 4 == 1 || i % 4 == 2) ? 1.0 : 0.8
                return Vec2(c.x + cos(a) * rx * r, c.y + sin(a) * ry * r)
            }
            let hole = Flatten.ellipse(center: c, rx: rx * 0.25, ry: ry * 0.25, step: 0.2)
            return [Polyline(pts, closed: true), hole]
        case .ring:
            return [Flatten.ellipse(center: c, rx: rx, ry: ry, step: 0.2),
                    Flatten.ellipse(center: c, rx: rx * 0.6, ry: ry * 0.6, step: 0.2)]
        case .crescent:
            // Left half of a circle, closed by a shallower curve through the same top and bottom points.
            let n = 120
            var pts: [Vec2] = []
            for i in 0...n {
                let a = Double.pi / 2 + Double.pi * Double(i) / Double(n) // bottom, left, top
                pts.append(Vec2(cos(a), sin(a)))
            }
            for i in 1..<n {
                let a = -Double.pi / 2 + Double.pi * Double(i) / Double(n) // top back to bottom
                pts.append(Vec2(-cos(a) * 0.45, sin(a)))
            }
            return [fit(Polyline(pts, closed: true), into: rect)]
        }
    }

    public static func roundedRect(_ r: Rect2, radius: Double) -> Polyline {
        let rad = max(0, min(radius, min(r.width, r.height) / 2))
        guard rad > 1e-6 else {
            return Polyline([Vec2(r.minX, r.minY), Vec2(r.maxX, r.minY), Vec2(r.maxX, r.maxY), Vec2(r.minX, r.maxY)], closed: true)
        }
        var pts: [Vec2] = []
        let corners: [(Vec2, Double)] = [(Vec2(r.maxX - rad, r.minY + rad), -Double.pi / 2),
                                         (Vec2(r.maxX - rad, r.maxY - rad), 0),
                                         (Vec2(r.minX + rad, r.maxY - rad), Double.pi / 2),
                                         (Vec2(r.minX + rad, r.minY + rad), Double.pi)]
        let steps = max(4, Int((rad * Double.pi / 2 / 0.3).rounded(.up)))
        for (center, start) in corners {
            for k in 0...steps {
                let a = start + Double.pi / 2 * Double(k) / Double(steps)
                pts.append(Vec2(center.x + cos(a) * rad, center.y + sin(a) * rad))
            }
        }
        return Polyline(pts, closed: true)
    }

    static func fit(_ p: Polyline, into rect: Rect2) -> Polyline {
        let b = p.bounds
        guard b.width > 0, b.height > 0 else { return p }
        return Polyline(p.points.map { q in
            Vec2(rect.minX + (q.x - b.minX) / b.width * rect.width, rect.minY + (q.y - b.minY) / b.height * rect.height)
        }, closed: p.closed)
    }
}
