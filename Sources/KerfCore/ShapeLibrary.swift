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
