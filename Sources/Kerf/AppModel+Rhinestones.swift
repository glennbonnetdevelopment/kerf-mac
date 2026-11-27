import KerfCore
import SwiftUI

/// Rhinestone layout: stones along the outline and inside the selected shapes, turned into template holes.
/// Each stone size and colour goes on a layer of its own (one template per colour), cut on the vinyl cutter
/// or laser with that layer's settings.
extension AppModel {
    /// Selected shapes stones can be laid out on: outlines, text and drawings (not images).
    var rhinestoneTargets: [Artwork] { selectedShapes.filter { $0.image == nil && !$0.paths.isEmpty } }

    /// The outlines the layout follows, on the bed.
    var rhinestoneSourcePaths: [Polyline] { rhinestoneTargets.flatMap(\.placedStyledPaths) }

    nonisolated static func loadRhinestones() -> RhinestoneOptions {
        guard let data = UserDefaults.standard.data(forKey: "rhinestones"),
              let o = try? JSONDecoder().decode(RhinestoneOptions.self, from: data) else { return RhinestoneOptions() }
        return o
    }

    /// The layer mode the template holes get on the current machine.
    var rhinestoneHoleMode: LayerMode { profile.kind.defaultMode }

    static let rhinestoneGuideLayerName = "Rhinestone guide"

    /// Lays out stones on the selection with `rhinestones` and adds the holes, one layer per stone size and
    /// colour. Returns false (with a message) when there is nothing to add.
    @discardableResult
    func addRhinestones(_ precomputed: [Stone]? = nil) -> Bool {
        let targets = rhinestoneTargets
        guard !targets.isEmpty else {
            alertMessage = "Select the shapes or text to lay stones on."
            return false
        }
        let options = rhinestones
        let stones = precomputed ?? Rhinestone.cachedLayout(rhinestoneSourcePaths, options: options)
        guard !stones.isEmpty else {
            alertMessage = "No stones fit. Try smaller stones, less spacing, or Centred on the outline for thin lines."
            return false
        }
        checkpoint()
        let sourceLayers = Set(targets.map(\.layerID))
        var insertAt = (document.layers.lastIndex { sourceLayers.contains($0.id) } ?? (document.layers.count - 1)) + 1
        var added: Set<UUID> = []
        var firstLayer: UUID?
        for group in Rhinestone.groups(stones) {
            var layer = Layer(name: "Rhinestones \(group.title)", colorHex: group.color.hex.uppercased(), mode: rhinestoneHoleMode)
            if layer.mode == .line { layer.speed = 1200; layer.power = 60 }
            document.layers.insert(layer, at: min(insertAt, document.layers.count))
            insertAt += 1
            firstLayer = firstLayer ?? layer.id
            var shape = Artwork(layerID: layer.id, name: "\(group.title) · \(group.stones.count) stones",
                                paths: Rhinestone.holes(group.stones, clearance: options.holeClearance))
            shape.millRole = .hole
            document.shapes.append(shape)
            added.insert(shape.id)
        }

        let ids = Set(targets.map(\.id))
        switch options.original {
        case .keep:
            break
        case .delete:
            document.shapes.removeAll { ids.contains($0.id) }
        case .guide:
            let guide: UUID
            if let existing = document.layers.first(where: { $0.name == Self.rhinestoneGuideLayerName && $0.mode == .print }) {
                guide = existing.id
            } else {
                var layer = Layer(name: Self.rhinestoneGuideLayerName, colorHex: "#9CA3AF", mode: .print)
                layer.enabled = false
                document.layers.insert(layer, at: 0)
                guide = layer.id
            }
            for i in document.shapes.indices where ids.contains(document.shapes[i].id) {
                document.shapes[i].layerID = guide
            }
        }
        selection = added
        if let firstLayer { currentLayerID = firstLayer }
        return true
    }
}
