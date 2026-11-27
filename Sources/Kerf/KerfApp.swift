import AppKit
import KerfCore
import SwiftUI

@main
struct KerfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var laser = LaserController()
    @StateObject private var cutter = CutterSender()
    @StateObject private var camera = CameraController()

    var body: some Scene {
        WindowGroup("KerfKutter") {
            ContentView()
                .environmentObject(model)
                .environmentObject(laser)
                .environmentObject(cutter)
                .environmentObject(camera)
                .environmentObject(camera.overlay)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { model.newDocument() }
                    .keyboardShortcut("n")
                Button("Open…") { model.openProject() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveProject() }
                    .keyboardShortcut("s")
                Button("Save As…") { model.saveProject(saveAs: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Import SVG, DXF, LightBurn or Easy Cut…") { model.importFiles() }
                    .keyboardShortcut("i")
                Button("Import Image to Engrave…") { model.importImages() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Machine File…") { model.exportMachineFile() }
                    .keyboardShortcut("e")
                Button("Export for KerfSender…") { model.exportForSender() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Print PDF…") { model.exportPrintPDF() }
                Button("Export Embroidery (PES, JEF, DST)…") { model.showEmbroideryExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .printItem) {
                Button("Print Preview…") { model.showPrintPreview = true }
                    .keyboardShortcut("p")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Arrange") {
                Button("Select All Shapes") { model.selectAll() }
                Button("Duplicate") { model.duplicateSelection() }
                    .keyboardShortcut("d")
                Button("Delete") { model.deleteSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("Rotate 90° Clockwise") { model.rotateSelection(degrees: 90) }
                    .keyboardShortcut("r")
                Button("Rotate 90° Counter-clockwise") { model.rotateSelection(degrees: -90) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Mirror Horizontally") { model.mirrorSelection(horizontal: true) }
                Button("Mirror Vertically") { model.mirrorSelection(horizontal: false) }
                Button("Centre on Bed") { model.centerSelectionOnBed() }
                Divider()
                Button("Weld") { model.combineSelection(.weld) }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                Button("Subtract") { model.combineSelection(.subtract) }
                Button("Intersect") { model.combineSelection(.intersect) }
                Button("Join Open Paths") { model.joinSelectedPaths() }
                    .keyboardShortcut("j")
                Button("Break Apart") { model.breakApartSelection() }
                Divider()
                Button("Nest on Bed") { model.nest() }
                Button("Put Text Around Selected Shape") { model.addTextAlongSelection() }
                Button("Add Registration Marks") { model.addRegistrationMarks() }
                Button("Add Contour Cut Around Artwork") { model.addContourCut() }
                Button("Rhinestone Layout…") { model.showRhinestones = true }
                    .keyboardShortcut("k", modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
                OpenPreviewButton()
                CameraMenuItems(overlay: camera.overlay, camera: camera, model: model)
            }
            CommandGroup(replacing: .help) {
                OpenHelpButton()
            }
        }

        Window("Material Preview", id: "material-preview") {
            MaterialPreviewView()
                .environmentObject(model)
        }
        .defaultSize(width: 820, height: 640)

        Window("Material Library", id: "material-library") {
            MaterialLibraryView()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 640)

        // One window like the others, so the main window keeps its File menu commands.
        Window("Edit Stitches", id: "stitch-editor") {
            StitchEditorHost()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 700)

        // Camera calibration and overlay controls (see CameraWindow).
        Window("Camera", id: "camera") {
            CameraWindowView()
                .environmentObject(model)
                .environmentObject(camera)
                .environmentObject(laser)
        }
        .defaultSize(width: 1180, height: 760)

        Window("KerfKutter Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 960, height: 680)
    }
}

/// Opens the wood-look carving preview.
struct OpenPreviewButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Material Preview") { openWindow(id: "material-preview") }
            .keyboardShortcut("p", modifiers: [.command, .option])
        Button("Material Library") { openWindow(id: "material-library") }
            .keyboardShortcut("l", modifiers: [.command, .option])
    }
}

/// A plain SwiftPM executable starts as a background process; make it a regular app with a menu bar and Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Offer to save unsaved changes when quitting (or closing the window, which quits).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = AppModel.current else { return .terminateNow }
            return model.confirmDiscardChanges(action: "quitting") ? .terminateNow : .terminateCancel
        }
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case layers = "Layers", arrange = "Arrange", machine = "Machine"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: SidebarTab = .layers

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                EditorToolbar()
                    .background(WindowCloseGuard())
                Divider()
                CanvasView()
            }
            .frame(minWidth: 520, maxWidth: .infinity)

            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(SidebarTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                Group {
                    switch tab {
                    case .layers: LayersPanel()
                    case .arrange: ArrangePanel()
                    case .machine: MachinePanel()
                    }
                }
                .padding([.horizontal, .bottom], 10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 330, idealWidth: 360, maxWidth: 480)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.importFiles() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import SVG or DXF")
                Button { model.importImages() } label: { Label("Image", systemImage: "photo") }
                    .help("Import an image to engrave")
                Toggle(isOn: $model.showToolpath) { Label("Preview", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    .help("Show toolpath order and travel moves")
                CameraToolbarItems()
                if model.profile.kind == .cncRouter {
                    MaterialPreviewToolbarButton()
                }
                Picker("Device", selection: $model.activeProfileID) {
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
                .frame(width: 220)
            }
        }
        .navigationTitle(model.fileURL?.lastPathComponent ?? "KerfKutter")
        .sheet(isPresented: $model.showEmbroideryExport) {
            EmbroideryExportView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showPrintPreview) {
            PrintPreviewView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showRhinestones) {
            RhinestoneView()
                .environmentObject(model)
        }
        .alert("KerfKutter", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let ext = url.pathExtension.lowercased()
                    if AppModel.importExtensions.contains(ext) {
                        Task { @MainActor in model.importFile(url) }
                    } else if ["png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "heic"].contains(ext) {
                        Task { @MainActor in model.importImage(url) }
                    }
                }
            }
            return true
        }
    }
}

struct MaterialPreviewToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "material-preview") } label: { Label("Wood preview", systemImage: "cube.transparent") }
            .help("Show the carving on a block of wood")
    }
}

/// Asks to save unsaved changes when the main window's close button is pressed. It sits in front of
/// SwiftUI's own window delegate and passes everything else through to it.
struct WindowCloseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, !(window.delegate is CloseGuardDelegate) else { return }
            let guardDelegate = CloseGuardDelegate(original: window.delegate)
            context.coordinator.delegate = guardDelegate
            window.delegate = guardDelegate
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Keeps the delegate alive (windows hold their delegate weakly).
        var delegate: CloseGuardDelegate?
    }
}

final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    init(original: NSWindowDelegate?) {
        self.original = original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let ok = MainActor.assumeIsolated { AppModel.current?.confirmDiscardChanges(action: "closing") ?? true }
        guard ok else { return false }
        // Changes are saved or discarded, so the quit check that follows won't ask again.
        MainActor.assumeIsolated { AppModel.current?.savedDocument = AppModel.current?.document ?? KerfDocument() }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}
