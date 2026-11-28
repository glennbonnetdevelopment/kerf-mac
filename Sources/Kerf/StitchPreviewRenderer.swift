import KerfCore
import SwiftUI

/// Draws an embroidery plan as sewn thread: each stitch a rounded strand with a shadow on the fabric and a sheen
/// along its top, needle holes when zoomed in close. Light comes from the top left.
@MainActor
enum StitchPreviewRenderer {
    /// Width of a 40 wt embroidery thread lying flat, in mm.
    static let threadWidth = 0.42

    /// - Parameters:
    ///   - toView: maps bed millimetres to view points.
    ///   - zoom: view points per millimetre.
    ///   - visible: the part of the bed on screen, in mm; stitches outside it are skipped.
    static func draw(_ plan: EmbroideryPlan, in ctx: inout GraphicsContext, zoom: Double, visible: Rect2,
                     toView: (Vec2) -> CGPoint) {
        let width = max(0.6, threadWidth * zoom)
        // Zoomed far out the strands are under a point wide: one flat pass looks the same and is much faster.
        let detailed = width >= 1.6
        let holes = zoom >= 9
        let pad = threadWidth * 2
        let area = visible.insetBy(-pad)
        let shadowOffset = CGSize(width: 0.07 * zoom, height: 0.09 * zoom)
        let sheenOffset = CGSize(width: -0.05 * zoom, height: -0.06 * zoom)
        let round = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)

        for block in plan.blocks {
            let base = block.color
            let body = Color(thread: base)
            let shadow = Color(thread: base.darkened(by: 0.45))
            let sheen = Color(thread: base.lightened(by: 0.5))
            for run in block.runs where run.count >= 2 {
                guard intersects(run, area) else { continue }
                // Separate segments, so each stitch gets its own rounded ends like a real strand.
                var strands = Path()
                for i in 1..<run.count {
                    strands.move(to: toView(run[i - 1]))
                    strands.addLine(to: toView(run[i]))
                }
                if detailed {
                    var s = ctx
                    s.translateBy(x: shadowOffset.width, y: shadowOffset.height)
                    s.stroke(strands, with: .color(.black.opacity(0.28)),
                             style: StrokeStyle(lineWidth: width * 1.15, lineCap: .round, lineJoin: .round))
                    ctx.stroke(strands, with: .color(shadow), style: round)
                    ctx.stroke(strands, with: .color(body),
                               style: StrokeStyle(lineWidth: width * 0.78, lineCap: .round, lineJoin: .round))
                    var h = ctx
                    h.translateBy(x: sheenOffset.width, y: sheenOffset.height)
                    h.stroke(strands, with: .color(sheen.opacity(0.75)),
                             style: StrokeStyle(lineWidth: width * 0.28, lineCap: .round, lineJoin: .round))
                } else {
                    ctx.stroke(strands, with: .color(body), style: round)
                }
                if holes {
                    let r = max(0.6, 0.07 * zoom)
                    var dots = Path()
                    for p in run {
                        let c = toView(p)
                        dots.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    }
                    ctx.fill(dots, with: .color(Color(thread: base.darkened(by: 0.65)).opacity(0.55)))
                }
            }
        }
    }

    private static func intersects(_ run: [Vec2], _ area: Rect2) -> Bool {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in run {
            if area.contains(p) { return true }
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return Rect2(minX: minX, minY: minY, maxX: maxX, maxY: maxY).intersects(area)
    }
}
