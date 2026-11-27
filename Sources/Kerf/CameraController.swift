import AppKit
import AVFoundation
import KerfCore
import SwiftUI

/// One camera picture, as BGRA bytes.
struct CameraFrame: @unchecked Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: Data

    init?(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        data = Data(bytes: base, count: bytesPerRow * height)
    }

    init(width: Int, height: Int, bytesPerRow: Int, data: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
    }

    var gray: GrayImage {
        data.withUnsafeBytes { GrayImage.fromBGRA($0, width: width, height: height, bytesPerRow: bytesPerRow) }
    }

    var cgImage: CGImage? { Self.cgImage(data, width: width, height: height, bytesPerRow: bytesPerRow, alpha: false) }

    func remapped(_ remap: CameraRemap) -> [UInt8] {
        data.withUnsafeBytes { remap.apply(bgra: $0, width: width, height: height, bytesPerRow: bytesPerRow) }
    }

    /// A CGImage over BGRA bytes; `alpha` for premultiplied pictures with transparent parts.
    static func cgImage(_ data: Data, width: Int, height: Int, bytesPerRow: Int, alpha: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = (alpha ? CGImageAlphaInfo.premultipliedFirst : CGImageAlphaInfo.noneSkipFirst).rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The newest frame from the capture queue, picked up by the main thread when it wants one.
final class FrameStore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var counter = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        buffer = pb
        counter += 1
        lock.unlock()
    }

    /// The latest frame and its sequence number.
    func latest() -> (CVPixelBuffer, Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let b = buffer else { return nil }
        return (b, counter)
    }

    func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
    }
}

/// The camera picture shown in the Camera window (only updated while the window is open).
@MainActor
final class CameraFeed: ObservableObject {
    @Published var image: CGImage?
    @Published var size: CGSize?
    var isShown = false
    /// Show the picture with the lens distortion removed.
    @Published var straighten = false
}

/// The camera picture warped onto the bed, drawn under the design on the canvas.
@MainActor
final class CameraOverlay: ObservableObject {
    @Published var visible = UserDefaults.standard.bool(forKey: "cameraOverlayVisible") {
        didSet { UserDefaults.standard.set(visible, forKey: "cameraOverlayVisible") }
    }
    /// Keep updating the picture (otherwise it is a snapshot taken on request).
    @Published var live = false
    @Published var opacity: Double = UserDefaults.standard.object(forKey: "cameraOverlayOpacity") as? Double ?? 0.85 {
        didSet { UserDefaults.standard.set(opacity, forKey: "cameraOverlayOpacity") }
    }
    @Published private(set) var image: CGImage?
    /// The bed area the picture covers, in design mm.
    @Published private(set) var area: Rect2 = .empty
    @Published private(set) var updatedAt: Date?
    /// The bed picture's pixels (BGRA, unseen parts transparent), kept for tracing.
    private(set) var pixels: [UInt8] = []
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private(set) var mmPerPixel = 1.0

    func set(pixels: [UInt8], width: Int, height: Int, area: Rect2, mmPerPixel: Double) {
        self.pixels = pixels
        pixelWidth = width
        pixelHeight = height
        self.mmPerPixel = mmPerPixel
        self.area = area
        image = CameraFrame.cgImage(Data(pixels), width: width, height: height, bytesPerRow: width * 4, alpha: true)
        updatedAt = Date()
    }

    func clear() {
        pixels = []
        image = nil
        area = .empty
        updatedAt = nil
    }
}

/// Picks a camera, runs it, and keeps each camera's lens and bed calibration.
@MainActor
final class CameraController: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published var selectedID: String = UserDefaults.standard.string(forKey: "cameraDevice") ?? "" {
        didSet {
            guard selectedID != oldValue else { return }
            UserDefaults.standard.set(selectedID, forKey: "cameraDevice")
            lensViews = []
            lastDetection = nil
            clearAlignmentClicks()
            overlay.clear()
            if isRunning {
                stop()
                start()
            }
        }
    }
    @Published private(set) var isRunning = false
    @Published var message = ""
    @Published private(set) var frameSize: CGSize?
    /// Lens and bed calibration per camera (keyed by the camera's unique ID), saved between launches.
    @Published private(set) var setups: [String: CameraSetup] = CameraController.loadSetups()

    // Lens calibration
    @Published var boardColumns = UserDefaults.standard.object(forKey: "cameraBoardColumns") as? Int ?? 9 {
        didSet { UserDefaults.standard.set(boardColumns, forKey: "cameraBoardColumns") }
    }
    @Published var boardRows = UserDefaults.standard.object(forKey: "cameraBoardRows") as? Int ?? 6 {
        didSet { UserDefaults.standard.set(boardRows, forKey: "cameraBoardRows") }
    }
    /// Checkerboard views captured so far for the next lens calibration.
    @Published var lensViews: [CheckerboardView] = []
    /// The corners found in the last capture (shown on the picture), or nil.
    @Published var lastDetection: CheckerboardView?
    @Published private(set) var busy = false

    // Bed alignment
    /// The frozen picture the burned marks are clicked on.
    @Published private(set) var alignmentFrame: CameraFrame?
    @Published private(set) var alignmentImage: CGImage?
    /// Clicked mark positions in the frozen picture (raw pixels), in mark order; nil where not clicked yet.
    @Published var alignmentClicks: [Vec2?] = []
    /// The mark to click next.
    @Published var alignmentPick = 0
    @Published var alignmentSettings = CameraTargetSettings.load() {
        didSet { alignmentSettings.save() }
    }

    let overlay = CameraOverlay()
    let feed = CameraFeed()

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "KerfKutter.camera")
    private let store = FrameStore()
    private var timer: Timer?
    private var startedAt = Date.distantPast
    private var lastPreview = 0
    private var lastOverlay = Date.distantPast
    private var previewBusy = false
    private var overlayBusy = false
    private var remapCache: (key: RemapKey, remap: CameraRemap)?
    private var straightenCache: (key: RemapKey, remap: CameraRemap)?
    private var observers: [NSObjectProtocol] = []

    struct RemapKey: Hashable {
        var setup: CameraSetup
        var area: Rect2
        var mmPerPixel: Double
        var width: Int
        var height: Int
    }

    init() {
        refreshDevices()
        for name in ["AVCaptureDeviceWasConnectedNotification", "AVCaptureDeviceWasDisconnectedNotification"] {
            observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
    }

    // MARK: Devices

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                         mediaType: .video, position: .unspecified)
        devices = discovery.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        if !devices.contains(where: { $0.id == selectedID }), let first = devices.first {
            selectedID = first.id
        }
    }

    var selectedName: String { devices.first { $0.id == selectedID }?.name ?? "No camera" }

    /// The selected camera's calibration.
    var setup: CameraSetup {
        get { setups[selectedID] ?? CameraSetup() }
        set {
            setups[selectedID] = newValue
            if let data = try? JSONEncoder().encode(setups) { UserDefaults.standard.set(data, forKey: "cameraSetups") }
            remapCache = nil
            straightenCache = nil
        }
    }

    private static func loadSetups() -> [String: CameraSetup] {
        guard let data = UserDefaults.standard.data(forKey: "cameraSetups"),
              let s = try? JSONDecoder().decode([String: CameraSetup].self, from: data) else { return [:] }
        return s
    }

    // MARK: Running

    func start() {
        guard !isRunning else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            message = "This build of KerfKutter has no camera permission text, so macOS won't let it use the camera. Build the app with Xcode or swift build from the repository."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted { self.run() } else { self.message = "Camera access was turned down." }
                }
            }
        default:
            message = "KerfKutter isn't allowed to use the camera. Turn it on in System Settings › Privacy & Security › Camera."
        }
    }

    private func run() {
        refreshDevices()
        guard let device = AVCaptureDevice(uniqueID: selectedID) else {
            message = "No camera found. Plug in a USB camera and click refresh."
            return
        }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(store, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                message = "\(device.localizedName) is busy in another app."
                return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            message = "Could not open \(device.localizedName): \(error.localizedDescription)"
            return
        }
        Self.chooseBestFormat(device)
        session.commitConfiguration()
        store.clear()
        let s = session
        queue.async { s.startRunning() }
        isRunning = true
        startedAt = Date()
        message = ""
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// The largest picture up to about 5 MP: more detail for calibration without slowing everything down.
    private static func chooseBestFormat(_ device: AVCaptureDevice) {
        let formats = device.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width <= 2600 && d.height <= 2000 && $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 5 }
        }
        guard let best = formats.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription), b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            // Keep the camera's own choice.
        }
    }

    func stop() {
        guard isRunning else { return }
        let s = session
        queue.async { s.stopRunning() }
        isRunning = false
        timer?.invalidate()
        timer = nil
        store.clear()
        lastPreview = 0
    }

    /// Stops the camera unless the live overlay still needs it.
    func stopIfIdle() {
        if !(overlay.visible && overlay.live) && !feed.isShown { stop() }
    }

    /// The newest frame, waiting for the camera to start (and settle its exposure) if needed.
    func captureFrame() async -> CameraFrame? {
        if !isRunning { start() }
        guard isRunning else { return nil }
        let settle = startedAt.addingTimeInterval(1.2)
        for _ in 0..<60 {
            if Date() >= settle, let latest = store.latest(), let frame = CameraFrame(latest.0) { return frame }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        message = "The camera didn't send a picture."
        return nil
    }

    private func tick() {
        guard let latest = store.latest() else { return }
        let pb = latest.0, count = latest.1
        if frameSize == nil || frameSize != CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)) {
            frameSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        }
        if feed.isShown, count != lastPreview, !previewBusy, let frame = CameraFrame(pb) {
            lastPreview = count
            previewBusy = true
            let straighten = feed.straighten ? straightenRemap(for: frame) : nil
            Task.detached(priority: .userInitiated) {
                let image: CGImage?
                if let straighten {
                    image = CameraFrame.cgImage(Data(frame.remapped(straighten)), width: straighten.width, height: straighten.height,
                                                bytesPerRow: straighten.width * 4, alpha: true)
                } else {
                    image = frame.cgImage
                }
                await MainActor.run { [weak self] in
                    self?.feed.image = image
                    self?.feed.size = CGSize(width: frame.width, height: frame.height)
                    self?.previewBusy = false
                }
            }
        }
        if overlay.visible, overlay.live, Date().timeIntervalSince(lastOverlay) > 0.3, !overlayBusy,
           let profile = AppModel.current?.profile, let frame = CameraFrame(pb) {
            lastOverlay = Date()
            renderOverlay(frame, profile: profile)
        }
    }

    // MARK: Overlay

    /// Whether the selected camera is aligned to `profile`'s bed.
    func isAligned(to profile: DeviceProfile) -> Bool {
        guard let a = setup.alignment else { return false }
        return a.profileID == nil || a.profileID == profile.id
    }

    /// Takes a fresh picture and puts it on the canvas.
    func updateSnapshot(profile: DeviceProfile) async {
        guard isAligned(to: profile) else {
            message = setup.alignment == nil ? "Align the camera to the bed first (Camera window, Alignment)."
                : "This camera was aligned on another machine. Pick that machine or align again."
            return
        }
        guard let frame = await captureFrame() else { return }
        overlay.visible = true
        renderOverlay(frame, profile: profile)
        stopIfIdle()
    }

    private func renderOverlay(_ frame: CameraFrame, profile: DeviceProfile) {
        guard isAligned(to: profile) else { return }
        let area = Rect2(minX: 0, minY: 0, maxX: profile.bedWidth, maxY: profile.bedHeight)
        // About 1200 pixels across the longer side of the bed.
        let mm = max(0.1, max(area.width, area.height) / 1200)
        let key = RemapKey(setup: setup, area: area, mmPerPixel: mm, width: frame.width, height: frame.height)
        overlayBusy = true
        let cached = remapCache?.key == key ? remapCache?.remap : nil
        let setup = self.setup
        Task.detached(priority: .userInitiated) {
            let remap = cached ?? setup.bedRemap(area: area, mmPerPixel: mm, sourceWidth: frame.width, sourceHeight: frame.height)
            let pixels = remap.map { frame.remapped($0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.overlayBusy = false
                guard let remap, let pixels else { return }
                self.remapCache = (key, remap)
                self.overlay.set(pixels: pixels, width: remap.width, height: remap.height, area: area, mmPerPixel: mm)
            }
        }
    }

    private func straightenRemap(for frame: CameraFrame) -> CameraRemap? {
        let key = RemapKey(setup: setup, area: .empty, mmPerPixel: 0, width: frame.width, height: frame.height)
        if let c = straightenCache, c.key == key { return c.remap }
        guard setup.lens(width: frame.width, height: frame.height) != nil else { return nil }
        // Built once per lens; small enough to do here.
        guard let remap = setup.undistortRemap(sourceWidth: frame.width, sourceHeight: frame.height) else { return nil }
        straightenCache = (key, remap)
        return remap
    }

    // MARK: Lens calibration

    /// Looks for the checkerboard in the current picture and keeps the view when the whole board is found.
    func captureBoardView() async {
        guard !busy, let frame = await captureFrame() else { return }
        busy = true
        let cols = boardColumns, rows = boardRows
        let found = await Task.detached(priority: .userInitiated) {
            CheckerboardDetector.detect(frame.gray, columns: cols, rows: rows)
        }.value
        busy = false
        lastDetection = found
        if let found {
            if let first = lensViews.first, first.imageWidth != found.imageWidth || first.imageHeight != found.imageHeight {
                lensViews = []
            }
            lensViews.append(found)
            message = "Found all \(found.imagePoints.count) corners. View \(lensViews.count) kept."
        } else {
            message = "Couldn't see the whole \(cols + 1) × \(rows + 1)-square board. Keep all of it in view, evenly lit, and try again."
        }
    }

    /// Calibrates the lens from the captured views. Changing the lens clears the bed alignment (it was
    /// measured through the old lens values).
    func calibrateLens() async {
        let views = lensViews
        guard views.count >= LensCalibration.minimumViews else {
            message = "Capture at least \(LensCalibration.minimumViews) views (8 or more is better)."
            return
        }
        busy = true
        let lens = await Task.detached(priority: .userInitiated) { LensCalibration.calibrate(views) }.value
        busy = false
        guard let lens else {
            message = "The lens calibration didn't work out. Capture the board in more places, including tilted views."
            return
        }
        var s = setup
        let hadAlignment = s.alignment != nil
        s.lens = lens
        s.alignment = nil
        setup = s
        overlay.clear()
        message = String(format: "Lens calibrated from %ld views, average error %.2f pixels.", lens.views, lens.rmsError)
            + (hadAlignment ? " Align the camera to the bed again." : "")
    }

    func clearLens() {
        var s = setup
        s.lens = nil
        s.alignment = nil
        setup = s
        overlay.clear()
    }

    // MARK: Bed alignment

    /// Freezes the current picture for clicking the burned marks.
    func takeAlignmentSnapshot() async {
        guard let frame = await captureFrame() else { return }
        alignmentFrame = frame
        alignmentImage = frame.cgImage
        clearAlignmentClicks()
    }

    func clearAlignmentClicks() {
        alignmentClicks = Array(repeating: nil, count: alignmentSettings.markCount)
        alignmentPick = 0
    }

    func discardAlignmentSnapshot() {
        alignmentFrame = nil
        alignmentImage = nil
        clearAlignmentClicks()
    }

    /// Records a click on the frozen picture for the mark being picked, snapped to the mark's centre
    /// unless `snap` is off.
    func clickMark(at q: Vec2, snap: Bool) {
        guard let frame = alignmentFrame else { return }
        if alignmentClicks.count != alignmentSettings.markCount { clearAlignmentClicks() }
        guard alignmentPick < alignmentClicks.count else { return }
        var p = q
        if snap {
            let radius = snapRadius(frameWidth: frame.width)
            if let s = CameraAlignment.snapToMark(frame.gray, near: q, radius: radius) { p = s }
        }
        alignmentClicks[alignmentPick] = p
        alignmentPick = alignmentClicks.firstIndex { $0 == nil } ?? alignmentClicks.count
    }

    /// How far around a click to look for the mark, in pixels: from the marks already clicked when there
    /// are two, otherwise a few percent of the picture.
    private func snapRadius(frameWidth: Int) -> Double {
        let marks = alignmentSettings.marks
        let known = alignmentClicks.enumerated().compactMap { i, p in p.map { (i, $0) } }
        if known.count >= 2 {
            let (i, a) = known[0], (j, b) = known[1]
            let mm = marks[i].distance(to: marks[j])
            if mm > 1 { return max(6, a.distance(to: b) / mm * alignmentSettings.markSize * 0.75) }
        }
        return Double(frameWidth) * 0.03
    }

    /// The alignment from the clicked marks, if enough are clicked.
    func alignmentFit() -> (homography: Homography, rms: Double, max: Double)? {
        guard let frame = alignmentFrame else { return nil }
        let marks = alignmentSettings.marks
        let lens = setup.lens(width: frame.width, height: frame.height)
        var image: [Vec2] = [], bed: [Vec2] = []
        for (i, p) in alignmentClicks.enumerated() where i < marks.count {
            guard let p else { continue }
            image.append(lens?.undistortPixel(p) ?? p)
            bed.append(marks[i])
        }
        return CameraAlignment.fit(image: image, bed: bed)
    }

    /// Saves the alignment for `profile` and shows the camera on the canvas.
    func saveAlignment(profile: DeviceProfile) {
        guard let frame = alignmentFrame, let fit = alignmentFit() else { return }
        if setup.lens != nil, setup.lens(width: frame.width, height: frame.height) == nil {
            message = "The camera's picture size changed since the lens was calibrated. Calibrate the lens again."
            return
        }
        var s = setup
        s.alignment = BedAlignment(imageWidth: frame.width, imageHeight: frame.height, imageToBed: fit.homography,
                                   profileID: profile.id, rmsError: fit.rms, maxError: fit.max)
        setup = s
        message = String(format: "Alignment saved: marks within %.2f mm on average (worst %.2f mm).", fit.rms, fit.max)
        renderOverlay(frame, profile: profile)
        overlay.visible = true
    }

    func clearAlignment() {
        var s = setup
        s.alignment = nil
        setup = s
        overlay.clear()
    }
}

/// Where and how the alignment target is burned, remembered between launches.
struct CameraTargetSettings: Codable, Hashable {
    /// Space between the target and the bed's edges, mm.
    var margin = 40.0
    var columns = 3
    var rows = 3
    var markSize = 12.0
    var speed = 1500.0
    var power = 25.0
    /// The bed the marks are spread over (set from the machine when the target is made).
    var bedWidth = 400.0
    var bedHeight = 400.0

    var markCount: Int { max(2, columns) * max(2, rows) }

    var area: Rect2 {
        let m = max(0, min(margin, min(bedWidth, bedHeight) / 2 - 5))
        return Rect2(minX: m, minY: m, maxX: bedWidth - m, maxY: bedHeight - m)
    }

    var marks: [Vec2] { CameraAlignment.markCentres(in: area, columns: columns, rows: rows) }

    static func load() -> CameraTargetSettings {
        guard let data = UserDefaults.standard.data(forKey: "cameraTarget"),
              let s = try? JSONDecoder().decode(CameraTargetSettings.self, from: data) else { return CameraTargetSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "cameraTarget") }
    }
}
