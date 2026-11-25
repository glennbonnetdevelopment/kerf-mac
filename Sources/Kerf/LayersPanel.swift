import KerfCore
import SwiftUI

struct LayersPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $model.currentLayerID) {
                ForEach(model.document.layers) { layer in
                    LayerRow(layerID: layer.id)
                        .tag(Optional(layer.id))
                }
                .onMove { from, to in
                    model.checkpoint()
                    model.document.layers.move(fromOffsets: from, toOffset: to)
                }
            }
            .frame(minHeight: 140, maxHeight: 220)

            HStack {
                Button { model.addLayer() } label: { Image(systemName: "plus") }
                    .help("Add layer")
                Button {
                    if let id = model.currentLayerID { model.removeLayer(id) }
                } label: { Image(systemName: "minus") }
                    .help("Delete layer and its shapes")
                    .disabled(model.currentLayerID == nil)
                Spacer()
                Button("Move selection here") {
                    if let id = model.currentLayerID { model.moveSelection(toLayer: id) }
                }
                .disabled(model.selection.isEmpty || model.currentLayerID == nil)
            }
            .buttonStyle(.borderless)

            Divider()

            if let id = model.currentLayerID, let binding = model.layerBinding(id) {
                LayerSettings(layer: binding, kind: model.profile.kind)
            } else {
                Text("Select a layer to edit its settings.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LayerRow: View {
    @EnvironmentObject var model: AppModel
    let layerID: UUID

    var body: some View {
        if let binding = model.layerBinding(layerID) {
            let layer = binding.wrappedValue
            let count = model.document.shapes.filter { $0.layerID == layerID }.count
            HStack(spacing: 8) {
                Toggle("", isOn: binding.enabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("Include this layer in jobs")
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: layer.colorHex))
                    .frame(width: 14, height: 14)
                Text(layer.name)
                    .lineLimit(1)
                Spacer()
                Text(layer.mode.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct LayerSettings: View {
    @Binding var layer: Layer
    let kind: DeviceKind

    private var color: Binding<Color> {
        Binding(get: { Color(hex: layer.colorHex) }, set: { layer.colorHex = $0.hexString })
    }

    var body: some View {
        Form {
            TextField("Name", text: $layer.name)
            ColorPicker("Colour", selection: color, supportsOpacity: false)
            Picker("Mode", selection: $layer.mode) {
                ForEach(LayerMode.allCases) { Text($0.title).tag($0) }
            }
            if !Planner.supports(layer.mode, on: kind) {
                Text("\(layer.mode.title) layers are skipped on a \(kind.title.lowercased()).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if layer.mode != .print {
                Stepper("Passes: \(layer.passes)", value: $layer.passes, in: 1...50)
            }

            switch layer.mode {
            case .print:
                Text("Print-only layers hold registration marks and print artwork. They go into the print PDF and are never cut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .cut:
                number("Speed (cm/s)", $layer.cutSpeed)
                number("Force (g)", $layer.cutForce)
            case .mill:
                number("Feed (mm/min)", $layer.speed)
                number("Plunge (mm/min)", $layer.plungeRate)
                number("Spindle (S value)", $layer.spindleSpeed)
                number("Cut depth (mm)", $layer.cutDepth)
                number("Pass depth (mm)", $layer.stepDown)
                number("Tool diameter (mm)", $layer.toolDiameter)
                Picker("Default cut", selection: $layer.defaultMillRole) {
                    ForEach(MillRole.allCases) { Text($0.title).tag($0) }
                }
                Text("Auto treats outer shapes as parts (cut outside) and shapes inside them as holes (cut inside). Set a shape's own cut type in Arrange.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Milling", selection: $layer.millStyle) {
                    ForEach(MillStyle.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Pocket stepover \(Int((layer.stepover * 100).rounded()))%") {
                    Slider(value: $layer.stepover, in: 0.1...0.9, step: 0.05).frame(width: 150)
                }
                number("Ramp length (mm)", $layer.rampLength)
                Toggle("Holding tabs on parts", isOn: $layer.tabsEnabled)
                if layer.tabsEnabled {
                    Stepper("Tabs per part: \(layer.tabCount)", value: $layer.tabCount, in: 1...20)
                    number("Tab width (mm)", $layer.tabWidth)
                    number("Tab height (mm)", $layer.tabHeight)
                }
            case .line, .fill, .image:
                number("Speed (mm/min)", $layer.speed)
                LabeledContent(layer.mode == .image ? "Max power \(Int(layer.power))%" : "Power \(Int(layer.power))%") {
                    Slider(value: $layer.power, in: 0...100, step: 1).frame(width: 150)
                }
                if layer.mode == .image {
                    LabeledContent("Min power \(Int(layer.powerMin))%") {
                        Slider(value: $layer.powerMin, in: 0...100, step: 1).frame(width: 150)
                    }
                    Picker("Dither", selection: $layer.dither) {
                        ForEach(DitherMode.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Line interval (mm)") {
                        TextField("", value: $layer.fillInterval, format: .number.precision(.fractionLength(0...3))).frame(width: 70)
                    }
                    Text(String(format: "%.0f DPI", 25.4 / max(0.01, layer.fillInterval)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    number("Overscan (mm)", $layer.overscan)
                    Toggle("Invert", isOn: $layer.invertImage)
                    Toggle("Bidirectional", isOn: $layer.fillBidirectional)
                }
                Toggle("Air assist", isOn: $layer.airAssist)
                if layer.mode == .fill {
                    LabeledContent("Line interval (mm)") {
                        TextField("", value: $layer.fillInterval, format: .number.precision(.fractionLength(0...3))).frame(width: 70)
                    }
                    number("Angle (°)", $layer.fillAngle)
                    Toggle("Bidirectional", isOn: $layer.fillBidirectional)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number).frame(width: 80)
        }
    }

    private func number(_ title: String, _ value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number).frame(width: 80)
        }
    }
}
