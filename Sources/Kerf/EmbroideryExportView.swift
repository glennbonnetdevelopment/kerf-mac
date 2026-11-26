import KerfCore
import SwiftUI

/// Stitch settings per layer, a preview in the hoop, and export to Brother, Janome or Tajima files.
struct EmbroideryExportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("embroideryFormat") private var formatRaw = EmbroideryFormat.pes.rawValue
    @AppStorage("embroideryHoop") private var hoopName = EmbroideryHoop.brother[1].name
    @AppStorage("embroideryGroupColors") private var groupColors = true
    @AppStorage("embroideryOptimizeOrder") private var optimizeOrder = true

    private var format: EmbroideryFormat { EmbroideryFormat(rawValue: formatRaw) ?? .pes }

    private var hoop: EmbroideryHoop {
        let hoops = format.hoops
        return hoops.first { $0.name == hoopName } ?? hoops[min(1, hoops.count - 1)]
    }

    var body: some View {
        let pattern = model.embroideryPattern(groupColors: groupColors, optimizeOrder: optimizeOrder)
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Embroidery").font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    StitchPreview(pattern: pattern, hoop: hoop)
                        .frame(width: 320, height: 320)
                    summary(pattern)
                }
                .frame(width: 320)
                Form {
                    Section("Machine") {
                        Picker("Format", selection: $formatRaw) {
                            ForEach(EmbroideryFormat.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        Picker("Hoop", selection: $hoopName) {
                            ForEach(format.hoops) { Text($0.name).tag($0.name) }
                        }
                        if !model.selection.isEmpty {
                            Toggle("Selected shapes only", isOn: $model.cutSelectionOnly)
                        }
                        Toggle("Group same colours", isOn: $groupColors)
                            .help("Sew a layer with an earlier layer of the same thread when nothing in between overlaps it, for fewer thread changes")
                    }
                    Section("Layers") {
                        let layers = model.embroideredLayers
                        if layers.isEmpty {
                            Text("No shapes to sew. Print-only and image layers, and turned-off layers, are skipped.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(layers) { layer in
                            EmbroideryLayerSettings(layerID: layer.id)
                        }
                    }
                    Section("Sewing order") {
                        Toggle("Optimize order", isOn: $optimizeOrder)
                            .help("Sew shapes with the same settings together, nearest first. Turn off to sew shapes in your own order.")
                        if !optimizeOrder {
                            SewingOrderList()
                        } else {
                            Text("Turn this off to set the order shapes are sewn in yourself.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 400, height: 470)
            }
            HStack {
                Text("Each layer is one thread colour, sewn in layer order. The design is centred in the hoop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export \(format.fileExtension.uppercased())…") {
                    if model.exportEmbroidery(pattern, format: format) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.stitchCount == 0)
            }
        }
        .padding(16)
        .onChange(of: formatRaw) { _, _ in
            if !format.hoops.contains(where: { $0.name == hoopName }) {
                hoopName = format.hoops[min(1, format.hoops.count - 1)].name
            }
        }
        .onAppear {
            // Start with the hoop shown on the canvas, if there is one.
            if let w = model.document.workpiece, w.kind == .hoop, let h = EmbroideryHoop.all.first(where: { $0.name == w.name }) {
                if !format.hoops.contains(h) { formatRaw = (h.brand == "Janome" ? EmbroideryFormat.jef : .pes).rawValue }
                hoopName = h.name
            }
        }
    }

    @ViewBuilder
    private func summary(_ pattern: StitchPattern) -> some View {
        let size = pattern.size
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%.1f × %.1f mm", size.width, size.height)
                + " · \(pattern.stitchCount) stitches · \(pattern.threads.count) colour\(pattern.threads.count == 1 ? "" : "s")")
                .font(.callout.monospacedDigit())
            Text("About \(Int(max(1, pattern.estimatedMinutes().rounded()))) min to sew, \(pattern.trimCount) trims")
                .font(.caption)
                .foregroundStyle(.secondary)
            if pattern.stitchCount > 0 {
                if !hoop.fits(width: size.width, height: size.height) {
                    Label("Too big for this hoop. Scale the design down or pick a larger hoop.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !hoop.fitsUpright(width: size.width, height: size.height) {
                    Label("Fits only turned 90°. Rotate it on the machine or in the design.", systemImage: "rotate.right")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            threadList(pattern)
        }
    }

    @ViewBuilder
    private func threadList(_ pattern: StitchPattern) -> some View {
        let codes: [Int]? = {
            switch format {
            case .pes: return ThreadChart.brotherCodes(for: pattern.threads)
            case .jef: return ThreadChart.janomeCodes(for: pattern.threads)
            case .dst: return nil
            }
        }()
        ForEach(Array(pattern.threads.enumerated()), id: \.offset) { i, t in
            HStack(spacing: 6) {
                Text("\(i + 1).").font(.caption.monospacedDigit()).frame(width: 20, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2).fill(Color(thread: t)).frame(width: 12, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.5), lineWidth: 0.5))
                if let codes, let chart = format.threadChart, i < codes.count, let entry = chart[codes[i]] {
                    RoundedRectangle(cornerRadius: 2).fill(Color(thread: entry.color)).frame(width: 12, height: 12)
                        .help("Nearest thread in the machine's chart")
                    Text("\(entry.name) (\(format == .pes ? "Brother" : "Janome") \(entry.code))").font(.caption)
                } else {
                    Text(t.hex).font(.caption.monospaced())
                }
            }
        }
    }
}

/// Stitch type and its settings for one layer.
private struct EmbroideryLayerSettings: View {
    @EnvironmentObject var model: AppModel
    let layerID: UUID

    var body: some View {
        if let s = model.embroiderySettingsBinding(layerID), let layer = model.document.layer(layerID) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: layer.colorHex)).frame(width: 14, height: 14)
                    Text(layer.name).bold()
                }
                EmbroiderySettingsFields(settings: s)
            }
            .padding(.vertical, 2)
        }
    }
}

/// Stitch type and the settings that go with it, for a layer or a single shape.
struct EmbroiderySettingsFields: View {
    @Binding var settings: EmbroiderySettings

    var body: some View {
        let s = $settings
        Picker("Stitch", selection: s.stitchType) {
            ForEach(StitchType.allCases) { Text($0.title).tag($0) }
        }
        switch settings.stitchType {
        case .running, .bean:
            number("Stitch length (mm)", s.stitchLength)
        case .satin:
            number("Column width (mm)", s.satinWidth)
            number("Density (mm between stitches)", s.density)
            number("Pull compensation (mm)", s.pullCompensation)
            Toggle("Centre-run underlay", isOn: s.underlay)
        case .auto:
            number("Satin and fill density (mm)", s.density)
            number("Widest satin column (mm)", s.maxColumnWidth)
            number("Line stitch length (mm)", s.stitchLength)
            number("Fill angle (°)", s.fillAngle)
            number("Pull compensation (mm)", s.pullCompensation)
            Toggle("Underlay", isOn: s.underlay)
            caption("Narrow parts of filled shapes become satin columns that turn with the stroke, wide parts are filled, and lines are sewn by their width from the SVG (satin, triple or running). Areas are sewn first, lines on top.")
        case .satinColumns:
            number("Density (mm between stitches)", s.density)
            number("Widest column (mm)", s.maxColumnWidth)
            number("Pull compensation (mm)", s.pullCompensation)
            Toggle("Centre-run underlay", isOn: s.underlay)
            number("Fill angle for wide parts (°)", s.fillAngle)
            caption("Satin stitches cross each stroke and turn with it. Parts wider than the widest column are filled. Open lines are skipped.")
        case .fill:
            number("Row spacing (mm)", s.density)
            number("Angle (°)", s.fillAngle)
            number("Stitch length (mm)", s.fillStitchLength)
            number("Pull compensation (mm)", s.pullCompensation)
            Toggle("Underlay", isOn: s.underlay)
            caption("Fill sews the inside of closed shapes. Open lines are skipped.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2))).frame(width: 70)
        }
    }
}

/// The shapes in the order they are sewn, with buttons to move them and to edit their stitches.
private struct SewingOrderList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.embroideredLayers) { layer in
            let shapes = model.embroideryShapes(in: layer.id)
            ForEach(Array(shapes.enumerated()), id: \.element.id) { i, shape in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: layer.colorHex)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shape.name).lineLimit(1)
                        Text(shape.stitches != nil ? "Hand-edited stitches"
                             : (shape.embroidery ?? layer.embroiderySettings).stitchType.title + (shape.embroidery != nil ? " (own settings)" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.moveInSewingOrder(shape.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0)
                        .help("Sew earlier")
                    Button { model.moveInSewingOrder(shape.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(i == shapes.count - 1)
                        .help("Sew later")
                    Button { model.stitchEditorShapeID = shape.id; openWindow(id: "stitch-editor") } label: { Image(systemName: "pencil.and.outline") }
                        .help("Edit this shape's stitches by hand")
                }
                .buttonStyle(.borderless)
            }
        }
        Text("Layers sew top to bottom (reorder them in the Layers panel). Shapes sew in this order within their layer.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The stitches drawn in thread colours inside the hoop outline.
struct StitchPreview: View {
    let pattern: StitchPattern
    let hoop: EmbroideryHoop

    var body: some View {
        Canvas { ctx, size in
            let e = pattern.extent
            let spanX = max(Double(max(abs(e.minX), abs(e.maxX))) * 2, hoop.width * 10)
            let spanY = max(Double(max(abs(e.minY), abs(e.maxY))) * 2, hoop.height * 10)
            let scale = min(size.width / spanX, size.height / spanY) * 0.92
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            func pt(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: mid.x + Double(x) * scale, y: mid.y + Double(y) * scale) }

            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color(white: 0.93)))
            let hw = hoop.width * 10 * scale, hh = hoop.height * 10 * scale
            let hoopRect = CGRect(x: mid.x - hw / 2, y: mid.y - hh / 2, width: hw, height: hh)
            ctx.stroke(Path(roundedRect: hoopRect, cornerRadius: 10), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            var cross = Path()
            cross.move(to: CGPoint(x: mid.x - 6, y: mid.y))
            cross.addLine(to: CGPoint(x: mid.x + 6, y: mid.y))
            cross.move(to: CGPoint(x: mid.x, y: mid.y - 6))
            cross.addLine(to: CGPoint(x: mid.x, y: mid.y + 6))
            ctx.stroke(cross, with: .color(.gray.opacity(0.6)), lineWidth: 0.8)

            var colorIndex = 0
            var path = Path()
            var started = false
            var last = mid
            func flush() {
                guard colorIndex < pattern.threads.count, started else { return }
                ctx.stroke(path, with: .color(Color(thread: pattern.threads[colorIndex])), lineWidth: 0.8)
                path = Path()
                started = false
            }
            for en in pattern.entries {
                switch en.command {
                case .stitch:
                    let p = pt(en.x, en.y)
                    if !started {
                        path.move(to: last)
                        started = true
                    }
                    path.addLine(to: p)
                    last = p
                case .jump:
                    flush()
                    last = pt(en.x, en.y)
                case .colorChange:
                    flush()
                    colorIndex += 1
                default:
                    break
                }
            }
            flush()
        }
    }
}
