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
                    numberRow("X (mm)", b.minX) { model.setSelectionFrame(x: $0, keepAspect: keepAspect) }
                    numberRow("Y (mm)", b.minY) { model.setSelectionFrame(y: $0, keepAspect: keepAspect) }
                    numberRow("Width (mm)", b.width) { model.setSelectionFrame(width: $0, keepAspect: keepAspect) }
                    numberRow("Height (mm)", b.height) { model.setSelectionFrame(height: $0, keepAspect: keepAspect) }
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

            if model.selection.count == 1, let shape = model.selectedShapes.first, let spec = shape.text {
                Section("Edit text") {
                    TextField("Text", text: Binding(get: { spec.text }, set: { var n = spec; n.text = $0; model.updateText(shape.id, to: n) }))
                    Picker("Font", selection: Binding(get: { spec.fontName }, set: { var n = spec; n.fontName = $0; model.updateText(shape.id, to: n) })) {
                        if !fonts.contains(spec.fontName) { Text(spec.fontName).tag(spec.fontName) }
                        ForEach(fonts, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("Cap height (mm)") {
                        TextField("", value: Binding(get: { spec.height }, set: { var n = spec; n.height = max(0.5, $0); model.updateText(shape.id, to: n) }), format: .number)
                            .frame(width: 70)
                    }
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

            Section("Shapes") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(ShapeKind.allCases) { kind in
                        Button {
                            model.shapeKind = kind
                            model.tool = .shape
                        } label: {
                            Image(systemName: kind.symbol)
                                .frame(width: 30, height: 26)
                                .background(model.tool == .shape && model.shapeKind == kind ? Color.accentColor.opacity(0.25) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help(kind.title)
                    }
                }
                switch model.shapeKind {
                case .star, .burst:
                    Stepper("Points: \(model.shapeOptions.points)", value: $model.shapeOptions.points, in: 3...40)
                    if model.shapeKind == .star {
                        LabeledContent("Inner size \(Int(model.shapeOptions.innerRatio * 100))%") {
                            Slider(value: $model.shapeOptions.innerRatio, in: 0.1...0.9).frame(width: 150)
                        }
                    }
                case .polygon:
                    Stepper("Sides: \(model.shapeOptions.sides)", value: $model.shapeOptions.sides, in: 3...40)
                case .roundedRectangle:
                    LabeledContent("Corner radius (mm)") {
                        TextField("", value: $model.shapeOptions.cornerRadius, format: .number).frame(width: 70)
                    }
                case .gear:
                    Stepper("Teeth: \(model.shapeOptions.teeth)", value: $model.shapeOptions.teeth, in: 4...80)
                default:
                    EmptyView()
                }
                Text("Pick a shape, then drag a box on the canvas. Hold Shift for equal width and height.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text tool") {
                TextField("Text", text: $model.textToAdd)
                Picker("Font", selection: $model.fontName) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Cap height (mm)") {
                    TextField("", value: $model.textHeight, format: .number).frame(width: 70)
                }
                Text("Choose the text tool, then click the canvas to place outlined text. Select placed text to edit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text around a shape") {
                Toggle("Inside the shape", isOn: $model.pathTextFlip)
                Button("Put text around selected shape") { model.addTextAlongSelection() }
                    .disabled(model.selection.count != 1 || model.selectedShapes.first?.pathText != nil)
                Text("Uses the text, font and height above. The letters bend to follow the outline. Drag the diamond on the canvas to slide the text along the path.")
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
            TextField("", value: Binding(get: { (value * 100).rounded() / 100 }, set: { apply($0) }), format: .number)
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
