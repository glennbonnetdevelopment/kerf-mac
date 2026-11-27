import KerfCore

extension AppModel {
    /// The toolpath that is sent, framed and exported: `toolpath`, mirrored when Mirror output is on.
    /// The canvas keeps showing the design as drawn.
    var outputToolpath: Toolpath {
        let plain = toolpath
        guard mirrorOutput != .none, !plain.isEmpty else { return plain }
        var doc = document
        if cutSelectionOnly, !selection.isEmpty { doc.shapes = doc.shapes.filter { selection.contains($0.id) } }
        // Flip about the job's own centre so it stays in the same place on the bed.
        return Planner.plan(doc.mirrored(mirrorOutput, about: plain.bounds.center), for: profile.kind)
    }
}
