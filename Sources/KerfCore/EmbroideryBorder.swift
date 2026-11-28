import Foundation

/// The stitch sewn along a filled shape's outline, on top of its fill.
public enum BorderStitch: String, Codable, CaseIterable, Sendable, Identifiable {
    case running
    case bean
    case satin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .running: return "Running stitch"
        case .bean: return "Triple (bean) stitch"
        case .satin: return "Satin border"
        }
    }

    public var stitchType: StitchType {
        switch self {
        case .running: return .running
        case .bean: return .bean
        case .satin: return .satin
        }
    }

    public init?(_ type: StitchType) {
        switch type {
        case .running: self = .running
        case .bean: self = .bean
        case .satin: self = .satin
        default: return nil
        }
    }
}

/// A border for a filled shape: its own stitch, length, width and line style, sewn after the fill.
public struct EmbroideryBorder: Codable, Hashable, Sendable {
    public var stitch: BorderStitch
    /// Running and triple stitch length.
    public var stitchLength: Double
    /// Satin and line-style width.
    public var width: Double
    /// Gap between satin zig-zags.
    public var density: Double
    public var lineStyle: LineStyle
    /// A centre run under a satin border.
    public var underlay: Bool
    public var pullCompensation: Double

    public init(stitch: BorderStitch = .satin, stitchLength: Double = 2.5, width: Double = 2.5, density: Double = 0.4,
                lineStyle: LineStyle = .plain, underlay: Bool = true, pullCompensation: Double = 0.2) {
        self.stitch = stitch
        self.stitchLength = stitchLength
        self.width = width
        self.density = density
        self.lineStyle = lineStyle
        self.underlay = underlay
        self.pullCompensation = pullCompensation
    }

    private enum CodingKeys: String, CodingKey {
        case stitch, stitchLength, width, density, lineStyle, underlay, pullCompensation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EmbroideryBorder()
        stitch = (try? c.decodeIfPresent(BorderStitch.self, forKey: .stitch)) ?? d.stitch
        stitchLength = try c.decodeIfPresent(Double.self, forKey: .stitchLength) ?? d.stitchLength
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? d.density
        lineStyle = (try? c.decodeIfPresent(LineStyle.self, forKey: .lineStyle)) ?? d.lineStyle
        underlay = try c.decodeIfPresent(Bool.self, forKey: .underlay) ?? d.underlay
        pullCompensation = try c.decodeIfPresent(Double.self, forKey: .pullCompensation) ?? d.pullCompensation
    }

    /// The border as line settings, to sew (and to edit with the same fields as a line layer).
    public var settings: EmbroiderySettings {
        EmbroiderySettings(stitchType: stitch.stitchType, stitchLength: stitchLength, satinWidth: width, density: density,
                           underlay: underlay, pullCompensation: pullCompensation, lineStyle: lineStyle)
    }

    /// The border part of line settings (running, triple or satin; anything else becomes satin).
    public init(settings s: EmbroiderySettings) {
        self.init(stitch: BorderStitch(s.stitchType) ?? .satin, stitchLength: s.stitchLength, width: s.satinWidth,
                  density: s.density, lineStyle: s.lineStyle, underlay: s.underlay, pullCompensation: s.pullCompensation)
    }

    public var sanitized: EmbroideryBorder { EmbroideryBorder(settings: settings.sanitized) }
}
