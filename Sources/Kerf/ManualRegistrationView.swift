import SwiftUI
import KerfCore

/// Machine › Print and cut › Manual registration: move the cutter head from the software until the laser pointer
/// (or blade tip) is on each printed mark, confirm it, and the cut is fitted to the marks.
struct ManualRegistrationView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cutter: CutterSender
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual registration").font(.title2.bold())
            Text("Load the printed sheet, lower the pinch rollers and press Origin Set on the cutter with the head near mark 1. Then move the pointer onto each mark here and confirm it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.canJogCutter {
                Text("This machine has no live connection, so the head can't be moved from KerfKutter.")
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    moveBox
                    pointerBox
                }
                .frame(width: 300)
                VStack(alignment: .leading, spacing: 12) {
                    marksBox
                    preview
                }
                .frame(minWidth: 340)
            }
            .disabled(!model.canJogCutter)
            HStack {
                if !cutter.message.isEmpty {
                    Text(cutter.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard model.canJogCutter else { return .ignored }
            let dir: Vec2
            switch press.key {
            case .upArrow: dir = Vec2(0, -1)
            case .downArrow: dir = Vec2(0, 1)
            case .leftArrow: dir = Vec2(-1, 0)
            default: dir = Vec2(1, 0)
            }
            model.jogCutter(dir, multiplier: press.modifiers.contains(.shift) ? 10 : 1, with: cutter)
            return .handled
        }
    }

    // MARK: Moving the head

    private var moveBox: some View {
        GroupBox("Move the head") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    jogPad
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "Pointer  X %.2f  Y %.2f", model.cutterPointer.x, model.cutterPointer.y))
                        Text(String(format: "Blade    X %.2f  Y %.2f", model.cutterHead.x, model.cutterHead.y))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                }
                Picker("Step", selection: $model.cutterJogStep) {
                    ForEach(ManualRegistration.stepSizes, id: \.self) { Text(stepTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Arrow keys move one step, Shift-arrow ten. Directions follow the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("I pressed Origin Set (head is at 0, 0)") { model.cutterHead = .zero }
                    .help("KerfKutter can't read the head position back, so tell it when the cutter's origin is where the head is")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stepTitle(_ s: Double) -> String {
        s < 1 ? String(format: "%.1f", s) : String(format: "%.0f", s)
    }

    private var jogPad: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                jogButton("arrow.up.left", Vec2(-1, -1))
                jogButton("arrow.up", Vec2(0, -1))
                jogButton("arrow.up.right", Vec2(1, -1))
            }
            GridRow {
                jogButton("arrow.left", Vec2(-1, 0))
                Button { model.moveCutterHead(to: .zero, with: cutter) } label: {
                    Image(systemName: "scope").frame(width: 26, height: 22)
                }
                .help("Move the blade back to the origin")
                jogButton("arrow.right", Vec2(1, 0))
            }
            GridRow {
                jogButton("arrow.down.left", Vec2(-1, 1))
                jogButton("arrow.down", Vec2(0, 1))
                jogButton("arrow.down.right", Vec2(1, 1))
            }
        }
    }

    private func jogButton(_ symbol: String, _ dir: Vec2) -> some View {
        Button { model.jogCutter(dir, with: cutter) } label: {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
    }

    // MARK: Laser pointer

    private var pointerBox: some View {
        GroupBox("Laser pointer") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Sight marks with the laser pointer", isOn: profileBinding(\.hasLaserPointer))
                if model.profile.hasLaserPointer {
                    HStack {
                        Text("Offset from blade (mm)")
                        Spacer()
                        Text("X")
                        TextField("", value: profileBinding(\.laserOffsetX), format: .number).frame(width: 55)
                        Text("Y")
                        TextField("", value: profileBinding(\.laserOffsetY), format: .number).frame(width: 55)
                    }
                    if model.laserCalibrationCross == nil {
                        Button("Calibrate offset…") { model.cutLaserCalibrationCross(with: cutter) }
                            .help("Cuts a small cross with the blade where the head is. Use scrap vinyl.")
                        Text("On scrap vinyl, Calibrate cuts a 6 mm cross with the blade. You then move the laser dot onto it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Move the head until the laser dot is on the centre of the cross.")
                            .font(.caption)
                        HStack {
                            Button("The dot is on the cross") { model.finishLaserCalibration() }
                                .buttonStyle(.borderedProminent)
                            Button("Cancel") { model.laserCalibrationCross = nil }
                        }
                    }
                } else {
                    Text("Without a pointer, lower the blade holder gently and sight the marks with the blade tip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Marks

    private var marksBox: some View {
        GroupBox("Marks") {
            VStack(alignment: .leading, spacing: 6) {
                let count = model.manualRegistrationDesign.count
                if count == 0 {
                    Text("Add registration marks first (any style, including GCC AAS L marks). Each mark's registration point is its centre, or the outside corner of an L.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(0..<count, id: \.self) { i in markRow(i) }
                    Divider()
                    fitSummary
                    HStack {
                        Toggle("Align the cut to these marks", isOn: $model.useManualRegistration)
                            .disabled(model.manualRegistrationFit == nil)
                        Spacer()
                        Button("Clear") { model.clearManualMarks() }
                            .disabled(model.manualMarks.isEmpty)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markRow(_ i: Int) -> some View {
        HStack {
            Image(systemName: model.manualMarks[i] == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(model.manualMarks[i] == nil ? Color.secondary : Color.green)
            Text("Mark \(i + 1)")
            if let p = model.manualMarks[i] {
                Text(String(format: "%.2f, %.2f", p.x, p.y)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Go to") { model.goToMark(i, with: cutter) }
                .help(model.manualMarks.isEmpty ? "Moves the pointer to where the mark is if the origin was set on mark 1"
                                                : "Moves the pointer to where the mark should be, from the marks confirmed so far")
            Button("Pointer is on mark") { model.confirmMark(i, with: cutter) }
        }
    }

    @ViewBuilder private var fitSummary: some View {
        let n = model.manualMarks.count
        if let t = model.manualRegistrationFit {
            let s = ManualRegistration.axisScales(t)
            Group {
                if n == 1 {
                    Text("One mark moves the cut only. Confirm a second to correct rotation, three or more for stretch and skew.")
                } else {
                    Text(String(format: "Rotation %.2f°, stretch X %.3f%%, Y %.3f%%", t.rotationAngle * 180 / .pi,
                                (s.x - 1) * 100, (s.y - 1) * 100))
                    if n >= 3 {
                        Text(String(format: "Marks agree to within %.2f mm.", model.manualRegistrationResidual))
                            .foregroundStyle(model.manualRegistrationResidual > 0.5 ? .orange : .secondary)
                    }
                }
            }
            .font(.caption)
            if abs(s.x - 1) > 0.02 || abs(s.y - 1) > 0.02 {
                Text("That's more than 2% stretch. Check the sheet printed at 100% and each mark was confirmed on the right mark.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Confirm at least two marks; three or four also correct stretch and skew.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Preview

    /// The marks as laid out in the design, with the pointer drawn where it is on the sheet.
    private var preview: some View {
        let design = model.allRegistrationPoints
        let fit = model.manualRegistrationFit
        let profile = model.profile
        let pointer = model.cutterPointer
        let origin = model.manualRegistrationDesign.first
        return Canvas { ctx, size in
            var r = Rect2.empty
            for p in design { r.include(p) }
            guard !r.isEmpty else { return }
            let pad = 18.0
            let scale = min((size.width - 2 * pad) / max(1, r.width), (size.height - 2 * pad) / max(1, r.height))
            func v(_ p: Vec2) -> CGPoint {
                CGPoint(x: pad + (p.x - r.minX) * scale + (size.width - 2 * pad - r.width * scale) / 2,
                        y: pad + (p.y - r.minY) * scale + (size.height - 2 * pad - r.height * scale) / 2)
            }
            ctx.stroke(Path(CGRect(origin: v(Vec2(r.minX, r.minY)), size: CGSize(width: r.width * scale, height: r.height * scale))),
                       with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            for (i, p) in design.enumerated() {
                let c = v(p)
                let done = model.manualMarks[i] != nil
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                         with: .color(done ? .green : .secondary))
                ctx.draw(Text("\(i + 1)").font(.caption2), at: CGPoint(x: c.x, y: c.y - 12))
            }
            // Pointer on the sheet: back through the fit, or relative to mark 1 before any mark is confirmed.
            let sheetMachine: Vec2? = fit.map { $0.inverted.apply(pointer) } ?? origin.map { pointer + $0 }
            if let m = sheetMachine {
                let c = v(profile.fromMachine(m))
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - 8, y: c.y))
                cross.addLine(to: CGPoint(x: c.x + 8, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - 8))
                cross.addLine(to: CGPoint(x: c.x, y: c.y + 8))
                ctx.stroke(cross, with: .color(.red), lineWidth: 1.5)
            }
        }
        .frame(height: 170)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
    }

    private func profileBinding<T>(_ keyPath: WritableKeyPath<DeviceProfile, T>) -> Binding<T> {
        Binding(get: { model.profile[keyPath: keyPath] }, set: { model.profile[keyPath: keyPath] = $0 })
    }
}
