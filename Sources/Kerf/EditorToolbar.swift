import KerfCore
import SwiftUI

/// Drawing tools above the canvas: select and basic shapes, the shapes library, text, and text around a shape.
struct EditorToolbar: View {
    @EnvironmentObject var model: AppModel
    @State private var fonts: [String] = []
    @State private var showShapes = false
    @State private var showCurve = false
    @State private var showContour = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach([Tool.select, .node, .measure, .rectangle, .ellipse, .line]) { t in
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

            Button { showCurve = true } label: { Label("Curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .help("Bend the selected text into an arch or a bowl")
                .disabled(curvableText == nil)
                .popover(isPresented: $showCurve, arrowEdge: .bottom) { curvePopover }

            Button { showContour = true } label: { Label("Contour cut", systemImage: "seal") }
                .help("Add a cut line around the artwork, a set distance out (print and cut)")
                .popover(isPresented: $showContour, arrowEdge: .bottom) { contourPopover }
            Divider().frame(height: 22)

            colorSwatches

            Spacer(minLength: 0)
            Picker("Units", selection: $model.units) {
                ForEach(DisplayUnits.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)
            .help("Units for the grid, rulers, measurements and sizes")
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

    /// The selected text, when it can be curved (text on a path follows its path instead).
    private var curvableText: Artwork? {
        guard model.selection.count == 1, let shape = model.selectedShapes.first, shape.text != nil, shape.pathText == nil else { return nil }
        return shape
    }

    private var curvePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Curve text").font(.headline)
            if let shape = curvableText, let spec = shape.text {
                let degrees = spec.curve ?? 0
                HStack {
                    Slider(value: Binding(get: { degrees }, set: { model.setTextCurve(shape.id, degrees: $0.rounded()) }),
                           in: -360...360)
                        .frame(width: 220)
                    TextField("", value: Binding(get: { degrees }, set: { model.setTextCurve(shape.id, degrees: $0) }),
                              format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                    Text("°")
                }
                HStack {
                    Button("Arch") { model.setTextCurve(shape.id, degrees: 120) }
                    Button("Bowl") { model.setTextCurve(shape.id, degrees: -120) }
                    Button("Circle") { model.setTextCurve(shape.id, degrees: 360) }
                    Button("Straight") { model.setTextCurve(shape.id, degrees: 0) }
                }
                Text("Positive bends the text up into an arch, negative into a bowl. 360° wraps it into a full circle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Select one piece of text.").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var contourPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contour cut").font(.headline)
            HStack {
                Text("Offset")
                TextField("", value: Binding(get: { model.contourOffset / model.units.mmPerUnit },
                                             set: { model.contourOffset = max(0, $0 * model.units.mmPerUnit) }),
                          format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text(model.units.title)
            }
            Text(model.selection.isEmpty ? "Outlines all the artwork." : "Outlines the selected artwork.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Images are followed by their printed (non-white) pixels. Inner holes are skipped so each piece cuts out whole. The line goes on its own Contour cut layer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add contour cut") {
                model.addContourCut()
                showContour = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .frame(width: 300)
    }

    /// Click a colour to put the selection on that colour's layer.
    private var colorSwatches: some View {
        HStack(spacing: 3) {
            ForEach(Layer.palette.prefix(8), id: \.self) { hex in
                Button { model.applyColor(hex) } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: hex))
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5), lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Put the selection on the \(hex) layer")
            }
            ColorPicker("", selection: Binding(
                get: { model.selectedShapes.first.flatMap { model.document.layer($0.layerID) }.map { Color(hex: $0.colorHex) } ?? .black },
                set: { model.applyColor($0.hexString) }), supportsOpacity: false)
                .labelsHidden()
                .help("Pick any colour for the selection")
        }
        .disabled(model.selection.isEmpty)
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
