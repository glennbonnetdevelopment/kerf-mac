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

            Section("Text tool") {
                TextField("Text", text: $model.textToAdd)
                Picker("Font", selection: $model.fontName) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Cap height (mm)") {
                    TextField("", value: $model.textHeight, format: .number).frame(width: 70)
                }
                Text("Choose the text tool, then click the canvas to place outlined text.")
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
