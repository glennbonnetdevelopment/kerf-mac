import Foundation
import KerfCore

/// Node editing and colour assignment.
extension AppModel {
    /// The one selected shape whose points can be edited (not images).
    var nodeEditableShape: Artwork? {
        guard selection.count == 1, let s = selectedShapes.first, s.image == nil else { return nil }
        return s
    }

    /// The node of the selected shape nearest `p` (bed mm), within `tolerance`.
    func nodeHit(at p: Vec2, tolerance: Double) -> NodeRef? {
        guard let shape = nodeEditableShape else { return nil }
        var best: (NodeRef, Double)?
        for (pi, poly) in shape.paths.enumerated() {
            for (i, q) in poly.points.enumerated() {
                let d = shape.transform.apply(q).distance(to: p)
                if d <= tolerance, d < (best?.1 ?? .infinity) { best = (NodeRef(shape: shape.id, path: pi, point: i), d) }
            }
        }
        return best?.0
    }

    /// Text and path text become plain outlines once their points are edited.
    private func detachText(_ index: Int) {
        guard document.shapes[index].text != nil else { return }
        document.shapes[index].text = nil
        document.shapes[index].pathText = nil
        document.shapes[index].name = document.shapes[index].name.replacingOccurrences(of: "Text", with: "Outlines")
    }

    func moveNode(_ ref: NodeRef, to p: Vec2, recordUndo: Bool) {
        guard let i = document.shapes.firstIndex(where: { $0.id == ref.shape }),
              ref.path < document.shapes[i].paths.count,
              ref.point < document.shapes[i].paths[ref.path].points.count else { return }
        if recordUndo { checkpoint() }
        detachText(i)
        let local = document.shapes[i].transform.inverted.apply(p)
        document.shapes[i].paths[ref.path].points[ref.point] = local
        selectedNode = ref
    }

    /// Removes a node, keeping at least a line (open) or a triangle (closed).
    func deleteNode(_ ref: NodeRef) {
        guard let i = document.shapes.firstIndex(where: { $0.id == ref.shape }), ref.path < document.shapes[i].paths.count else { return }
        let poly = document.shapes[i].paths[ref.path]
        let minimum = poly.closed ? 3 : 2
        guard ref.point < poly.points.count else { return }
        guard poly.points.count > minimum else { return }
        checkpoint()
        detachText(i)
        document.shapes[i].paths[ref.path].points.remove(at: ref.point)
        selectedNode = nil
    }

    /// Adds a node on the selected shape's outline nearest `p`, if within `tolerance`. Returns it.
    @discardableResult
    func insertNode(at p: Vec2, tolerance: Double) -> NodeRef? {
        guard let shape = nodeEditableShape, let i = document.shapes.firstIndex(where: { $0.id == shape.id }) else { return nil }
        let local = shape.transform.inverted.apply(p)
        let tolLocal = tolerance / max(1e-9, shape.transform.meanScale)
        var best: (path: Int, after: Int, point: Vec2, d: Double)?
        for (pi, poly) in shape.paths.enumerated() {
            let pts = poly.points
            guard pts.count > 1 else { continue }
            let n = poly.closed ? pts.count : pts.count - 1
            for k in 0..<n {
                let a = pts[k], b = pts[(k + 1) % pts.count]
                let ab = b - a, len2 = ab.dot(ab)
                let t = len2 > 0 ? max(0, min(1, (local - a).dot(ab) / len2)) : 0
                let q = a + ab * t
                let d = q.distance(to: local)
                if d <= tolLocal, d < (best?.d ?? .infinity) { best = (pi, k, q, d) }
            }
        }
        guard let b = best else { return nil }
        checkpoint()
        detachText(i)
        document.shapes[i].paths[b.path].points.insert(b.point, at: b.after + 1)
        let ref = NodeRef(shape: shape.id, path: b.path, point: b.after + 1)
        selectedNode = ref
        return ref
    }

    /// Puts the selection on the layer with this colour (creating it with the same mode if needed).
    func applyColor(_ hex: String) {
        guard !selection.isEmpty else { return }
        let mode = selectedShapes.first.flatMap { document.layer($0.layerID)?.mode } ?? defaultMode
        checkpoint()
        let layerID = document.layer(forColor: hex, defaultMode: mode)
        for i in document.shapes.indices where selection.contains(document.shapes[i].id) {
            document.shapes[i].layerID = layerID
        }
        currentLayerID = layerID
    }
}
