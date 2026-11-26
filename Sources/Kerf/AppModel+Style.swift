import KerfCore
import SwiftUI

/// Stroke, fill and offset styles on the selected shapes. Each style turned on goes on a layer of its own,
/// listed under the shape's layer, so it can be made with different settings (or sewn in a different thread).
extension AppModel {
    /// Selected shapes that can take styles (not images).
    var styleTargets: [Artwork] { selectedShapes.filter { $0.image == nil } }

    /// The style part shown in the inspector: the first selected shape's.
    func stylePart(_ kind: StylePartKind) -> StylePart? {
        styleTargets.first?.style?.part(kind)
    }

    func isStyleEnabled(_ kind: StylePartKind) -> Bool { stylePart(kind)?.enabled ?? false }

    var selectionOutlineEnabled: Bool { styleTargets.first?.outlineEnabled ?? true }

    /// Turns a style on or off for the selected shapes. The first time a style is turned on, it gets a new layer
    /// (one for the whole selection) named after the shape, placed right after the shape's layer.
    func setStyle(_ kind: StylePartKind, enabled: Bool) {
        let targets = styleTargets
        guard !targets.isEmpty else { return }
        checkpoint()
        var newLayer: UUID?
        for t in targets {
            guard let i = document.shapes.firstIndex(where: { $0.id == t.id }) else { continue }
            var style = document.shapes[i].style ?? ArtworkStyle()
            if let k = style.parts.firstIndex(where: { $0.kind == kind }), document.layer(style.parts[k].layerID) != nil {
                style.parts[k].enabled = enabled
            } else if enabled {
                let id = newLayer ?? makeStyleLayer(kind, for: document.shapes[i])
                newLayer = id
                let amount = stylePart(kind)?.amount
                style.parts.removeAll { $0.kind == kind }
                style.parts.append(StylePart(kind: kind, layerID: id, amount: amount))
                style.parts.sort { StylePartKind.allCases.firstIndex(of: $0.kind)! < StylePartKind.allCases.firstIndex(of: $1.kind)! }
            }
            // A shape with no styles left always keeps its outline.
            if style.enabledParts.isEmpty { style.outlineEnabled = true }
            document.shapes[i].style = style.isEmpty ? nil : style
        }
        if let newLayer { currentLayerID = newLayer }
    }

    /// Sets the stroke width or offset distance for the selected shapes.
    func setStyleAmount(_ kind: StylePartKind, _ value: Double) {
        let ids = Set(styleTargets.map(\.id))
        guard !ids.isEmpty else { return }
        let v = kind == .stroke ? max(0.01, value) : value
        checkpoint()
        for i in document.shapes.indices where ids.contains(document.shapes[i].id) {
            guard let k = document.shapes[i].style?.parts.firstIndex(where: { $0.kind == kind }) else { continue }
            document.shapes[i].style?.parts[k].amount = v
        }
    }

    /// Puts a style of the selected shapes on another layer.
    func setStyleLayer(_ kind: StylePartKind, _ layerID: UUID) {
        let ids = Set(styleTargets.map(\.id))
        guard !ids.isEmpty, document.layer(layerID) != nil else { return }
        checkpoint()
        for i in document.shapes.indices where ids.contains(document.shapes[i].id) {
            guard let k = document.shapes[i].style?.parts.firstIndex(where: { $0.kind == kind }) else { continue }
            document.shapes[i].style?.parts[k].layerID = layerID
        }
        currentLayerID = layerID
    }

    /// Gives a style of the selected shapes a fresh layer of its own.
    func moveStyleToNewLayer(_ kind: StylePartKind) {
        guard let first = styleTargets.first, first.style?.part(kind) != nil else { return }
        let id = makeStyleLayer(kind, for: first)
        setStyleLayer(kind, id)
    }

    /// The colour of a style is its layer's colour. Changes the layer's colour when only this selection uses it,
    /// otherwise moves the style to a layer of that colour (as the colour swatches do for shapes).
    func setStyleColor(_ kind: StylePartKind, _ hex: String) {
        guard let part = stylePart(kind), let layer = document.layer(part.layerID) else { return }
        let ids = Set(styleTargets.map(\.id))
        let sharedOutside = document.shapes.contains { s in
            (s.layerID == layer.id && s.outlineEnabled)
                || (!ids.contains(s.id) && s.style?.parts.contains { $0.layerID == layer.id } == true)
        }
        if !sharedOutside, let i = document.layers.firstIndex(where: { $0.id == layer.id }) {
            checkpoint()
            document.layers[i].colorHex = hex.uppercased()
        } else {
            let target = document.layer(forColor: hex, defaultMode: layer.mode)
            setStyleLayer(kind, target)
        }
    }

    /// Makes or leaves out the selected shapes' own outline (only allowed while a style is on).
    func setOutlineEnabled(_ on: Bool) {
        let ids = Set(styleTargets.map(\.id))
        guard !ids.isEmpty else { return }
        checkpoint()
        for i in document.shapes.indices where ids.contains(document.shapes[i].id) {
            guard var style = document.shapes[i].style, !style.enabledParts.isEmpty || on else { continue }
            style.outlineEnabled = on
            document.shapes[i].style = style.isEmpty ? nil : style
        }
    }

    /// A new layer for a style of `shape`, with the next free colour, right after the shape's layer.
    private func makeStyleLayer(_ kind: StylePartKind, for shape: Artwork) -> UUID {
        let used = Set(document.layers.map { $0.colorHex.uppercased() })
        let color = Layer.palette.first { !used.contains($0) } ?? Layer.palette[document.layers.count % Layer.palette.count]
        let base = shape.text?.text ?? shape.name
        let short = base.count > 24 ? String(base.prefix(24)) + "…" : base
        var layer = Layer(name: "\(short) \(kind.title.lowercased())", colorHex: color, mode: kind.defaultMode(for: profile.kind))
        if layer.mode == .fill { layer.speed = 3000; layer.power = 30 }
        let at = (document.layers.firstIndex { $0.id == shape.layerID } ?? document.layers.count - 1) + 1
        document.layers.insert(layer, at: min(at, document.layers.count))
        return layer.id
    }
}
