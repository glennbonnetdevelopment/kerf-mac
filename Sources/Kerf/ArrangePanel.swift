import KerfCore
import SwiftUI

/// Position, size and transforms for the selection, plus text tool settings.
struct ArrangePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var keepAspect = true
    @State private var fonts: [String] = []

    var body: some View {
        Form {
            Section("Selection") {
                let b = model.selectionBounds
                if b.isEmpty {
                    Text("Nothing selected. Click a shape, or drag a box around shapes.")
                        .foregroundStyle(.secondary)
                } else {
                    numberRow("X (\(model.units.title))", b.minX) { model.setSelectionFrame(x: $0, keepAspect: keepAspect) }
                    numberRow("Y (\(model.units.title))", b.minY) { model.setSelectionFrame(y: $0, keepAspect: keepAspect) }
                    numberRow("Width (\(model.units.title))", b.width) { model.setSelectionFrame(width: $0, keepAspect: keepAspect) }
                    numberRow("Height (\(model.units.title))", b.height) { model.setSelectionFrame(height: $0, keepAspect: keepAspect) }
                    Toggle("Keep proportions", isOn: $keepAspect)
                    HStack {
                        Button { model.rotateSelection(degrees: -90) } label: { Image(systemName: "rotate.left") }
                            .help("Rotate 90° counter-clockwise")
                        Button { model.rotateSelection(degrees: 90) } label: { Image(systemName: "rotate.right") }
                            .help("Rotate 90° clockwise")
                        Button { model.mirrorSelection(horizontal: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                            .help("Mirror horizontally")
                        Button { model.mirrorSelection(horizontal: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                            .help("Mirror vertically")
                        Spacer()
                        Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                            .help("Duplicate")
                        Button(role: .destructive) { model.deleteSelection() } label: { Image(systemName: "trash") }
                            .help("Delete")
                    }
                    .buttonStyle(.borderless)
                    Button("Centre on bed") { model.centerSelectionOnBed() }
                }
            }

            if !model.styleTargets.isEmpty {
                ShapeStyleSection()
            }

            if model.selection.count == 1, let shape = model.selectedShapes.first, shape.text != nil, shape.pathText != nil {
                Section("Text on path") {
                    if let pt = shape.pathText {
                        let total = max(0.1, pt.length)
                        LabeledContent("Position on path") {
                            Slider(value: Binding(get: { pt.offset }, set: { var n = pt; n.offset = $0; model.updatePathText(shape.id, to: n) }),
                                   in: (pt.closed ? 0 : -total)...total)
                                .frame(width: 150)
                        }
                        LabeledContent("Gap from path (mm)") {
                            TextField("", value: Binding(get: { pt.gap }, set: { var n = pt; n.gap = $0; model.updatePathText(shape.id, to: n) }), format: .number)
                                .frame(width: 70)
                        }
                        Button("Move to other side of path") { model.flipPathText(shape.id) }
                    }
                }
            }

            if model.profile.kind == .cncRouter, !model.selection.isEmpty {
                Section("CNC cut type") {
                    Picker("Cut", selection: Binding(get: { model.selectionMillRole },
                                                     set: { model.setMillRole($0) })) {
                        Text("Layer default").tag(MillRole?.none)
                        ForEach(MillRole.allCases) { Text($0.title).tag(MillRole?.some($0)) }
                    }
                    Text("Part cuts outside the line so the piece keeps its size. Hole cuts inside. On the line follows it exactly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.tabsInUse, !model.selection.isEmpty {
                Section("Holding tabs") {
                    let mode = model.selectionTabMode
                    LabeledContent("Tabs", value: "\(model.selectionTabCount) · " + {
                        switch mode {
                        case .automatic: return "automatic"
                        case .manual: return "placed by hand"
                        case .none: return "none"
                        case .mixed: return "mixed"
                        }
                    }())
                    HStack {
                        Button("Automatic") { model.setSelectionTabsAutomatic() }
                            .disabled(mode == .automatic)
                        Button("No tabs") { model.setSelectionNoTabs() }
                            .disabled(mode == .none)
                        Button("Edit by hand") { model.tool = .tabs }
                    }
                    Text("Automatic tabs follow the layer's settings. With the Holding tabs tool, click an outline to add a tab, drag a tab to move it, and Command-click or press Delete to remove it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.selection.count == 1, let shape = model.selectedShapes.first, shape.image == nil {
                ShapeEmbroiderySection(shapeID: shape.id)
            }

            WorkpieceSection()

            Section("Combine") {
                HStack {
                    ForEach(AppModel.BooleanOp.allCases) { op in
                        Button(op.title) { model.combineSelection(op) }
                    }
                }
                .disabled(model.selection.count < 2)
                HStack {
                    Button("Join open paths") { model.joinSelectedPaths() }
                    Button("Break apart") { model.breakApartSelection() }
                }
                .disabled(model.selection.isEmpty)
                Text("Weld merges overlapping shapes into one outline. Subtract cuts the later shapes out of the first one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Nest") {
                LabeledContent("Spacing (mm)") {
                    TextField("", value: $model.nestSpacing, format: .number).frame(width: 70)
                }
                Toggle("Allow 90° rotation", isOn: $model.nestAllowRotation)
                Button(model.selection.isEmpty ? "Nest all shapes on the bed" : "Nest selected shapes") { model.nest() }
                Text("Packs shapes by their bounding boxes, tallest first, to save material.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Drawing tools") {
                Text("Shapes, text and text around a shape are on the toolbar above the canvas. Select text and type in the toolbar to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if fonts.isEmpty {
                var list = TextOutliner.availableFonts
                if !list.contains(model.fontName) { list.insert(model.fontName, at: 0) }
                fonts = list
            }
        }
    }

    private func numberRow(_ title: String, _ value: Double, apply: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            let k = model.units.mmPerUnit
            TextField("", value: Binding(get: { (value / k * 1000).rounded() / 1000 }, set: { apply($0 * k) }), format: .number)
                .frame(width: 90)
        }
    }
}

/// The material piece (CNC stock or cutter mat) shown on the canvas.
struct WorkpieceSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Workpiece") {
            Toggle("Show a workpiece on the bed", isOn: Binding(
                get: { model.document.workpiece != nil },
                set: { on in
                    if on {
                        let p = model.profile
                        let preset = p.kind == .vinylCutter ? Workpiece.presets[0] : Workpiece.presets[5]
                        var w = preset
                        w.width = min(w.width, p.bedWidth)
                        w.height = min(w.height, p.bedHeight)
                        model.setWorkpiece(w)
                    } else {
                        model.setWorkpiece(nil)
                    }
                }))
            if let w = model.document.workpiece {
                Menu("Size preset: \(w.name)") {
                    ForEach(Workpiece.presets, id: \.name) { preset in
                        Button(preset.name) {
                            var n = preset
                            n.x = w.x
                            n.y = w.y
                            model.setWorkpiece(n)
                        }
                    }
                }
                Picker("Kind", selection: field(\.kind)) {
                    ForEach(Workpiece.Kind.allCases) { Text($0.title).tag($0) }
                }
                number("Width (mm)", \.width)
                number("Height (mm)", \.height)
                if w.kind == .stock { number("Thickness (mm)", \.thickness) }
                number("Left edge X (mm)", \.x)
                number("Top edge Y (mm)", \.y)
                HStack {
                    Button("Move to bed origin") {
                        var n = w
                        let o = model.profile.fromMachine(.zero)
                        n.x = o.x <= model.profile.bedWidth / 2 ? 0 : model.profile.bedWidth - n.width
                        n.y = o.y <= model.profile.bedHeight / 2 ? 0 : model.profile.bedHeight - n.height
                        model.setWorkpiece(n)
                    }
                    Button("Fit to artwork") {
                        let b = model.document.shapes.filter { model.document.layer($0.layerID)?.mode != .print }
                            .reduce(Rect2.empty) { $0.union($1.bounds) }
                        guard !b.isEmpty else { return }
                        var n = w
                        let m = 5.0
                        n.x = b.minX - m
                        n.y = b.minY - m
                        n.width = b.width + 2 * m
                        n.height = b.height + 2 * m
                        model.setWorkpiece(n)
                    }
                }
                let outside = model.shapesOutsideWorkpiece
                if outside > 0 {
                    Label("\(outside) shape\(outside == 1 ? "" : "s") reach outside the workpiece", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Text("Nest and Centre use the workpiece instead of the whole bed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func field<T>(_ key: WritableKeyPath<Workpiece, T>) -> Binding<T> {
        Binding(get: { (model.document.workpiece ?? Workpiece(width: 1, height: 1))[keyPath: key] },
                set: { v in
                    guard var w = model.document.workpiece else { return }
                    w[keyPath: key] = v
                    model.setWorkpiece(w)
                })
    }

    private func number(_ title: String, _ key: WritableKeyPath<Workpiece, Double>) -> some View {
        LabeledContent(title) {
            TextField("", value: field(key), format: .number.precision(.fractionLength(0...2))).frame(width: 80)
        }
    }
}

/// Embroidery settings for one shape, and the way into the stitch editor.
private struct ShapeEmbroiderySection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let shapeID: UUID

    var body: some View {
        if let shape = model.shape(shapeID) {
            Section("Embroidery") {
                Toggle("Own stitch settings", isOn: Binding(get: { shape.embroidery != nil },
                                                            set: { model.setOwnEmbroidery(shapeID, $0) }))
                    .help("Sew this shape differently from the rest of its layer")
                if let binding = model.shapeEmbroideryBinding(shapeID) {
                    EmbroiderySettingsFields(settings: binding)
                }
                HStack {
                    Button("Edit stitches…") { model.stitchEditorShapeID = shapeID; openWindow(id: "stitch-editor") }
                    if shape.stitches != nil {
                        Button("Discard hand edits") { model.setEditedStitches(shapeID, nil) }
                    }
                }
                if shape.stitches != nil {
                    Text("This shape sews its hand-edited stitches. They move and scale with the shape, but changing its outline or settings won't update them until you discard the edits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
