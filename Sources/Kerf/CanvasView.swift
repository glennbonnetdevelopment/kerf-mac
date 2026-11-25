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
}

struct CanvasView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var viewport = Viewport()
    @State private var dragMode = DragMode.none
    @State private var scrollMonitor: Any?
    @State private var magnifyBase: Double?
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
            .onKeyPress(.delete) { model.deleteSelection(); return .handled }
            .onKeyPress(.deleteForward) { model.deleteSelection(); return .handled }
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
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .overlay(alignment: .bottomLeading) { statusBar }
        }
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let vp = viewport
        let profile = model.profile
        let bedRect = CGRect(origin: vp.toView(.zero),
                             size: CGSize(width: profile.bedWidth * vp.zoom, height: profile.bedHeight * vp.zoom))
        ctx.fill(Path(bedRect), with: .color(Color(nsColor: .textBackgroundColor)))

        // Grid every 10 mm (100 mm lines stronger).
        let gridStep = vp.zoom * 10 < 6 ? 50.0 : 10.0
        var minor = Path(), major = Path()
        var x = 0.0
        while x <= profile.bedWidth + 1e-6 {
            let a = vp.toView(Vec2(x, 0)), b = vp.toView(Vec2(x, profile.bedHeight))
            if Int(x.rounded()) % 100 == 0 { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
            x += gridStep
        }
        var y = 0.0
        while y <= profile.bedHeight + 1e-6 {
            let a = vp.toView(Vec2(0, y)), b = vp.toView(Vec2(profile.bedWidth, y))
            if Int(y.rounded()) % 100 == 0 { major.move(to: a); major.addLine(to: b) } else { minor.move(to: a); minor.addLine(to: b) }
            y += gridStep
        }
        ctx.stroke(minor, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(.gray.opacity(0.35)), lineWidth: 0.8)
        ctx.stroke(Path(bedRect), with: .color(.gray.opacity(0.6)), lineWidth: 1)

        // Machine origin marker.
        let originDoc = profile.fromMachine(.zero)
        let o = vp.toView(originDoc)
        ctx.fill(Path(ellipseIn: CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)), with: .color(.orange))

        // Shapes.
        for shape in model.document.shapes {
            guard let layer = model.document.layer(shape.layerID) else { continue }
            let path = viewPath(shape.placedPaths)
            let color = Color(hex: layer.colorHex).opacity(layer.enabled ? 1 : 0.3)
            if layer.mode == .fill {
                ctx.fill(path, with: .color(color.opacity(0.18)), style: FillStyle(eoFill: true))
            }
            ctx.stroke(path, with: .color(color), lineWidth: model.selection.contains(shape.id) ? 1.6 : 1)
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
        }

        // Selection box.
        let sb = model.selectionBounds
        if !sb.isEmpty {
            let r = CGRect(origin: vp.toView(sb.origin), size: CGSize(width: sb.width * vp.zoom, height: sb.height * vp.zoom)).insetBy(dx: -4, dy: -4)
            ctx.stroke(Path(r), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        }

        // In-progress drag feedback.
        switch dragMode {
        case .marquee(let s, let c):
            let r = viewRect(s, c)
            ctx.fill(Path(r), with: .color(.accentColor.opacity(0.08)))
            ctx.stroke(Path(r), with: .color(.accentColor), lineWidth: 1)
        case .create(let s, let c):
            ctx.stroke(viewPath(previewShape(from: s, to: c)), with: .color(.accentColor), lineWidth: 1.2)
        default:
            break
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
        default:
            return []
        }
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
                    case .rectangle, .ellipse, .line:
                        dragMode = .create(start: start, current: doc)
                    case .text:
                        break
                    case .select:
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
                case .marquee(let s, _):
                    dragMode = .marquee(start: s, current: doc)
                case .create(let s, _):
                    dragMode = .create(start: s, current: doc)
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
                        model.addShape(paths: shape, name: model.tool.title)
                    }
                case .none where model.tool == .text:
                    model.addText(at: doc)
                    model.tool = .select
                default:
                    break
                }
                dragMode = .none
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
        } else {
            text = String(format: "Selection %.1f × %.1f mm at %.1f, %.1f", sb.width, sb.height, sb.minX, sb.minY)
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
    }
}
