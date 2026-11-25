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
                }
            }

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
                LabeledContent("Start offset (mm)") {
                    TextField("", value: $model.pathTextOffset, format: .number).frame(width: 70)
                }
                Toggle("Other side / reverse direction", isOn: $model.pathTextFlip)
                Button("Put text around selected shape") { model.addTextAlongSelection() }
                    .disabled(model.selection.count != 1)
                Text("Uses the text, font and height above, laid along the selected shape's outline.")
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
