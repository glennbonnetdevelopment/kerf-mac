import AppKit
import KerfCore
import SwiftUI

/// Zoom and pan state for the canvas. A class so the scroll-wheel monitor can update it.
@MainActor
final class Viewport: ObservableObject {
    /// Points per millimetre.
    @Published var zoom: Double = 2
    /// View position of the bed's (0, 0).
    @Published var pan = CGPoint(x: 40, y: 40)
    var viewSize: CGSize = .zero
    var frameInWindow: CGRect = .zero
    /// The window the canvas is in. Scroll events from any other window (sheets, popovers, menus) are left alone.
    weak var window: NSWindow?

    func toView(_ p: Vec2) -> CGPoint {
        CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom)
    }

    func toDoc(_ p: CGPoint) -> Vec2 {
        Vec2((p.x - pan.x) / zoom, (p.y - pan.y) / zoom)
    }

    func zoom(by factor: Double, around viewPoint: CGPoint) {
        let anchor = toDoc(viewPoint)
        zoom = min(200, max(0.1, zoom * factor))
        pan = CGPoint(x: viewPoint.x - anchor.x * zoom, y: viewPoint.y - anchor.y * zoom)
    }

    func fit(_ rect: Rect2, margin: Double = 30) {
        guard viewSize.width > 0, rect.width > 0, rect.height > 0 else { return }
        zoom = min((viewSize.width - 2 * margin) / rect.width, (viewSize.height - 2 * margin) / rect.height)
        zoom = max(0.1, zoom)
        pan = CGPoint(x: (viewSize.width - rect.width * zoom) / 2 - rect.minX * zoom,
                      y: (viewSize.height - rect.height * zoom) / 2 - rect.minY * zoom)
    }
}

private enum DragMode {
    case none
    case move(last: Vec2, moved: Bool)
    case marquee(start: Vec2, current: Vec2)
    case create(start: Vec2, current: Vec2)
    case pan(lastView: CGPoint)
    /// Dragging a sizing handle: `handle` is the handle's position as fractions of the box (0, 0.5 or 1).
    case scale(handle: Vec2, startBounds: Rect2, base: [UUID: Affine], moved: Bool)
    case rotate(center: Vec2, startAngle: Double, base: [UUID: Affine], moved: Bool)
    /// Sliding text along its path.
    case slideText(id: UUID, moved: Bool)
    /// Dragging one node with the node tool.
    case node(ref: NodeRef, moved: Bool)
    /// Dragging a holding tab along its outline; `index` is its hand-placed index once it has moved.
    case tab(mark: TabMark, index: Int?, moved: Bool)
    /// Measuring with the ruler tool.
    case measure(start: Vec2, current: Vec2)
    /// Drawing with the pen or brush.
    case freehand(samples: [StrokeSample])
    /// Rubbing out with the eraser.
    case erase(trail: [Vec2])
}

/// The eight sizing handles, as fractions of the selection box, starting top-left and going clockwise.
private let handleFractions: [Vec2] = [Vec2(0, 0), Vec2(0.5, 0), Vec2(1, 0), Vec2(1, 0.5),
                                       Vec2(1, 1), Vec2(0.5, 1), Vec2(0, 1), Vec2(0, 0.5)]
private let rotateHandleOffset: CGFloat = 22

struct CanvasView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var viewport = Viewport()
    @State private var dragMode = DragMode.none
    @State private var scrollMonitor: Any?
    @State private var magnifyBase: Double?
    /// The last measurement, kept on screen until the next one.
    @State private var lastMeasure: (Vec2, Vec2)?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(&ctx, size: size)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.delete) { deletePressed(); return .handled }
            .onKeyPress(.deleteForward) { deletePressed(); return .handled }
            .onKeyPress(.escape) {
                model.selection = []
                model.tool = .select
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
                switch press.key {
                case .leftArrow: model.moveSelection(by: Vec2(-step, 0))
                case .rightArrow: model.moveSelection(by: Vec2(step, 0))
                case .upArrow: model.moveSelection(by: Vec2(0, -step))
                default: model.moveSelection(by: Vec2(0, step))
                }
                return .handled
            }
            .onAppear {
                viewport.viewSize = geo.size
                viewport.frameInWindow = geo.frame(in: .global)
                fitBed()
                installScrollMonitor()
            }
            .onDisappear {
                if let m = scrollMonitor { NSEvent.removeMonitor(m) }
                scrollMonitor = nil
            }
            .onChange(of: geo.size) { _, newSize in
                viewport.viewSize = newSize
                viewport.frameInWindow = geo.frame(in: .global)
            }
            .background(WindowReader { viewport.window = $0 })
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .overlay(alignment: .bottomLeading) { statusBar }
        }
    }

    /// Delete removes the picked node in the node tool, otherwise the selection.
    private func deletePressed() {
        if model.tool == .node, let ref = model.selectedNode {
            model.deleteNode(ref)
        } else if model.tool == .tabs {
            if let mark = model.selectedTab { model.removeTab(mark) }
            model.selectedTab = nil
        } else {
            model.deleteSelection()
        }
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let vp = viewport
        let profile = model.profile
        let bedRect = CGRect(origin: vp.toView(.zero),
                             size: CGSize(width: profile.bedWidth * vp.zoom, height: profile.bedHeight * vp.zoom))
        ctx.fill(Path(bedRect), with: .color(Color(nsColor: .textBackgroundColor)))

        // Grid: 10 mm with 100 mm lines stronger, or ¼ inch with whole inches stronger.
        let inch = model.units == .inch
        let majorEvery = inch ? 25.4 : 100.0
        var gridStep = inch ? 6.35 : 10.0
        if vp.zoom * gridStep < 6 { gridStep = inch ? 25.4 : 50.0 }
        var minor = Path(), major = Path()
        func isMajor(_ v: Double) -> Bool {
            let r = v / majorEvery
            return abs(r - r.rounded()) < 1e-6
        }
        var x = 0.0
        while x <= profile.bedWidth + 1e-6 {
            let a = vp.toView(Vec2(x, 0)), b = vp.toView(Vec2(x, profile.bedHeight))
            if isMajor(x) { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
            x += gridStep
        }
        var y = 0.0
        while y <= profile.bedHeight + 1e-6 {
            let a = vp.toView(Vec2(0, y)), b = vp.toView(Vec2(profile.bedWidth, y))
            if isMajor(y) { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
            y += gridStep
        }
        ctx.stroke(minor, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(.gray.opacity(0.35)), lineWidth: 0.8)
        ctx.stroke(Path(bedRect), with: .color(.gray.opacity(0.6)), lineWidth: 1)

        // Workpiece: the material sitting on the bed.
        if let w = model.document.workpiece {
            let r = CGRect(origin: vp.toView(Vec2(w.x, w.y)), size: CGSize(width: w.width * vp.zoom, height: w.height * vp.zoom))
            let fill: Color, edge: Color
            switch w.kind {
            case .stock: fill = Color(red: 0.87, green: 0.72, blue: 0.52).opacity(0.35); edge = Color(red: 0.55, green: 0.36, blue: 0.18)
            case .mat: fill = Color(red: 0.55, green: 0.78, blue: 0.85).opacity(0.25); edge = Color(red: 0.2, green: 0.45, blue: 0.55)
            case .sheet: fill = Color.white.opacity(0.6); edge = Color.gray
            case .hoop: fill = Color.white.opacity(0.35); edge = Color(red: 0.45, green: 0.3, blue: 0.6)
            }
            ctx.fill(Path(r), with: .color(fill))
            if w.kind == .mat {
                // Cutting mats carry a 1 inch grid.
                var g = Path()
                var gx = 25.4
                while gx < w.width - 1e-6 {
                    g.move(to: vp.toView(Vec2(w.x + gx, w.y)))
                    g.addLine(to: vp.toView(Vec2(w.x + gx, w.y + w.height)))
                    gx += 25.4
                }
                var gy = 25.4
                while gy < w.height - 1e-6 {
                    g.move(to: vp.toView(Vec2(w.x, w.y + gy)))
                    g.addLine(to: vp.toView(Vec2(w.x + w.width, w.y + gy)))
                    gy += 25.4
                }
                ctx.stroke(g, with: .color(edge.opacity(0.25)), lineWidth: 0.6)
            }
            if w.kind == .hoop {
                // Hoop centre: embroidery machines sew the design centred here.
                var g = Path()
                g.move(to: CGPoint(x: r.midX, y: r.minY))
                g.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                g.move(to: CGPoint(x: r.minX, y: r.midY))
                g.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                ctx.stroke(g, with: .color(edge.opacity(0.3)), style: StrokeStyle(lineWidth: 0.6, dash: [4, 4]))
            }
            ctx.stroke(Path(r), with: .color(edge), lineWidth: 1.5)
            let label = String(format: "%@ · %.0f × %.0f mm", w.name, w.width, w.height) + (w.kind == .stock ? String(format: " × %.1f", w.thickness) : "")
            ctx.draw(Text(label).font(.caption2).foregroundColor(edge), at: CGPoint(x: r.minX + 4, y: r.minY - 3), anchor: .bottomLeading)
        }

        // Machine origin marker.
        let originDoc = profile.fromMachine(.zero)
        let o = vp.toView(originDoc)
        ctx.fill(Path(ellipseIn: CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)), with: .color(.orange))

        // Shapes.
        for shape in model.document.shapes {
            guard let layer = model.document.layer(shape.layerID) else { continue }
            let path = viewPath(shape.style?.roundedCorners != nil ? shape.placedStyledPaths : shape.placedPaths)
            if let style = shape.style { drawStyle(style, of: shape, path: path, in: &ctx, vp: vp) }
            let color = Color(hex: layer.colorHex).opacity(layer.enabled ? 1 : 0.3)
            if let img = shape.image, let cg = ImageCache.shared.cgImage(for: shape.id, image: img) {
                var ictx = ctx
                let t = shape.transform
                ictx.concatenate(CGAffineTransform(a: t.a * vp.zoom, b: t.b * vp.zoom, c: t.c * vp.zoom, d: t.d * vp.zoom,
                                                   tx: vp.pan.x + t.tx * vp.zoom, ty: vp.pan.y + t.ty * vp.zoom))
                let f = shape.localFrame
                ictx.opacity = layer.enabled ? 1 : 0.4
                ictx.draw(Image(decorative: cg, scale: 1), in: CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height))
            } else if layer.mode == .fill {
                ctx.fill(path, with: .color(color.opacity(0.18)), style: FillStyle(eoFill: true))
            } else if layer.mode == .print {
                ctx.fill(path, with: .color(color.opacity(0.85)), style: FillStyle(eoFill: true))
            }
            let width: CGFloat = model.selection.contains(shape.id) ? 1.6 : 1
            if shape.outlineEnabled {
                ctx.stroke(path, with: .color(color), lineWidth: width)
            } else {
                // Not made: a faint guide so the shape can still be seen and picked.
                ctx.stroke(path, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: width, dash: [3, 3]))
            }
        }

        // Vinyl weeding box and lines.
        let weeding = model.weedingCuts
        if !weeding.isEmpty {
            var weed = Path()
            for p in weeding.allPaths {
                guard let f = p.first else { continue }
                weed.move(to: vp.toView(f))
                for q in p.dropFirst() { weed.addLine(to: vp.toView(q)) }
            }
            ctx.stroke(weed, with: .color(.secondary), style: StrokeStyle(lineWidth: 0.8, dash: [5, 3]))
        }

        // Toolpath preview.
        if model.showToolpath {
            var travel = Path()
            for (a, b) in model.toolpath.travelMoves {
                travel.move(to: vp.toView(a))
                travel.addLine(to: vp.toView(b))
            }
            ctx.stroke(travel, with: .color(.red.opacity(0.7)), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3]))
            for l in model.toolpath.layers where l.layer.mode == .fill {
                var rows = Path()
                for p in l.paths {
                    guard let f = p.first else { continue }
                    rows.move(to: vp.toView(f))
                    for q in p.dropFirst() { rows.addLine(to: vp.toView(q)) }
                }
                ctx.stroke(rows, with: .color(Color(hex: l.layer.colorHex).opacity(0.6)), lineWidth: 0.5)
            }
            for l in model.toolpath.layers where l.layer.mode == .mill {
                let color = Color(hex: l.layer.colorHex)
                let width = max(0.5, l.layer.toolDiameter * vp.zoom)
                for (i, p) in l.paths.enumerated() {
                    guard let f = p.first else { continue }
                    let cut = l.cut(at: i)
                    if cut == .drill || p.count == 1 {
                        let c = vp.toView(f), rr = max(3, width / 2)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), with: .color(color), lineWidth: 1)
                        continue
                    }
                    var line = Path()
                    line.move(to: vp.toView(f))
                    for q in p.dropFirst() { line.addLine(to: vp.toView(q)) }
                    // Tool-width band underneath, centre line on top.
                    ctx.stroke(line, with: .color(color.opacity(cut == .pocketClear ? 0.12 : 0.18)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    ctx.stroke(line, with: .color(color.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 0.6, dash: cut == .pocketClear ? [2, 2] : []))
                }
            }
        }

        // Holding tabs.
        let marks = model.tabMarks
        if !marks.isEmpty {
            let editing = model.tool == .tabs
            for m in marks {
                let half = max(3 / vp.zoom, m.length / 2)
                let a = vp.toView(m.point - m.direction * half), b = vp.toView(m.point + m.direction * half)
                var bar = Path()
                bar.move(to: a)
                bar.addLine(to: b)
                let selected = editing && model.selectedTab == m
                if editing {
                    ctx.stroke(bar, with: .color(.white), style: StrokeStyle(lineWidth: selected ? 9 : 7, lineCap: .round))
                }
                // Hand-placed tabs are solid; automatic ones lighter.
                let color = Color.orange.opacity(m.manualIndex == nil ? 0.65 : 1)
                ctx.stroke(bar, with: .color(selected ? .accentColor : color),
                           style: StrokeStyle(lineWidth: editing ? (selected ? 6 : 4.5) : 3.5, lineCap: .round))
            }
        }

        // Job zero point.
        if let z = model.jobZeroPoint {
            let c = vp.toView(z)
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - 10, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 10, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - 10)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 10))
            ctx.stroke(cross, with: .color(.green), lineWidth: 1.5)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.green), lineWidth: 1.5)
            ctx.draw(Text("X0 Y0").font(.caption2).foregroundColor(.green), at: CGPoint(x: c.x + 7, y: c.y + 7), anchor: .topLeading)
        }

        // Selection box.
        let sb = model.selectionBounds
        if !sb.isEmpty {
            let r = CGRect(origin: vp.toView(sb.origin), size: CGSize(width: sb.width * vp.zoom, height: sb.height * vp.zoom)).insetBy(dx: -4, dy: -4)
            ctx.stroke(Path(r), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            if model.tool == .select, case let (shape, pt)? = selectedPathText {
                // The guide path and a diamond at the start of the text.
                var guide = Path()
                for (i, q) in pt.guide.enumerated() {
                    let v = vp.toView(shape.transform.apply(q))
                    if i == 0 { guide.move(to: v) } else { guide.addLine(to: v) }
                }
                ctx.stroke(guide, with: .color(.accentColor.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                if let start = PathText.point(on: pt, at: pt.offset) {
                    let c = vp.toView(shape.transform.apply(start))
                    var d = Path()
                    d.move(to: CGPoint(x: c.x, y: c.y - 7))
                    d.addLine(to: CGPoint(x: c.x + 7, y: c.y))
                    d.addLine(to: CGPoint(x: c.x, y: c.y + 7))
                    d.addLine(to: CGPoint(x: c.x - 7, y: c.y))
                    d.closeSubpath()
                    ctx.fill(d, with: .color(.accentColor))
                    ctx.stroke(d, with: .color(.white), lineWidth: 1)
                }
            }
            if model.tool == .select {
                for f in handleFractions {
                    let c = CGPoint(x: r.minX + r.width * f.x, y: r.minY + r.height * f.y)
                    let h = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                    ctx.fill(Path(h), with: .color(Color(nsColor: .textBackgroundColor)))
                    ctx.stroke(Path(h), with: .color(.accentColor), lineWidth: 1.2)
                }
                let top = CGPoint(x: r.midX, y: r.minY)
                let knob = CGPoint(x: r.midX, y: r.minY - rotateHandleOffset)
                var stem = Path()
                stem.move(to: top)
                stem.addLine(to: knob)
                ctx.stroke(stem, with: .color(.accentColor), lineWidth: 1)
                let kr = CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10)
                ctx.fill(Path(ellipseIn: kr), with: .color(Color(nsColor: .textBackgroundColor)))
                ctx.stroke(Path(ellipseIn: kr), with: .color(.accentColor), lineWidth: 1.2)
            }
        }

        // Nodes of the shape being edited.
        if model.tool == .node, let shape = model.nodeEditableShape {
            let all = shape.paths.reduce(0) { $0 + $1.points.count }
            let size: CGFloat = all > 600 ? 3 : 6
            var boxes = Path()
            for poly in shape.paths {
                for q in poly.points {
                    let c = vp.toView(shape.transform.apply(q))
                    boxes.addRect(CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
                }
            }
            ctx.fill(boxes, with: .color(Color(nsColor: .textBackgroundColor)))
            ctx.stroke(boxes, with: .color(.accentColor), lineWidth: 1)
            if let ref = model.selectedNode, ref.shape == shape.id, ref.path < shape.paths.count,
               ref.point < shape.paths[ref.path].points.count {
                let c = vp.toView(shape.transform.apply(shape.paths[ref.path].points[ref.point]))
                ctx.fill(Path(CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.accentColor))
            }
        }

        // Measurement.
        var measuring: (Vec2, Vec2)?
        if case .measure(let a, let b) = dragMode { measuring = (a, b) } else if model.tool == .measure { measuring = lastMeasure }
        if case let (a, b)? = measuring, a != b {
            let pa = vp.toView(a), pb = vp.toView(b)
            var line = Path()
            line.move(to: pa)
            line.addLine(to: pb)
            ctx.stroke(line, with: .color(.pink), lineWidth: 1.5)
            for p in [pa, pb] { ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.pink), lineWidth: 1.5) }
            let d = b - a
            let u = model.units
            let angle = atan2(-d.y, d.x) * 180 / .pi
            let label = "\(u.format(d.length, digits: u == .mm ? 2 : 3)) \(u.title)   Δx \(u.format(abs(d.x))) Δy \(u.format(abs(d.y)))   \(String(format: "%.1f°", angle))"
            let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2 - 8)
            let text = ctx.resolve(Text(label).font(.caption.monospacedDigit()).foregroundColor(.white))
            let sz = text.measure(in: CGSize(width: 600, height: 40))
            let bg = CGRect(x: mid.x - sz.width / 2 - 5, y: mid.y - sz.height - 2, width: sz.width + 10, height: sz.height + 4)
            ctx.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(.pink.opacity(0.9)))
            ctx.draw(text, at: CGPoint(x: mid.x, y: mid.y), anchor: .bottom)
        }

        // In-progress drag feedback.
        switch dragMode {
        case .marquee(let s, let c):
            let r = viewRect(s, c)
            ctx.fill(Path(r), with: .color(.accentColor.opacity(0.08)))
            ctx.stroke(Path(r), with: .color(.accentColor), lineWidth: 1)
        case .create(let s, let c):
            let preview = previewShape(from: s, to: c)
            ctx.stroke(viewPath(preview), with: .color(.accentColor), lineWidth: 1.2)
            let pb = preview.bounds
            if !pb.isEmpty { sizeTag(&ctx, bounds: pb, extra: nil) }
        case .scale(_, let start, _, true):
            let b = model.selectionBounds
            let pct = start.width > 1e-9 && start.height > 1e-9
                ? String(format: "%.0f%% × %.0f%%", b.width / start.width * 100, b.height / start.height * 100) : nil
            sizeTag(&ctx, bounds: b, extra: pct)
        case .rotate(_, _, _, true):
            sizeTag(&ctx, bounds: model.selectionBounds, extra: nil)
        case .freehand(let samples):
            if model.tool == .brush {
                let outline = model.brushOutline(samples, zoom: vp.zoom, clean: false)
                let color = model.currentLayerColor
                ctx.fill(viewPath(outline), with: .color(color.opacity(0.35)), style: FillStyle(eoFill: outline.count == 2))
                ctx.stroke(viewPath(outline), with: .color(color), lineWidth: 1)
            } else {
                ctx.stroke(viewPath([Polyline(samples.map(\.point))]), with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        case .erase(let trail):
            let width = max(2, model.freehand.eraserSize * vp.zoom)
            ctx.stroke(viewPath([Polyline(trail)]), with: .color(.gray.opacity(0.3)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            if let last = trail.last {
                let c = vp.toView(last)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - width / 2, y: c.y - width / 2, width: width, height: width)),
                           with: .color(.secondary), lineWidth: 1)
            }
        case .move(_, true):
            let b = model.selectionBounds
            let u = model.units
            sizeTag(&ctx, bounds: b, extra: "at \(u.format(b.minX)), \(u.format(b.minY))")
        default:
            break
        }

        drawRulers(&ctx, size: size)
    }

    /// A small label under the box showing its width and height while it is drawn, sized, rotated or moved.
    private func sizeTag(_ ctx: inout GraphicsContext, bounds b: Rect2, extra: String?) {
        guard !b.isEmpty else { return }
        let u = model.units
        var label = "\(u.format(b.width)) × \(u.format(b.height)) \(u.title)"
        if let extra { label += "   " + extra }
        let text = ctx.resolve(Text(label).font(.caption.monospacedDigit()).foregroundColor(.white))
        let sz = text.measure(in: CGSize(width: 600, height: 40))
        let below = viewport.toView(Vec2(b.center.x, b.maxY))
        var center = CGPoint(x: below.x, y: below.y + 14 + sz.height / 2)
        // Keep it on screen.
        let vs = viewport.viewSize
        if center.y + sz.height > vs.height - 30 { center.y = viewport.toView(Vec2(b.center.x, b.minY)).y - 30 - sz.height / 2 }
        center.x = min(max(center.x, sz.width / 2 + 26), max(sz.width / 2 + 26, vs.width - sz.width / 2 - 8))
        let bg = CGRect(x: center.x - sz.width / 2 - 6, y: center.y - sz.height / 2 - 3, width: sz.width + 12, height: sz.height + 6)
        ctx.fill(Path(roundedRect: bg, cornerRadius: 5), with: .color(Color.black.opacity(0.75)))
        ctx.draw(text, at: center)
    }

    /// Rulers along the top and left edges, in the chosen units, measured from the bed's top-left.
    private func drawRulers(_ ctx: inout GraphicsContext, size: CGSize) {
        let vp = viewport
        let thick: CGFloat = 18
        let unit = model.units.mmPerUnit
        let pxPerUnit = vp.zoom * unit
        // Labelled step: the smallest "nice" step at least 50 px apart.
        let nice: [Double] = model.units == .mm ? [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000] : [0.125, 0.25, 0.5, 1, 2, 4, 6, 12, 24, 48]
        let step = nice.first { $0 * pxPerUnit >= 50 } ?? nice.last!
        let subdivisions = model.units == .mm ? (step >= 10 ? 10.0 : 5.0) : 4.0
        let bg = Color(nsColor: .windowBackgroundColor).opacity(0.95)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: thick)), with: .color(bg))
        ctx.fill(Path(CGRect(x: 0, y: 0, width: thick, height: size.height)), with: .color(bg))
        var ticks = Path()
        let minorStep = step / subdivisions

        // Top ruler.
        let firstX = (vp.toDoc(CGPoint(x: thick, y: 0)).x / unit / minorStep).rounded(.down) * minorStep
        var u = firstX
        while true {
            let x = vp.toView(Vec2(u * unit, 0)).x
            if x > size.width { break }
            if x >= thick {
                let isLabel = abs((u / step) - (u / step).rounded()) < 1e-6
                ticks.move(to: CGPoint(x: x, y: thick))
                ticks.addLine(to: CGPoint(x: x, y: thick - (isLabel ? thick * 0.75 : thick * 0.3)))
                if isLabel {
                    ctx.draw(Text(rulerLabel(u)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary),
                             at: CGPoint(x: x + 2, y: 1), anchor: .topLeading)
                }
            }
            u += minorStep
        }
        // Left ruler.
        let firstY = (vp.toDoc(CGPoint(x: 0, y: thick)).y / unit / minorStep).rounded(.down) * minorStep
        u = firstY
        while true {
            let y = vp.toView(Vec2(0, u * unit)).y
            if y > size.height { break }
            if y >= thick {
                let isLabel = abs((u / step) - (u / step).rounded()) < 1e-6
                ticks.move(to: CGPoint(x: thick, y: y))
                ticks.addLine(to: CGPoint(x: thick - (isLabel ? thick * 0.75 : thick * 0.3), y: y))
                if isLabel {
                    var label = ctx
                    label.translateBy(x: 1, y: y + 2)
                    label.rotate(by: .degrees(90))
                    label.draw(Text(rulerLabel(u)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary),
                               at: .zero, anchor: .bottomLeading)
                }
            }
            u += minorStep
        }
        ctx.stroke(ticks, with: .color(.secondary), lineWidth: 0.6)
        var edges = Path()
        edges.move(to: CGPoint(x: 0, y: thick)); edges.addLine(to: CGPoint(x: size.width, y: thick))
        edges.move(to: CGPoint(x: thick, y: 0)); edges.addLine(to: CGPoint(x: thick, y: size.height))
        ctx.stroke(edges, with: .color(.gray.opacity(0.5)), lineWidth: 1)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: thick, height: thick)), with: .color(bg))
        ctx.draw(Text(model.units.title).font(.system(size: 8)).foregroundColor(.secondary), at: CGPoint(x: thick / 2, y: thick / 2))
    }

    private func rulerLabel(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        return r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
    }

    /// Draws a shape's style parts in their layers' colours, under the shape's outline.
    private func drawStyle(_ style: ArtworkStyle, of shape: Artwork, path: Path, in ctx: inout GraphicsContext, vp: Viewport) {
        for part in style.enabledParts {
            guard let layer = model.document.layer(part.layerID) else { continue }
            let color = Color(hex: layer.colorHex).opacity(layer.enabled ? 1 : 0.3)
            switch part.kind {
            case .fill:
                let closed = viewPath(shape.placedStyledPaths.filter { $0.closed })
                ctx.fill(closed, with: .color(color.opacity(0.35)), style: FillStyle(eoFill: true))
            case .stroke:
                ctx.stroke(path, with: .color(color.opacity(0.6)),
                           style: StrokeStyle(lineWidth: max(1, part.amount * vp.zoom), lineCap: .round, lineJoin: .round))
            case .offset:
                let scale = max(1e-9, shape.transform.meanScale)
                let loops = StyleGeometry.cached(.offset, shape.styledPaths, part.amount / scale).transformed(shape.transform)
                ctx.stroke(viewPath(loops), with: .color(color), lineWidth: 1)
            }
        }
    }

    private func viewPath(_ polys: [Polyline]) -> Path {
        var path = Path()
        for poly in polys {
            guard let f = poly.points.first else { continue }
            path.move(to: viewport.toView(f))
            for p in poly.points.dropFirst() { path.addLine(to: viewport.toView(p)) }
            if poly.closed { path.closeSubpath() }
        }
        return path
    }

    private func viewRect(_ a: Vec2, _ b: Vec2) -> CGRect {
        let pa = viewport.toView(a), pb = viewport.toView(b)
        return CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
    }

    private func previewShape(from s: Vec2, to c: Vec2) -> [Polyline] {
        var end = c
        if NSEvent.modifierFlags.contains(.shift), model.tool != .line {
            let side = max(abs(c.x - s.x), abs(c.y - s.y))
            end = Vec2(s.x + (c.x >= s.x ? side : -side), s.y + (c.y >= s.y ? side : -side))
        }
        let r = Rect2(minX: min(s.x, end.x), minY: min(s.y, end.y), maxX: max(s.x, end.x), maxY: max(s.y, end.y))
        switch model.tool {
        case .rectangle:
            return [Polyline([Vec2(r.minX, r.minY), Vec2(r.maxX, r.minY), Vec2(r.maxX, r.maxY), Vec2(r.minX, r.maxY)], closed: true)]
        case .ellipse:
            guard r.width > 0, r.height > 0 else { return [] }
            return [Flatten.ellipse(center: r.center, rx: r.width / 2, ry: r.height / 2, step: 0.2)]
        case .line:
            return [Polyline([s, c])]
        case .shape:
            return ShapeLibrary.make(model.shapeKind, in: r, options: model.shapeOptions)
        default:
            return []
        }
    }

    // MARK: - Sizing and rotate handles

    /// The selected shape when it is a single piece of text on a path.
    private var selectedPathText: (Artwork, PathTextSpec)? {
        guard model.selection.count == 1, let shape = model.selectedShapes.first, let pt = shape.pathText else { return nil }
        return (shape, pt)
    }

    /// Starts a handle drag when the press lands on a sizing or rotate handle of the selection.
    private func handleDrag(at viewPoint: CGPoint, docStart: Vec2) -> DragMode? {
        let sb = model.selectionBounds
        guard !sb.isEmpty else { return nil }
        let vp = viewport
        if case let (shape, pt)? = selectedPathText, let start = PathText.point(on: pt, at: pt.offset) {
            let c = vp.toView(shape.transform.apply(start))
            if hypot(c.x - viewPoint.x, c.y - viewPoint.y) <= 9 { return .slideText(id: shape.id, moved: false) }
        }
        let r = CGRect(origin: vp.toView(sb.origin), size: CGSize(width: sb.width * vp.zoom, height: sb.height * vp.zoom)).insetBy(dx: -4, dy: -4)
        func near(_ c: CGPoint, _ radius: CGFloat) -> Bool { hypot(c.x - viewPoint.x, c.y - viewPoint.y) <= radius }
        let base = Dictionary(uniqueKeysWithValues: model.selectedShapes.map { ($0.id, $0.transform) })
        if near(CGPoint(x: r.midX, y: r.minY - rotateHandleOffset), 8) {
            let c = sb.center
            return .rotate(center: c, startAngle: atan2(docStart.y - c.y, docStart.x - c.x), base: base, moved: false)
        }
        for f in handleFractions where near(CGPoint(x: r.minX + r.width * f.x, y: r.minY + r.height * f.y), 7) {
            // A flat selection (a horizontal or vertical line) can only be sized along its length.
            if sb.width < 1e-6, f.x != 0.5 { continue }
            if sb.height < 1e-6, f.y != 0.5 { continue }
            return .scale(handle: f, startBounds: sb, base: base, moved: false)
        }
        return nil
    }

    /// Scales about the handle's opposite side so it follows the pointer. Shift keeps proportions.
    private func scaleTransform(handle f: Vec2, bounds b: Rect2, to p: Vec2, uniform: Bool) -> Affine {
        let anchor = Vec2(b.minX + b.width * (1 - f.x), b.minY + b.height * (1 - f.y))
        let grabbed = Vec2(b.minX + b.width * f.x, b.minY + b.height * f.y)
        func ratio(_ now: Double, _ was: Double, _ a: Double) -> Double {
            let d = was - a
            guard abs(d) > 1e-9 else { return 1 }
            let s = (now - a) / d
            return abs(s) < 0.01 ? (s < 0 ? -0.01 : 0.01) : s
        }
        var sx = f.x == 0.5 ? 1 : ratio(p.x, grabbed.x, anchor.x)
        var sy = f.y == 0.5 ? 1 : ratio(p.y, grabbed.y, anchor.y)
        if uniform {
            let s: Double
            if f.x == 0.5 { s = sy } else if f.y == 0.5 { s = sx } else { s = abs(sx) > abs(sy) ? sx : sy }
            sx = s
            sy = s
        }
        return Affine.translation(-anchor.x, -anchor.y).then(.scale(sx, sy)).then(.translation(anchor.x, anchor.y))
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                focused = true
                let doc = viewport.toDoc(value.location)
                switch dragMode {
                case .none:
                    let start = viewport.toDoc(value.startLocation)
                    if NSEvent.modifierFlags.contains(.option) || NSEvent.pressedMouseButtons & 0b100 != 0 {
                        dragMode = .pan(lastView: value.location)
                        return
                    }
                    switch model.tool {
                    case .measure:
                        dragMode = .measure(start: start, current: doc)
                    case .node:
                        let tolerance = 6 / viewport.zoom
                        if let ref = model.nodeHit(at: start, tolerance: tolerance) {
                            if NSEvent.modifierFlags.contains(.option) {
                                model.deleteNode(ref)
                            } else {
                                model.selectedNode = ref
                                dragMode = .node(ref: ref, moved: false)
                            }
                        } else if NSEvent.modifierFlags.contains(.option), model.insertNode(at: start, tolerance: tolerance) != nil {
                            // Added a node on the outline.
                        } else if let hit = model.hitTest(start, tolerance: 4 / viewport.zoom) {
                            model.selection = [hit]
                        } else {
                            model.selection = []
                        }
                    case .tabs:
                        let tolerance = 6 / viewport.zoom
                        if let mark = model.tabHit(at: start, tolerance: tolerance) {
                            if NSEvent.modifierFlags.contains(.command) {
                                model.removeTab(mark)
                                model.selectedTab = nil
                            } else {
                                model.selectedTab = mark
                                model.selection = [mark.shapeID]
                                dragMode = .tab(mark: mark, index: mark.manualIndex, moved: false)
                            }
                        } else if model.addTab(at: start, tolerance: 4 / viewport.zoom) {
                            model.selectedTab = nil
                        } else {
                            model.selection = []
                            model.selectedTab = nil
                        }
                    case .rectangle, .ellipse, .line, .shape:
                        dragMode = .create(start: start, current: doc)
                    case .pen, .brush:
                        let t = value.time.timeIntervalSinceReferenceDate
                        dragMode = .freehand(samples: [StrokeSample(start, pressure: currentPressure, time: t)])
                    case .eraser:
                        dragMode = .erase(trail: [start])
                    case .text:
                        break
                    case .select:
                        if let mode = handleDrag(at: value.startLocation, docStart: start) {
                            dragMode = mode
                            return
                        }
                        let tolerance = 4 / viewport.zoom
                        if let hit = model.hitTest(start, tolerance: tolerance) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                if model.selection.contains(hit) { model.selection.remove(hit) } else { model.selection.insert(hit) }
                            } else if !model.selection.contains(hit) {
                                model.selection = [hit]
                            }
                            dragMode = .move(last: start, moved: false)
                        } else {
                            dragMode = .marquee(start: start, current: doc)
                        }
                    }
                case .move(let last, let moved):
                    let d = doc - last
                    guard d.length > 0 else { return }
                    if !moved { model.checkpoint() }
                    model.moveSelection(by: d, recordUndo: false)
                    dragMode = .move(last: doc, moved: true)
                case .scale(let handle, let b, let base, let moved):
                    if !moved { model.checkpoint() }
                    model.applyTransform(scaleTransform(handle: handle, bounds: b, to: doc,
                                                        uniform: NSEvent.modifierFlags.contains(.shift)), toBase: base)
                    dragMode = .scale(handle: handle, startBounds: b, base: base, moved: true)
                case .node(let ref, let moved):
                    model.moveNode(ref, to: doc, recordUndo: !moved)
                    dragMode = .node(ref: ref, moved: true)
                case .tab(let mark, let index, let moved):
                    let k = model.moveTab(mark, index: index, to: doc, recordUndo: !moved)
                    dragMode = .tab(mark: mark, index: k, moved: true)
                case .measure(let a, _):
                    var end = doc
                    if NSEvent.modifierFlags.contains(.shift) {
                        // Snap to 45° steps.
                        let d = doc - a, ang = (atan2(d.y, d.x) / (.pi / 4)).rounded() * (.pi / 4)
                        end = a + Vec2(cos(ang), sin(ang)) * d.length
                    }
                    dragMode = .measure(start: a, current: end)
                case .slideText(let id, let moved):
                    guard let shape = model.document.shapes.first(where: { $0.id == id }), var pt = shape.pathText else { return }
                    let local = shape.transform.inverted.apply(doc)
                    pt.offset = PathText.nearestOffset(on: pt, to: local)
                    model.updatePathText(id, to: pt, recordUndo: !moved)
                    dragMode = .slideText(id: id, moved: true)
                case .rotate(let c, let a0, let base, let moved):
                    if !moved { model.checkpoint() }
                    var angle = atan2(doc.y - c.y, doc.x - c.x) - a0
                    if NSEvent.modifierFlags.contains(.shift) {
                        let snap = Double.pi / 12
                        angle = (angle / snap).rounded() * snap
                    }
                    let t = Affine.translation(-c.x, -c.y).then(.rotation(angle)).then(.translation(c.x, c.y))
                    model.applyTransform(t, toBase: base)
                    dragMode = .rotate(center: c, startAngle: a0, base: base, moved: true)
                case .marquee(let s, _):
                    dragMode = .marquee(start: s, current: doc)
                case .create(let s, _):
                    dragMode = .create(start: s, current: doc)
                case .freehand(var samples):
                    // Skip readings closer than half a screen point; they only add noise.
                    guard let last = samples.last, last.point.distance(to: doc) * viewport.zoom >= 0.5 else { return }
                    samples.append(StrokeSample(doc, pressure: currentPressure, time: value.time.timeIntervalSinceReferenceDate))
                    dragMode = .freehand(samples: samples)
                case .erase(var trail):
                    guard let last = trail.last, last.distance(to: doc) * viewport.zoom >= 1 else { return }
                    trail.append(doc)
                    dragMode = .erase(trail: trail)
                case .pan(let lastView):
                    viewport.pan.x += value.location.x - lastView.x
                    viewport.pan.y += value.location.y - lastView.y
                    dragMode = .pan(lastView: value.location)
                }
            }
            .onEnded { value in
                let doc = viewport.toDoc(value.location)
                switch dragMode {
                case .marquee(let s, _):
                    let r = Rect2(minX: min(s.x, doc.x), minY: min(s.y, doc.y), maxX: max(s.x, doc.x), maxY: max(s.y, doc.y))
                    let hits = Set(model.document.shapes.filter { r.width > 0.01 && r.contains($0.bounds) }.map(\.id))
                    if NSEvent.modifierFlags.contains(.shift) {
                        model.selection.formUnion(hits)
                    } else {
                        model.selection = hits
                    }
                case .create(let s, _):
                    let shape = previewShape(from: s, to: doc)
                    let b = shape.bounds
                    if max(b.width, b.height) > 0.5 {
                        model.addShape(paths: shape, name: model.tool == .shape ? model.shapeKind.title : model.tool.title)
                    }
                case .measure(let a, let b):
                    lastMeasure = (a, b)
                case .freehand(var samples):
                    if let last = samples.last, last.point != doc {
                        samples.append(StrokeSample(doc, pressure: last.pressure, time: value.time.timeIntervalSinceReferenceDate))
                    }
                    if model.tool == .brush {
                        model.addBrushStroke(samples, zoom: viewport.zoom)
                    } else {
                        model.addPenStroke(samples.map(\.point), zoom: viewport.zoom)
                    }
                case .erase(var trail):
                    if trail.last != doc { trail.append(doc) }
                    model.erase(trail: trail)
                case .tab(let mark, let index, true):
                    // Keep the moved tab picked, at its new place.
                    model.selectedTab = model.tabMarks.first { $0.shapeID == mark.shapeID && $0.manualIndex == index }
                case .none where model.tool == .text:
                    // Clicking existing text selects it for editing in the toolbar; elsewhere adds new text.
                    if let hit = model.hitTest(doc, tolerance: 4 / viewport.zoom),
                       model.document.shapes.first(where: { $0.id == hit })?.text != nil {
                        model.selection = [hit]
                    } else {
                        model.addText(at: doc)
                    }
                default:
                    break
                }
                dragMode = .none
            }
    }

    /// Pen pressure of the event being handled (a tablet or Force Touch trackpad), 1 for a mouse.
    private var currentPressure: Double {
        guard let e = NSApp.currentEvent else { return 1 }
        switch e.type {
        case .leftMouseDown, .leftMouseDragged, .tabletPoint, .pressure:
            let p = Double(e.pressure)
            return p > 0 ? p : 1
        default:
            return 1
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = magnifyBase ?? viewport.zoom
                if magnifyBase == nil { magnifyBase = base }
                let target = base * value.magnification
                viewport.zoom(by: target / viewport.zoom, around: value.startLocation)
            }
            .onEnded { _ in magnifyBase = nil }
    }

    /// Two-finger scroll pans; Command-scroll or a mouse wheel with Command zooms.
    @MainActor
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let vp = viewport
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window, let content = window.contentView else { return event }
            let loc = event.locationInWindow
            let p = CGPoint(x: loc.x, y: content.bounds.height - loc.y)
            let precise = event.hasPreciseScrollingDeltas
            let command = event.modifierFlags.contains(.command)
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let handled = MainActor.assumeIsolated { () -> Bool in
                // Only scrolls aimed at the canvas itself: not other windows, and not while a sheet covers it.
                guard let canvasWindow = vp.window, window === canvasWindow, canvasWindow.attachedSheet == nil else { return false }
                let frame = vp.frameInWindow
                guard frame.contains(p) else { return false }
                let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
                if command || !precise {
                    vp.zoom(by: exp(precise ? dy / 100 : dy / 10), around: local)
                } else {
                    vp.pan.x += dx
                    vp.pan.y += dy
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func fitBed() {
        let p = model.profile
        viewport.fit(Rect2(minX: 0, minY: 0, maxX: p.bedWidth, maxY: p.bedHeight))
    }

    // MARK: - Overlays

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { viewport.zoom(by: 1 / 1.25, around: CGPoint(x: viewport.viewSize.width / 2, y: viewport.viewSize.height / 2)) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            Button { viewport.zoom(by: 1.25, around: CGPoint(x: viewport.viewSize.width / 2, y: viewport.viewSize.height / 2)) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            Button { fitBed() } label: { Image(systemName: "rectangle.dashed") }
                .help("Fit bed")
            Button {
                let b = model.document.bounds
                if !b.isEmpty { viewport.fit(b.insetBy(-5)) }
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Zoom to artwork")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(10)
    }

    private var statusBar: some View {
        let sb = model.selectionBounds
        let text: String
        if sb.isEmpty {
            text = "\(model.document.shapes.count) shapes · \(Int(model.profile.bedWidth))×\(Int(model.profile.bedHeight)) mm bed"
                + (model.document.workpiece.map { String(format: " · workpiece %.0f×%.0f mm", $0.width, $0.height) } ?? "")
                + (model.shapesOutsideWorkpiece > 0 ? " · \(model.shapesOutsideWorkpiece) outside workpiece" : "")
        } else {
            let u = model.units
            text = "Selection \(u.format(sb.width)) × \(u.format(sb.height)) \(u.title) at \(u.format(sb.minX)), \(u.format(sb.minY))"
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
    }
}

/// Reports the window that hosts a SwiftUI view.
private struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
