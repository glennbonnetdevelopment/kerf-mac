import AppKit
import KerfCore
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, line, shape, text

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .shape: return "star"
        case .text: return "textformat"
        }
    }

    var title: String { self == .shape ? "Shapes" : rawValue.capitalized }
}

/// Where the job's coordinates are measured from.
enum JobOrigin: String, CaseIterable, Identifiable {
    /// Positions on the canvas are machine positions (from home).
    case absolute
    /// The chosen anchor point becomes X0 Y0; set the machine's work zero there ("Set origin here").
    case userOrigin
    /// The chosen anchor point starts wherever the head is when you press Start.
    case currentPosition
    var id: String { rawValue }
    var title: String {
        switch self {
        case .absolute: return "Machine home (absolute)"
        case .userOrigin: return "Work zero (user origin)"
        case .currentPosition: return "Current head position"
        }
    }
}

/// One of nine points on a box: corners, edge midpoints and centre.
enum OriginAnchor: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: String { rawValue }
    /// Position as fractions of the box, y down.
    var fraction: Vec2 {
        let i = OriginAnchor.allCases.firstIndex(of: self)!
        return Vec2(Double(i % 3) / 2, Double(i / 3) / 2)
    }
    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top centre"
        case .topRight: return "Top right"
        case .left: return "Left centre"
        case .center: return "Centre"
        case .right: return "Right centre"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        }
    }
}

/// What the zero anchor is measured on.
enum OriginReference: String, CaseIterable, Identifiable {
    case job, workpiece
    var id: String { rawValue }
    var title: String { self == .job ? "Job outline" : "Workpiece" }
}

/// Document, selection, device profiles and editing operations.
@MainActor
final class AppModel: ObservableObject {
    @Published var document = KerfDocument() {
        didSet { cachedToolpath = nil }
    }
    @Published var selection: Set<UUID> = [] {
        didSet { if selection != oldValue { syncTextFieldsFromSelection() } }
    }
    @Published var currentLayerID: UUID?
    @Published var tool: Tool = .select
    @Published var showToolpath = false
    @Published var fileURL: URL?
    @Published var alertMessage: String?
    @Published var jobOrigin: JobOrigin = .absolute
    @Published var originAnchor: OriginAnchor = .bottomLeft
    @Published var originReference: OriginReference = .job
    @Published var weedBorderEnabled = false
    @Published var weedBorderMargin = 3.0

    // Nesting
    @Published var nestSpacing = 3.0
    @Published var nestAllowRotation = true

    // Text along a path
    @Published var pathTextFlip = false

    // Print and cut: measured machine positions of registration marks 1 and 2
    @Published var shapeKind: ShapeKind = .star
    @Published var shapeOptions = ShapeOptions()
    @Published var registrationStyle: RegistrationStyle = .square
    @Published var registrationMarkSize = 5.0
    @Published var registrationMarkCount = 3
    @Published var registrationMargin = 8.0
    @Published var measuredMark1: Vec2?
    @Published var measuredMark2: Vec2?
    @Published var useAlignment = false

    // Text tool settings
    /// Text tool settings. When one text shape is selected they show and edit that text.
    @Published var textToAdd = "Kerf" { didSet { applyTextFieldsToSelection() } }
    @Published var fontName = "Helvetica-Bold" { didSet { applyTextFieldsToSelection() } }
    @Published var textHeight = 20.0 { didSet { applyTextFieldsToSelection() } }
    private var syncingText = false
    private var lastTextEdit: (id: UUID, time: Date)?

    @Published var profiles: [DeviceProfile] {
        didSet { saveProfiles() }
    }
    @Published var activeProfileID: UUID {
        didSet {
            UserDefaults.standard.set(activeProfileID.uuidString, forKey: "activeProfile")
            cachedToolpath = nil
        }
    }

    private var undoStack: [KerfDocument] = []
    private var redoStack: [KerfDocument] = []
    private var cachedToolpath: Toolpath?

    init() {
        var loaded: [DeviceProfile] = []
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data), !decoded.isEmpty {
            loaded = decoded
        } else {
            loaded = [.defaultLaser, .defaultCutter]
        }
        profiles = loaded
        let savedID = UserDefaults.standard.string(forKey: "activeProfile").flatMap(UUID.init(uuidString:))
        activeProfileID = loaded.first { $0.id == savedID }?.id ?? loaded[0].id
        newDocument()
    }

    // MARK: - Profiles

    var profile: DeviceProfile {
        get { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
        set {
            if let i = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[i] = newValue
                cachedToolpath = nil
            }
        }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "profiles")
        }
    }

    var defaultMode: LayerMode { profile.kind.defaultMode }

    // MARK: - Undo

    func checkpoint() {
        undoStack.append(document)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(document)
        document = prev
        pruneSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        pruneSelection()
    }

    private func pruneSelection() {
        let ids = Set(document.shapes.map(\.id))
        selection = selection.intersection(ids)
        if let c = currentLayerID, document.layer(c) == nil { currentLayerID = document.layers.first?.id }
    }

    // MARK: - Toolpath

    var toolpath: Toolpath {
        if let t = cachedToolpath { return t }
        let t = Planner.plan(document, for: profile.kind)
        cachedToolpath = t
        return t
    }

    // MARK: - Files

    func newDocument() {
        var doc = KerfDocument()
        let id = doc.addLayer(mode: defaultMode)
        document = doc
        currentLayerID = id
        selection = []
        fileURL = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    static let dxfType = UTType(filenameExtension: "dxf") ?? .data
    static let kerfType = UTType(filenameExtension: "kerf") ?? .json

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg, Self.dxfType]
        panel.allowsMultipleSelection = true
        panel.message = "Choose SVG or DXF files to import"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importFile(url) }
    }

    func importFile(_ url: URL) {
        do {
            let groups: [ImportedGroup]
            if url.pathExtension.lowercased() == "dxf" {
                groups = try DXFImporter.importFile(at: url)
            } else {
                groups = try SVGImporter.importFile(at: url)
            }
            checkpoint()
            // Drop the default empty layer if it is unused and the file brings its own colours.
            if document.shapes.isEmpty, document.layers.count == 1 { document.layers.removeAll() }
            var added: Set<UUID> = []
            for g in groups {
                let layerID = document.layer(forColor: g.colorHex, defaultMode: defaultMode)
                let shape = Artwork(layerID: layerID, name: url.deletingPathExtension().lastPathComponent, paths: g.paths)
                document.shapes.append(shape)
                added.insert(shape.id)
            }
            selection = added
            if currentLayerID == nil || document.layer(currentLayerID!) == nil {
                currentLayerID = document.layers.first?.id
            }
        } catch {
            alertMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.kerfType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            document = try KerfDocument.decode(Data(contentsOf: url))
            fileURL = url
            selection = []
            currentLayerID = document.layers.first?.id
            undoStack.removeAll()
            redoStack.removeAll()
        } catch {
            alertMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func saveProject(saveAs: Bool = false) {
        var url = fileURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.kerfType]
            panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.kerf"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let target = url else { return }
        do {
            try document.encoded().write(to: target, options: .atomic)
            fileURL = target
        } catch {
            alertMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    /// G-code for the active laser profile.
    func gcodeLines(offset: Vec2 = .zero) -> [String] {
        GCodeGenerator.generate(toolpath, profile: profile, offset: useAlignment ? .zero : offset, alignment: alignmentTransform)
    }

    /// HPGL or GP-GL for the active cutter profile.
    func plotterText() -> String {
        PlotterGenerator.generate(toolpath, profile: profile,
                                  options: CutterJobOptions(weedBorder: weedBorderEnabled ? weedBorderMargin : nil))
    }

    func exportMachineFile() {
        guard !toolpath.isEmpty else {
            alertMessage = "Nothing to export: add shapes to an enabled layer first."
            return
        }
        let panel = NSSavePanel()
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "job"
        let text: String
        if profile.kind.usesGRBL {
            panel.allowedContentTypes = [UTType(filenameExtension: "gc") ?? .plainText]
            panel.nameFieldStringValue = base + ".gc"
            // A file can't know where the head will be, so current-position jobs are written from the zero point.
            text = gcodeLines(offset: jobOffset(head: nil)).joined(separator: "\n") + "\n"
        } else {
            let ext = profile.language.fileExtension
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
            panel.nameFieldStringValue = base + "." + ext
            text = plotterText()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = "Could not export: \(error.localizedDescription)"
        }
    }

    // MARK: - Layers

    func ensureCurrentLayer() -> UUID {
        if let id = currentLayerID, document.layer(id) != nil { return id }
        let id = document.layers.first?.id ?? document.addLayer(mode: defaultMode)
        currentLayerID = id
        return id
    }

    func addLayer() {
        checkpoint()
        currentLayerID = document.addLayer(mode: defaultMode)
    }

    func removeLayer(_ id: UUID) {
        checkpoint()
        document.shapes.removeAll { $0.layerID == id }
        document.layers.removeAll { $0.id == id }
        if document.layers.isEmpty { document.addLayer(mode: defaultMode) }
        pruneSelection()
        if currentLayerID == id { currentLayerID = document.layers.first?.id }
    }

    func moveSelection(toLayer id: UUID) {
        guard !selection.isEmpty else { return }
        checkpoint()
        for i in document.shapes.indices where selection.contains(document.shapes[i].id) {
            document.shapes[i].layerID = id
        }
    }

    func layerBinding(_ id: UUID) -> Binding<Layer>? {
        guard document.layer(id) != nil else { return nil }
        return Binding(
            get: { [weak self] in self?.document.layer(id) ?? Layer(name: "", colorHex: "#000000") },
            set: { [weak self] newValue in
                guard let self, let i = self.document.layers.firstIndex(where: { $0.id == id }) else { return }
                self.document.layers[i] = newValue
            }
        )
    }

    // MARK: - Shapes

    func addShape(paths: [Polyline], name: String) {
        guard !paths.isEmpty else { return }
        checkpoint()
        let shape = Artwork(layerID: ensureCurrentLayer(), name: name, paths: paths)
        document.shapes.append(shape)
        selection = [shape.id]
    }

    func addText(at point: Vec2) {
        let spec = TextSpec(text: textToAdd, fontName: fontName, height: textHeight)
        let outlines = TextOutliner.outlines(for: spec)
        guard !outlines.isEmpty else {
            alertMessage = "The text produced no outlines. Check the font name."
            return
        }
        checkpoint()
        let shape = Artwork(layerID: ensureCurrentLayer(), name: "Text: \(spec.text)", paths: outlines,
                            transform: .translation(point.x, point.y), text: spec)
        document.shapes.append(shape)
        selection = [shape.id]
    }

    /// The single selected text shape, if any.
    var selectedText: Artwork? {
        guard selection.count == 1, let shape = selectedShapes.first, shape.text != nil else { return nil }
        return shape
    }

    private func syncTextFieldsFromSelection() {
        guard let spec = selectedText?.text else { return }
        syncingText = true
        textToAdd = spec.text
        fontName = spec.fontName
        textHeight = spec.height
        syncingText = false
    }

    /// Typing in the text tool edits the selected text. Quick successive edits share one undo step.
    private func applyTextFieldsToSelection() {
        guard !syncingText, let shape = selectedText, let old = shape.text, !textToAdd.isEmpty else { return }
        let spec = TextSpec(text: textToAdd, fontName: fontName, height: max(0.5, textHeight))
        guard spec != old else { return }
        let now = Date()
        let coalesce = lastTextEdit.map { $0.id == shape.id && now.timeIntervalSince($0.time) < 1.5 } ?? false
        updateText(shape.id, to: spec, recordUndo: !coalesce)
        lastTextEdit = (shape.id, now)
    }

    /// Rebuilds a text shape's outlines from new settings, keeping its placement, rotation and mirroring.
    func updateText(_ id: UUID, to spec: TextSpec, recordUndo: Bool = true) {
        guard let i = document.shapes.firstIndex(where: { $0.id == id }), document.shapes[i].text != nil else { return }
        let outlines = document.shapes[i].pathText.map { TextOutliner.alongPath(spec, pathText: $0) } ?? TextOutliner.outlines(for: spec)
        guard !outlines.isEmpty else { return }
        if recordUndo { checkpoint() }
        document.shapes[i].paths = outlines
        document.shapes[i].text = spec
        document.shapes[i].name = "Text: \(spec.text)"
    }

    /// Sets the CNC cut type for the selected shapes (nil follows the layer's default).
    func setMillRole(_ role: MillRole?) {
        guard !selection.isEmpty else { return }
        checkpoint()
        for i in document.shapes.indices where selection.contains(document.shapes[i].id) {
            document.shapes[i].millRole = role
        }
    }

    /// The cut type shared by every selected shape, or nil when they differ or follow the layer.
    var selectionMillRole: MillRole? {
        let roles = Set(selectedShapes.map { $0.millRole })
        return roles.count == 1 ? roles.first! : nil
    }

    var selectedShapes: [Artwork] { document.shapes.filter { selection.contains($0.id) } }

    var selectionBounds: Rect2 { selectedShapes.reduce(Rect2.empty) { $0.union($1.bounds) } }

    /// Applies `t` (in bed coordinates) to all selected shapes.
    func transformSelection(_ t: Affine, recordUndo: Bool = true) {
        guard !selection.isEmpty else { return }
        if recordUndo { checkpoint() }
        for i in document.shapes.indices where selection.contains(document.shapes[i].id) {
            document.shapes[i].transform = document.shapes[i].transform.then(t)
        }
    }

    /// Sets each listed shape's transform to its saved `base` followed by `t` (used while dragging handles).
    func applyTransform(_ t: Affine, toBase base: [UUID: Affine]) {
        for i in document.shapes.indices {
            if let b = base[document.shapes[i].id] { document.shapes[i].transform = b.then(t) }
        }
    }

    func moveSelection(by d: Vec2, recordUndo: Bool = true) {
        transformSelection(.translation(d.x, d.y), recordUndo: recordUndo)
    }

    func setSelectionFrame(x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil, keepAspect: Bool) {
        let b = selectionBounds
        guard !b.isEmpty else { return }
        var sx = 1.0, sy = 1.0
        if let w = width, w > 0, b.width > 0 { sx = w / b.width }
        if let h = height, h > 0, b.height > 0 { sy = h / b.height }
        if keepAspect {
            if width != nil { sy = sx } else if height != nil { sx = sy }
        }
        if b.width == 0 { sx = 1 }
        if b.height == 0 { sy = 1 }
        let nx = x ?? b.minX, ny = y ?? b.minY
        let t = Affine.translation(-b.minX, -b.minY).then(.scale(sx, sy)).then(.translation(nx, ny))
        transformSelection(t)
    }

    func rotateSelection(degrees: Double) {
        let c = selectionBounds.center
        transformSelection(Affine.translation(-c.x, -c.y).then(.rotation(degrees * .pi / 180)).then(.translation(c.x, c.y)))
    }

    func mirrorSelection(horizontal: Bool) {
        let c = selectionBounds.center
        let s = horizontal ? Affine.scale(-1, 1) : Affine.scale(1, -1)
        transformSelection(Affine.translation(-c.x, -c.y).then(s).then(.translation(c.x, c.y)))
    }

    /// Centres the selection on the workpiece when there is one, otherwise on the bed.
    func centerSelectionOnBed() {
        let b = selectionBounds
        guard !b.isEmpty else { return }
        moveSelection(by: workArea.center - b.center)
    }

    /// The workpiece if one is set, otherwise the whole bed.
    var workArea: Rect2 {
        document.workpiece?.rect ?? Rect2(minX: 0, minY: 0, maxX: profile.bedWidth, maxY: profile.bedHeight)
    }

    func setWorkpiece(_ w: Workpiece?) {
        guard document.workpiece != w else { return }
        checkpoint()
        document.workpiece = w
    }

    /// Shapes that reach outside the workpiece.
    var shapesOutsideWorkpiece: Int {
        guard let r = document.workpiece?.rect else { return 0 }
        return document.shapes.filter { !r.contains($0.bounds, tolerance: 0.01) && document.layer($0.layerID)?.mode != .print }.count
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        checkpoint()
        document.shapes.removeAll { selection.contains($0.id) }
        selection = []
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        checkpoint()
        var added: Set<UUID> = []
        for s in selectedShapes {
            var copy = s
            copy.id = UUID()
            copy.transform = copy.transform.then(.translation(5, 5))
            document.shapes.append(copy)
            added.insert(copy.id)
        }
        selection = added
    }

    func selectAll() {
        selection = Set(document.shapes.map(\.id))
    }

    /// Topmost shape under `p` (bed mm), within `tolerance` mm of an outline or inside a closed one.
    func hitTest(_ p: Vec2, tolerance: Double) -> UUID? {
        for shape in document.shapes.reversed() {
            guard document.layer(shape.layerID) != nil else { continue }
            let b = shape.bounds.insetBy(-tolerance)
            guard b.contains(p) else { continue }
            var inside = false
            for path in shape.placedPaths {
                let pts = path.drawnPoints
                guard pts.count > 1 else { continue }
                for i in 1..<pts.count where distanceToSegment(p, pts[i - 1], pts[i]) <= tolerance {
                    return shape.id
                }
                if path.closed {
                    for i in 1..<pts.count {
                        let a = pts[i - 1], c = pts[i]
                        if (a.y > p.y) != (c.y > p.y), p.x < (c.x - a.x) * (p.y - a.y) / (c.y - a.y) + a.x {
                            inside.toggle()
                        }
                    }
                }
            }
            if inside { return shape.id }
        }
        return nil
    }

    private func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / len2))
        return p.distance(to: a + ab * t)
    }

    /// Machine-space bounds of the current job (for framing and offsets).
    /// The design-space point that becomes the job's zero, or nil for absolute jobs.
    var jobZeroPoint: Vec2? {
        guard jobOrigin != .absolute else { return nil }
        let box: Rect2
        if originReference == .workpiece, let w = document.workpiece {
            box = w.rect
        } else {
            box = toolpath.bounds
        }
        guard !box.isEmpty else { return nil }
        let f = originAnchor.fraction
        return Vec2(box.minX + box.width * f.x, box.minY + box.height * f.y)
    }

    /// Machine offset that puts the job's zero point at work X0 Y0, or at `head` for current-position jobs.
    func jobOffset(head: Vec2?) -> Vec2 {
        guard !useAlignment, let zero = jobZeroPoint else { return .zero }
        let base = profile.toMachine(zero)
        switch jobOrigin {
        case .absolute: return .zero
        case .userOrigin: return Vec2(-base.x, -base.y)
        case .currentPosition: return (head ?? .zero) - base
        }
    }

    func jobMachineBounds() -> Rect2 {
        let b = toolpath.bounds
        guard !b.isEmpty else { return .empty }
        var r = Rect2.empty
        for c in [Vec2(b.minX, b.minY), Vec2(b.maxX, b.minY), Vec2(b.maxX, b.maxY), Vec2(b.minX, b.maxY)] {
            r.include(profile.toMachine(c))
        }
        return r
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02lX%02lX%02lX",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
