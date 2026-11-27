import KerfCore
import SwiftUI

/// Machine tab section for cutting vinyl signs bigger than the cutter as overlapping panels.
struct PanelSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Panels (oversized signs)") {
            Toggle("Split into panels", isOn: $model.panels.enabled)
                .help("Cut a sign bigger than the cutter as overlapping panels, one at a time")
            if model.panels.enabled {
                let profile = model.profile
                LabeledContent("Panel width (mm)") {
                    TextField("", value: $model.panels.maxWidth, format: .number).frame(width: 70)
                }
                .help("Across the vinyl. 0 uses the machine's full cut width.")
                LabeledContent("Panel length (mm)") {
                    TextField("", value: $model.panels.maxHeight, format: .number).frame(width: 70)
                }
                .help("Along the roll. 0 uses the machine's bed length.")
                Text("Up to \(mm(model.panels.panelWidth(for: profile))) × \(mm(model.panels.panelHeight(for: profile))) mm per panel. Leave a size at 0 to use the machine's \(mm(profile.bedWidth)) × \(mm(profile.bedHeight)) mm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.panels.panelHeight(for: profile) > profile.bedHeight + 1e-9 {
                    Label("Panels are longer than the bed. Make sure the cutter can feed that much vinyl and keep it tracking straight.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Overlap (mm)") {
                    TextField("", value: $model.panels.overlap, format: .number).frame(width: 70)
                }
                .help("How far neighbouring panels overlap, so there's no gap when you apply them")
                Toggle("Alignment marks", isOn: $model.panels.marks)
                    .help("Cuts small crosshairs in each overlap, at the same spot on both panels, to line them up")
                if model.panels.marks {
                    LabeledContent("Mark size (mm)") {
                        TextField("", value: $model.panels.markSize, format: .number).frame(width: 70)
                    }
                }
                PanelList()
            }
        }
    }
}

/// The panels laid out as they sit on the sign, with the selected panel's preview and send state.
private struct PanelList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let layout = model.panelLayout
        if layout.panels.isEmpty {
            Text("No enabled cut layers with shapes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !layout.isSplit {
            Text("The design fits the cutter in one piece, so it's cut as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let first = layout.panels[0].rect
            Text("\(layout.panels.count) panels (\(layout.rows) × \(layout.columns)), each about \(mm(first.width)) × \(mm(first.height)) mm. Cut and send them one at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if layout.unmarkedSeams > 0 {
                Label("\(layout.unmarkedSeams) seam\(layout.unmarkedSeams == 1 ? "" : "s") had no room for a mark clear of the artwork. Line those up by the artwork itself.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<layout.rows, id: \.self) { r in
                    GridRow {
                        ForEach(0..<layout.columns, id: \.self) { c in
                            cell(layout.panels[r * layout.columns + c])
                        }
                    }
                }
            }
            if let panel = model.currentPanel {
                let tp = model.panelToolpath(panel)
                PanelPreview(toolpath: tp, weeding: Weeding.cuts(for: tp, options: model.weeding), profile: model.profile)
                    .frame(height: 170)
                Text("Panel \(panel.name): \(mm(panel.rect.width)) × \(mm(panel.rect.height)) mm, \(layout.marks(in: panel).count) alignment marks. It starts at the cutter's origin (orange dot).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("\(layout.panels.filter { model.isPanelSent($0) }.count) of \(layout.panels.count) sent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Skip") { model.selectNextUnsentPanel(after: panel) }
                        .help("Move on to the next panel without sending this one")
                    Button("Start over") { model.resetSentPanels() }
                        .disabled(model.sentPanels.isEmpty)
                }
            }
        }
    }

    private func cell(_ panel: Panel) -> some View {
        let selected = model.currentPanel?.index == panel.index
        let sent = model.isPanelSent(panel)
        let tint: Color? = selected ? Color.accentColor : (sent ? Color.green : nil)
        return Button {
            model.selectedPanel = panel.index
        } label: {
            HStack(spacing: 2) {
                if sent { Image(systemName: "checkmark") }
                Text(panel.name).monospacedDigit()
            }
            .frame(minWidth: 40)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .help(sent ? "Panel \(panel.name), sent" : "Panel \(panel.name)")
    }
}

/// One panel's cuts on the cutter's bed, as they'll be sent.
private struct PanelPreview: View {
    let toolpath: Toolpath
    let weeding: WeedingCuts
    let profile: DeviceProfile

    var body: some View {
        Canvas { ctx, size in
            var area = Rect2(minX: 0, minY: 0, maxX: profile.bedWidth, maxY: profile.bedHeight)
            area = area.union(toolpath.bounds)
            for p in weeding.allPaths { for v in p { area.include(v) } }
            guard area.width > 0, area.height > 0 else { return }
            let scale = min((size.width - 8) / area.width, (size.height - 8) / area.height)
            let ox = (size.width - area.width * scale) / 2 - area.minX * scale
            let oy = (size.height - area.height * scale) / 2 - area.minY * scale
            func pt(_ v: Vec2) -> CGPoint { CGPoint(x: ox + v.x * scale, y: oy + v.y * scale) }
            func path(_ paths: [[Vec2]]) -> Path {
                var out = Path()
                for p in paths {
                    guard let f = p.first else { continue }
                    out.move(to: pt(f))
                    for q in p.dropFirst() { out.addLine(to: pt(q)) }
                }
                return out
            }
            let bed = CGRect(origin: pt(.zero), size: CGSize(width: profile.bedWidth * scale, height: profile.bedHeight * scale))
            ctx.fill(Path(bed), with: .color(.secondary.opacity(0.08)))
            ctx.stroke(Path(bed), with: .color(.secondary.opacity(0.5)), lineWidth: 0.8)
            ctx.stroke(path(weeding.allPaths), with: .color(.secondary), style: StrokeStyle(lineWidth: 0.6, dash: [3, 2]))
            for l in toolpath.layers {
                let marks = l.layer.name == "Panel marks"
                ctx.stroke(path(l.paths), with: .color(marks ? .orange : Color(hex: l.layer.colorHex)), lineWidth: marks ? 1.2 : 0.8)
            }
            let o = pt(profile.fromMachine(.zero))
            ctx.fill(Path(ellipseIn: CGRect(x: o.x - 3, y: o.y - 3, width: 6, height: 6)), with: .color(.orange))
        }
        .background(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
    }
}

private func mm(_ v: Double) -> String {
    v.formatted(.number.precision(.fractionLength(0...1)))
}
