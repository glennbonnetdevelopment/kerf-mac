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

/// Starting-point settings for drag-knife vinyl cutters such as the GCC Expert 24.
/// Force is in grams and speed in cm/s, as GCC lists them. Rolls and batches differ, so test first.
public extension CutMaterial {
    static let vinylStarterNote = "Starter setting for a drag-knife cutter such as the GCC Expert 24: cut a small test shape (a triangle inside a square) and weed it, then adjust. The blade should cut through the film and only lightly mark the backing."

    /// 45° is the standard blade for thin film; 60° for thick or textured material.
    private enum Blade {
        case standard, deep
        var note: String {
            switch self {
            case .standard: return "45° blade, using the machine's blade offset."
            case .deep: return "60° blade with a 0.5 mm blade offset."
            }
        }
        /// nil keeps the machine's offset, which is set for the 45° blade most people leave in.
        var offset: Double? { self == .deep ? 0.5 : nil }
    }

    private struct VinylSpec {
        var material: String
        var thickness: Double = 0
        var operation: String = "Cut"
        var force: Int
        var speed: Int
        var passes: Int = 1
        var blade: Blade = .standard
        var note: String = ""
    }

    private static let htvNote = "Heat-transfer vinyl: mirror the design and put the shiny carrier side down."

    private static let vinylSpecs: [VinylSpec] = [
        // Adhesive (sign) vinyl
        VinylSpec(material: "Adhesive vinyl – Oracal 651 (permanent)", force: 85, speed: 30),
        VinylSpec(material: "Adhesive vinyl – Oracal 751 (cast)", force: 75, speed: 30),
        VinylSpec(material: "Adhesive vinyl – Oracal 631 (removable)", force: 70, speed: 30),
        VinylSpec(material: "Adhesive vinyl – Metallic or chrome", force: 100, speed: 20),
        VinylSpec(material: "Adhesive vinyl – Holographic", force: 100, speed: 20),
        VinylSpec(material: "Adhesive vinyl – Etched glass (frosted)", force: 80, speed: 30),
        VinylSpec(material: "Adhesive vinyl – Chalkboard", force: 95, speed: 25),
        VinylSpec(material: "Printable sticker vinyl", operation: "Kiss cut", force: 90, speed: 20,
                  note: "For print and cut: cut through the vinyl, not the liner."),
        VinylSpec(material: "Sticker paper", operation: "Kiss cut", force: 80, speed: 20,
                  note: "For print and cut: cut through the paper, not the liner."),
        VinylSpec(material: "Static cling window film", force: 120, speed: 20),

        // Heat-transfer vinyl
        VinylSpec(material: "HTV – Siser EasyWeed (standard)", force: 70, speed: 25, note: htvNote),
        VinylSpec(material: "HTV – EasyWeed Stretch", force: 75, speed: 25, note: htvNote),
        VinylSpec(material: "HTV – Metallic or foil", force: 80, speed: 20, note: htvNote),
        VinylSpec(material: "HTV – Holographic", force: 85, speed: 20, note: htvNote),
        VinylSpec(material: "HTV – Glitter", force: 140, speed: 15, blade: .deep,
                  note: htvNote + " Glitter dulls blades quickly; keep one blade for it."),
        VinylSpec(material: "HTV – Flock", force: 120, speed: 15, blade: .deep, note: htvNote),
        VinylSpec(material: "HTV – Puff", force: 150, speed: 10, blade: .deep, note: htvNote),
        VinylSpec(material: "HTV – Reflective", force: 110, speed: 15, note: htvNote),

        // Reflective sign vinyl
        VinylSpec(material: "Reflective vinyl – Engineering grade (Oralite 5600)", thickness: 0.15, force: 150, speed: 10, blade: .deep),
        VinylSpec(material: "Reflective vinyl – High intensity prismatic", thickness: 0.3, force: 200, speed: 8, passes: 2, blade: .deep,
                  note: "Prismatic sheeting is tough; slow down further if corners lift."),

        // Stencils
        VinylSpec(material: "Stencil film – Oramask 813", force: 80, speed: 30),
        VinylSpec(material: "Sandblast stencil – 15 mil", thickness: 0.38, force: 200, speed: 8, passes: 2, blade: .deep),
        VinylSpec(material: "Sandblast stencil – 25 mil", thickness: 0.64, force: 250, speed: 5, passes: 2, blade: .deep,
                  note: "Near the GCC Expert 24's 250 g limit; add a third pass if it doesn't weed cleanly."),

        // Paper and card (on a carrier sheet or cutting mat)
        VinylSpec(material: "Copy paper or vellum", force: 60, speed: 20, note: "Use a carrier sheet or cutting mat."),
        VinylSpec(material: "Cardstock – 65 lb (176 gsm)", thickness: 0.25, force: 160, speed: 10, blade: .deep,
                  note: "Use a carrier sheet or cutting mat."),
        VinylSpec(material: "Cardstock – 110 lb (300 gsm)", thickness: 0.4, force: 230, speed: 8, passes: 2, blade: .deep,
                  note: "Use a carrier sheet or cutting mat."),
        VinylSpec(material: "Magnet sheet – 20 mil", thickness: 0.5, force: 250, speed: 5, passes: 3, blade: .deep,
                  note: "At the GCC Expert 24's limit; cut slowly and check depth between passes."),
    ]

    /// The built-in vinyl cutter starter settings.
    static var vinylStarters: [CutMaterial] {
        vinylSpecs.enumerated().map { i, s in
            let layer = Layer(name: "", colorHex: "#000000", mode: .cut, passes: s.passes,
                              cutSpeed: s.speed, cutForce: s.force, bladeOffset: s.blade.offset)
            let note = [s.note, s.blade.note, vinylStarterNote].filter { !$0.isEmpty }.joined(separator: " ")
            return CutMaterial(id: starterID(1001 + i), name: s.material, thickness: s.thickness, operation: s.operation,
                               notes: note, kind: .vinylCutter, settings: layer, modified: starterDate)
        }
    }

    /// Every built-in starter setting (lasers and vinyl cutters).
    static var starters: [CutMaterial] { xToolStarters + vinylStarters }
}
