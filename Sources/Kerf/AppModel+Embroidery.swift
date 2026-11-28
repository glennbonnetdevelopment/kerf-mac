import AppKit
import KerfCore
import SwiftUI
import UniformTypeIdentifiers

/// Embroidery machine export: stitches from the design's layers, written as PES, JEF or DST.
extension AppModel {
    /// The shapes embroidery covers: the selection when "selected shapes only" is on, otherwise all of them.
    var embroideryShapeIDs: Set<UUID>? { cutSelectionOnly && !selection.isEmpty ? selection : nil }

    var embroideryDesignName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Design" }

    func embroideryPattern(groupColors: Bool = true, optimizeOrder: Bool = true) -> StitchPattern {
        embroideryPlanAndPattern(groupColors: groupColors, optimizeOrder: optimizeOrder).pattern
    }

    /// The design's stitches on the bed (mm) and as a machine pattern centred on them.
    func embroideryPlanAndPattern(groupColors: Bool = true, optimizeOrder: Bool = true) -> (plan: EmbroideryPlan, pattern: StitchPattern) {
        let ids = embroideryShapeIDs, name = embroideryDesignName
        if let c = embroideryCache, c.groupColors == groupColors, c.optimizeOrder == optimizeOrder, c.shapes == ids,
           c.name == name, c.document == document {
            return (c.plan, c.pattern)
        }
        let plan = EmbroideryPlanner.plan(document, shapeIDs: ids, groupColors: groupColors, optimizeOrder: optimizeOrder)
        let pattern = StitchPattern(plan: plan, name: name)
        embroideryCache = (document, ids, groupColors, optimizeOrder, name, plan, pattern)
        return (plan, pattern)
    }

    nonisolated static func loadMultiHoop() -> MultiHoopOptions {
        guard let data = UserDefaults.standard.data(forKey: "multiHoop"),
              let o = try? JSONDecoder().decode(MultiHoopOptions.self, from: data) else { return MultiHoopOptions() }
        return o
    }

    /// File names for each sewn hooping, keyed by hooping index: "Design 1 of 4.pes" and so on.
    func multiHoopFileNames(_ layout: MultiHoopLayout, format: EmbroideryFormat) -> [Int: String] {
        let sewn = layout.sewnHoopings
        var names: [Int: String] = [:]
        for (k, h) in sewn.enumerated() {
            names[h.index] = "\(embroideryDesignName) \(k + 1) of \(sewn.count).\(format.fileExtension)"
        }
        return names
    }

    /// Asks for a folder and writes one file per hooping plus a text guide. Returns true when written.
    @discardableResult
    func exportMultiHoop(_ layout: MultiHoopLayout, format: EmbroideryFormat, hoop: EmbroideryHoop) -> Bool {
        let sewn = layout.sewnHoopings
        guard !sewn.isEmpty else {
            alertMessage = "Nothing to stitch: add shapes to an enabled layer first."
            return false
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the \(sewn.count) hooping files and the hooping guide."
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        let names = multiHoopFileNames(layout, format: format)
        do {
            for (k, h) in sewn.enumerated() {
                guard let file = names[h.index] else { continue }
                let pattern = MultiHoop.pattern(h, name: "\(embroideryDesignName) \(k + 1)")
                try format.data(pattern).write(to: folder.appendingPathComponent(file), options: .atomic)
            }
            let guide = MultiHoop.guide(layout, name: embroideryDesignName, fileNames: names, hoop: hoop, options: multiHoop)
            try guide.write(to: folder.appendingPathComponent("\(embroideryDesignName) hooping guide.txt"),
                            atomically: true, encoding: .utf8)
            return true
        } catch {
            alertMessage = "Could not export: \(error.localizedDescription)"
            return false
        }
    }

    /// The shapes of a layer that embroidery covers, in document (sewing) order.
    func embroideryShapes(in layerID: UUID) -> [Artwork] {
        let ids = embroideryShapeIDs
        return document.shapes.filter { $0.layerID == layerID && $0.image == nil && (ids?.contains($0.id) ?? true) }
    }

    /// Moves a shape earlier (-1) or later (+1) among the shapes of its layer.
    func moveInSewingOrder(_ id: UUID, by step: Int) {
        guard let i = document.shapes.firstIndex(where: { $0.id == id }) else { return }
        let layer = document.shapes[i].layerID
        let ids = embroideryShapeIDs
        var j = i + step
        while j >= 0 && j < document.shapes.count {
            let s = document.shapes[j]
            if s.layerID == layer && s.image == nil && (ids?.contains(s.id) ?? true) { break }
            j += step
        }
        guard j >= 0 && j < document.shapes.count else { return }
        checkpoint()
        document.shapes.swapAt(i, j)
    }

    func shape(_ id: UUID) -> Artwork? { document.shapes.first { $0.id == id } }

    /// Gives a shape its own embroidery settings (starting from its layer's), or returns it to the layer's.
    func setOwnEmbroidery(_ id: UUID, _ on: Bool) {
        guard let i = document.shapes.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        let layer = document.layer(document.shapes[i].layerID)
        document.shapes[i].embroidery = on ? (layer?.embroiderySettings ?? EmbroiderySettings()) : nil
    }

    func shapeEmbroideryBinding(_ id: UUID) -> Binding<EmbroiderySettings>? {
        guard let i = document.shapes.firstIndex(where: { $0.id == id }), document.shapes[i].embroidery != nil else { return nil }
        return Binding(
            get: { [weak self] in self?.shape(id)?.embroidery ?? EmbroiderySettings() },
            set: { [weak self] v in
                guard let self, let k = self.document.shapes.firstIndex(where: { $0.id == id }) else { return }
                self.document.shapes[k].embroidery = v
            })
    }

    /// The stitches to start editing from: the shape's hand edits, or a fresh digitizing of it.
    func editableStitches(_ id: UUID) -> [[Vec2]] {
        guard let s = shape(id), let layer = document.layer(s.layerID) else { return [] }
        return s.stitches ?? EmbroideryPlanner.editableStitches(for: s, layer: layer)
    }

    /// A fresh digitizing of the shape from its settings, ignoring any hand edits (shape coordinates).
    func editableStitchesFromSettings(_ id: UUID) -> [[Vec2]] {
        guard let s = shape(id), let layer = document.layer(s.layerID) else { return [] }
        return EmbroideryPlanner.editableStitches(for: s, layer: layer)
    }

    /// Saves hand-edited stitches for a shape (shape coordinates), or with nil goes back to digitizing it.
    func setEditedStitches(_ id: UUID, _ runs: [[Vec2]]?) {
        guard let i = document.shapes.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        document.shapes[i].stitches = runs
    }

    /// Layers that will be sewn, with at least one shape in the export.
    var embroideredLayers: [Layer] {
        let ids = embroideryShapeIDs
        var source = document
        if let ids { source.shapes = document.shapes.filter { ids.contains($0.id) } }
        let shapes = source.machineShapes(embroidery: true)
        return document.layers.filter { layer in
            layer.isEmbroidered && shapes.contains { $0.layerID == layer.id && $0.image == nil }
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
