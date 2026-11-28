import Foundation
import KerfCore

/// Saved workpieces: the user's own material sizes and colours.
extension AppModel {
    nonisolated static func loadSavedWorkpieces() -> WorkpieceLibrary {
        guard let data = UserDefaults.standard.data(forKey: "savedWorkpieces"),
              let lib = try? JSONDecoder().decode(WorkpieceLibrary.self, from: data) else { return WorkpieceLibrary() }
        return lib
    }

    /// Saves the current workpiece's size, kind and colour under `name`. Returns false when there's nothing to save.
    @discardableResult
    func saveCurrentWorkpiece(as name: String) -> Bool {
        guard var w = document.workpiece else { return false }
        guard savedWorkpieces.save(w, as: name) else { return false }
        // The piece on the canvas takes the saved name too, so the preset menu shows it as chosen.
        w.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        setWorkpiece(w)
        return true
    }

    func deleteSavedWorkpiece(named name: String) {
        savedWorkpieces.remove(named: name)
    }
}

extension AppModel {
    /// Sets the workpiece's colour (nil for the kind's usual tint). Quick changes in a row undo together.
    func setWorkpieceColor(_ hex: String?) {
        guard var w = document.workpiece, w.colorHex != hex else { return }
        let now = Date()
        if let last = lastWorkpieceColorEdit, now.timeIntervalSince(last) < 1.5 {
            w.colorHex = hex
            document.workpiece = w
        } else {
            w.colorHex = hex
            setWorkpiece(w)
        }
        lastWorkpieceColorEdit = now
    }
}
