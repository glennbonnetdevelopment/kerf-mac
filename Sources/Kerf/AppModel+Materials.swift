import AppKit
import KerfCore
import UniformTypeIdentifiers

extension AppModel {
    /// Where the material library is kept (inside the app's sandbox container).
    static var materialsURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("KerfKutter", isDirectory: true).appendingPathComponent("materials.json")
    }

    func loadMaterials() {
        if let url = Self.materialsURL, let data = try? Data(contentsOf: url), let lib = try? MaterialLibrary.decode(data) {
            materials = lib
        }
        // Add each set of starter settings once; deleting them afterwards keeps them deleted.
        for (key, starters) in [("addedXToolStarters", CutMaterial.xToolStarters), ("addedVinylStarters", CutMaterial.vinylStarters)]
        where !UserDefaults.standard.bool(forKey: key) {
            materials.merge(MaterialLibrary(materials: starters))
            UserDefaults.standard.set(true, forKey: key)
            saveMaterials()
        }
        materialsLoaded = true
    }

    /// Adds back any starter settings for `kind` that are missing, without touching ones you've edited.
    func restoreStarterMaterials(for kind: DeviceKind) {
        let before = materials.materials.count
        var lib = materials
        for m in CutMaterial.starters where m.kind == kind && lib.material(m.id) == nil { lib.upsert(m) }
        materials = lib
        let added = materials.materials.count - before
        let what = kind == .vinylCutter ? "vinyl cutter" : "xTool"
        alertMessage = added == 0 ? "All the \(what) starter settings are already in your library." : "Added \(added) \(what) starter setting\(added == 1 ? "" : "s")."
    }

    func saveMaterials() {
        guard let url = Self.materialsURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try materials.encoded().write(to: url, options: .atomic)
        } catch {
            alertMessage = "Could not save the material library: \(error.localizedDescription)"
        }
    }

    /// Saves a layer's settings as a new material for the current machine type and links the layer to it.
    @discardableResult
    func saveLayerAsMaterial(_ layerID: UUID, name: String, thickness: Double, operation: String, notes: String) -> CutMaterial? {
        guard let i = document.layers.firstIndex(where: { $0.id == layerID }) else { return nil }
        var m = CutMaterial(name: name.trimmingCharacters(in: .whitespaces), thickness: max(0, thickness),
                         operation: operation.trimmingCharacters(in: .whitespaces), notes: notes, kind: profile.kind,
                         settings: document.layers[i])
        m.capture(document.layers[i])
        materials.upsert(m)
        document.layers[i].materialID = m.id
        return m
    }

    /// Overwrites a material's settings with the layer's current ones.
    func updateMaterial(_ id: UUID, from layerID: UUID) {
        guard var m = materials.material(id), let layer = document.layer(layerID) else { return }
        m.capture(layer)
        materials.upsert(m)
        if let i = document.layers.firstIndex(where: { $0.id == layerID }) { document.layers[i].materialID = id }
    }

    /// Puts a material's settings on a layer (undoable). The layer keeps its name and colour.
    func applyMaterial(_ id: UUID, to layerID: UUID) {
        guard let m = materials.material(id), let i = document.layers.firstIndex(where: { $0.id == layerID }) else { return }
        checkpoint()
        m.apply(to: &document.layers[i])
        if document.layers[i].name.hasPrefix("Layer ") { document.layers[i].name = m.title }
        // Use the material's thickness for the CNC stock when there is one.
        if profile.kind == .cncRouter, m.thickness > 0, var w = document.workpiece, w.kind == .stock {
            w.thickness = m.thickness
            document.workpiece = w
        }
    }

    /// True when a layer's settings still match the material it came from.
    func layerMatchesMaterial(_ layer: Layer) -> Bool {
        guard let m = materials.material(layer.materialID) else { return false }
        var probe = layer
        m.apply(to: &probe)
        return probe == layer
    }

    func exportMaterials(_ ids: Set<UUID>? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "KerfKutter materials.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let picked = ids.map { set in MaterialLibrary(materials: materials.materials.filter { set.contains($0.id) }) } ?? materials
        do {
            try picked.encoded().write(to: url, options: .atomic)
        } catch {
            alertMessage = "Could not export materials: \(error.localizedDescription)"
        }
    }

    func importMaterials() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var total = 0
        for url in panel.urls {
            do {
                total += materials.merge(try MaterialLibrary.decode(Data(contentsOf: url)))
            } catch {
                alertMessage = "\(url.lastPathComponent) is not a KerfKutter material library."
                return
            }
        }
        alertMessage = total == 0 ? "No new materials found." : "Imported \(total) material\(total == 1 ? "" : "s")."
    }
}
