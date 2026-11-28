import AppKit
import KerfCore
import SwiftUI

/// Monogram templates: initials set in a classic, circle, diamond or arched style, with an optional frame.
/// The letters and the frame go on layers of their own so they can be sewn or cut in different colours.
extension AppModel {
    nonisolated static func loadMonogram() -> MonogramOptions {
        guard let data = UserDefaults.standard.data(forKey: "monogram"),
              let o = try? JSONDecoder().decode(MonogramOptions.self, from: data) else { return MonogramOptions() }
        return o
    }

    static let monogramLettersLayerName = "Monogram letters"
    static let monogramFrameLayerName = "Monogram frame"

    /// The monogram's pieces, centred on (0, 0), with letters outlined as the text tool does.
    func monogramPieces(_ o: MonogramOptions) -> [MonogramPiece] {
        Monogram.build(o) { spec in TextOutliner.shaped(spec, pathText: nil) }
    }

    /// Outlines that overlap, merged into one outline (for cutting the vine's stem and leaves as one piece).
    static func welded(_ polys: [Polyline]) -> [Polyline] {
        let closed = polys.filter { $0.closed && $0.points.count > 2 }
        guard let first = closed.first else { return polys }
        var result = cgPath([first]).normalized(using: .winding)
        for p in closed.dropFirst() {
            result = result.union(cgPath([p]).normalized(using: .winding), using: .winding)
        }
        let out = TextOutliner.flatten(result, offset: .zero, step: 0.1)
        return out.isEmpty ? polys : out
    }

    /// Adds the monogram in the middle of the workpiece or bed, the letters and frame each on a new layer.
    @discardableResult
    func addMonogram(_ options: MonogramOptions? = nil) -> Bool {
        let o = (options ?? monogram).sanitized
        let pieces = monogramPieces(o)
        guard pieces.contains(where: { $0.role == .letters }) || o.frame != .none else {
            alertMessage = "Type at least one initial for the monogram."
            return false
        }
        guard !pieces.isEmpty else {
            alertMessage = "The monogram produced no outlines. Check the font."
            return false
        }
        checkpoint()
        let mode = profile.kind.defaultMode
        func layer(_ name: String, _ color: String) -> UUID {
            var l = Layer(name: name, colorHex: color, mode: mode)
            l.embroidery = EmbroiderySettings(stitchType: .auto)
            document.layers.append(l)
            return l.id
        }
        var lettersLayer: UUID?, frameLayer: UUID?
        let centre = workArea.center
        var added: Set<UUID> = []
        for piece in pieces {
            let id: UUID
            switch piece.role {
            case .letters:
                id = lettersLayer ?? layer(Self.monogramLettersLayerName, "#1E3A8A")
                lettersLayer = id
            case .frame:
                id = frameLayer ?? layer(Self.monogramFrameLayerName, "#B45309")
                frameLayer = id
            }
            let paths = piece.weld ? Self.welded(piece.placedPaths) : piece.paths
            let transform = piece.weld ? Affine.translation(centre.x, centre.y)
                : piece.transform.then(.translation(centre.x, centre.y))
            let shape = Artwork(layerID: id, name: piece.name, paths: paths, transform: transform, text: piece.text)
            document.shapes.append(shape)
            added.insert(shape.id)
        }
        selection = added
        if let l = lettersLayer ?? frameLayer { currentLayerID = l }
        return true
    }
}
