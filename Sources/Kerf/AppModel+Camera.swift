import AppKit
import KerfCore

/// Camera alignment helpers on the document: the burned target, a checkerboard to print or engrave,
/// and outlines traced from the camera picture.
extension AppModel {
    static let cameraTargetLayerName = "Camera target"

    /// The alignment target as a one-layer design, at absolute bed positions.
    func cameraTargetDocument(_ settings: CameraTargetSettings) -> KerfDocument {
        var doc = KerfDocument()
        var layer = Layer(name: Self.cameraTargetLayerName, colorHex: "#E5222D", mode: .line)
        layer.speed = settings.speed
        layer.power = settings.power
        doc.layers = [layer]
        doc.shapes = [Artwork(layerID: layer.id, name: "Camera target",
                              paths: CameraAlignment.targetPaths(marks: settings.marks, size: settings.markSize))]
        return doc
    }

    /// G-code that burns the alignment target. It always runs from machine home (absolute positions),
    /// whatever the job's zero point is set to, because the camera is aligned to the bed itself.
    func cameraTargetGCode(_ settings: CameraTargetSettings) -> [String] {
        let tp = Planner.plan(cameraTargetDocument(settings), for: profile.kind)
        return GCodeGenerator.generate(tp, profile: profile)
    }

    /// Puts the alignment target in the design instead, to run it like any other job.
    func addCameraTargetToDesign(_ settings: CameraTargetSettings) {
        let target = cameraTargetDocument(settings)
        checkpoint()
        var layer = target.layers[0]
        if let existing = document.layers.first(where: { $0.name == Self.cameraTargetLayerName }) {
            layer.id = existing.id
        } else {
            document.layers.append(layer)
        }
        var shape = target.shapes[0]
        shape.layerID = layer.id
        document.shapes.append(shape)
        selection = [shape.id]
        jobOrigin = .absolute
    }

    /// Adds a checkerboard of `columns + 1` × `rows + 1` squares, centred on the bed, to print or engrave
    /// for lens calibration. Laser machines get a fill layer; others a print-only layer.
    func addCalibrationCheckerboard(columns: Int, rows: Int, square: Double) {
        let nx = columns + 1, ny = rows + 1
        let s = max(2, square)
        var squares: [Polyline] = []
        for j in 0..<ny {
            for i in 0..<nx where (i + j) % 2 == 0 {
                let x = Double(i) * s, y = Double(j) * s
                squares.append(Polyline([Vec2(x, y), Vec2(x + s, y), Vec2(x + s, y + s), Vec2(x, y + s)], closed: true))
            }
        }
        let size = Vec2(Double(nx) * s, Double(ny) * s)
        let c = Vec2(profile.bedWidth / 2, profile.bedHeight / 2)
        checkpoint()
        let mode: LayerMode = profile.kind == .grblLaser ? .fill : .print
        let layerID = document.layer(forMode: mode, name: mode == .fill ? "Checkerboard" : "Print", colorHex: "#000000")
        let shape = Artwork(layerID: layerID, name: "Calibration checkerboard \(nx) × \(ny)", paths: squares,
                            transform: .translation(c.x - size.x / 2, c.y - size.y / 2))
        document.shapes.append(shape)
        selection = [shape.id]
        currentLayerID = layerID
    }

    /// Adds outlines traced from the camera picture, on the current layer.
    func addCameraTrace(_ loops: [Polyline]) {
        guard !loops.isEmpty else {
            alertMessage = "Nothing was traced. Try another threshold, or trace light areas instead."
            return
        }
        addShape(paths: loops, name: "Camera trace")
    }

    /// The area to trace: the selection when there is one, else the workpiece, else the whole picture.
    var cameraTraceRegion: Rect2? {
        if !selection.isEmpty { return selectionBounds }
        return document.workpiece?.rect
    }
}
