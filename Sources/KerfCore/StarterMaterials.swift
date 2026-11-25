import Foundation

/// Starting-point settings for xTool diode lasers and the 2 W infrared (1064 nm) module.
/// Every machine, lens and batch of material differs, so these are for a test cut on scrap first.
public extension CutMaterial {
    static let starterNote = "Starter setting: run a small test on scrap first and adjust. Focus on the material surface; air assist on for cuts."

    /// A fixed id per starter, so adding them again updates them instead of duplicating.
    private static func starterID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5EED0000-0000-4000-8000-%012ld", n))!
    }

    /// Starters are dated in the past, so any edit you make wins when they are merged again.
    private static let starterDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    private struct Spec {
        var laser: String
        var material: String
        var thickness: Double
        var operation: String
        var mode: LayerMode
        /// mm/s, as xTool lists them; stored as mm/min.
        var mmPerSecond: Double
        var power: Double
        var passes: Int
        var interval: Double = 0.1
        var air: Bool = true
        var note: String = ""
    }

    private static let specs: [Spec] = [
        // xTool D1 / D1 Pro 5 W
        Spec(laser: "xTool 5 W", material: "Basswood plywood", thickness: 3, operation: "Cut", mode: .line, mmPerSecond: 3, power: 100, passes: 2),
        Spec(laser: "xTool 5 W", material: "Birch plywood", thickness: 3, operation: "Cut", mode: .line, mmPerSecond: 2, power: 100, passes: 3),
        Spec(laser: "xTool 5 W", material: "Wood", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 100, power: 40, passes: 1, air: false),
        Spec(laser: "xTool 5 W", material: "Wood", thickness: 0, operation: "Score", mode: .line, mmPerSecond: 20, power: 50, passes: 1, air: false),
        Spec(laser: "xTool 5 W", material: "Cardstock", thickness: 0.3, operation: "Cut", mode: .line, mmPerSecond: 15, power: 70, passes: 1),
        Spec(laser: "xTool 5 W", material: "Leather", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 100, power: 30, passes: 1, air: false),
        Spec(laser: "xTool 5 W", material: "Anodized aluminium", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 30, power: 100, passes: 1, interval: 0.05, air: false),

        // xTool D1 / D1 Pro 10 W
        Spec(laser: "xTool 10 W", material: "Basswood plywood", thickness: 3, operation: "Cut", mode: .line, mmPerSecond: 6, power: 100, passes: 1),
        Spec(laser: "xTool 10 W", material: "Birch plywood", thickness: 3, operation: "Cut", mode: .line, mmPerSecond: 4, power: 100, passes: 2),
        Spec(laser: "xTool 10 W", material: "Birch plywood", thickness: 5, operation: "Cut", mode: .line, mmPerSecond: 3, power: 100, passes: 3),
        Spec(laser: "xTool 10 W", material: "Black acrylic", thickness: 3, operation: "Cut", mode: .line, mmPerSecond: 3, power: 100, passes: 2,
             note: "Diode lasers can't cut clear or light-coloured acrylic."),
        Spec(laser: "xTool 10 W", material: "Wood", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 150, power: 30, passes: 1, air: false),
        Spec(laser: "xTool 10 W", material: "Wood", thickness: 0, operation: "Score", mode: .line, mmPerSecond: 30, power: 40, passes: 1, air: false),
        Spec(laser: "xTool 10 W", material: "Cardstock", thickness: 0.3, operation: "Cut", mode: .line, mmPerSecond: 25, power: 50, passes: 1),
        Spec(laser: "xTool 10 W", material: "Leather", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 150, power: 25, passes: 1, air: false),
        Spec(laser: "xTool 10 W", material: "Anodized aluminium", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 60, power: 100, passes: 1, interval: 0.05, air: false),
        Spec(laser: "xTool 10 W", material: "Slate", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 100, power: 80, passes: 1, interval: 0.08, air: false),

        // xTool D1 Pro 40 W (high-power diode)
        Spec(laser: "xTool 40 W", material: "Basswood plywood", thickness: 3, operation: "Cut", mode: .line, mmPerSecond: 15, power: 100, passes: 1),
        Spec(laser: "xTool 40 W", material: "Birch plywood", thickness: 3, operation: "Cut", mode: .line, mmPerSecond: 10, power: 100, passes: 1),
        Spec(laser: "xTool 40 W", material: "Birch plywood", thickness: 6, operation: "Cut", mode: .line, mmPerSecond: 4, power: 100, passes: 1),
        Spec(laser: "xTool 40 W", material: "Black acrylic", thickness: 3, operation: "Cut", mode: .line, mmPerSecond: 8, power: 100, passes: 1,
             note: "Diode lasers can't cut clear or light-coloured acrylic."),
        Spec(laser: "xTool 40 W", material: "Wood", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 250, power: 20, passes: 1, air: false),
        Spec(laser: "xTool 40 W", material: "Wood", thickness: 0, operation: "Score", mode: .line, mmPerSecond: 60, power: 25, passes: 1, air: false),
        Spec(laser: "xTool 40 W", material: "Cardstock", thickness: 0.3, operation: "Cut", mode: .line, mmPerSecond: 60, power: 30, passes: 1),
        Spec(laser: "xTool 40 W", material: "Leather", thickness: 2, operation: "Cut", mode: .line, mmPerSecond: 12, power: 100, passes: 1),
        Spec(laser: "xTool 40 W", material: "Anodized aluminium", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 150, power: 70, passes: 1, interval: 0.05, air: false),

        // xTool 2 W infrared (1064 nm) module: marks metals and plastics, doesn't cut wood.
        Spec(laser: "xTool 2 W IR", material: "Stainless steel", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 40, power: 100, passes: 2, interval: 0.05, air: false),
        Spec(laser: "xTool 2 W IR", material: "Stainless steel", thickness: 0, operation: "Black mark", mode: .fill, mmPerSecond: 15, power: 100, passes: 1, interval: 0.02, air: false,
             note: "Slow and fine-spaced for a dark oxide mark."),
        Spec(laser: "xTool 2 W IR", material: "Anodized aluminium", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 150, power: 60, passes: 1, interval: 0.05, air: false),
        Spec(laser: "xTool 2 W IR", material: "Brass", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 30, power: 100, passes: 2, interval: 0.05, air: false),
        Spec(laser: "xTool 2 W IR", material: "Black plastic (ABS)", thickness: 0, operation: "Engrave", mode: .fill, mmPerSecond: 100, power: 30, passes: 1, interval: 0.05, air: false),
        Spec(laser: "xTool 2 W IR", material: "Painted or coated metal", thickness: 0, operation: "Remove coating", mode: .fill, mmPerSecond: 80, power: 80, passes: 1, interval: 0.05, air: false),
        Spec(laser: "xTool 2 W IR", material: "Stainless steel", thickness: 0, operation: "Line mark", mode: .line, mmPerSecond: 20, power: 100, passes: 2, air: false),
    ]

    /// The built-in xTool starter settings, for GRBL lasers.
    static var xToolStarters: [CutMaterial] {
        specs.enumerated().map { i, s in
            var layer = Layer(name: "", colorHex: "#000000", mode: s.mode, passes: s.passes, speed: s.mmPerSecond * 60,
                              power: s.power, airAssist: s.air, fillInterval: s.interval)
            layer.fillBidirectional = true
            let note = s.note.isEmpty ? starterNote : s.note + " " + starterNote
            return CutMaterial(id: starterID(i + 1), name: "\(s.laser) – \(s.material)", thickness: s.thickness,
                               operation: s.operation, notes: note, kind: .grblLaser, settings: layer, modified: starterDate)
        }
    }
}
