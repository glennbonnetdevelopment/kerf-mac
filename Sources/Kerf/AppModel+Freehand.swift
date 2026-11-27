import CoreGraphics
import Foundation
import KerfCore
import SwiftUI

/// What the eraser does to the lines it passes over.
enum EraserMode: String, Codable, CaseIterable, Identifiable {
    /// Cuts lines and outlines where the eraser crosses them, leaving open pieces.
    case split
    /// Rubs a hole through filled shapes (closed outlines stay closed); open lines are split.
    case area
    /// Removes any whole path the eraser touches.
    case wholePath

    var id: String { rawValue }
    var title: String {
        switch self {
        case .split: return "Split lines"
        case .area: return "Rub out area"
        case .wholePath: return "Whole paths"
        }
    }
    var help: String {
        switch self {
        case .split: return "Cuts lines and outlines where you rub, leaving the rest as separate open paths."
        case .area: return "Takes the rubbed area out of closed shapes so they stay closed and can still be filled or cut. Open lines are split."
        case .wholePath: return "Removes every path the eraser touches."
        }
    }
}

/// Settings for the pen, brush and eraser tools.
struct FreehandSettings: Codable, Equatable {
    /// 0 follows the hand exactly, 1 smooths the most.
    var smoothing = 0.5
    var brushWidth = 3.0
    var brushThinning = 0.5
    var brushTaper = true
    var brushPressure = true
    /// Eraser diameter in mm.
    var eraserSize = 4.0
    var eraserMode: EraserMode = .area
    /// Only erase the selected shapes.
    var eraserSelectionOnly = false

    var brush: BrushOptions {
        BrushOptions(width: max(0.05, brushWidth), thinning: brushThinning, taper: brushTaper, usePressure: brushPressure)
    }

    private static let key = "freehandSettings"

    static func load() -> FreehandSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(FreehandSettings.self, from: data) else { return FreehandSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    init() {}

    /// Missing keys fall back to defaults so older saved settings still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FreehandSettings()
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        brushWidth = try c.decodeIfPresent(Double.self, forKey: .brushWidth) ?? d.brushWidth
        brushThinning = try c.decodeIfPresent(Double.self, forKey: .brushThinning) ?? d.brushThinning
        brushTaper = try c.decodeIfPresent(Bool.self, forKey: .brushTaper) ?? d.brushTaper
        brushPressure = try c.decodeIfPresent(Bool.self, forKey: .brushPressure) ?? d.brushPressure
        eraserSize = try c.decodeIfPresent(Double.self, forKey: .eraserSize) ?? d.eraserSize
        eraserMode = (try? c.decodeIfPresent(EraserMode.self, forKey: .eraserMode)) ?? d.eraserMode
        eraserSelectionOnly = try c.decodeIfPresent(Bool.self, forKey: .eraserSelectionOnly) ?? d.eraserSelectionOnly
    }
}

/// Pen, brush and eraser.
extension AppModel {
    /// Colour of the layer new strokes go on.
    var currentLayerColor: Color {
        let layer = currentLayerID.flatMap { document.layer($0) } ?? document.layers.first
        return Color(hex: layer?.colorHex ?? "#000000")
    }

    /// How far (mm) a pen line may move from the hand-drawn one, for a canvas zoom of `zoom` points per mm.
    /// Hand wobble is a matter of screen distance, so the tolerance shrinks as you zoom in.
    func freehandTolerance(zoom: Double) -> Double {
        (0.3 + 4 * min(1, max(0, freehand.smoothing))) / max(1e-6, zoom)
    }

    /// Adds a smoothed pen line through the pointer positions. It closes when it ends near where it started.
    func addPenStroke(_ points: [Vec2], zoom: Double) {
        guard points.count > 1 else { return }
        let line = Freehand.smooth(points, tolerance: freehandTolerance(zoom: zoom), closeDistance: 8 / zoom)
        guard line.points.count > 1, max(line.bounds.width, line.bounds.height) > 0.2 else { return }
        addFreehandShape([line], name: "Pen line")
    }

    /// The outline a brush stroke makes, cleaned so it doesn't overlap itself.
    func brushOutline(_ samples: [StrokeSample], zoom: Double, clean: Bool) -> [Polyline] {
        let raw = Freehand.brushOutline(samples, options: freehand.brush, tolerance: freehandTolerance(zoom: zoom),
                                        closeDistance: 8 / zoom, speedReference: 600 / zoom)
        return clean ? Self.cleaned(raw, rule: raw.count == 2 ? .evenOdd : .winding) : raw
    }

    /// Adds a brush stroke as a filled outline, so it can be cut, engraved or stitched like any shape.
    func addBrushStroke(_ samples: [StrokeSample], zoom: Double) {
        guard !samples.isEmpty else { return }
        let outline = brushOutline(samples, zoom: zoom, clean: true)
        guard !outline.isEmpty else { return }
        addFreehandShape(outline, name: "Brush stroke")
    }

    /// Adds a drawn stroke on the current layer without selecting it, so the selection box doesn't get in
    /// the way of the next stroke.
    private func addFreehandShape(_ paths: [Polyline], name: String) {
        checkpoint()
        document.shapes.append(Artwork(layerID: ensureCurrentLayer(), name: name, paths: paths))
        selection = []
    }

    /// Merges overlapping parts of the outlines into simple loops.
    static func cleaned(_ polys: [Polyline], rule: CGPathFillRule) -> [Polyline] {
        let path = cgPath(polys).normalized(using: rule)
        let out = TextOutliner.flatten(path, offset: .zero, step: 0.1).filter { $0.closed && abs($0.signedArea) > 1e-4 }
        return out.isEmpty ? polys : out
    }

    /// Rubs out what the eraser trail passed over (bed coordinates), as one undo step.
    func erase(trail: [Vec2]) {
        guard !trail.isEmpty else { return }
        let radius = max(0.05, freehand.eraserSize / 2)
        let onlySelected = freehand.eraserSelectionOnly && !selection.isEmpty
        var changed = false
        var next = document.shapes
        var removed: Set<UUID> = []
        for i in next.indices {
            let shape = next[i]
            guard shape.image == nil, !onlySelected || selection.contains(shape.id) else { continue }
            let box = shape.bounds.insetBy(-radius)
            guard trail.contains(where: { box.contains($0) }) || Self.trailCrosses(trail, box) else { continue }

            // Work in the shape's own coordinates so its placement is kept.
            let inv = shape.transform.inverted
            let localTrail = trail.map(inv.apply)
            let localRadius = radius / max(1e-9, shape.transform.meanScale)
            let paths = erasedPaths(shape.paths, trail: localTrail, radius: localRadius)
            guard paths != shape.paths else { continue }
            changed = true
            if paths.isEmpty {
                removed.insert(shape.id)
                continue
            }
            next[i].paths = paths
            // Erased text and hand-edited stitches no longer match their source.
            next[i].text = nil
            next[i].pathText = nil
            next[i].stitches = nil
        }
        guard changed else { return }
        checkpoint()
        next.removeAll { removed.contains($0.id) }
        document.shapes = next
        document.pruneStyleParts()
        selection.subtract(removed)
    }

    private func erasedPaths(_ paths: [Polyline], trail: [Vec2], radius: Double) -> [Polyline] {
        switch freehand.eraserMode {
        case .split:
            return Eraser.split(paths, trail: trail, radius: radius)
        case .wholePath:
            return Eraser.removeTouched(paths, trail: trail, radius: radius)
        case .area:
            let closed = paths.filter(\.closed)
            let open = Eraser.split(paths.filter { !$0.closed }, trail: trail, radius: radius)
            guard closed.contains(where: { Eraser.touches($0, trail: trail, radius: radius, insideCounts: true) }) else {
                return closed + open
            }
            let swept = Self.cgPath(Eraser.sweptArea(trail, radius: radius)).normalized(using: .winding)
            let result = Self.cgPath(closed).normalized(using: .evenOdd).subtracting(swept, using: .evenOdd)
            let polys = TextOutliner.flatten(result, offset: .zero, step: 0.1).filter { $0.closed && abs($0.signedArea) > 1e-4 }
            return polys + open
        }
    }

    /// True when any step of the trail crosses the box (for fast strokes whose points all land outside it).
    private static func trailCrosses(_ trail: [Vec2], _ box: Rect2) -> Bool {
        guard trail.count > 1 else { return false }
        for i in 1..<trail.count {
            let a = trail[i - 1], b = trail[i]
            let seg = Rect2(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
            if seg.intersects(box) { return true }
        }
        return false
    }
}
