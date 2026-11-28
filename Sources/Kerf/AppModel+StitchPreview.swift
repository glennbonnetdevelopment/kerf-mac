import Foundation
import KerfCore

/// The canvas stitch preview: the whole design digitized in the background and drawn as thread.
extension AppModel {
    /// Digitizes the current document for the preview, after a short pause so dragging and typing stay smooth.
    func scheduleStitchPreview(immediately: Bool = false) {
        let doc = stitchSource
        guard showStitchPreview, stitchPreviewSource != doc else { return }
        stitchPreviewSource = doc
        stitchPreviewTask?.cancel()
        stitchPreviewTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            let plan = await Task.detached(priority: .userInitiated) {
                EmbroideryPlanner.plan(doc)
            }.value
            guard !Task.isCancelled, let self, self.showStitchPreview else { return }
            self.stitchPreview = (doc, plan)
        }
    }

    func cancelStitchPreview() {
        stitchPreviewTask?.cancel()
        stitchPreviewTask = nil
        stitchPreviewSource = nil
        stitchPreview = nil
    }

    /// True while the preview still shows stitches for an older version of the design.
    var stitchPreviewIsStale: Bool {
        guard showStitchPreview else { return false }
        guard let shown = stitchPreview else { return true }
        return shown.source != stitchSource
    }

    /// The document as far as stitches go: the workpiece (size, colour) doesn't change them.
    private var stitchSource: KerfDocument {
        var d = document
        d.workpiece = nil
        return d
    }

    /// Stitch count of the preview, for the status bar.
    var stitchPreviewCount: Int {
        stitchPreview?.plan.blocks.reduce(0) { $0 + $1.runs.reduce(0) { $0 + $1.count } } ?? 0
    }
}
