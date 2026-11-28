import KerfCore
import SwiftUI

/// Drawing tools above the canvas: select and basic shapes, the shapes library, text, and text around a shape.
struct EditorToolbar: View {
    @EnvironmentObject var model: AppModel
    @State private var fonts: [String] = []
    @State private var showRotate = false
    @State private var rotateAngle = 45.0
    @State private var showShapes = false
    @State private var showCurve = false
    @State private var showContour = false
    @State private var showStyle = false
    @State private var freehandPopover: Tool?

    var body: some View {
        ToolbarFlowLayout(spacing: 6, rowSpacing: 4) {
            ForEach([Tool.select, .node, .tabs, .measure, .rectangle, .ellipse, .line]) { t in
                toolButton(t.symbol, help: t.title, active: model.tool == t) { model.tool = t }
            }
            Divider().frame(height: 22)
            transformButtons
            Divider().frame(height: 22)

            toolButton(model.shapeKind.symbol, help: "Shapes: \(model.shapeKind.title)", active: model.tool == .shape) {
                model.tool = .shape
                showShapes = true
            }
            .popover(isPresented: $showShapes, arrowEdge: .bottom) { shapesPopover }

            Divider().frame(height: 22)

            ForEach([Tool.pen, .brush, .eraser]) { t in
                toolButton(t.symbol, help: t.title, active: model.tool == t) {
                    model.tool = t
                    freehandPopover = t
                }
                .popover(isPresented: Binding(get: { freehandPopover == t }, set: { if !$0 { freehandPopover = nil } }),
                         arrowEdge: .bottom) {
                    FreehandOptions(tool: t).environmentObject(model)
                }
            }

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
            Button { model.showRhinestones = true } label: { Label("Rhinestones", systemImage: "circle.grid.3x3.fill") }
                .help("Lay rhinestones along and inside the selected shapes or text, and cut the template holes")
                .disabled(model.rhinestoneTargets.isEmpty)
            Button { model.showPatch = true } label: { Label("Patch", systemImage: "shield.lefthalf.filled") }
                .help("Make an embroidered patch around the selected design: shape, satin border, fabric or fill background, and cut lines")
            Divider().frame(height: 22)

            colorSwatches

            Button { showStyle = true } label: { Label("Style", systemImage: "lineweight") }
                .help("Stroke colour and width, fill and offset outline for the selection")
                .disabled(model.styleTargets.isEmpty)
                .popover(isPresented: $showStyle, arrowEdge: .bottom) {
                    Form { ShapeStyleControls() }
                        .formStyle(.grouped)
                        .frame(width: 340)
                        .environmentObject(model)
                }

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

    /// Mirror and rotate the selection about its centre.
    @ViewBuilder private var transformButtons: some View {
        Group {
            toolButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Mirror horizontally (flip left to right)",
                       active: false) { model.mirrorSelection(horizontal: true) }
            toolButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Mirror vertically (flip top to bottom)",
                       active: false) { model.mirrorSelection(horizontal: false) }
            toolButton("rotate.left", help: "Rotate 90° counter-clockwise", active: false) { model.rotateSelection(degrees: -90) }
            toolButton("rotate.right", help: "Rotate 90° clockwise", active: false) { model.rotateSelection(degrees: 90) }
            toolButton("angle", help: "Rotate by any angle", active: showRotate) { showRotate = true }
                .popover(isPresented: $showRotate, arrowEdge: .bottom) { rotatePopover }
        }
        .disabled(model.selection.isEmpty)
    }

    private var rotatePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rotate").font(.headline)
            HStack {
                TextField("", value: $rotateAngle, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("°")
                Button("Rotate") { model.rotateSelection(degrees: rotateAngle) }
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                ForEach([-45.0, 45, 180], id: \.self) { a in
                    Button("\(a, specifier: "%+g")°") { model.rotateSelection(degrees: a) }
                }
            }
            Text("Positive turns clockwise, about the middle of the selection. You can also drag the round handle above the selection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
        .disabled(model.selection.isEmpty)
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

extension EditorToolbar {
    /// Inside the toolbar, `Divider()` means the vertical toolbar separator: SwiftUI's own divider draws
    /// horizontally in a custom layout. Shadowing the name keeps every `Divider().frame(height: 22)` working.
    struct Divider: View {
        var body: some View { ToolbarSeparator() }
    }
}
