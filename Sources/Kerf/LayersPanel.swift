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
                LayerSettings(layer: binding, kind: model.profile.kind, machineBladeOffset: model.profile.bladeOffset)
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
            let count = model.document.itemCount(onLayer: layerID)
            let owner = model.document.styleOwner(ofLayer: layerID)
            HStack(spacing: 8) {
                Toggle("", isOn: binding.enabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("Include this layer in jobs")
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: layer.colorHex))
                    .frame(width: 14, height: 14)
                if owner != nil {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(layer.name)
                        .lineLimit(1)
                    if let owner {
                        Text("\(owner.kind.title) of \(owner.shape.name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(layer.output == .embroidery ? "Embroidery" : layer.mode.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, owner == nil ? 0 : 10)
            .help(owner.map { "Holds the \($0.kind.title.lowercased()) of \($0.shape.name)" } ?? "")
        }
    }
}

struct LayerSettings: View {
    @Binding var layer: Layer
    let kind: DeviceKind
    /// False in the material library, where the name, colour and material links don't apply.
    var showsIdentity = true
    /// The current machine's blade offset, shown when a layer starts using its own.
    var machineBladeOffset: Double = 0.25

    private var color: Binding<Color> {
        Binding(get: { Color(hex: layer.colorHex) }, set: { layer.colorHex = $0.hexString })
    }

    var body: some View {
        Form {
            if showsIdentity {
                TextField("Name", text: $layer.name)
                ColorPicker("Colour", selection: color, supportsOpacity: false)
                LayerMaterialRow(layer: layer, kind: kind)
            }
            Picker("Mode", selection: $layer.mode) {
                ForEach(LayerMode.allCases) { Text($0.title).tag($0) }
            }
            if !Planner.supports(layer.mode, on: kind) {
                Text("\(layer.mode.title) layers are skipped on a \(kind.title.lowercased()).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if showsIdentity && layer.mode != .print && layer.mode != .image {
                Picker("Used for", selection: $layer.output) {
                    ForEach(LayerOutput.allCases) { Text($0.title).tag($0) }
                }
                .help("Keep a layer to embroidery export only (never cut or engraved), or to the machine only (never sewn)")
                if layer.output != .machines {
                    Toggle("Stop the embroidery machine before and after", isOn: $layer.embroideryStop)
                        .help("For appliqué: the machine stops so you can lay or trim fabric. The layer is never grouped with others of its thread.")
                }
            }
            if layer.output == .embroidery {
                Text("Sewn only: this layer is left out of laser, cutter and CNC jobs. Set its stitches in File › Export Embroidery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if layer.mode != .print {
                Stepper("Passes: \(layer.passes)", value: $layer.passes, in: 1...50)
            }

            if layer.output != .embroidery {
                switch layer.mode {
                case .print:
                    Text("Print-only layers hold registration marks and print artwork. They go into the print PDF and are never cut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .cut:
                    number("Speed (cm/s)", $layer.cutSpeed)
                    number("Force (g)", $layer.cutForce)
                    if kind == .vinylCutter { bladeOffsetSettings }
                    if kind == .grblLaser { tabSettings(cnc: false) }
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
                    tabSettings(cnc: true)
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
                    if layer.mode == .line, kind == .grblLaser { tabSettings(cnc: false) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Holding tab settings: on a laser the tab is a short stretch left uncut; on a CNC a bridge left
    /// standing at the bottom of the cut.
    @ViewBuilder
    private func tabSettings(cnc: Bool) -> some View {
        Toggle("Holding tabs on parts", isOn: $layer.tabsEnabled)
        if layer.tabsEnabled {
            Picker("Place", selection: $layer.tabPlacement) {
                Text("A number per part").tag(TabPlacement.count)
                Text("By spacing").tag(TabPlacement.spacing)
            }
            if layer.tabPlacement == .count {
                Stepper("Tabs per part: \(layer.tabCount)", value: $layer.tabCount, in: 1...20)
            } else {
                number("One tab every (mm)", $layer.tabSpacing)
            }
            if cnc {
                number("Tab width (mm)", $layer.tabWidth)
                number("Tab height (mm)", $layer.tabHeight)
            } else {
                number("Tab width (mm)", $layer.laserTabWidth)
            }
            Text(cnc
                 ? "Tabs go on parts, away from corners. The tool lifts to leave a bridge this tall. Use the Holding tabs tool to add, move or remove tabs by hand."
                 : "Tabs go on parts, away from corners, and are left uncut so pieces stay in the sheet. Use the Holding tabs tool to add, move or remove tabs by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var bladeOffsetSettings: some View {
        Toggle("Own blade offset", isOn: Binding(
            get: { layer.bladeOffset != nil },
            set: { layer.bladeOffset = $0 ? (layer.bladeOffset ?? (machineBladeOffset > 0 ? machineBladeOffset : 0.25)) : nil }))
            .help("Use a different blade offset from the machine's for this layer, such as for a 60° blade")
        if layer.bladeOffset != nil {
            number("Blade offset (mm)", Binding(get: { layer.bladeOffset ?? 0 }, set: { layer.bladeOffset = max(0, $0) }))
            Text("About 0.25 mm for a 45° blade and 0.5 mm for a 60° blade. Machines with a blade offset of 0 ignore this.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

/// Shows which material a layer uses, and applies or saves materials.
private struct LayerMaterialRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let layer: Layer
    let kind: DeviceKind
    @State private var saving = false

    var body: some View {
        let linked = model.materials.material(layer.materialID)
        let choices = model.materials.materials(for: kind)
        LabeledContent("Material") {
            HStack(spacing: 6) {
                Menu {
                    if choices.isEmpty {
                        Text("No saved materials for a \(kind.title.lowercased()) yet")
                    }
                    ForEach(choices) { m in
                        Button(m.title) { model.applyMaterial(m.id, to: layer.id) }
                    }
                    Divider()
                    Button("Save these settings as a material…") { saving = true }
                    if let linked {
                        Button("Update \"\(linked.title)\" with these settings") { model.updateMaterial(linked.id, from: layer.id) }
                    }
                    Button("Open Material Library…") { openWindow(id: "material-library") }
                } label: {
                    Text(linked.map { $0.title + (model.layerMatchesMaterial(layer) ? "" : " (edited)") } ?? "None")
                        .lineLimit(1)
                }
                .frame(maxWidth: 210)
                .popover(isPresented: $saving, arrowEdge: .bottom) {
                    SaveMaterialForm(layerID: layer.id, kind: kind, suggestion: linked) { saving = false }
                }
            }
        }
    }
}

/// Name, thickness and operation for a new material.
struct SaveMaterialForm: View {
    @EnvironmentObject var model: AppModel
    let layerID: UUID
    let kind: DeviceKind
    let suggestion: CutMaterial?
    let done: () -> Void
    @State private var name = ""
    @State private var thickness = 0.0
    @State private var operation = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save as material").font(.headline)
            Text("For a \(kind.title.lowercased()). Saves this layer's mode and all its cut settings.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("Material", text: $name, prompt: Text("e.g. Birch plywood"))
                LabeledContent("Thickness (mm)") {
                    TextField("", value: $thickness, format: .number.precision(.fractionLength(0...2))).frame(width: 70)
                }
                TextField("Operation", text: $operation, prompt: Text("Cut, Score, Engrave…"))
                TextField("Notes", text: $notes, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...4)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done() }
                Button("Save") {
                    model.saveLayerAsMaterial(layerID, name: name, thickness: thickness, operation: operation, notes: notes)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            if let s = suggestion {
                name = s.name
                thickness = s.thickness
            }
            if operation.isEmpty, let layer = model.document.layer(layerID) {
                switch layer.mode {
                case .line: operation = kind == .grblLaser ? "Cut" : "Line"
                case .fill: operation = "Engrave"
                case .image: operation = "Photo engrave"
                case .cut: operation = "Cut"
                case .mill: operation = "Profile"
                case .print: operation = "Print"
                }
            }
        }
    }
}
