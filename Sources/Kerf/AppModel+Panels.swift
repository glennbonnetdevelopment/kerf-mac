import AppKit
import KerfCore
import UniformTypeIdentifiers

/// Panel (tiling) cutting: vinyl signs bigger than the cutter are cut as overlapping panels, one at a time.
extension AppModel {
    /// Panels are on for the current machine.
    var panelsActive: Bool { profile.kind == .vinylCutter && panels.enabled }

    /// How the current job splits into panels (one panel when it fits the machine).
    var panelLayout: PanelLayout {
        if let l = cachedPanelLayout { return l }
        let l = Panels.layout(for: toolpath, profile: profile, options: panels)
        cachedPanelLayout = l
        return l
    }

    /// The selected panel, kept inside the layout when the panel count changes.
    var currentPanel: Panel? {
        let list = panelLayout.panels
        guard !list.isEmpty else { return nil }
        return list[min(max(0, selectedPanel), list.count - 1)]
    }

    func isPanelSent(_ panel: Panel) -> Bool { sentPanels.contains(panel.rect) }

    /// One panel's job, mirrored when Mirror output is on and moved to the machine origin.
    /// It sits in from the origin by the weeding margin when there is a weeding box, so the box fits on the vinyl.
    func panelToolpath(_ panel: Panel) -> Toolpath {
        let inset = profile.kind == .vinylCutter && weeding.box != .none ? max(0, weeding.margin) + 1 : 0
        return Panels.toolpath(toolpath, panel: panel, layout: panelLayout, profile: profile,
                               mirror: mirrorOutput, inset: inset)
    }

    /// HPGL, GP-GL or SVG for one panel, weeding included.
    func panelPlotterText(_ panel: Panel) -> String {
        PlotterGenerator.generate(panelToolpath(panel), profile: profile, options: CutterJobOptions(weeding: weeding))
    }

    /// Sends one panel, ticks it off and moves on to the next panel not yet sent.
    func sendPanel(_ panel: Panel, with cutter: CutterSender) {
        cutter.send(panelPlotterText(panel), profile: profile)
        sentPanels.insert(panel.rect)
        selectNextUnsentPanel(after: panel)
    }

    func selectNextUnsentPanel(after panel: Panel) {
        let list = panelLayout.panels
        guard !list.isEmpty else { return }
        for k in 1...list.count {
            let p = list[(panel.index + k) % list.count]
            if !isPanelSent(p) {
                selectedPanel = p.index
                return
            }
        }
    }

    func resetSentPanels() {
        sentPanels.removeAll()
        selectedPanel = 0
    }

    /// Saves every panel as its own machine file (name-A1.plt, name-A2.plt, …) in a folder the user picks.
    func exportPanels() {
        let layout = panelLayout
        guard !layout.panels.isEmpty else {
            alertMessage = "Nothing to export: add shapes to an enabled layer first."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Panels"
        panel.message = "Choose a folder for the \(layout.panels.count) panel files."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "job"
        let ext = profile.language.fileExtension
        do {
            for p in layout.panels {
                let url = folder.appendingPathComponent("\(base)-\(p.name).\(ext)")
                try panelPlotterText(p).write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            alertMessage = "Could not export the panels: \(error.localizedDescription)"
        }
    }
}
