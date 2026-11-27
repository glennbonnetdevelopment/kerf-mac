import Foundation

/// Mirrors a job as it goes to the machine, leaving the design itself alone.
/// Used for heat-transfer vinyl (cut face down) and for stamps (carved in reverse).
public enum OutputMirror: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, horizontal, vertical

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "Off"
        case .horizontal: return "Left to right"
        case .vertical: return "Top to bottom"
        }
    }

    /// The flip about `center`, or identity when off.
    public func transform(about center: Vec2) -> Affine {
        switch self {
        case .none: return .identity
        case .horizontal: return Affine.translation(-center.x, -center.y).then(.scale(-1, 1)).then(.translation(center.x, center.y))
        case .vertical: return Affine.translation(-center.x, -center.y).then(.scale(1, -1)).then(.translation(center.x, center.y))
        }
    }
}

extension KerfDocument {
    /// A copy with every shape flipped about `center` (by default the centre of all the shapes),
    /// so the job stays where it is on the bed but comes out as a mirror image.
    public func mirrored(_ mirror: OutputMirror, about center: Vec2? = nil) -> KerfDocument {
        guard mirror != .none else { return self }
        let b = bounds
        guard !b.isEmpty else { return self }
        let flip = mirror.transform(about: center ?? b.center)
        var doc = self
        for i in doc.shapes.indices {
            doc.shapes[i].transform = doc.shapes[i].transform.then(flip)
        }
        return doc
    }
}
