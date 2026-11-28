import KerfCore
import SwiftUI

/// Embroidered patch sheet: the patch shape, border, background and cut lines, with a stitch preview,
/// then adds the patch's layers around the selected design.
struct PatchView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = StitchPattern(entries: [], threads: [], name: "")
    @State private var parts: [PatchPart] = []
    @State private var problem: String?
    @State private var computedFor: PreviewKey?

    struct PreviewKey: Hashable {
        var options: PatchOptions
        var selection: Set<UUID>
        var document: KerfDocument
    }

    private var hasDesign: Bool { !model.patchDesign.isEmpty }

    var body: some View {
        let key = PreviewKey(options: model.patch.sanitized, selection: model.selection, document: model.document)
        VStack(alignment: .leading, spacing: 12) {
            Text("Embroidered Patch").font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    StitchPreview(pattern: pattern, hoop: hoop)
                        .frame(width: 320, height: 320)
                        .overlay(alignment: .topTrailing) {
                            if computedFor != key { ProgressView().controlSize(.small).padding(8) }
                        }
                    summary
                }
                .frame(width: 320)
                Form {
                    shapeSection
                    borderSection
                    backgroundSection
                    cutSection
                }
                .formStyle(.grouped)
                .frame(width: 410, height: 540)
            }
            HStack {
                Text("Sewing layers are embroidery only, cut lines go to the laser or cutter. Undo removes the patch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Patch") {
                    if model.addPatch() { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(computedFor == key && parts.isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            if !hasDesign && model.patch.shape != .contour { model.patch.sizeToDesign = false }
        }
        .task(id: key) {
            // Wait a moment so typing a number doesn't redigitize for every keystroke.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let result = model.patchPreview(key.options)
            pattern = result.pattern
            parts = result.parts
            problem = result.problem
            computedFor = key
        }
    }

    /// The hoop on the canvas, or the smallest one the patch fits in.
    private var hoop: EmbroideryHoop {
        if let w = model.document.workpiece, w.kind == .hoop, let h = EmbroideryHoop.all.first(where: { $0.name == w.name }) {
            return h
        }
        let size = pattern.size
        return EmbroideryHoop.brother.first { $0.fits(width: size.width, height: size.height) } ?? EmbroideryHoop.brother[EmbroideryHoop.brother.count - 1]
    }

    // MARK: - Summary

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let edge = parts.first(where: { !$0.kind.isCut })?.paths.first ?? parts.first?.paths.first {
                let b = patchBounds(edge)
                Text(String(format: "Patch %.1f × %.1f mm (%.2f × %.2f in)", b.width, b.height, b.width / 25.4, b.height / 25.4))
                    .font(.callout.monospacedDigit())
            }
            if pattern.stitchCount > 0 {
                Text("\(pattern.stitchCount) stitches · about \(Int(max(1, pattern.estimatedMinutes().rounded()))) min · \(stopCount) stop\(stopCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let size = pattern.size
                if !hoop.fits(width: size.width, height: size.height) {
                    Label("Too big for the \(hoop.name) hoop.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Fits the \(hoop.name) hoop.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: part.layer.colorHex)).frame(width: 10, height: 10)
                    Text(partLine(part)).font(.caption)
                }
            }
        }
    }

    /// The finished size: the outer edge is the border's middle grown by half the border.
    private func patchBounds(_ path: Polyline) -> Rect2 {
        let o = model.patch.sanitized
        if let border = parts.first(where: { $0.kind == .border })?.paths.first {
            return border.bounds.insetBy(-o.borderReach / 2)
        }
        return path.bounds
    }

    /// Colour changes the machine stops at, including the appliqué stops.
    private var stopCount: Int { pattern.colorChangeCount }

    private func partLine(_ part: PatchPart) -> String {
        switch part.kind {
        case .placement: return "Placement line, then stop: lay the fabric"
        case .tackdown: return model.patch.cutFabricPiece ? "Tackdown, then stop" : "Tackdown, then stop: trim the fabric"
        case .backingFill: return "Background fill"
        case .border: return model.patch.border == .satin ? "Satin border" : "Border line"
        case .fabricCut: return "Fabric piece: cut on the \(model.profile.kind.title.lowercased()) first"
        case .outerCut: return "Cut-out line: cut the patch free after sewing"
        }
    }

    // MARK: - Sections

    private var shapeSection: some View {
        Section("Shape") {
            Picker("Shape", selection: $model.patch.shape) {
                ForEach(PatchShape.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            if model.patch.shape != .contour {
                Toggle("Size around the selected design", isOn: $model.patch.sizeToDesign)
                    .disabled(!hasDesign)
            }
            if model.patch.sizeToDesign || model.patch.shape == .contour {
                number("Space around the design (mm)", $model.patch.margin)
                if !hasDesign {
                    caption("Select the design first, then open this again.")
                }
            } else {
                number(model.patch.shape == .circle ? "Diameter (mm)" : "Width (mm)", $model.patch.width)
                if model.patch.shape != .circle {
                    number("Height (mm)", $model.patch.height)
                }
                caption(hasDesign ? "Centred on the selected design." : "Centred on the bed or workpiece.")
            }
            if model.patch.shape == .roundedRectangle {
                number("Corner radius (mm)", $model.patch.cornerRadius)
            }
        }
    }

    private var borderSection: some View {
        Section("Border") {
            Picker("Edge", selection: $model.patch.border) {
                ForEach(PatchBorder.allCases) { Text($0.title).tag($0) }
            }
            if model.patch.border != .none {
                color("Thread", $model.patch.borderColorHex)
            }
            if model.patch.border == .satin {
                number("Width (mm)", $model.patch.borderWidth)
                number("Density (mm between stitches)", $model.patch.borderDensity)
                caption("3 to 5 mm with 0.3 to 0.4 mm density gives a full, merrowed-looking edge. Sewn last, over everything else.")
            }
        }
    }

    private var backgroundSection: some View {
        Section("Background") {
            Picker("Background", selection: $model.patch.backing) {
                ForEach(PatchBacking.allCases) { Text($0.title).tag($0) }
            }
            switch model.patch.backing {
            case .fabric:
                color("Fabric colour", $model.patch.backgroundColorHex)
                Toggle("Placement line", isOn: $model.patch.placementLine)
                caption("The machine sews the placement line and stops so you can lay the fabric over it, then tacks it down and stops again so you can trim close to the tackdown. The design and border sew on top.")
            case .fill:
                color("Thread", $model.patch.backgroundColorHex)
                number("Row spacing (mm)", $model.patch.fillDensity)
                number("Angle (°)", $model.patch.fillAngle)
                caption("Fill stitches cover the whole patch and run under the border. Dense fills are stiff and slow; 0.4 to 0.5 mm suits most patches.")
            case .none:
                caption("The hooped fabric is the patch background.")
            }
        }
    }

    private var cutSection: some View {
        Section("Cut lines") {
            if model.patch.backing == .fabric {
                Toggle("Cut the fabric piece to shape", isOn: $model.patch.cutFabricPiece)
                    .help("A line for the laser or cutter to cut the patch fabric before sewing, so there's nothing to trim after the tackdown")
            }
            Toggle("Cut out the finished patch", isOn: $model.patch.cutOutPatch)
                .help("A line just outside the border to cut the patch free after sewing")
            if model.patch.cutOutPatch {
                number("Gap outside the border (mm)", $model.patch.cutOffset)
            }
            if model.patch.hasCutLine {
                Toggle("Keep the design off the laser and cutter", isOn: $model.patch.designSewnOnly)
                    .help("Set the design's layers to embroidery only, so the machine cuts just the patch lines")
                caption("Cut lines go on their own layers for the current machine (\(model.profile.kind.title.lowercased())) and are never sewn. A laser seals polyester twill as it cuts; test the power on a scrap first.")
            }
        }
    }

    // MARK: - Fields

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2))).frame(width: 70)
        }
    }

    private func color(_ title: String, _ hex: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(hex: hex.wrappedValue) }, set: { hex.wrappedValue = $0.hexString }),
                    supportsOpacity: false)
    }
}
