import Foundation

/// One straight tool move read back from CNC G-code, in machine millimetres.
public struct MillMove: Sendable, Equatable {
    public var from: MillPoint
    public var to: MillPoint
    /// True for G1 (cutting feed), false for G0 (rapid).
    public var feed: Bool
    /// Tool diameter in effect for this move.
    public var toolDiameter: Double
}

public struct MillPoint: Sendable, Equatable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
}

/// Removes material from a block of stock by sweeping a flat end mill along G-code moves.
/// The result is a height map: 0 is the top of the stock, negative values are cut depth.
public struct MillSimulator: Sendable {
    public var originX: Double
    public var originY: Double
    /// Size of one cell in mm.
    public var cell: Double
    public var columns: Int
    public var rows: Int
    /// Row-major heights; row 0 is the lowest machine Y.
    public var heights: [Float]

    /// Reads G0/G1 moves (absolute mm) from G-code. The tool diameter comes from Kerf's layer
    /// comments ("tool 3 mm"), falling back to `defaultTool`.
    public static func moves(from gcode: [String], defaultTool: Double = 3) -> [MillMove] {
        var pos = MillPoint(0, 0, 5)
        var tool = defaultTool
        var out: [MillMove] = []
        for raw in gcode {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(";") || line.hasPrefix("(") {
                if let r = line.range(of: "tool ") {
                    let rest = line[r.upperBound...].prefix { "0123456789.".contains($0) }
                    if let d = Double(rest), d > 0 { tool = d }
                }
                continue
            }
            let code = line.split(separator: ";").first.map(String.init) ?? ""
            let words = code.uppercased().split(separator: " ")
            guard let g = words.first, g == "G0" || g == "G1" || g == "G00" || g == "G01" else { continue }
            var next = pos
            for w in words.dropFirst() {
                guard let letter = w.first, let value = Double(w.dropFirst()) else { continue }
                switch letter {
                case "X": next.x = value
                case "Y": next.y = value
                case "Z": next.z = value
                default: break
                }
            }
            if next != pos {
                out.append(MillMove(from: pos, to: next, feed: g == "G1" || g == "G01", toolDiameter: tool))
            }
            pos = next
        }
        return out
    }

    /// A stock block covering every move below the surface, plus a margin.
    public init(moves: [MillMove], margin: Double = 10, maxCells: Int = 1400) {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for m in moves where min(m.from.z, m.to.z) < 0 {
            let r = m.toolDiameter / 2
            minX = min(minX, m.from.x - r, m.to.x - r)
            maxX = max(maxX, m.from.x + r, m.to.x + r)
            minY = min(minY, m.from.y - r, m.to.y - r)
            maxY = max(maxY, m.from.y + r, m.to.y + r)
        }
        if !minX.isFinite { minX = 0; minY = 0; maxX = 100; maxY = 100 }
        minX -= margin; minY -= margin; maxX += margin; maxY += margin
        let longest = max(maxX - minX, maxY - minY)
        cell = max(0.05, longest / Double(maxCells))
        originX = minX
        originY = minY
        columns = max(1, Int(((maxX - minX) / cell).rounded(.up)))
        rows = max(1, Int(((maxY - minY) / cell).rounded(.up)))
        heights = [Float](repeating: 0, count: columns * rows)
    }

    /// Sweeps the tool along each cutting move. Moves above the stock leave it untouched.
    public mutating func run(_ moves: some Sequence<MillMove>) {
        for m in moves where min(m.from.z, m.to.z) < 0 {
            let r = m.toolDiameter / 2
            let dx = m.to.x - m.from.x, dy = m.to.y - m.from.y
            let length = (dx * dx + dy * dy).squareRoot()
            let steps = max(1, Int((length / max(cell * 0.75, r * 0.2)).rounded(.up)))
            for s in 0...steps {
                let t = Double(s) / Double(steps)
                stamp(x: m.from.x + dx * t, y: m.from.y + dy * t, z: m.from.z + (m.to.z - m.from.z) * t, radius: r)
            }
        }
    }

    mutating func stamp(x: Double, y: Double, z: Double, radius: Double) {
        guard z < 0 else { return }
        let zf = Float(z)
        let cx = (x - originX) / cell, cy = (y - originY) / cell, rc = radius / cell
        let r2 = rc * rc
        let y0 = max(0, Int((cy - rc).rounded(.down))), y1 = min(rows - 1, Int((cy + rc).rounded(.up)))
        let x0 = max(0, Int((cx - rc).rounded(.down))), x1 = min(columns - 1, Int((cx + rc).rounded(.up)))
        guard y0 <= y1, x0 <= x1 else { return }
        heights.withUnsafeMutableBufferPointer { h in
            for j in y0...y1 {
                let ddy = Double(j) + 0.5 - cy
                let row = j * columns
                for i in x0...x1 {
                    let ddx = Double(i) + 0.5 - cx
                    if ddx * ddx + ddy * ddy <= r2, h[row + i] > zf { h[row + i] = zf }
                }
            }
        }
    }

    /// The height at a machine position, or 0 outside the stock.
    public func height(x: Double, y: Double) -> Float {
        let i = Int((x - originX) / cell), j = Int((y - originY) / cell)
        guard i >= 0, j >= 0, i < columns, j < rows else { return 0 }
        return heights[j * columns + i]
    }

    public var deepest: Float { heights.min() ?? 0 }
}
