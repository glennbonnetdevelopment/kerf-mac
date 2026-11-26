import AppKit
import KerfCore
import SwiftUI
import UniformTypeIdentifiers

/// Embroidery machine export: stitches from the design's layers, written as PES, JEF or DST.
extension AppModel {
    /// The shapes embroidery covers: the selection when "selected shapes only" is on, otherwise all of them.
    var embroideryShapeIDs: Set<UUID>? { cutSelectionOnly && !selection.isEmpty ? selection : nil }

    var embroideryDesignName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Design" }

    func embroideryPattern() -> StitchPattern {
        let plan = EmbroideryPlanner.plan(document, shapeIDs: embroideryShapeIDs)
        return StitchPattern(plan: plan, name: embroideryDesignName)
    }

    /// Layers that will be sewn, with at least one shape in the export.
    var embroideredLayers: [Layer] {
        let ids = embroideryShapeIDs
        return document.layers.filter { layer in
            layer.isEmbroidered && document.shapes.contains {
                $0.layerID == layer.id && $0.image == nil && (ids?.contains($0.id) ?? true)
            }
        }
    }

    func embroiderySettingsBinding(_ id: UUID) -> Binding<EmbroiderySettings>? {
        guard let layer = layerBinding(id) else { return nil }
        return Binding(get: { layer.wrappedValue.embroiderySettings },
                       set: { layer.wrappedValue.embroidery = $0 })
    }

    /// Asks where to save and writes the file. Returns true when it was written.
    @discardableResult
    func exportEmbroidery(_ pattern: StitchPattern, format: EmbroideryFormat) -> Bool {
        guard pattern.stitchCount > 0 else {
            alertMessage = "Nothing to stitch: add shapes to an enabled layer first. Print-only and image layers aren't sewn."
            return false
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = pattern.name + "." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try format.data(pattern).write(to: url, options: .atomic)
            return true
        } catch {
            alertMessage = "Could not export: \(error.localizedDescription)"
            return false
        }
    }
}

extension Color {
    init(thread t: ThreadColor) {
        self.init(red: Double(t.red) / 255, green: Double(t.green) / 255, blue: Double(t.blue) / 255)
    }
}
