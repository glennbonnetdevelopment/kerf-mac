import Foundation

/// Saved cut settings for one material and operation on one kind of machine,
/// such as "Birch plywood, 3 mm, cut" on a laser or "Oracal 651, cut" on a vinyl cutter.
public struct Material: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Material thickness in mm; 0 when it doesn't matter (vinyl, engraving).
    public var thickness: Double
    /// What the settings do: "Cut", "Score", "Engrave", "Pocket" and so on.
    public var operation: String
    public var notes: String
    /// The machine type the settings are for.
    public var kind: DeviceKind
    /// The settings, kept as a layer so every machine's options are covered.
    /// Its id, name, colour and on/off state are not used.
    public var settings: Layer
    public var modified: Date

    public init(id: UUID = UUID(), name: String, thickness: Double = 0, operation: String = "Cut", notes: String = "",
                kind: DeviceKind, settings: Layer, modified: Date = Date()) {
        self.id = id
        self.name = name
        self.thickness = thickness
        self.operation = operation
        self.notes = notes
        self.kind = kind
        self.settings = settings
        self.modified = modified
    }

    /// "Birch plywood · 3 mm · Cut"
    public var title: String {
        var parts = [name.isEmpty ? "Untitled" : name]
        if thickness > 0 { parts.append(Self.formatThickness(thickness)) }
        if !operation.isEmpty { parts.append(operation) }
        return parts.joined(separator: " · ")
    }

    public static func formatThickness(_ mm: Double) -> String {
        let s = String(format: "%.2f", mm)
        let trimmed = s.replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
        return trimmed + " mm"
    }

    /// Copies the machine settings onto `layer`, keeping the layer's own name, colour and on/off state.
    public func apply(to layer: inout Layer) {
        var s = settings
        s.id = layer.id
        s.name = layer.name
        s.colorHex = layer.colorHex
        s.enabled = layer.enabled
        s.materialID = id
        layer = s
    }

    /// Takes the settings from `layer`.
    public mutating func capture(_ layer: Layer) {
        var s = layer
        s.materialID = nil
        settings = s
        modified = Date()
    }
}

/// The saved materials, stored as JSON.
public struct MaterialLibrary: Codable, Hashable, Sendable {
    public var materials: [Material]

    public init(materials: [Material] = []) {
        self.materials = materials
    }

    /// Materials for one machine type, sorted by name, then thickness, then operation.
    public func materials(for kind: DeviceKind) -> [Material] {
        materials.filter { $0.kind == kind }.sorted {
            let a = $0.name.localizedLowercase, b = $1.name.localizedLowercase
            if a != b { return a < b }
            if $0.thickness != $1.thickness { return $0.thickness < $1.thickness }
            return $0.operation.localizedLowercase < $1.operation.localizedLowercase
        }
    }

    public func material(_ id: UUID?) -> Material? {
        guard let id else { return nil }
        return materials.first { $0.id == id }
    }

    /// Adds a material, or replaces the one with the same id.
    public mutating func upsert(_ m: Material) {
        if let i = materials.firstIndex(where: { $0.id == m.id }) { materials[i] = m } else { materials.append(m) }
    }

    public mutating func remove(_ id: UUID) {
        materials.removeAll { $0.id == id }
    }

    /// Adds materials from another library. Ones with an id already here replace the existing copy
    /// when they are newer. Returns how many were added or updated.
    @discardableResult
    public mutating func merge(_ other: MaterialLibrary) -> Int {
        var changed = 0
        for m in other.materials {
            if let i = materials.firstIndex(where: { $0.id == m.id }) {
                if m.modified > materials[i].modified { materials[i] = m; changed += 1 }
            } else {
                materials.append(m)
                changed += 1
            }
        }
        return changed
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> MaterialLibrary {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(MaterialLibrary.self, from: data)
    }
}
