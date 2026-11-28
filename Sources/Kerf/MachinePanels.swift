import KerfCore
import SwiftUI

struct MachinePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var editingDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Device", selection: $model.activeProfileID) {
                    ForEach(model.profiles) { p in
                        Label(p.name, systemImage: p.kind == .grblLaser ? "flame" : (p.kind == .cncRouter ? "gearshape.2" : "scissors")).tag(p.id)
                    }
                }
                Button { editingDevices = true } label: { Image(systemName: "gearshape") }
                    .help("Edit devices")
                    .buttonStyle(.borderless)
            }
            if model.profile.kind.usesGRBL {
                ScrollView { LaserPanel().padding(.trailing, 4) }
            } else {
                CutterPanel()
            }
        }
        .sheet(isPresented: $editingDevices) {
            DeviceEditor().environmentObject(model)
        }
    }
}

private func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) : String(format: "%dm %02ds", s / 60, s % 60)
}

// MARK: - Laser

struct LaserPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var laser: LaserController
    @State private var jogStep = 10.0
    @State private var jogFeed = 3000.0
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            connectionRow
            statusRow
            GroupBox("Move") {
                HStack(alignment: .top, spacing: 16) {
                    jogPad
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Step", selection: $jogStep) {
                            ForEach([0.1, 1, 10, 50], id: \.self) { Text("\($0, specifier: "%g") mm").tag($0) }
                        }
                        .frame(width: 150)
                        LabeledContent("Speed") {
                            TextField("", value: $jogFeed, format: .number).frame(width: 70)
                        }
                        .frame(width: 150)
                        HStack {
                            Button("Home") { laser.home() }
                            Button("Unlock") { laser.unlock() }
                        }
                        Button("Set origin here") { laser.setWorkOrigin() }
                            .help("Make the current position the work origin (G10 L20)")
                        if isCNC {
                            HStack {
                                Button("Z +") { laser.jogZ(jogStep, feed: min(jogFeed, 600)) }
                                Button("Z −") { laser.jogZ(-jogStep, feed: min(jogFeed, 600)) }
                                Button("Zero Z") { laser.setWorkZeroZ() }
                                    .help("Touch the tool to the top of the stock first")
                            }
                        }
                    }
                }
                .disabled(!laser.isConnected || laser.isRunning || laser.isWiFi)
            }
            if laser.isWiFi {
                Text("Over Wi-Fi the laser doesn't report its position and can't be jogged or homed from here. Jobs run from where the head is: the laser treats that as X0 Y0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.profile.rotaryEnabled {
                Label(String(format: "Rotary on (%@): Y scaled ×%.3f", model.profile.rotaryType.title.lowercased(), model.profile.rotaryYScale),
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            GroupBox("Job") {
                VStack(alignment: .leading, spacing: 8) {
                    JobOriginPicker()
                    MirrorOutputPicker()
                    let tp = model.toolpath
                    Text(tp.isEmpty ? "No enabled layers with shapes." : "Estimated time \(formatDuration(tp.estimatedSeconds(profile: model.profile)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Frame") { laser.frame(lines: frameLines()) }
                            .help(laser.isWiFi ? "Upload the job outline, then press the laser's button to trace it with the laser off"
                                               : "Trace the job outline with the laser off")
                            .disabled(tp.isEmpty || laser.isRunning || laser.isUploading)
                        Spacer()
                        if laser.isRunning {
                            if laser.isPaused {
                                Button("Resume") { laser.resume() }
                            } else {
                                Button("Pause") { laser.pause() }
                            }
                        } else {
                            Button(startTitle) { laser.run(lines: model.gcodeLines(offset: jobOffset())) }
                                .buttonStyle(.borderedProminent)
                                .disabled(tp.isEmpty || laser.isUploading)
                        }
                        Button("Stop", role: .destructive) { laser.stop() }
                    }
                    .disabled(!laser.isConnected)
                    if laser.isUploading {
                        ProgressView { Text("Uploading to the laser…").font(.caption) }
                            .progressViewStyle(.linear)
                    } else if laser.awaitingButton {
                        Label("Uploaded. Press the button on the laser to start.", systemImage: "hand.point.up.left")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    if laser.isRunning && laser.isWiFi {
                        Text("Running on the laser · \(formatDuration(laser.elapsed)) elapsed")
                            .font(.caption)
                    } else if laser.isRunning {
                        ProgressView(value: laser.progress) {
                            Text("\(Int(laser.progress * 100))% · \(formatDuration(laser.elapsed)) elapsed")
                                .font(.caption)
                        }
                    }
                }
            }
            if !isCNC { printAndCut }
            console
        }
    }

    private var isCNC: Bool { model.profile.kind == .cncRouter }

    /// Two-point alignment to registration marks on a printed sheet.
    private var printAndCut: some View {
        GroupBox("Print and cut") {
            VStack(alignment: .leading, spacing: 6) {
                RegistrationSettings()
                HStack {
                    Button("Add registration marks") { model.addRegistrationMarks() }
                    Button("Print preview…") { model.showPrintPreview = true }
                }
                if model.registrationMarkCenters.count < 2 {
                    Text("Add registration marks, print the sheet, and place it on the bed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Jog the laser dot onto each mark's centre and record it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Record mark 1") { model.measuredMark1 = laser.workPosition }
                        Text(model.measuredMark1.map { String(format: "%.2f, %.2f", $0.x, $0.y) } ?? "not set")
                            .font(.caption.monospacedDigit())
                    }
                    HStack {
                        Button("Record mark 2") { model.measuredMark2 = laser.workPosition }
                        Text(model.measuredMark2.map { String(format: "%.2f, %.2f", $0.x, $0.y) } ?? "not set")
                            .font(.caption.monospacedDigit())
                    }
                    Toggle("Align job to marks", isOn: $model.useAlignment)
                        .disabled(model.measuredMark1 == nil || model.measuredMark2 == nil)
                    if model.useAlignment {
                        let t = model.alignmentTransform
                        Text(String(format: "Rotation %.2f°, scale %.4f", t.rotationAngle * 180 / .pi, t.meanScale))
                            .font(.caption)
                            .foregroundStyle(abs(t.meanScale - 1) > 0.02 ? .orange : .secondary)
                    }
                }
            }
            .disabled(!laser.isConnected || laser.isWiFi)
        }
    }

    /// Over Wi-Fi without auto start, the button only uploads; the laser's own button starts the job.
    private var startTitle: String {
        laser.isWiFi && !model.profile.wifiAutoStart ? "Upload" : "Start"
    }

    @ViewBuilder
    private var connectionRow: some View {
        if model.profile.usesWiFi || laser.isWiFi {
            wifiConnectionRow
        } else {
            serialConnectionRow
        }
    }

    private var wifiConnectionRow: some View {
        HStack {
            Label(model.profile.networkHost.isEmpty ? "No IP address set" : model.profile.networkHost, systemImage: "wifi")
                .foregroundStyle(model.profile.networkHost.isEmpty ? .secondary : .primary)
            Spacer()
            if laser.isConnected {
                Button("Disconnect") { laser.disconnect() }
            } else {
                Button("Connect") { laser.connect(profile: model.profile) }
                    .disabled(model.profile.networkHost.isEmpty)
            }
        }
    }

    private var serialConnectionRow: some View {
        HStack {
            Picker("Port", selection: $laser.selectedPort) {
                if laser.ports.isEmpty { Text("No serial ports").tag("") }
                ForEach(laser.ports, id: \.self) { Text($0.replacingOccurrences(of: "/dev/", with: "")).tag($0) }
            }
            .disabled(laser.isConnected)
            Button { laser.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh ports")
                .disabled(laser.isConnected)
            if laser.isConnected {
                Button("Disconnect") { laser.disconnect() }
            } else {
                Button("Connect") { laser.connect(profile: model.profile) }
                    .disabled(laser.selectedPort.isEmpty)
            }
        }
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 9, height: 9)
            Text(laser.status.state)
            Spacer()
            if let w = laser.workPosition {
                Text(String(format: "X %.2f  Y %.2f", w.x, w.y))
                    .font(.body.monospacedDigit())
            }
        }
    }

    private var stateColor: Color {
        switch laser.status.state {
        case "Idle": return .green
        case "Run", "Jog", "Home": return .blue
        case "Hold", "Door": return .orange
        case "Alarm": return .red
        default: return .gray
        }
    }

    private var jogPad: some View {
        let f = jogFeed, s = jogStep
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                jogButton("arrow.up.left") { laser.jog(dx: -s, dy: s, feed: f) }
                jogButton("arrow.up") { laser.jog(dx: 0, dy: s, feed: f) }
                jogButton("arrow.up.right") { laser.jog(dx: s, dy: s, feed: f) }
            }
            GridRow {
                jogButton("arrow.left") { laser.jog(dx: -s, dy: 0, feed: f) }
                jogButton("scope") { laser.goToOrigin(feed: f) }
                    .help("Go to work origin")
                jogButton("arrow.right") { laser.jog(dx: s, dy: 0, feed: f) }
            }
            GridRow {
                jogButton("arrow.down.left") { laser.jog(dx: -s, dy: -s, feed: f) }
                jogButton("arrow.down") { laser.jog(dx: 0, dy: -s, feed: f) }
                jogButton("arrow.down.right") { laser.jog(dx: s, dy: -s, feed: f) }
            }
        }
    }

    private func jogButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
    }

    private var console: some View {
        GroupBox("Console") {
            VStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(laser.log) { line in
                                Text(line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(line.kind))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                    }
                    .frame(height: 160)
                    .onChange(of: laser.log.count) { _, _ in
                        if let last = laser.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                HStack {
                    TextField("Command (e.g. $$)", text: $command)
                        .onSubmit(sendCommand)
                    Button("Send", action: sendCommand)
                        .disabled(!laser.isConnected || command.isEmpty)
                    Button { laser.clearLog() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func color(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .sent: return .secondary
        case .received: return .primary
        case .info: return .blue
        case .error: return .red
        }
    }

    private func sendCommand() {
        guard !command.isEmpty else { return }
        laser.send(command)
        command = ""
    }

    private func jobOffset() -> Vec2 {
        model.jobOffset(head: laser.workPosition)
    }

    private func frameLines() -> [String] {
        let tp = model.outputToolpath
        let offset = jobOffset()
        return GCodeGenerator.frame(tp.bounds, profile: model.profile, offset: offset, alignment: model.alignmentTransform,
                                    feed: model.profile.rapidSpeed)
    }
}

// MARK: - Vinyl cutter

struct CutterPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cutter: CutterSender
    @State private var queues: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Toggle("Cut selected shapes only", isOn: $model.cutSelectionOnly)
                    .help("Send and export only the selected shapes")
                MirrorOutputPicker()
                CutterConnectionSettings(queues: queues)
                if model.profile.language != .svgFile {
                    LabeledContent("Blade offset (mm)") {
                        TextField("", value: profileBinding(\.bladeOffset), format: .number).frame(width: 70)
                    }
                    LabeledContent("Overcut (mm)") {
                        TextField("", value: profileBinding(\.overcut), format: .number).frame(width: 70)
                    }
                }
                Section("Print and cut") {
                    RegistrationSettings()
                    Button("Add registration marks") { model.addRegistrationMarks() }
                    Button("Print preview…") { model.showPrintPreview = true }
                    if model.profile.aasEnabled && !model.useManualRegistration {
                        AASControls()
                    } else if !model.profile.aasEnabled {
                        Text("Print the sheet, then load it with mark 1 at the cutter's origin, or line the cut up with Manual registration. For a GCC LX cutter, turn on optical marks in the device settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ManualRegistrationSummary()
                }
                Section("Weeding") {
                    Picker("Weeding box", selection: $model.weeding.box) {
                        ForEach(WeedBoxStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Cuts a box around the design so the waste peels off in one sheet")
                    if model.weeding.box != .none || model.weeding.lines != .none {
                        LabeledContent("Box margin (mm)") {
                            TextField("", value: $model.weeding.margin, format: .number).frame(width: 70)
                        }
                    }
                    Picker("Weeding lines", selection: $model.weeding.lines) {
                        ForEach(WeedLineStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Splits the waste inside the box into strips that are easier to peel")
                    if model.weeding.lines != .none {
                        LabeledContent("Line spacing (mm)") {
                            TextField("", value: $model.weeding.spacing, format: .number).frame(width: 70)
                        }
                        LabeledContent("Stop short of design (mm)") {
                            TextField("", value: $model.weeding.clearance, format: .number).frame(width: 70)
                        }
                    }
                    if model.weeding.isActive {
                        Text("Shown as dashed lines on the canvas. They're cut last, lines before boxes, with the last layer's settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                PanelSettings()
            }
            .formStyle(.grouped)

            let tp = model.toolpath
            Text(tp.isEmpty ? "No enabled cut layers with shapes." : "Estimated time \(formatDuration(tp.estimatedSeconds(profile: model.profile)))")
                .font(.caption)
                .foregroundStyle(.secondary)

            let tiled = model.panelsActive && model.panelLayout.isSplit
            HStack {
                Button(tiled ? "Export panels…" : "Export file…") { model.exportMachineFile() }
                    .disabled(tp.isEmpty)
                Spacer()
                if model.profile.language != .svgFile {
                    if cutter.isSending {
                        Button("Stop", role: .destructive) { cutter.cancel() }
                    } else {
                        Button(tiled ? "Send panel \(model.currentPanel?.name ?? "")…" : "Send to cutter…") { model.showSendToCutter = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(tp.isEmpty)
                            .help("Check blade, force, mirror and placement with a preview of the cut, then send")
                    }
                }
            }
            if cutter.isSending {
                ProgressView(value: cutter.progress)
            }
            if !cutter.message.isEmpty {
                Text(cutter.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { queues = CutterSender.printerQueues() }
    }

    private func profileBinding<T>(_ keyPath: WritableKeyPath<DeviceProfile, T>) -> Binding<T> {
        Binding(get: { model.profile[keyPath: keyPath] }, set: { model.profile[keyPath: keyPath] = $0 })
    }
}

// MARK: - Device editor

struct DeviceEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(selection: $selected) {
                    ForEach(model.profiles) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                HStack {
                    Menu {
                        ForEach(DeviceProfile.presets, id: \.name) { preset in
                            Button(preset.name) { add(preset) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 40)
                    Button {
                        guard let id = selected, model.profiles.count > 1 else { return }
                        model.profiles.removeAll { $0.id == id }
                        if model.activeProfileID == id { model.activeProfileID = model.profiles[0].id }
                        selected = model.profiles.first?.id
                    } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(model.profiles.count < 2)
                }
                .padding(6)
            }
            .frame(minWidth: 200, maxWidth: 260)

            Group {
                if let id = selected, let i = model.profiles.firstIndex(where: { $0.id == id }) {
                    ProfileForm(profile: $model.profiles[i])
                } else {
                    Text("Select a device").foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { selected = model.activeProfileID }
    }

    private func add(_ preset: DeviceProfile) {
        var p = preset
        p.id = UUID()
        model.profiles.append(p)
        selected = p.id
    }
}

private struct ProfileForm: View {
    @Binding var profile: DeviceProfile

    var body: some View {
        Form {
            TextField("Name", text: $profile.name)
            Picker("Type", selection: $profile.kind) {
                ForEach(DeviceKind.allCases) { Text($0.title).tag($0) }
            }
            Section("Work area") {
                LabeledContent("Width (mm)") { TextField("", value: $profile.bedWidth, format: .number).frame(width: 80) }
                LabeledContent("Height (mm)") { TextField("", value: $profile.bedHeight, format: .number).frame(width: 80) }
                Picker("Origin", selection: $profile.origin) {
                    ForEach(OriginCorner.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Swap X and Y", isOn: $profile.swapAxes)
            }
            Section("Connection") {
                if profile.kind == .grblLaser {
                    Picker("Connect by", selection: $profile.link) {
                        ForEach(LaserLink.allCases) { Text($0.title).tag($0) }
                    }
                }
                if profile.usesWiFi {
                    LabeledContent("IP address") {
                        TextField("192.168.1.50", text: $profile.networkHost).frame(width: 140)
                    }
                    LabeledContent("Port") { TextField("", value: $profile.networkPort, format: .number.grouping(.never)).frame(width: 80) }
                    Toggle("Start jobs from KerfKutter", isOn: $profile.wifiAutoStart)
                    Text(profile.wifiAutoStart
                         ? "Jobs start as soon as they're uploaded, using a call xTool doesn't document. On older firmware (40.30.002.01) the laser has been seen to fire while framing this way. Framing always waits for the button."
                         : "Jobs are uploaded to the laser, then you press its button to start. This is the safest way. Find the IP address in xTool Creative Space or your router.")
                        .font(.caption)
                        .foregroundStyle(profile.wifiAutoStart ? .orange : .secondary)
                } else {
                    Picker("Baud rate", selection: $profile.baudRate) {
                        ForEach([9600, 19200, 38400, 57600, 115200, 230400, 250000], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Flow control", selection: $profile.flowControl) {
                        ForEach(FlowControl.allCases) { Text($0.title).tag($0) }
                    }
                    if profile.kind == .grblLaser && profile.name.localizedCaseInsensitiveContains("falcon") {
                        Text("The Falcon2 connects over USB only. Falcon A1 models have Wi-Fi, but KerfKutter can't send to them over it yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if profile.kind == .cncRouter {
                Section("CNC") {
                    LabeledContent("Safe Z (mm)") { TextField("", value: $profile.safeZ, format: .number).frame(width: 80) }
                }
            }
            if profile.kind.usesGRBL {
                Section("Rotary (Y axis)") {
                    Toggle("Rotary attachment fitted", isOn: $profile.rotaryEnabled)
                    if profile.rotaryEnabled {
                        Picker("Type", selection: $profile.rotaryType) {
                            ForEach(RotaryType.allCases) { Text($0.title).tag($0) }
                        }
                        LabeledContent("Y travel per rotation (mm)") {
                            TextField("", value: $profile.rotaryMMPerRotation, format: .number).frame(width: 80)
                        }
                        if profile.rotaryType == .roller {
                            LabeledContent("Roller diameter (mm)") {
                                TextField("", value: $profile.rotaryRollerDiameter, format: .number).frame(width: 80)
                            }
                        } else {
                            LabeledContent("Object diameter (mm)") {
                                TextField("", value: $profile.rotaryObjectDiameter, format: .number).frame(width: 80)
                            }
                            Text(String(format: "One turn of the object is %.1f mm of design height.", profile.rotaryCircumference))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Y travel per rotation is how far the controller thinks Y moved when the rotary turns once. Measure it by jogging Y and counting one full turn.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("GRBL") {
                    LabeledContent("Max S value ($30)") { TextField("", value: $profile.sMax, format: .number).frame(width: 80) }
                    LabeledContent("Rapid speed (mm/min)") { TextField("", value: $profile.rapidSpeed, format: .number).frame(width: 80) }
                    LabeledContent("RX buffer (bytes)") { TextField("", value: $profile.rxBufferSize, format: .number).frame(width: 80) }
                }
            } else {
                Section("Cutter") {
                    Picker("Language", selection: $profile.language) {
                        ForEach(CutterLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Units per mm") { TextField("", value: $profile.unitsPerMM, format: .number).frame(width: 80) }
                    LabeledContent("Blade offset (mm)") { TextField("", value: $profile.bladeOffset, format: .number).frame(width: 80) }
                    LabeledContent("Overcut (mm)") { TextField("", value: $profile.overcut, format: .number).frame(width: 80) }
                    Toggle("Send speed and force", isOn: $profile.sendSpeedAndForce)
                }
                Section("Laser pointer") {
                    Toggle("Head has a laser pointer", isOn: $profile.hasLaserPointer)
                    if profile.hasLaserPointer {
                        LabeledContent("Offset from blade X (mm)") { TextField("", value: $profile.laserOffsetX, format: .number).frame(width: 80) }
                        LabeledContent("Offset from blade Y (mm)") { TextField("", value: $profile.laserOffsetY, format: .number).frame(width: 80) }
                        Text("Where the laser dot is relative to the blade, along the cutter's own X and Y. Manual registration can measure it for you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Optical registration (GCC AAS II)") {
                    Toggle("Reads printed marks (Expert II LX and similar)", isOn: $profile.aasEnabled)
                        .disabled(profile.language != .hpgl)
                    if profile.aasEnabled {
                        Picker("Mark distance units", selection: $profile.aasUnits) {
                            ForEach(AASDistanceUnits.allCases) { Text($0.title).tag($0) }
                        }
                        Text("GCC doesn't publish the units. If the cutter looks for the far marks in the wrong place, try another setting. Fine offsets are set on the cutter under AAS Offset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Style, size, count and margin for new registration marks.
struct RegistrationSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Mark style", selection: $model.registrationStyle) {
            ForEach(RegistrationStyle.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: model.registrationStyle) { _, style in
            guard style == .gccAAS else { return }
            // GCC's suggested sizes.
            model.registrationMarkCount = 4
            model.registrationMarkSize = GCCAAS.defaultLength
            model.registrationLineWidth = GCCAAS.defaultThickness
            model.registrationMargin = GCCAAS.defaultMargin
        }
        Picker("Marks", selection: $model.registrationMarkCount) {
            Text("3 corners").tag(3)
            Text("4 corners").tag(4)
        }
        .pickerStyle(.segmented)
        .disabled(model.registrationStyle == .gccAAS)
        LabeledContent(model.registrationStyle == .gccAAS ? "L length (mm)" : "Mark size (mm)") {
            TextField("", value: $model.registrationMarkSize, format: .number).frame(width: 60)
        }
        if model.registrationStyle == .gccAAS {
            LabeledContent("Line thickness (mm)") {
                TextField("", value: $model.registrationLineWidth, format: .number).frame(width: 60)
            }
        }
        LabeledContent("Gap from artwork (mm)") {
            TextField("", value: $model.registrationMargin, format: .number).frame(width: 60)
        }
        if model.registrationStyle == .gccAAS {
            Text("Four L marks, black on white. GCC allows 5–50 mm long, 1–2 mm thick and 1–50 mm from the art; 25, 1 and 5 work best. Mark 1, the thicker one, is the origin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The manual registration button and what it will do to the next cut.
struct ManualRegistrationSummary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button("Manual registration…") { model.showManualRegistration = true }
            .help("Move the head from KerfKutter onto each printed mark with the laser pointer, then cut aligned to them")
            .disabled(!model.canJogCutter)
        if model.manualRegistrationTransform != nil {
            Text("The cut is aligned to \(model.manualMarks.count) mark\(model.manualMarks.count == 1 ? "" : "s") found by hand\(model.profile.aasEnabled ? "; the optical sensor isn't used" : "").")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Reading GCC AAS II marks with the cutter's optical sensor.
struct AASControls: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cutter: CutterSender

    var body: some View {
        if let job = model.aasJob {
            Toggle("Read marks with the optical sensor (AAS)", isOn: $model.useAAS)
            Text(String(format: "Marks %.1f × %.1f mm apart. The cut is placed from mark 1.", job.xDistance, job.yDistance))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Load the printed sheet, lower the pinch rollers, move the blade over mark 1 (the thick L nearest the origin) and press Origin Set, then Send to cutter.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Scan marks only (test)") {
                if let text = model.aasScanOnlyText() { cutter.send(text, profile: model.profile) }
            }
            .help("Reads the four marks without cutting, then returns to mark 1")
            .disabled(cutter.isSending || (model.profile.output == .serial && cutter.selectedPort.isEmpty))
        } else {
            Text("Choose the GCC AAS II mark style and add registration marks. The cutter reads all four with its sensor, then cuts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Choose where the job's X0 Y0 is: machine home, a work zero you set, or the head's current position,
/// anchored at one of nine points on the job or the workpiece.
struct JobOriginPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Cut selected shapes only", isOn: $model.cutSelectionOnly)
                .help("Start, Frame, export and preview use only the selected shapes")
            if model.cutSelectionOnly && model.selection.isEmpty {
                Text("Nothing selected, so the whole design runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Zero point", selection: $model.jobOrigin) {
                ForEach(JobOrigin.allCases) { Text($0.title).tag($0) }
            }
            if model.jobOrigin != .absolute {
                HStack(alignment: .top, spacing: 12) {
                    Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(0..<3, id: \.self) { row in
                            GridRow {
                                ForEach(0..<3, id: \.self) { col in
                                    let a = OriginAnchor.allCases[row * 3 + col]
                                    Circle()
                                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                        .background(Circle().fill(model.originAnchor == a ? Color.accentColor : .clear))
                                        .frame(width: 16, height: 16)
                                        .padding(2)
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.originAnchor = a }
                                    .help(a.title)
                                }
                            }
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("On", selection: $model.originReference) {
                            ForEach(OriginReference.allCases) { Text($0.title).tag($0) }
                        }
                        .disabled(model.document.workpiece == nil)
                        Text(model.jobOrigin == .userOrigin
                             ? "Jog to this spot on the material and press Set origin here. The job runs from that zero."
                             : "This spot starts wherever the head is when you press Start or Frame.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
