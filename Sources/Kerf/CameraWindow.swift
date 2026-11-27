import AppKit
import KerfCore
import SwiftUI

enum CameraStep: String, CaseIterable, Identifiable {
    case lens = "Lens", align = "Alignment", overlay = "Overlay"
    var id: String { rawValue }
}

/// Window › Camera: pick the camera, calibrate its lens, align it to the bed, and control the canvas overlay.
struct CameraWindowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraController
    @AppStorage("cameraStep") private var step: CameraStep = .lens

    var body: some View {
        HSplitView {
            CameraPicturePane(feed: camera.feed, step: step)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                CameraPickerRow()
                Picker("", selection: $step) {
                    ForEach(CameraStep.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ScrollView {
                    Group {
                        switch step {
                        case .lens: LensCalibrationPanel(feed: camera.feed)
                        case .align: BedAlignmentPanel()
                        case .overlay: CameraOverlayPanel(overlay: camera.overlay)
                        }
                    }
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !camera.message.isEmpty {
                    Text(camera.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(minWidth: 320, idealWidth: 350, maxWidth: 440, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            camera.feed.isShown = true
            camera.start()
        }
        .onDisappear {
            camera.feed.isShown = false
            camera.stopIfIdle()
        }
    }
}

// MARK: - Camera picker

private struct CameraPickerRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Camera", selection: $camera.selectedID) {
                    if camera.devices.isEmpty { Text("No cameras").tag("") }
                    ForEach(camera.devices) { Text($0.name).tag($0.id) }
                }
                Button { camera.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Look for cameras again")
                Button(camera.isRunning ? "Stop" : "Start") {
                    if camera.isRunning { camera.stop() } else { camera.start() }
                }
                .disabled(camera.devices.isEmpty)
            }
            let setup = camera.setup
            HStack(spacing: 12) {
                status(setup.lens != nil, setup.lens.map { String(format: "Lens calibrated (%.2f px)", $0.rmsError) } ?? "Lens not calibrated")
                status(camera.isAligned(to: model.profile),
                       setup.alignment == nil ? "Not aligned"
                           : (camera.isAligned(to: model.profile) ? String(format: "Aligned (%.2f mm)", setup.alignment!.rmsError)
                                                                   : "Aligned on another machine"))
            }
            .font(.caption)
            if let s = camera.frameSize {
                Text("Picture \(Int(s.width)) × \(Int(s.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}

// MARK: - Picture

/// Fits a picture into a view (aspect fit) and converts between the two. Pixel centres are whole numbers.
private struct PictureFit {
    var scale: CGFloat
    var origin: CGPoint
    var imageSize: CGSize

    init(view: CGSize, image: CGSize) {
        imageSize = image
        scale = max(1e-6, min(view.width / max(1, image.width), view.height / max(1, image.height)))
        origin = CGPoint(x: (view.width - image.width * scale) / 2, y: (view.height - image.height * scale) / 2)
    }

    var rect: CGRect { CGRect(x: origin.x, y: origin.y, width: imageSize.width * scale, height: imageSize.height * scale) }

    func toView(_ p: Vec2) -> CGPoint {
        CGPoint(x: origin.x + (p.x + 0.5) * scale, y: origin.y + (p.y + 0.5) * scale)
    }

    func toImage(_ v: CGPoint) -> Vec2 {
        Vec2(Double((v.x - origin.x) / scale) - 0.5, Double((v.y - origin.y) / scale) - 0.5)
    }
}

private struct CameraPicturePane: View {
    @ObservedObject var feed: CameraFeed
    @EnvironmentObject var camera: CameraController
    let step: CameraStep
    @State private var hover: CGPoint?

    private var frozen: Bool { step == .align && camera.alignmentImage != nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = frozen ? camera.alignmentImage : feed.image {
                    let fit = PictureFit(view: geo.size, image: CGSize(width: image.width, height: image.height))
                    Canvas { ctx, size in
                        ctx.draw(Image(decorative: image, scale: 1), in: fit.rect)
                        drawMarks(&ctx, fit: fit)
                        if frozen, let h = hover, fit.rect.contains(h) {
                            drawLoupe(&ctx, image: image, fit: fit, at: h, size: size)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = p
                        case .ended: hover = nil
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard frozen, fit.rect.contains(location) else { return }
                        camera.clickMark(at: fit.toImage(location), snap: !NSEvent.modifierFlags.contains(.option))
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash").font(.largeTitle)
                        Text(camera.isRunning ? "Waiting for the camera…" : "Camera off")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .top) { banner }
        }
    }

    @ViewBuilder private var banner: some View {
        if frozen {
            let n = camera.alignmentPick
            Text(n < camera.alignmentClicks.count ? "Click the centre of mark \(n + 1)  (hold Option to place it exactly)"
                                                  : "All marks clicked. Save the alignment, or click a number to redo one.")
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        } else if step == .lens, camera.lastDetection != nil, !feed.straighten {
            Text("Corners found")
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        }
    }

    private func drawMarks(_ ctx: inout GraphicsContext, fit: PictureFit) {
        if step == .lens, !feed.straighten, let view = camera.lastDetection,
           view.imageWidth == Int(fit.imageSize.width), view.imageHeight == Int(fit.imageSize.height) {
            var line = Path()
            for (k, p) in view.imagePoints.enumerated() {
                let v = fit.toView(p)
                if k == 0 || view.boardPoints[k].x == 0 { line.move(to: v) } else { line.addLine(to: v) }
            }
            ctx.stroke(line, with: .color(.green.opacity(0.8)), lineWidth: 1.5)
            for (k, p) in view.imagePoints.enumerated() {
                let v = fit.toView(p)
                ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)),
                           with: .color(k == 0 ? .red : .green), lineWidth: 1.5)
            }
        }
        if frozen {
            for (i, click) in camera.alignmentClicks.enumerated() {
                guard let p = click else { continue }
                let v = fit.toView(p)
                var cross = Path()
                cross.move(to: CGPoint(x: v.x - 9, y: v.y)); cross.addLine(to: CGPoint(x: v.x + 9, y: v.y))
                cross.move(to: CGPoint(x: v.x, y: v.y - 9)); cross.addLine(to: CGPoint(x: v.x, y: v.y + 9))
                ctx.stroke(cross, with: .color(.black.opacity(0.6)), lineWidth: 3)
                ctx.stroke(cross, with: .color(.yellow), lineWidth: 1.5)
                ctx.draw(Text("\(i + 1)").font(.caption.bold()).foregroundColor(.yellow),
                         at: CGPoint(x: v.x + 8, y: v.y - 8), anchor: .bottomLeading)
            }
        }
    }

    /// A 4× magnified view around the pointer, for clicking mark centres precisely.
    private func drawLoupe(_ ctx: inout GraphicsContext, image: CGImage, fit: PictureFit, at h: CGPoint, size: CGSize) {
        let side: CGFloat = 200, zoom: CGFloat = 4
        var box = CGRect(x: size.width - side - 12, y: 44, width: side, height: side)
        if box.insetBy(dx: -20, dy: -20).contains(h) { box.origin.x = 12 }
        let p = fit.toImage(h)
        let z = fit.scale * zoom
        var l = ctx
        l.clip(to: Path(box))
        l.fill(Path(box), with: .color(.black))
        let origin = CGPoint(x: box.midX - (p.x + 0.5) * z, y: box.midY - (p.y + 0.5) * z)
        l.draw(Image(decorative: image, scale: 1).interpolation(.none),
               in: CGRect(x: origin.x, y: origin.y, width: CGFloat(image.width) * z, height: CGFloat(image.height) * z))
        for click in camera.alignmentClicks {
            guard let c = click else { continue }
            let v = CGPoint(x: origin.x + (c.x + 0.5) * z, y: origin.y + (c.y + 0.5) * z)
            l.stroke(Path(ellipseIn: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)), with: .color(.yellow), lineWidth: 1.5)
        }
        var cross = Path()
        cross.move(to: CGPoint(x: box.midX - 14, y: box.midY)); cross.addLine(to: CGPoint(x: box.midX + 14, y: box.midY))
        cross.move(to: CGPoint(x: box.midX, y: box.midY - 14)); cross.addLine(to: CGPoint(x: box.midX, y: box.midY + 14))
        l.stroke(cross, with: .color(.red), lineWidth: 1)
        ctx.stroke(Path(box), with: .color(.white), lineWidth: 1.5)
    }
}

// MARK: - Lens

private struct LensCalibrationPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraController
    @ObservedObject var feed: CameraFeed
    @AppStorage("cameraBoardSquare") private var square = 15.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wide camera lenses bend straight lines. Calibrating the lens once removes that, so the picture lines up across the whole bed. Skip it if your camera's picture already looks straight.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("1. Checkerboard") {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Inner corners across: \(camera.boardColumns)", value: $camera.boardColumns, in: 3...20)
                    Stepper("Inner corners down: \(camera.boardRows)", value: $camera.boardRows, in: 3...20)
                    Text("That is a board of \(camera.boardColumns + 1) × \(camera.boardRows + 1) squares. Inner corners are where four squares meet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Square")
                        TextField("", value: $square, format: .number).frame(width: 50)
                        Text("mm")
                        Spacer()
                        Button("Add to design") {
                            model.addCalibrationCheckerboard(columns: camera.boardColumns, rows: camera.boardRows, square: square)
                        }
                        .help("Add a checkerboard to print, or to engrave on card or plywood")
                    }
                    Text("Print it or engrave it, and keep it flat (glue a print to card or board).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("2. Capture views") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Put the board in a different place for each view, covering the middle, the edges and the corners of the picture. Tilt it in a few views. 8 to 15 views is plenty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Capture view") { Task { await camera.captureBoardView() } }
                            .disabled(camera.busy || !camera.isRunning)
                        if camera.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        Text("\(camera.lensViews.count) views")
                            .font(.callout.monospacedDigit())
                    }
                    HStack {
                        Button("Remove last") {
                            _ = camera.lensViews.popLast()
                            camera.lastDetection = nil
                        }
                        .disabled(camera.lensViews.isEmpty)
                        Button("Clear") {
                            camera.lensViews = []
                            camera.lastDetection = nil
                        }
                        .disabled(camera.lensViews.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("3. Calibrate") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Calibrate lens") { Task { await camera.calibrateLens() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(camera.lensViews.count < LensCalibration.minimumViews || camera.busy)
                    if let lens = camera.setup.lens {
                        Text(String(format: "Calibrated from %ld views at %ld × %ld. Average error %.2f px; the corners were bent %.1f%%.",
                                    lens.views, lens.imageWidth, lens.imageHeight, lens.rmsError, abs(lens.cornerDistortion) * 100))
                            .font(.caption)
                            .foregroundStyle(lens.rmsError > 1 ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Show the straightened picture", isOn: $feed.straighten)
                        Button("Forget lens calibration", role: .destructive) { camera.clearLens() }
                    } else {
                        Text("An error under about 0.5 px is good. Above 1 px, capture more varied views.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Alignment

private struct BedAlignmentPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var laser: LaserController
    @State private var confirmBurn = false

    private var isLaser: Bool { model.profile.kind == .grblLaser }

    var body: some View {
        let s = $camera.alignmentSettings
        VStack(alignment: .leading, spacing: 10) {
            Text("Burn marks at known places on the bed, then click them in a snapshot. That ties the camera picture to the bed. Do it again if the camera or its mount moves.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("1. Burn the target") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cover the bed with scrap card or plywood the camera can see, at the height you usually work. Home the laser first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Stepper("Marks across: \(s.wrappedValue.columns)", value: s.columns, in: 2...5)
                    Stepper("Marks down: \(s.wrappedValue.rows)", value: s.rows, in: 2...5)
                    field("Edge margin", s.margin, "mm")
                    field("Mark size", s.markSize, "mm")
                    field("Speed", s.speed, "mm/min")
                    field("Power", s.power, "%")
                    HStack {
                        Button("Burn target…") { confirmBurn = true }
                            .disabled(!isLaser || !laser.isConnected || laser.isRunning || model.profile.rotaryEnabled)
                        Button("Add to design") {
                            prepareTarget()
                            model.addCameraTargetToDesign(camera.alignmentSettings)
                        }
                        .help("Put the target in the design to frame and run it yourself (from machine home)")
                    }
                    if !isLaser {
                        note("Pick your laser in the Device picker to burn the target.")
                    } else if model.profile.rotaryEnabled {
                        note("Turn the rotary off in the device settings first.")
                    } else if !laser.isConnected {
                        note("Connect the laser in the Machine tab to burn the target.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("2. Click the marks") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button(camera.alignmentImage == nil ? "Take snapshot" : "Retake snapshot") {
                            Task { await camera.takeAlignmentSnapshot() }
                        }
                        if camera.alignmentImage != nil {
                            Button("Back to live") { camera.discardAlignmentSnapshot() }
                        }
                    }
                    note("Click each mark's centre in order: left to right, top row first, as the marks sit on the canvas. Mark 1 has a small inner ring. Clicks snap to the mark; hold Option to place one exactly.")
                    MarkOrderGrid(columns: camera.alignmentSettings.columns, rows: camera.alignmentSettings.rows,
                                  clicks: camera.alignmentClicks, pick: camera.alignmentPick) { camera.alignmentPick = $0 }
                    HStack {
                        Button("Undo last") { undoLast() }
                            .disabled(!camera.alignmentClicks.contains { $0 != nil })
                        Button("Clear") { camera.clearAlignmentClicks() }
                            .disabled(!camera.alignmentClicks.contains { $0 != nil })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(camera.alignmentImage == nil && !camera.isRunning)
            }
            GroupBox("3. Save") {
                VStack(alignment: .leading, spacing: 6) {
                    let fit = camera.alignmentFit()
                    if let fit {
                        Text(String(format: "The marks fit within %.2f mm on average (worst %.2f mm).", fit.rms, fit.max))
                            .font(.caption)
                            .foregroundStyle(fit.max > 1.5 ? .orange : .secondary)
                        if fit.max > 1.5 {
                            note("A big error usually means a mark was clicked out of order, or the lens needs calibrating.")
                        }
                    } else {
                        note("Click at least 4 marks.")
                    }
                    Button("Save alignment") { camera.saveAlignment(profile: model.profile) }
                        .buttonStyle(.borderedProminent)
                        .disabled(fit == nil)
                    if let a = camera.setup.alignment {
                        let machine = model.profiles.first { $0.id == a.profileID }?.name ?? "another machine"
                        note("Aligned \(a.date.formatted(date: .abbreviated, time: .shortened)) for \(machine).")
                        Button("Forget alignment", role: .destructive) { camera.clearAlignment() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog("Burn the alignment target?", isPresented: $confirmBurn) {
            Button("Burn") { burn() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let a = targetArea
            Text(String(format: "The laser will burn %ld marks between X %.0f–%.0f and Y %.0f–%.0f mm, measured from machine home, at %.0f%% power. Stay with the machine.",
                        camera.alignmentSettings.markCount, a.minX, a.maxX, a.minY, a.maxY, camera.alignmentSettings.power))
        }
    }

    private var targetArea: Rect2 {
        var t = camera.alignmentSettings
        t.bedWidth = model.profile.bedWidth
        t.bedHeight = model.profile.bedHeight
        return t.area
    }

    private func prepareTarget() {
        camera.alignmentSettings.bedWidth = model.profile.bedWidth
        camera.alignmentSettings.bedHeight = model.profile.bedHeight
        camera.clearAlignmentClicks()
    }

    private func burn() {
        prepareTarget()
        laser.run(lines: model.cameraTargetGCode(camera.alignmentSettings))
    }

    private func undoLast() {
        let pick = camera.alignmentPick
        let clicks = camera.alignmentClicks
        let before = clicks[..<min(pick, clicks.count)].lastIndex(where: { $0 != nil })
        let last = before ?? clicks.lastIndex(where: { $0 != nil })
        guard let i = last else { return }
        camera.alignmentClicks[i] = nil
        camera.alignmentPick = i
    }

    private func field(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number).frame(width: 70)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The marks in their bed layout, numbered; clicked ones are filled and the next one is outlined.
/// Clicking a number picks that mark to click again.
private struct MarkOrderGrid: View {
    let columns: Int
    let rows: Int
    let clicks: [Vec2?]
    let pick: Int
    let choose: (Int) -> Void

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<max(2, rows), id: \.self) { j in
                GridRow {
                    ForEach(0..<max(2, columns), id: \.self) { i in
                        let k = j * max(2, columns) + i
                        let done = k < clicks.count && clicks[k] != nil
                        Button { choose(k) } label: {
                            Text("\(k + 1)")
                                .font(.caption.bold().monospacedDigit())
                                .frame(width: 26, height: 22)
                                .background(done ? Color.accentColor.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(k == pick ? Color.accentColor : Color.secondary.opacity(0.4),
                                                                                  lineWidth: k == pick ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Overlay and trace

private struct CameraOverlayPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraController
    @ObservedObject var overlay: CameraOverlay
    @State private var threshold = 128.0
    @State private var traceLight = false
    @State private var minimumArea = 4.0
    @State private var smoothing = 2
    @State private var tracing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Camera on the canvas") {
                VStack(alignment: .leading, spacing: 6) {
                    if !camera.isAligned(to: model.profile) {
                        Text(camera.setup.alignment == nil ? "Align the camera to the bed first (Alignment tab)."
                                                           : "This camera was aligned on another machine. Pick it in the Device picker, or align again.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Show camera on canvas", isOn: $overlay.visible)
                    Toggle("Live (keep updating)", isOn: $overlay.live)
                        .onChange(of: overlay.live) { _, live in
                            if live { camera.start() } else { camera.stopIfIdle() }
                        }
                    HStack {
                        Text("Opacity")
                        Slider(value: $overlay.opacity, in: 0.2...1)
                    }
                    HStack {
                        Button("Update snapshot") { Task { await camera.updateSnapshot(profile: model.profile) } }
                        if let t = overlay.updatedAt {
                            Text("Taken \(t.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!camera.isAligned(to: model.profile))
                    Text("Place your design on the material in the picture. Run it with the zero point set to **Machine home (absolute)** so it lands where it shows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Trace from the camera") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turns dark areas in the picture (a drawing, a shape cut from paper) into outlines at the same place on the bed. Traces \(regionName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Threshold")
                        Slider(value: $threshold, in: 1...254)
                        Text("\(Int(threshold))").font(.caption.monospacedDigit()).frame(width: 28)
                        Button("Auto") { autoThreshold() }
                    }
                    Toggle("Trace light areas instead", isOn: $traceLight)
                    HStack {
                        Text("Ignore specks under")
                        TextField("", value: $minimumArea, format: .number).frame(width: 50)
                        Text("mm²")
                    }
                    Stepper("Smoothing: \(smoothing)", value: $smoothing, in: 0...5)
                    HStack {
                        Button("Trace and add outlines") { trace() }
                            .disabled(overlay.pixels.isEmpty || tracing)
                        if tracing { ProgressView().controlSize(.small) }
                    }
                    if overlay.pixels.isEmpty {
                        Text("Take a snapshot first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var regionName: String {
        if !model.selection.isEmpty { return "inside the selected shapes' box" }
        if model.document.workpiece != nil { return "the workpiece" }
        return "everything the camera sees"
    }

    private func autoThreshold() {
        let (gray, seen) = CameraTrace.grayscale(bgra: overlay.pixels, width: overlay.pixelWidth, height: overlay.pixelHeight)
        threshold = Double(CameraTrace.otsuThreshold(gray, seen: seen))
    }

    private func trace() {
        let pixels = overlay.pixels, w = overlay.pixelWidth, h = overlay.pixelHeight
        let origin = overlay.area.origin, cell = overlay.mmPerPixel
        let region = model.cameraTraceRegion
        let options = CameraTrace.Options(threshold: UInt8(threshold.rounded()), traceLight: traceLight,
                                          minimumArea: max(0, minimumArea), smoothing: smoothing)
        tracing = true
        Task {
            let loops = await Task.detached(priority: .userInitiated) { () -> [Polyline] in
                let (gray, seen) = CameraTrace.grayscale(bgra: pixels, width: w, height: h)
                return CameraTrace.trace(gray: gray, seen: seen, width: w, height: h, origin: origin, cell: cell,
                                         region: region, options: options)
            }.value
            tracing = false
            model.addCameraTrace(loops)
        }
    }
}

// MARK: - Main window bits

/// Toolbar buttons in the main window: show the camera on the canvas and take a fresh snapshot.
struct CameraToolbarItems: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var overlay: CameraOverlay
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle(isOn: Binding(get: { overlay.visible }, set: { show in
            overlay.visible = show
            if show, overlay.image == nil {
                if camera.isAligned(to: model.profile) {
                    Task { await camera.updateSnapshot(profile: model.profile) }
                } else {
                    openWindow(id: "camera")
                }
            }
        })) {
            Label("Camera", systemImage: "camera.viewfinder")
        }
        .help("Show the camera picture on the canvas")
        if overlay.visible {
            Button { Task { await camera.updateSnapshot(profile: model.profile) } } label: {
                Label("Snapshot", systemImage: "camera.shutter.button")
            }
            .help("Take a fresh camera snapshot (⌥⌘U)")
        }
    }
}

/// View menu items for the camera.
struct CameraMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var overlay: CameraOverlay
    let camera: CameraController
    let model: AppModel

    var body: some View {
        Divider()
        Button("Camera…") { openWindow(id: "camera") }
            .keyboardShortcut("c", modifiers: [.command, .option])
        Toggle("Show Camera on Canvas", isOn: $overlay.visible)
        Button("Update Camera Snapshot") { Task { await camera.updateSnapshot(profile: model.profile) } }
            .keyboardShortcut("u", modifiers: [.command, .option])
    }
}
