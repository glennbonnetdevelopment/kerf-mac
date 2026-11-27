import KerfCore
import SwiftUI

/// Rhinestone layout sheet: stone sizes, colours, spacing and fill pattern for the selection, with a live
/// preview and a stone count, then adds the template holes to the design.
struct RhinestoneView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var stones: [Stone] = []
    @State private var computedFor: LayoutKey?

    struct LayoutKey: Hashable, Sendable {
        var paths: [Polyline]
        var options: RhinestoneOptions
    }

    var body: some View {
        let paths = model.rhinestoneSourcePaths
        let key = LayoutKey(paths: paths, options: model.rhinestones)
        let upToDate = computedFor == key
        VStack(alignment: .leading, spacing: 12) {
            Text("Rhinestone Layout").font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    RhinestonePreview(paths: paths, stones: stones)
                        .frame(width: 340, height: 340)
                        .overlay(alignment: .topTrailing) {
                            if !upToDate && !paths.isEmpty {
                                ProgressView().controlSize(.small).padding(8)
                            }
                        }
                    summary
                }
                .frame(width: 340)
                Form {
                    if paths.isEmpty {
                        Section {
                            Text("Select the shapes or text to lay stones on, then open this again.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    outlineSection
                    fillSection
                    templateSection
                }
                .formStyle(.grouped)
                .frame(width: 410, height: 540)
            }
            HStack {
                Text("Each stone size and colour becomes its own layer and template. Undo removes the stones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(upToDate ? "\(stones.count) " : "")Stones") {
                    if model.addRhinestones(upToDate ? stones : nil) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(paths.isEmpty || (upToDate && stones.isEmpty))
            }
        }
        .padding(16)
        .task(id: key) {
            // Wait a moment so typing a number doesn't start a layout for every keystroke.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Rhinestone.cachedLayout(key.paths, options: key.options)
            }.value
            guard !Task.isCancelled else { return }
            stones = result
            computedFor = key
        }
    }

    // MARK: - Sections

    private var outlineSection: some View {
        Section("Outline") {
            Toggle("Stones along the outline", isOn: $model.rhinestones.outline)
            if model.rhinestones.outline {
                StoneChoice(title: "Stone", size: $model.rhinestones.outlineSize, color: $model.rhinestones.outlineColor)
                Picker("Position", selection: $model.rhinestones.outlinePosition) {
                    ForEach(RhinestoneOutlinePosition.allCases) { Text($0.title).tag($0) }
                }
                .help("Centred on the outline suits thin lettering and single lines")
                Stepper("Rows: \(model.rhinestones.outlineRows)", value: $model.rhinestones.outlineRows, in: 1...10)
                    .help("Extra rows go further in, each following the outline")
            }
        }
    }

    private var fillSection: some View {
        Section("Fill") {
            Picker("Pattern", selection: $model.rhinestones.fill) {
                ForEach(RhinestoneFill.allCases) { Text($0.title).tag($0) }
            }
            if model.rhinestones.fill != .none {
                StoneChoice(title: "Stone", size: $model.rhinestones.fillSize, color: $model.rhinestones.fillColor)
                if model.rhinestones.fill == .honeycomb || model.rhinestones.fill == .grid {
                    LabeledContent("Row angle (°)") {
                        TextField("", value: $model.rhinestones.fillAngle, format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 70)
                    }
                }
                Toggle("Fill gaps with smaller stones", isOn: $model.rhinestones.gapFill)
                    .help("After the fill, put smaller stones where the gaps near edges and corners are big enough")
                if model.rhinestones.gapFill {
                    StoneChoice(title: "Gap stone", size: $model.rhinestones.gapFillSize, color: $model.rhinestones.gapFillColor)
                }
            }
        }
    }

    private var templateSection: some View {
        Section("Template") {
            LabeledContent("Spacing (mm)") {
                TextField("", value: Binding(get: { model.rhinestones.spacing },
                                             set: { model.rhinestones.spacing = max(0, min(20, $0)) }),
                          format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 70)
            }
            .help("Space between neighbouring stones, edge to edge")
            LabeledContent("Hole clearance (mm)") {
                TextField("", value: Binding(get: { model.rhinestones.holeClearance },
                                             set: { model.rhinestones.holeClearance = max(0, min(2, $0)) }),
                          format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 70)
            }
            .help("How much wider than the stone each hole is cut, so stones drop in easily. 0.1 to 0.3 mm suits most flock.")
            if model.rhinestones.narrowestWeb < 0.3 {
                Label("Holes may run together. Use more spacing or less clearance.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Original artwork", selection: $model.rhinestones.original) {
                ForEach(RhinestoneOriginal.allCases) { Text($0.title).tag($0) }
            }
            Text("Holes go on \(model.rhinestoneHoleMode.title) layers for \(model.profile.name). Cut them in rhinestone template material (flock, sticky flex or rubber), brush the stones in, lift them with transfer tape and press.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summary: some View {
        let groups = Rhinestone.groups(stones)
        let b = stones.reduce(Rect2.empty) { r, s in
            r.union(Rect2(minX: s.center.x - s.radius, minY: s.center.y - s.radius,
                          maxX: s.center.x + s.radius, maxY: s.center.y + s.radius))
        }
        VStack(alignment: .leading, spacing: 4) {
            if stones.isEmpty {
                Text(model.rhinestoneSourcePaths.isEmpty ? "Nothing selected." : "No stones fit with these settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(stones.count) stones · " + String(format: "%.1f × %.1f mm", b.width, b.height))
                    .font(.callout.monospacedDigit())
                ForEach(groups) { g in
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: g.color.hex)).frame(width: 10, height: 10)
                        Text("\(g.size.title) \(g.color.name)")
                        Spacer()
                        Text("\(g.stones.count)").monospacedDigit()
                    }
                    .font(.caption)
                }
                if stones.count >= Rhinestone.maxStones {
                    Label("Stopped at \(Rhinestone.maxStones) stones.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

/// A stone size picker and a stone colour picker on one row.
private struct StoneChoice: View {
    let title: String
    @Binding var size: StoneSize
    @Binding var color: StoneColor

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Picker("Size", selection: $size) {
                    if !StoneSize.all.contains(size) { Text(size.title).tag(size) }
                    ForEach(StoneSize.all) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                Circle()
                    .fill(Color(hex: color.hex))
                    .overlay(Circle().stroke(.secondary.opacity(0.6), lineWidth: 0.5))
                    .frame(width: 12, height: 12)
                Picker("Colour", selection: $color) {
                    if !StoneColor.palette.contains(color) { Text(color.name).tag(color) }
                    ForEach(StoneColor.palette) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
    }
}

/// The selected outlines in grey with the stones drawn as coloured dots.
struct RhinestonePreview: View {
    let paths: [Polyline]
    let stones: [Stone]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color(white: 0.95)))
            var b = paths.bounds
            for s in stones {
                b.include(s.center - Vec2(s.radius, s.radius))
                b.include(s.center + Vec2(s.radius, s.radius))
            }
            guard !b.isEmpty else { return }
            let scale = min(size.width / max(b.width, 1), size.height / max(b.height, 1)) * 0.9
            let ox = (size.width - b.width * scale) / 2 - b.minX * scale
            let oy = (size.height - b.height * scale) / 2 - b.minY * scale
            func pt(_ p: Vec2) -> CGPoint { CGPoint(x: ox + p.x * scale, y: oy + p.y * scale) }

            var outline = Path()
            for p in paths {
                let pts = p.drawnPoints
                guard let first = pts.first else { continue }
                outline.move(to: pt(first))
                for q in pts.dropFirst() { outline.addLine(to: pt(q)) }
            }
            ctx.stroke(outline, with: .color(.gray.opacity(0.7)), lineWidth: 0.8)

            for group in Rhinestone.groups(stones) {
                var dots = Path()
                for s in group.stones {
                    let c = pt(s.center), r = s.radius * scale
                    dots.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                }
                ctx.fill(dots, with: .color(Color(hex: group.color.hex)))
                ctx.stroke(dots, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
            }
        }
    }
}
