import Foundation
import KerfCore

/// Holding tabs: showing them, and adding, moving and removing them by hand with the tabs tool.
extension AppModel {
    /// True when any layer that runs on the current machine uses holding tabs.
    var tabsInUse: Bool {
        profile.kind != .vinylCutter && document.layers.contains { $0.enabled && $0.tabsEnabled }
    }

    /// Every holding tab in the planned job.
    var tabMarks: [TabMark] { tabsInUse ? toolpath.tabMarks : [] }

    /// The tab nearest `p` within `tolerance` mm.
    func tabHit(at p: Vec2, tolerance: Double) -> TabMark? {
        var best: (TabMark, Double)?
        for m in tabMarks {
            let d = m.point.distance(to: p)
            if d <= tolerance + m.length / 2, best == nil || d < best!.1 { best = (m, d) }
        }
        return best?.0
    }

    /// Makes `shapeID`'s tabs hand-placed, starting from where they are now, and returns the
    /// hand-placed index of `mark` (when given).
    @discardableResult
    func makeTabsManual(_ shapeID: UUID, keeping mark: TabMark? = nil) -> Int? {
        guard let i = document.shapes.firstIndex(where: { $0.id == shapeID }) else { return nil }
        if document.shapes[i].tabs != nil { return mark?.manualIndex }
        let marks = tabMarks.filter { $0.shapeID == shapeID }
        let inverse = document.shapes[i].transform.inverted
        document.shapes[i].tabs = marks.map { inverse.apply($0.point) }
        guard let mark else { return nil }
        return marks.firstIndex(of: mark)
    }

    /// Adds a tab on the outline nearest `p`, on a shape whose layer can have tabs.
    /// Turns tabs on for that layer if they were off. Returns false when no outline is close enough.
    @discardableResult
    func addTab(at p: Vec2, tolerance: Double) -> Bool {
        guard profile.kind != .vinylCutter, let id = hitTest(p, tolerance: tolerance),
              let shape = document.shapes.first(where: { $0.id == id }), shape.image == nil,
              let layerIndex = document.layers.firstIndex(where: { $0.id == shape.layerID }),
              canHaveTabs(document.layers[layerIndex].mode),
              shape.placedPaths.contains(where: { $0.closed }) else { return false }
        guard document.layers[layerIndex].tabsEnabled else {
            alertMessage = "Holding tabs are off for layer \(document.layers[layerIndex].name). Turn on Holding tabs in the layer's settings, then add tabs by hand."
            return true
        }
        checkpoint()
        makeTabsManual(id)
        guard let i = document.shapes.firstIndex(where: { $0.id == id }) else { return false }
        document.shapes[i].tabs?.append(document.shapes[i].transform.inverted.apply(p))
        selection = [id]
        return true
    }

    /// Moves a tab to the outline point nearest `p`. `recordUndo` is true for the first move of a drag.
    /// Returns the tab's hand-placed index, for the rest of the drag.
    @discardableResult
    func moveTab(_ mark: TabMark, index: Int?, to p: Vec2, recordUndo: Bool) -> Int? {
        if recordUndo { checkpoint() }
        guard let k = index ?? makeTabsManual(mark.shapeID, keeping: mark),
              let i = document.shapes.firstIndex(where: { $0.id == mark.shapeID }),
              let tabs = document.shapes[i].tabs, k < tabs.count else { return nil }
        document.shapes[i].tabs![k] = document.shapes[i].transform.inverted.apply(p)
        return k
    }

    func removeTab(_ mark: TabMark) {
        checkpoint()
        guard let k = makeTabsManual(mark.shapeID, keeping: mark),
              let i = document.shapes.firstIndex(where: { $0.id == mark.shapeID }),
              let tabs = document.shapes[i].tabs, k < tabs.count else { return }
        document.shapes[i].tabs!.remove(at: k)
    }

    /// Whether layers of `mode` get tabs on the current machine.
    func canHaveTabs(_ mode: LayerMode) -> Bool {
        switch profile.kind {
        case .grblLaser: return mode == .line || mode == .cut
        case .cncRouter: return Planner.supports(mode, on: .cncRouter)
        case .vinylCutter: return false
        }
    }

    // MARK: - Selection

    enum TabMode: Equatable {
        case automatic, manual, none, mixed
    }

    /// How the selected shapes' tabs are placed.
    var selectionTabMode: TabMode {
        let modes = Set(selectedShapes.map { s -> TabMode in
            guard let t = s.tabs else { return .automatic }
            return t.isEmpty ? .none : .manual
        })
        return modes.count == 1 ? modes.first! : .mixed
    }

    /// Puts the selected shapes back on automatic tabs from their layer's settings.
    func setSelectionTabsAutomatic() {
        setSelectionTabs(nil)
    }

    /// Leaves the selected shapes without tabs.
    func setSelectionNoTabs() {
        setSelectionTabs([])
    }

    private func setSelectionTabs(_ tabs: [Vec2]?) {
        guard !selection.isEmpty else { return }
        checkpoint()
        for i in document.shapes.indices where selection.contains(document.shapes[i].id) {
            document.shapes[i].tabs = tabs
        }
    }

    /// Number of tabs on the selected shapes.
    var selectionTabCount: Int {
        tabMarks.filter { selection.contains($0.shapeID) }.count
    }
}
