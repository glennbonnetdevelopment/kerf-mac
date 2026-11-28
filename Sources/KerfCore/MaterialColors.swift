import Foundation

/// Colour helpers for drawing thread and material on the canvas.
extension ThreadColor {
    /// The colour darkened towards black by `amount` (0…1).
    public func darkened(by amount: Double) -> ThreadColor {
        let k = 1 - Swift.min(1, Swift.max(0, amount))
        func f(_ v: UInt8) -> UInt8 { UInt8((Double(v) * k).rounded()) }
        return ThreadColor(red: f(red), green: f(green), blue: f(blue))
    }

    /// The colour lightened towards white by `amount` (0…1).
    public func lightened(by amount: Double) -> ThreadColor {
        let k = Swift.min(1, Swift.max(0, amount))
        func f(_ v: UInt8) -> UInt8 { UInt8((Double(v) + (255 - Double(v)) * k).rounded()) }
        return ThreadColor(red: f(red), green: f(green), blue: f(blue))
    }

    /// Relative brightness, 0 (black) to 1 (white).
    public var luminance: Double {
        (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
    }
}

extension Workpiece {
    /// The colour the piece is drawn in when it has none of its own.
    public static func defaultColorHex(for kind: Kind) -> String {
        switch kind {
        case .stock: return "#DEB884"
        case .mat: return "#8CC7D9"
        case .sheet: return "#FFFFFF"
        case .hoop: return "#F7F4EE"
        }
    }

    /// An edge colour that shows against the piece's own colour: darker on light material, lighter on dark.
    public var edgeColor: ThreadColor {
        let c = ThreadColor(hex: colorHex ?? Workpiece.defaultColorHex(for: kind))
        return c.luminance > 0.45 ? c.darkened(by: 0.45) : c.lightened(by: 0.45)
    }
}
