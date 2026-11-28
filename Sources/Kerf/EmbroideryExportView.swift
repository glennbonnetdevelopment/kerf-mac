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
    @AppStorage("embroideryMultiHoop") private var multiHoopOn = false
    /// The hooping shown in the preview when the design is split, or nil for the whole design.
    @State private var shownHooping: Int?

    private var format: EmbroideryFormat { EmbroideryFormat(rawValue: formatRaw) ?? .pes }

    private var hoop: EmbroideryHoop {
        let hoops = format.hoops
        return hoops.first { $0.name == hoopName } ?? hoops[min(1, hoops.count - 1)]
    }

    var body: some View {
        let (plan, pattern) = model.embroideryPlanAndPattern(groupColors: groupColors, optimizeOrder: optimizeOrder)
        let layout = multiHoopOn ? MultiHoop.split(plan, hoop: hoop, options: model.multiHoop) : nil
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Embroidery").font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    if let layout {
                        multiHoopPreview(layout, plan: plan)
                    } else {
                        StitchPreview(pattern: pattern, hoop: hoop)
                            .frame(width: 320, height: 320)
                    }
                    summary(pattern)
                    if let layout { multiHoopSummary(layout) }
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
                    Section("Multi-hooping") {
                        Toggle("Split across several hoopings", isOn: $multiHoopOn)
                            .help("Sew a design bigger than the hoop in parts, re-hooping between them, with alignment marks in the overlaps")
                        if multiHoopOn {
                            MultiHoopSettings()
                        }
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
                Text(multiHoopOn
                     ? "Each hooping is its own file, centred in the hoop, with a hooping guide beside them."
                     : "Each layer is one thread colour, sewn in layer order. The design is centred in the hoop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let layout {
                    let n = layout.sewnHoopings.count
                    Button("Export \(n) \(format.fileExtension.uppercased()) File\(n == 1 ? "" : "s")…") {
                        if model.exportMultiHoop(layout, format: format, hoop: hoop) { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pattern.stitchCount == 0)
                } else {
                    Button("Export \(format.fileExtension.uppercased())…") {
                        if model.exportEmbroidery(pattern, format: format) { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pattern.stitchCount == 0)
                }
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
                if multiHoopOn {
                    EmptyView()
                } else if !hoop.fits(width: size.width, height: size.height) {
                    Label("Too big for this hoop. Scale the design down, pick a larger hoop, or turn on Split across several hoopings.",
                          systemImage: "exclamationmark.triangle.fill")
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

    /// The whole design with the hoopings over it, or one hooping's stitches in the hoop.
    @ViewBuilder
    private func multiHoopPreview(_ layout: MultiHoopLayout, plan: EmbroideryPlan) -> some View {
        let sewn = layout.sewnHoopings
        let shown = shownHooping.flatMap { i in sewn.first { $0.index == i } }
        if let h = shown {
            let turnedHoop = EmbroideryHoop(hoop.name, brand: hoop.brand, width: layout.hoopWidth + 2 * model.multiHoop.margin,
                                            height: layout.hoopHeight + 2 * model.multiHoop.margin)
            StitchPreview(pattern: MultiHoop.pattern(h, name: model.embroideryDesignName), hoop: turnedHoop)
                .frame(width: 320, height: 290)
        } else {
            MultiHoopOverview(layout: layout, plan: plan)
                .frame(width: 320, height: 290)
        }
        Picker("Show", selection: $shownHooping) {
            Text("Whole design").tag(Int?.none)
            ForEach(Array(sewn.enumerated()), id: \.element.index) { k, h in
                Text("Hooping \(k + 1)").tag(Int?.some(h.index))
            }
        }
        .labelsHidden()
        .onChange(of: layout.count) { _, _ in shownHooping = nil }
    }

    @ViewBuilder
    private func multiHoopSummary(_ layout: MultiHoopLayout) -> some View {
        let sewn = layout.sewnHoopings
        VStack(alignment: .leading, spacing: 2) {
            Text("\(sewn.count) hooping\(sewn.count == 1 ? "" : "s") (\(layout.columns) × \(layout.rows))\(layout.turned ? ", hoop turned 90°" : "")")
                .font(.callout.bold())
            if sewn.count == 1 {
                Text("The design fits one hooping, so there is nothing to split.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let h = shownHooping.flatMap({ i in sewn.first { $0.index == i } }) {
                let p = MultiHoop.pattern(h, name: "")
                Text("\(p.stitchCount) stitches, \(p.threads.count) colours (alignment marks and basting included)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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


/// Overlap, margin, hoop direction and the alignment marks for splitting a design across hoopings.
private struct MultiHoopSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let o = $model.multiHoop
        LabeledContent("Overlap (mm)") {
            TextField("", value: o.overlap, format: .number.precision(.fractionLength(0...1))).frame(width: 70)
        }
        .help("How far neighbouring hoopings reach into each other. The seam runs down the middle.")
        LabeledContent("Margin inside hoop (mm)") {
            TextField("", value: o.margin, format: .number.precision(.fractionLength(0...1))).frame(width: 70)
        }
        .help("Keeps stitches this far in from the edge of the hoop's sewing area")
        Picker("Hoop direction", selection: o.orientation) {
            ForEach(HoopOrientation.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Alignment marks", isOn: o.alignmentMarks)
            .help("Small crosses in each overlap, sewn first in their own colour, to line up the next hooping")
        if model.multiHoop.alignmentMarks {
            LabeledContent("Mark size (mm)") {
                TextField("", value: o.markSize, format: .number.precision(.fractionLength(0...1))).frame(width: 70)
            }
        }
        Toggle("Baste each hooping", isOn: o.basting)
            .help("A long running-stitch box around each hooping's area, sewn first, to hold fabric and stabiliser together")
        Text("Shapes that fit in one hooping are sewn whole there; bigger ones are cut at the seams. Each part starts with its alignment crosses: in later hoopings, line the needle up with the crosses already sewn before sewing on.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The whole design in thread colours, with each hooping's area and number drawn over it.
struct MultiHoopOverview: View {
    let layout: MultiHoopLayout
    let plan: EmbroideryPlan

    var body: some View {
        Canvas { ctx, size in
            var all = layout.designBounds
            for h in layout.hoopings { all = all.union(h.area) }
            guard !all.isEmpty, all.width > 0, all.height > 0 else { return }
            let scale = min(size.width / all.width, size.height / all.height) * 0.94
            let ox = (size.width - all.width * scale) / 2 - all.minX * scale
            let oy = (size.height - all.height * scale) / 2 - all.minY * scale
            func pt(_ p: Vec2) -> CGPoint { CGPoint(x: ox + p.x * scale, y: oy + p.y * scale) }
            func rect(_ r: Rect2) -> CGRect {
                CGRect(x: ox + r.minX * scale, y: oy + r.minY * scale, width: r.width * scale, height: r.height * scale)
            }

            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color(white: 0.93)))
            for block in plan.blocks {
                var path = Path()
                for run in block.runs where run.count >= 2 {
                    path.move(to: pt(run[0]))
                    for p in run.dropFirst() { path.addLine(to: pt(p)) }
                }
                ctx.stroke(path, with: .color(Color(thread: block.color)), lineWidth: 0.7)
            }
            let sewn = layout.sewnHoopings
            for h in layout.hoopings {
                let isSewn = sewn.contains { $0.index == h.index }
                let r = rect(h.area)
                ctx.fill(Path(r), with: .color(.accentColor.opacity(isSewn ? 0.05 : 0)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(isSewn ? .accentColor : .gray.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                if let k = sewn.firstIndex(where: { $0.index == h.index }) {
                    ctx.draw(Text("\(k + 1)").font(.system(size: 13, weight: .bold)).foregroundColor(.accentColor),
                             at: CGPoint(x: r.minX + 10, y: r.minY + 10))
                }
                for m in h.marks {
                    let c = pt(m), a: CGFloat = 4
                    var cross = Path()
                    cross.move(to: CGPoint(x: c.x - a, y: c.y))
                    cross.addLine(to: CGPoint(x: c.x + a, y: c.y))
                    cross.move(to: CGPoint(x: c.x, y: c.y - a))
                    cross.addLine(to: CGPoint(x: c.x, y: c.y + a))
                    ctx.stroke(cross, with: .color(Color(thread: MultiHoop.markColor)), lineWidth: 1.2)
                }
            }
        }
    }
}
