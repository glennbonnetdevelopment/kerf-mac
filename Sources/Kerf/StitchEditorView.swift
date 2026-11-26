import KerfCore
import SwiftUI

/// Shows the stitch editor for the shape picked in the model, starting afresh when another shape is picked.
struct StitchEditorHost: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let id = model.stitchEditorShapeID, model.shape(id) != nil {
            StitchEditorView(shapeID: id)
                .id(id)
        } else {
            Text("Select a shape and choose Edit stitches… in Arrange > Embroidery.")
                .foregroundStyle(.secondary)
                .frame(minWidth: 480, minHeight: 300)
        }
    }
}

/// Hand editing of one shape's stitches: move, add and delete needle points, split runs, and save the result to
/// the shape so it is sewn exactly as edited.
struct StitchEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let shapeID: UUID

    enum EditTool: String, CaseIterable, Identifiable {
        case move, add, delete
        var id: String { rawValue }
        var title: String {
            switch self {
            case .move: return "Move"
            case .add: return "Add"
            case .delete: return "Delete"
            }
        }
        var symbol: String {
            switch self {
            case .move: return "arrow.up.and.down.and.arrow.left.and.right"
            case .add: return "plus.circle"
            case .delete: return "minus.circle"
            }
        }
    }

    struct PointRef: Equatable {
        var run: Int
        var index: Int
    }

    /// Stitches on the bed (mm), one array per run sewn without a jump.
    @State private var runs: [[Vec2]] = []
    @State private var history: [[[Vec2]]] = []
    @State private var loaded = false
    @State private var edited = false
    @State private var selected: PointRef?
    @State private var tool: EditTool = .move
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var dragStart: (pan: CGSize, point: Vec2?)?
    @State private var pinchBase: Double?

    private var shape: Artwork? { model.shape(shapeID) }
    private var color: Color {
        guard let s = shape, let layer = model.document.layer(s.layerID) else { return .black }
        return Color(hex: layer.colorHex)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                GeometryReader { geo in
                    editorCanvas(size: geo.size)
                }
                Divider()
                sidebar.frame(width: 240)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .navigationTitle("Edit Stitches: \(shape?.name ?? "")")
        .onAppear(perform: load)
        .onDeleteCommand { deleteSelected() }
        .onMoveCommand { dir in
            let step = 0.1
            switch dir {
            case .left: nudge(Vec2(-step, 0))
            case .right: nudge(Vec2(step, 0))
            case .up: nudge(Vec2(0, -step))
            case .down: nudge(Vec2(0, step))
            default: break
            }
        }
    }

    // MARK: Layout

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $tool) {
                ForEach(EditTool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .help("Move: drag a point (drag empty space to pan). Add: click a stitch to put a point on it. Delete: click a point.")
            Button("Undo edit") { undoEdit() }
                .disabled(history.isEmpty)
            Spacer()
            Text("Zoom")
            Slider(value: $zoom, in: 0.5...30).frame(width: 160)
            Button("Fit") { zoom = 1; pan = .zero }
        }
        .padding(10)
    }

    private var sidebar: some View {
        let stats = statistics
        return Form {
            Section("Stitches") {
                LabeledContent("Stitches", value: "\(stats.count)")
                LabeledContent("Runs (jumps between)", value: "\(runs.count)")
                if stats.long > 0 {
                    Label("\(stats.long) longer than 7 mm (red)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if stats.tiny > 0 {
                    Label("\(stats.tiny) shorter than 0.3 mm (orange)", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            if let sel = selected, sel.run < runs.count, sel.index < runs[sel.run].count {
                Section("Selected point") {
                    coordinate("X (mm)", \.x, sel)
                    coordinate("Y (mm)", \.y, sel)
                    let run = runs[sel.run]
                    if sel.index > 0 {
                        LabeledContent("From previous", value: String(format: "%.2f mm", run[sel.index].distance(to: run[sel.index - 1])))
                    }
                    if sel.index + 1 < run.count {
                        LabeledContent("To next", value: String(format: "%.2f mm", run[sel.index].distance(to: run[sel.index + 1])))
                    }
                    Button("Delete point") { deleteSelected() }
                    Button("Split run here (trim and jump)") { splitAtSelected() }
                        .disabled(sel.index == 0 || sel.index >= run.count - 1)
                    if sel.run + 1 < runs.count {
                        Button("Join with next run") { joinWithNext(sel.run) }
                    }
                }
            }
            Section {
                Button("Re-digitize from settings") {
                    record()
                    runs = placed(model.editableStitchesFromSettings(shapeID))
                    selected = nil
                }
                .help("Throw away hand edits and start again from the shape's stitch settings")
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!edited && shape?.stitches != nil)
                }
                Text("Saved stitches are sewn exactly as they are. Discard them in Arrange to go back to automatic stitches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func coordinate(_ title: String, _ key: WritableKeyPath<Vec2, Double>, _ sel: PointRef) -> some View {
        LabeledContent(title) {
            TextField("", value: Binding(get: { runs[sel.run][sel.index][keyPath: key] },
                                         set: { v in
                                             record()
                                             runs[sel.run][sel.index][keyPath: key] = v
                                         }),
                      format: .number.precision(.fractionLength(0...2)))
                .frame(width: 80)
        }
    }

    // MARK: Canvas

    private struct ViewMap {
        var center: Vec2
        var scale: Double
        var mid: CGPoint
        func toView(_ p: Vec2) -> CGPoint {
            CGPoint(x: mid.x + (p.x - center.x) * scale, y: mid.y + (p.y - center.y) * scale)
        }
        func toDesign(_ q: CGPoint) -> Vec2 {
            Vec2((q.x - mid.x) / scale + center.x, (q.y - mid.y) / scale + center.y)
        }
    }

    private func viewMap(_ size: CGSize) -> ViewMap {
        var b = Rect2.empty
        for run in runs { for p in run { b.include(p) } }
        if let s = shape { b = b.union(s.bounds) }
        if b.isEmpty { b = Rect2(minX: 0, minY: 0, maxX: 10, maxY: 10) }
        let fit = min(size.width / max(1, b.width), size.height / max(1, b.height)) * 0.9
        return ViewMap(center: b.center, scale: fit * zoom,
                       mid: CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height))
    }

    private func editorCanvas(size: CGSize) -> some View {
        let map = viewMap(size)
        return Canvas { ctx, sz in
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(Color(white: 0.96)))
            // The outline being sewn.
            if let s = shape {
                var outline = Path()
                for poly in s.placedPaths {
                    let pts = poly.drawnPoints
                    guard let f = pts.first else { continue }
                    outline.move(to: map.toView(f))
                    for p in pts.dropFirst() { outline.addLine(to: map.toView(p)) }
                }
                ctx.stroke(outline, with: .color(.gray.opacity(0.5)), lineWidth: 0.8)
            }
            // Jumps between runs.
            var jumps = Path()
            for i in runs.indices.dropFirst() {
                if let a = runs[i - 1].last, let b = runs[i].first {
                    jumps.move(to: map.toView(a))
                    jumps.addLine(to: map.toView(b))
                }
            }
            ctx.stroke(jumps, with: .color(.gray), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            // Stitches, with long and tiny ones marked.
            var normal = Path(), long = Path(), tiny = Path()
            for run in runs {
                for i in run.indices.dropFirst() {
                    let d = run[i].distance(to: run[i - 1])
                    let a = map.toView(run[i - 1]), b = map.toView(run[i])
                    if d > 7 {
                        long.move(to: a); long.addLine(to: b)
                    } else if d < 0.3 {
                        tiny.move(to: a); tiny.addLine(to: b)
                    } else {
                        normal.move(to: a); normal.addLine(to: b)
                    }
                }
            }
            ctx.stroke(normal, with: .color(color), lineWidth: 1)
            ctx.stroke(long, with: .color(.red), lineWidth: 1.6)
            ctx.stroke(tiny, with: .color(.orange), lineWidth: 2)
            // Needle points, when there's room to see them.
            if map.scale > 4 {
                var dots = Path()
                for run in runs {
                    for p in run {
                        let q = map.toView(p)
                        dots.addEllipse(in: CGRect(x: q.x - 1.6, y: q.y - 1.6, width: 3.2, height: 3.2))
                    }
                }
                ctx.fill(dots, with: .color(.black.opacity(0.6)))
            }
            // Start of each run.
            for run in runs {
                if let f = run.first {
                    let q = map.toView(f)
                    ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8)), with: .color(.green), lineWidth: 1.2)
                }
            }
            if let sel = selected, sel.run < runs.count, sel.index < runs[sel.run].count {
                let q = map.toView(runs[sel.run][sel.index])
                ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(.red), lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in dragChanged(g, map: map) }
                .onEnded { g in dragEnded(g, map: map) }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in
                    if pinchBase == nil { pinchBase = zoom }
                    zoom = min(30, max(0.5, (pinchBase ?? zoom) * v.magnification))
                }
                .onEnded { _ in pinchBase = nil }
        )
    }

    // MARK: Interaction

    private func nearestPoint(to q: CGPoint, map: ViewMap, within px: Double = 7) -> PointRef? {
        var best: PointRef?
        var bestD = px
        for (r, run) in runs.enumerated() {
            for (i, p) in run.enumerated() {
                let v = map.toView(p)
                let d = hypot(v.x - q.x, v.y - q.y)
                if d <= bestD { bestD = d; best = PointRef(run: r, index: i) }
            }
        }
        return best
    }

    /// The stitch nearest a view point, and where on it (0…1).
    private func nearestStitch(to q: CGPoint, map: ViewMap, within px: Double = 8) -> (run: Int, index: Int, t: Double)? {
        var best: (Int, Int, Double)?
        var bestD = px
        for (r, run) in runs.enumerated() {
            for i in run.indices.dropFirst() {
                let a = map.toView(run[i - 1]), b = map.toView(run[i])
                let abx = b.x - a.x, aby = b.y - a.y
                let len2 = abx * abx + aby * aby
                let t = len2 > 0 ? max(0, min(1, ((q.x - a.x) * abx + (q.y - a.y) * aby) / len2)) : 0
                let d = hypot(a.x + abx * t - q.x, a.y + aby * t - q.y)
                if d <= bestD { bestD = d; best = (r, i, t) }
            }
        }
        return best
    }

    private func dragChanged(_ g: DragGesture.Value, map: ViewMap) {
        if dragStart == nil {
            switch tool {
            case .move:
                if let hit = nearestPoint(to: g.startLocation, map: map) {
                    selected = hit
                    record()
                    dragStart = (pan, runs[hit.run][hit.index])
                } else {
                    dragStart = (pan, nil)
                }
            case .add, .delete:
                dragStart = (pan, nil)
                return
            }
        }
        guard let start = dragStart, tool == .move else { return }
        if let origin = start.point, let sel = selected {
            runs[sel.run][sel.index] = origin + Vec2(g.translation.width / map.scale, g.translation.height / map.scale)
            edited = true
        } else {
            pan = CGSize(width: start.pan.width + g.translation.width, height: start.pan.height + g.translation.height)
        }
    }

    private func dragEnded(_ g: DragGesture.Value, map: ViewMap) {
        defer { dragStart = nil }
        let isClick = hypot(g.translation.width, g.translation.height) < 3
        switch tool {
        case .move:
            if isClick, dragStart?.point == nil { selected = nil }
        case .add:
            guard isClick, let hit = nearestStitch(to: g.location, map: map) else { return }
            record()
            let a = runs[hit.run][hit.index - 1], b = runs[hit.run][hit.index]
            runs[hit.run].insert(a + (b - a) * hit.t, at: hit.index)
            selected = PointRef(run: hit.run, index: hit.index)
            edited = true
        case .delete:
            guard isClick, let hit = nearestPoint(to: g.location, map: map) else { return }
            selected = hit
            deleteSelected()
        }
    }

    private func record() {
        history.append(runs)
        if history.count > 200 { history.removeFirst() }
    }

    private func undoEdit() {
        guard let last = history.popLast() else { return }
        runs = last
        selected = nil
        edited = true
    }

    private func nudge(_ d: Vec2) {
        guard let sel = selected, sel.run < runs.count, sel.index < runs[sel.run].count else { return }
        record()
        runs[sel.run][sel.index] = runs[sel.run][sel.index] + d
        edited = true
    }

    private func deleteSelected() {
        guard let sel = selected, sel.run < runs.count, sel.index < runs[sel.run].count else { return }
        record()
        runs[sel.run].remove(at: sel.index)
        if runs[sel.run].count < 2 { runs.remove(at: sel.run) }
        selected = nil
        edited = true
    }

    private func splitAtSelected() {
        guard let sel = selected, sel.run < runs.count, sel.index > 0, sel.index < runs[sel.run].count - 1 else { return }
        record()
        let run = runs[sel.run]
        runs[sel.run] = Array(run[...sel.index])
        runs.insert(Array(run[(sel.index + 1)...]), at: sel.run + 1)
        selected = nil
        edited = true
    }

    private func joinWithNext(_ r: Int) {
        guard r + 1 < runs.count else { return }
        record()
        runs[r] += runs[r + 1]
        runs.remove(at: r + 1)
        selected = nil
        edited = true
    }

    // MARK: Load and save

    private var statistics: (count: Int, long: Int, tiny: Int) {
        var count = 0, long = 0, tiny = 0
        for run in runs {
            count += run.count
            for i in run.indices.dropFirst() {
                let d = run[i].distance(to: run[i - 1])
                if d > 7 { long += 1 } else if d < 0.3 { tiny += 1 }
            }
        }
        return (count, long, tiny)
    }

    private func placed(_ local: [[Vec2]]) -> [[Vec2]] {
        guard let s = shape else { return local }
        return local.map { $0.map(s.transform.apply) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        runs = placed(model.editableStitches(shapeID))
    }

    private func save() {
        guard let s = shape else { return }
        let back = s.transform.inverted
        model.setEditedStitches(shapeID, runs.map { $0.map(back.apply) }.filter { $0.count >= 2 })
        edited = false
        dismiss()
    }
}
