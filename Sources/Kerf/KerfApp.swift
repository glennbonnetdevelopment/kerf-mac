import AppKit
import KerfCore
import SwiftUI

@main
struct KerfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var laser = LaserController()
    @StateObject private var cutter = CutterSender()

    var body: some Scene {
        WindowGroup("Kerf") {
            ContentView()
                .environmentObject(model)
                .environmentObject(laser)
                .environmentObject(cutter)
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
                Button("Import SVG or DXF…") { model.importFiles() }
                    .keyboardShortcut("i")
                Button("Import Image to Engrave…") { model.importImages() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Machine File…") { model.exportMachineFile() }
                    .keyboardShortcut("e")
                Button("Export Print PDF…") { model.exportPrintPDF() }
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
            }
        }
    }
}

/// A plain SwiftPM executable starts as a background process; make it a regular app with a menu bar and Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
            HStack(spacing: 0) {
                toolStrip
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
                Picker("Device", selection: $model.activeProfileID) {
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
                .frame(width: 220)
            }
        }
        .navigationTitle(model.fileURL?.lastPathComponent ?? "Kerf")
        .alert("Kerf", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let ext = url.pathExtension.lowercased()
                    if ["svg", "dxf"].contains(ext) {
                        Task { @MainActor in model.importFile(url) }
                    } else if ["png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "heic"].contains(ext) {
                        Task { @MainActor in model.importImage(url) }
                    }
                }
            }
            return true
        }
    }

    private var toolStrip: some View {
        VStack(spacing: 6) {
            ForEach(Tool.allCases) { t in
                Button { model.tool = t } label: {
                    Image(systemName: t.symbol)
                        .frame(width: 28, height: 28)
                        .background(model.tool == t ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
            Spacer()
        }
        .padding(6)
    }
}
