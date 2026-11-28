import KerfCore
import SwiftUI

/// The Send to Cutter sheet: blade and force, mirror, what to cut and where it goes on the vinyl,
/// with a preview of the job exactly as the cutter gets it and which way the vinyl feeds.
struct SendToCutterView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cutter: CutterSender
    @Environment(\.dismiss) private var dismiss
    @State private var showTravel = false
    @State private var queues: [String] = []

    var body: some View {
        let preview = model.cutterPreview()
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                settings
                    .frame(width: 360)
                Divider()
                CutterPreviewPane(preview: preview, showTravel: $showTravel)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            }
            Divider()
            footer(preview)
                .padding(12)
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 600, idealHeight: 680)
        .onAppear {
            queues = CutterSender.printerQueues()
            cutter.refreshPorts()
        }
    }

    // MARK: Settings

    private var settings: some View {
        Form {
            Section("Material, blade and force") {
                materialMenu
                ForEach(model.cutterLayerIDs, id: \.self) { id in
                    LayerCutSettings(layerID: id, showName: model.cutterLayerIDs.count > 1)
                }
                if model.cutterLayerIDs.isEmpty {
                    Text("No cut layers with shapes.").foregroundStyle(.secondary)
                }
                LabeledContent("Blade offset (mm)") {
                    TextField("", value: profileBinding(\.bladeOffset), format: .number).frame(width: 70)
                }
                .help("How far the drag blade's tip trails its centre: about 0.25 mm for a 45° blade, 0.5 mm for a 60° blade. 0 turns compensation off.")
                LabeledContent("Overcut (mm)") {
                    TextField("", value: profileBinding(\.overcut), format: .number).frame(width: 70)
                }
                if !model.profile.sendSpeedAndForce {
                    Text("This device is set not to send speed and force, so the cutter uses its own panel settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("What to cut") {
                Toggle("Cut selected shapes only", isOn: $model.cutSelectionOnly)
                    .help("Send only the shapes selected on the canvas")
                if model.cutSelectionOnly && model.selection.isEmpty {
                    Text("Nothing is selected, so the whole design is cut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                MirrorOutputPicker()
                if model.cutterSendsPanels {
                    Picker("Panel", selection: $model.selectedPanel) {
                        ForEach(model.panelLayout.panels) { p in
                            Text(p.name + (model.isPanelSent(p) ? " (sent)" : "")).tag(p.index)
                        }
                    }
                }
            }

            Section("Placement on the vinyl") {
                Picker("Placement", selection: $model.cutterPlacement) {
                    ForEach(CutterPlacement.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.homeCornerUnavailableReason != nil)
                if let reason = model.homeCornerUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if model.cutterPlacement == .homeCorner {
                    LabeledContent("Gap from home (mm)") {
                        TextField("", value: $model.cutterHomeMargin, format: .number).frame(width: 70)
                    }
                    Text("The job is moved into the corner where you set the cutter's origin, wherever it sits on the canvas, so no vinyl is wasted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The job is cut where it sits on the canvas, measured from the cutter's origin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Connection") {
                CutterConnectionSettings(queues: queues)
            }
        }
        .formStyle(.grouped)
    }

    private var materialMenu: some View {
        let list = model.materials.materials(for: .vinylCutter)
        return LabeledContent("Material") {
            Menu(currentMaterialTitle ?? "Choose…") {
                ForEach(list) { m in
                    Button(m.title) { model.applyMaterialToCutLayers(m.id) }
                }
                if list.isEmpty {
                    Text("No vinyl materials in the library")
                }
            }
            .frame(maxWidth: 220)
            .disabled(model.cutterLayerIDs.isEmpty)
        }
        .help("Sets force, speed, passes and blade for every cut layer from your material library")
    }

    /// The material every cut layer uses, when they all use the same one.
    private var currentMaterialTitle: String? {
        let ids = Set(model.cutterLayerIDs.compactMap { model.document.layer($0)?.materialID })
        guard ids.count == 1, model.cutterLayerIDs.allSatisfy({ model.document.layer($0)?.materialID != nil }) else {
            return ids.isEmpty ? nil : "Mixed"
        }
        return model.materials.material(ids.first)?.title
    }

    // MARK: Footer

    private func footer(_ preview: CutterPreview) -> some View {
        HStack(spacing: 12) {
            if cutter.isSending {
                ProgressView(value: cutter.progress).frame(width: 160)
            }
            Text(cutter.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Export file…") { model.exportMachineFile() }
                .disabled(preview.isEmpty)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if cutter.isSending {
                Button("Stop", role: .destructive) { cutter.cancel() }
            } else {
                Button(sendTitle) { model.sendCutterJob(with: cutter) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.isEmpty || model.profile.language == .svgFile
                              || (model.profile.output == .serial && cutter.selectedPort.isEmpty))
            }
        }
    }

    private var sendTitle: String {
        if model.cutterSendsPanels, let p = model.currentPanel { return "Send panel \(p.name)" }
        return "Send to cutter"
    }

    private func profileBinding<T>(_ keyPath: WritableKeyPath<DeviceProfile, T>) -> Binding<T> {
        Binding(get: { model.profile[keyPath: keyPath] }, set: { model.profile[keyPath: keyPath] = $0 })
    }
}

/// Force, speed and passes for one cut layer.
private struct LayerCutSettings: View {
    @EnvironmentObject var model: AppModel
    let layerID: UUID
    let showName: Bool

    var body: some View {
        if let layer = model.document.layer(layerID) {
            if showName {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: layer.colorHex)).frame(width: 10, height: 10)
                    Text(layer.name).font(.callout.weight(.medium))
                }
            }
            LabeledContent("Force (g)") {
                TextField("", value: binding(\.cutForce), format: .number).frame(width: 70)
            }
            LabeledContent("Speed (cm/s)") {
                TextField("", value: binding(\.cutSpeed), format: .number).frame(width: 70)
            }
            Stepper("Passes: \(layer.passes)", value: binding(\.passes), in: 1...10)
            if let own = layer.bladeOffset, model.profile.bladeOffset > 0 {
                LabeledContent("Layer's own blade offset", value: String(format: "%.2f mm", own))
                    .font(.caption)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Layer, T>) -> Binding<T> {
        Binding(get: { model.document.layer(layerID)![keyPath: keyPath] },
                set: { value in
                    guard let i = model.document.layers.firstIndex(where: { $0.id == layerID }) else { return }
                    model.document.layers[i][keyPath: keyPath] = value
                })
    }
}

/// How the cutter is reached: USB serial port or a raw printer queue.
struct CutterConnectionSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cutter: CutterSender
    let queues: [String]

    var body: some View {
        if model.profile.language == .svgFile {
            Text("This machine has no live connection. Export an SVG and load it with a USB stick or the maker's app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Send via", selection: profileBinding(\.output)) {
                ForEach(CutterOutput.allCases) { Text($0.title).tag($0) }
            }
            if model.profile.output == .serial {
                HStack {
                    Picker("Port", selection: $cutter.selectedPort) {
                        if cutter.ports.isEmpty { Text("No serial ports").tag("") }
                        ForEach(cutter.ports, id: \.self) { Text($0.replacingOccurrences(of: "/dev/", with: "")).tag($0) }
                    }
                    Button { cutter.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
                Text("\(model.profile.baudRate) baud, \(model.profile.flowControl.title) flow control")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Printer queue", selection: profileBinding(\.printerQueue)) {
                    if !queues.contains(model.profile.printerQueue) {
                        Text(model.profile.printerQueue.isEmpty ? "Choose…" : model.profile.printerQueue).tag(model.profile.printerQueue)
                    }
                    ForEach(queues, id: \.self) { Text($0).tag($0) }
                }
                Text("Add the cutter in System Settings › Printers as a Generic PostScript printer; Kerf sends raw data to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Language", value: model.profile.language.title)
        }
    }

    private func profileBinding<T>(_ keyPath: WritableKeyPath<DeviceProfile, T>) -> Binding<T> {
        Binding(get: { model.profile[keyPath: keyPath] }, set: { model.profile[keyPath: keyPath] = $0 })
    }
}

// MARK: - Preview

/// The vinyl as seen from above with the front of the cutter at the bottom, the cutter's home corner,
/// which way the vinyl moves, and the cut exactly as it will be sent.
private struct CutterPreviewPane: View {
    @EnvironmentObject var model: AppModel
    let preview: CutterPreview
    @Binding var showTravel: Bool

    var body: some View {
        let profile = model.profile
        let home = profile.fromMachine(.zero)
        let homeAtFront = home.y > profile.bedHeight / 2
        let region = viewRegion(home: home, homeAtFront: homeAtFront)
        let bounds = preview.cutBounds

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.headline)
                Text("as it will cut").foregroundStyle(.secondary)
                Spacer()
                Toggle("Knife-up moves", isOn: $showTravel)
                    .toggleStyle(.checkbox)
            }
            Text(homeAtFront ? "Rear (roll side)" : "Rear")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                feedStrip(homeAtFront: homeAtFront)
                Canvas { ctx, size in
                    draw(&ctx, size: size, region: region, home: home)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            Text("Front of cutter")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            if preview.isEmpty {
                Label("Nothing to cut: put shapes on an enabled cut layer.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                summary(bounds: bounds, home: home, homeAtFront: homeAtFront)
            }
        }
    }

    private func feedStrip(homeAtFront: Bool) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: homeAtFront ? "arrow.down" : "arrow.up")
            Text("Vinyl feeds")
                .font(.caption)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 16, height: 70)
            Image(systemName: homeAtFront ? "arrow.down" : "arrow.up")
            Spacer()
        }
        .foregroundStyle(.blue)
        .frame(width: 22)
        .help(homeAtFront ? "As the cut goes on, the vinyl moves out the front of the cutter"
                          : "As the cut goes on, the sheet moves towards the back of the cutter")
    }

    private func summary(bounds: Rect2, home: Vec2, homeAtFront: Bool) -> some View {
        let u = model.units
        let used = homeAtFront ? home.y - bounds.minY : bounds.maxY - home.y
        let time = model.toolpath.estimatedSeconds(profile: model.profile)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Job \(u.format(bounds.width)) × \(u.format(bounds.height)) \(u.title) · uses about \(u.format(max(0, used))) \(u.title) of vinyl from the home edge")
            Text("Cut length \(u == .mm ? String(format: "%.2f m", preview.cutLength / 1000) : String(format: "%.1f ft", preview.cutLength / 304.8)) · about \(formatMinutes(time))")
            if model.mirrorOutput != .none {
                Text("Mirrored \(model.mirrorOutput == .horizontal ? "left to right" : "top to bottom") for the cutter.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func formatMinutes(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }

    /// The part of the vinyl to show: its full width, from the home edge to just past the far end of the job.
    private func viewRegion(home: Vec2, homeAtFront: Bool) -> Rect2 {
        let bed = Rect2(minX: 0, minY: 0, maxX: model.profile.bedWidth, maxY: model.profile.bedHeight)
        let b = preview.cutBounds
        let pad = 15.0
        let minLength = min(bed.height, max(150, bed.width * 0.5))
        var r = bed
        if homeAtFront {
            let far = b.isEmpty ? bed.maxY - minLength : min(b.minY - pad, bed.maxY - minLength)
            r.minY = far
            r.maxY = max(bed.maxY, b.isEmpty ? bed.maxY : b.maxY + 2)
        } else {
            let far = b.isEmpty ? minLength : max(b.maxY + pad, minLength)
            r.maxY = far
            r.minY = min(0, b.isEmpty ? 0 : b.minY - 2)
        }
        if !b.isEmpty {
            r.minX = min(r.minX, b.minX - 2)
            r.maxX = max(r.maxX, b.maxX + 2)
        }
        return r
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, region: Rect2, home: Vec2) {
        let margin: CGFloat = 14
        let s = min((size.width - 2 * margin) / region.width, (size.height - 2 * margin) / region.height)
        let ox = (size.width - region.width * s) / 2, oy = (size.height - region.height * s) / 2
        func pt(_ p: Vec2) -> CGPoint { CGPoint(x: ox + (p.x - region.minX) * s, y: oy + (p.y - region.minY) * s) }

        // The vinyl across the cutter's width.
        let bed = Rect2(minX: 0, minY: max(region.minY, 0), maxX: model.profile.bedWidth, maxY: min(region.maxY, model.profile.bedHeight))
        let vinyl = CGRect(origin: pt(bed.origin), size: CGSize(width: bed.width * s, height: bed.height * s))
        ctx.fill(Path(vinyl), with: .color(Color(white: 0.97)))
        ctx.stroke(Path(vinyl), with: .color(.gray.opacity(0.6)), lineWidth: 1)

        // 50 mm grid.
        var grid = Path()
        var x = (bed.minX / 50).rounded(.up) * 50
        while x <= bed.maxX { grid.move(to: pt(Vec2(x, bed.minY))); grid.addLine(to: pt(Vec2(x, bed.maxY))); x += 50 }
        var y = (bed.minY / 50).rounded(.up) * 50
        while y <= bed.maxY { grid.move(to: pt(Vec2(bed.minX, y))); grid.addLine(to: pt(Vec2(bed.maxX, y))); y += 50 }
        ctx.stroke(grid, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)

        if showTravel {
            var travel = Path()
            for st in preview.strokes where !st.isCut {
                guard let f = st.points.first else { continue }
                travel.move(to: pt(f))
                for p in st.points.dropFirst() { travel.addLine(to: pt(p)) }
            }
            ctx.stroke(travel, with: .color(.red.opacity(0.6)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
        }

        var cuts = Path()
        for st in preview.strokes where st.isCut {
            guard let f = st.points.first else { continue }
            cuts.move(to: pt(f))
            for p in st.points.dropFirst() { cuts.addLine(to: pt(p)) }
        }
        ctx.stroke(cuts, with: .color(.black), lineWidth: 1)

        // First cut starts here.
        if let first = preview.strokes.first(where: \.isCut)?.points.first {
            let c = pt(first)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.green))
        }

        // Home corner: where the cutter's origin is set.
        let h = pt(home)
        ctx.fill(Path(ellipseIn: CGRect(x: h.x - 5, y: h.y - 5, width: 10, height: 10)), with: .color(.blue))
        let rightSide = home.x > model.profile.bedWidth / 2
        let atFront = home.y > model.profile.bedHeight / 2
        let label = ctx.resolve(Text("Home").font(.caption2.bold()).foregroundColor(.blue))
        let ls = label.measure(in: size)
        ctx.draw(label, at: CGPoint(x: h.x + (rightSide ? -ls.width / 2 - 8 : ls.width / 2 + 8),
                                    y: h.y + (atFront ? -ls.height / 2 - 4 : ls.height / 2 + 4)))
    }
}
