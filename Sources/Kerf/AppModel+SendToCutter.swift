import Foundation
import KerfCore

/// The Send to Cutter sheet: the job as it will go to the cutter, and sending it.
extension AppModel {
    /// The job goes out one panel at a time (a sign bigger than the cutter).
    var cutterSendsPanels: Bool { panelsActive && panelLayout.isSplit }

    /// Why the job can't be moved into the home corner right now, or nil when it can.
    var homeCornerUnavailableReason: String? {
        if manualRegistrationTransform != nil {
            return "Manual registration places the cut on the printed marks."
        }
        if aasActive {
            return "The cutter places the cut from the printed marks it reads."
        }
        if !allRegistrationPoints.isEmpty {
            return "This design has registration marks, so it is cut where it sits on the printed sheet."
        }
        if cutterSendsPanels {
            return "Each panel is already moved to the cutter's origin."
        }
        return nil
    }

    /// The exact cutter data the Send button sends: the current panel when panels are on, else the whole job.
    func cutterJobText() -> String {
        if cutterSendsPanels, let panel = currentPanel { return panelPlotterText(panel) }
        return plotterText()
    }

    /// The job as the cutter will cut it, in canvas layout (front of the cutter at the bottom).
    func cutterPreview() -> CutterPreview {
        CutterPreview.parse(cutterJobText(), profile: profile).inDesignSpace(profile)
    }

    /// Sends the job (or the current panel) to the cutter.
    func sendCutterJob(with cutter: CutterSender) {
        if cutterSendsPanels, let panel = currentPanel {
            sendPanel(panel, with: cutter)
        } else {
            cutter.send(plotterText(), profile: profile)
        }
    }

    /// Layers that the cutter cuts, in order.
    var cutterLayerIDs: [UUID] {
        let used = Set(toolpath.layers.map(\.layer.id))
        return document.layers.filter { $0.mode == .cut && $0.output != .embroidery && used.contains($0.id) }.map(\.id)
    }

    /// Puts a saved vinyl material's force, speed, passes and blade on every cut layer in the job (undoable as one step).
    func applyMaterialToCutLayers(_ id: UUID) {
        guard let m = materials.material(id) else { return }
        let ids = cutterLayerIDs
        guard !ids.isEmpty else { return }
        checkpoint()
        for layerID in ids {
            guard let i = document.layers.firstIndex(where: { $0.id == layerID }) else { continue }
            m.apply(to: &document.layers[i])
            if document.layers[i].name.hasPrefix("Layer ") { document.layers[i].name = m.title }
        }
    }
}
