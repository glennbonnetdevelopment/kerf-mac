import KerfCore
import SwiftUI

/// Drawing tools above the canvas: select and basic shapes, the shapes library, text, and text around a shape.
struct EditorToolbar: View {
    @EnvironmentObject var model: AppModel
    @State private var fonts: [String] = []
    @State private var showShapes = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach([Tool.select, .rectangle, .ellipse, .line]) { t in
                toolButton(t.symbol, help: t.title, active: model.tool == t) { model.tool = t }
            }
            Divider().frame(height: 22)

            toolButton(model.shapeKind.symbol, help: "Shapes: \(model.shapeKind.title)", active: model.tool == .shape) {
                model.tool = .shape
                showShapes = true
            }
            .popover(isPresented: $showShapes, arrowEdge: .bottom) { shapesPopover }

            Divider().frame(height: 22)

            toolButton("textformat", help: "Text: click the canvas to add, or click text to edit it", active: model.tool == .text) {
                model.tool = .text
            }
            TextField(model.selectedText == nil ? "New text" : "Selected text", text: $model.textToAdd)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, idealWidth: 150, maxWidth: 220)
                .help(model.selectedText == nil ? "Text to add" : "Editing the selected text")
            Picker("Font", selection: $model.fontName) {
                if !fonts.contains(model.fontName) { Text(model.fontName).tag(model.fontName) }
                ForEach(fonts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            TextField("Height", value: $model.textHeight, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
                .help("Cap height in mm")
            Text("mm").font(.caption).foregroundStyle(.secondary)

            Divider().frame(height: 22)

            Button { model.addTextAlongSelection() } label: {
                Label("Text around shape", systemImage: "textformat.abc.dottedunderline")
            }
            .help("Lay the text along the selected shape's outline")
            .disabled(model.selection.count != 1 || model.selectedShapes.first?.text != nil)
            Toggle("Inside", isOn: $model.pathTextFlip)
                .toggleStyle(.checkbox)
                .help("Put the text inside the shape")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear {
            if fonts.isEmpty {
                var list = TextOutliner.availableFonts
                if !list.contains(model.fontName) { list.insert(model.fontName, at: 0) }
                fonts = list
            }
        }
    }

    private func toolButton(_ symbol: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 24)
                .background(active ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var shapesPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), spacing: 6) {
                ForEach(ShapeKind.allCases) { kind in
                    Button {
                        model.shapeKind = kind
                        model.tool = .shape
                    } label: {
                        Image(systemName: kind.symbol)
                            .frame(width: 32, height: 28)
                            .background(model.shapeKind == kind ? Color.accentColor.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(kind.title)
                }
            }
            Text(model.shapeKind.title).font(.headline)
            switch model.shapeKind {
            case .star, .burst:
                Stepper("Points: \(model.shapeOptions.points)", value: $model.shapeOptions.points, in: 3...40)
                if model.shapeKind == .star {
                    HStack {
                        Text("Inner size \(Int(model.shapeOptions.innerRatio * 100))%")
                        Slider(value: $model.shapeOptions.innerRatio, in: 0.1...0.9)
                    }
                }
            case .polygon:
                Stepper("Sides: \(model.shapeOptions.sides)", value: $model.shapeOptions.sides, in: 3...40)
            case .roundedRectangle:
                HStack {
                    Text("Corner radius (mm)")
                    TextField("", value: $model.shapeOptions.cornerRadius, format: .number).frame(width: 60)
                }
            case .gear:
                Stepper("Teeth: \(model.shapeOptions.teeth)", value: $model.shapeOptions.teeth, in: 4...80)
            default:
                EmptyView()
            }
            Text("Drag a box on the canvas. Hold Shift for equal width and height.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 260)
    }
}
