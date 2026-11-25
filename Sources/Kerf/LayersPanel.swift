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
            Stepper("Passes: \(layer.passes)", value: $layer.passes, in: 1...50)

            if layer.mode == .cut {
                if kind == .grblLaser {
                    Text("Cut layers are for vinyl cutters. Switch to Line or Fill for the laser.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Speed (cm/s)") {
                    TextField("", value: $layer.cutSpeed, format: .number).frame(width: 70)
                }
                LabeledContent("Force (g)") {
                    TextField("", value: $layer.cutForce, format: .number).frame(width: 70)
                }
            } else {
                if kind == .vinylCutter && layer.mode == .fill {
                    Text("Fill layers are skipped when cutting vinyl.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Speed (mm/min)") {
                    TextField("", value: $layer.speed, format: .number).frame(width: 80)
                }
                LabeledContent("Power \(Int(layer.power))%") {
                    Slider(value: $layer.power, in: 0...100, step: 1).frame(width: 150)
                }
                Toggle("Air assist", isOn: $layer.airAssist)
                if layer.mode == .fill {
                    LabeledContent("Line interval (mm)") {
                        TextField("", value: $layer.fillInterval, format: .number.precision(.fractionLength(0...3))).frame(width: 70)
                    }
                    LabeledContent("Angle (°)") {
                        TextField("", value: $layer.fillAngle, format: .number).frame(width: 70)
                    }
                    Toggle("Bidirectional", isOn: $layer.fillBidirectional)
                }
            }
        }
        .formStyle(.grouped)
    }
}
