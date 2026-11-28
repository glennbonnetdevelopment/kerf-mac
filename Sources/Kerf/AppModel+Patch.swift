import KerfCore
import SwiftUI

/// Standalone embroidered patches: a shape and border around the selected design (or a set size), with a
/// fabric or fill background, appliqué stops, and laser or cutter lines for the fabric and the finished patch.
extension AppModel {
    nonisolated static func loadPatchOptions() -> PatchOptions {
        guard let data = UserDefaults.standard.data(forKey: "patch"),
              let o = try? JSONDecoder().decode(PatchOptions.self, from: data) else { return PatchOptions() }
        return o
    }

    /// The selected shapes the patch goes around (print-only marks are left out).
    var patchDesign: [Artwork] {
        selectedShapes.filter { document.layer($0.layerID)?.mode != .print }
    }

    var patchDesignBounds: Rect2 { patchDesign.reduce(Rect2.empty) { $0.union($1.bounds) } }

    /// The patch's finished outer edge for `options`, or nil with the reason it can't be made.
    func patchEdge(_ options: PatchOptions) -> (edge: Polyline?, problem: String?) {
        let o = options.sanitized
        let design = patchDesign
        let bounds = patchDesignBounds
        if o.sizeToDesign || o.shape == .contour {
            guard !design.isEmpty, !bounds.isEmpty else {
                return (nil, o.shape == .contour ? "Select the design for the patch to follow."
                                                 : "Select the design to size the patch around, or set a size.")
            }
        }
        if o.shape == .contour {
            let offset = o.margin + o.borderReach
            var mask = Contour.grid(for: bounds, margin: offset, maxCells: 900, finest: 0.15)
            Self.rasterize(design, into: &mask)
            guard mask.cells.contains(true), let edge = Patch.contourEdge(Contour.outline(mask, offset: offset, smoothing: 3)) else {
                return (nil, "Could not trace around the selected design.")
            }
            return (edge, nil)
        }
        if o.sizeToDesign {
            return (Patch.edge(o.shape, around: bounds, options: o), nil)
        }
        let centre = bounds.isEmpty ? workArea.center : bounds.center
        let w = o.width, h = o.shape == .circle ? o.width : o.height
        let rect = Rect2(minX: centre.x - w / 2, minY: centre.y - h / 2, maxX: centre.x + w / 2, maxY: centre.y + h / 2)
        return (Patch.edge(o.shape, in: rect, cornerRadius: o.cornerRadius), nil)
    }

    /// The patch's parts for `options` with the current machine's cut layer mode.
    func patchParts(_ options: PatchOptions) -> (parts: [PatchPart], problem: String?) {
        let (edge, problem) = patchEdge(options)
        guard let edge else { return ([], problem) }
        return (Patch.parts(edge: edge, options: options, cutMode: profile.kind.defaultMode), nil)
    }

    /// What the patch will sew: the selected design with the patch's parts around it.
    func patchPreview(_ options: PatchOptions) -> (pattern: StitchPattern, parts: [PatchPart], problem: String?) {
        let (parts, problem) = patchParts(options)
        var doc = document
        let added = Patch.apply(parts, to: &doc)
        let ids = Set(patchDesign.map(\.id)).union(added)
        let plan = EmbroideryPlanner.plan(doc, shapeIDs: ids)
        return (StitchPattern(plan: plan, name: embroideryDesignName), parts, problem)
    }

    /// Adds the patch's layers and shapes. Returns false (with a message) when there is nothing to add.
    @discardableResult
    func addPatch() -> Bool {
        let o = patch.sanitized
        let (parts, problem) = patchParts(o)
        guard !parts.isEmpty else {
            alertMessage = problem ?? "Turn on a border, a background or a cut line to make a patch."
            return false
        }
        checkpoint()
        if o.designSewnOnly && o.hasCutLine {
            let layers = Set(patchDesign.map(\.layerID))
            for i in document.layers.indices where layers.contains(document.layers[i].id) && document.layers[i].output == .all {
                document.layers[i].output = .embroidery
            }
        }
        let ids = Patch.apply(parts, to: &document)
        selection = Set(ids)
        if let first = parts.first { currentLayerID = first.layer.id }
        return true
    }
}
