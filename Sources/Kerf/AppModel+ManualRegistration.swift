import Foundation
import KerfCore

/// Print and cut on a vinyl cutter without an optical sensor: move the head from the software onto each printed
/// mark with the laser pointer (or blade tip), confirm it, and the cut is fitted to where the marks really are.
extension AppModel {
    /// The marks' registration points in cutter coordinates as laid out in the design, in mark order.
    var manualRegistrationDesign: [Vec2] { allRegistrationPoints.map(profile.toMachine) }

    /// The cutter can be moved from the software.
    var canJogCutter: Bool { profile.kind == .vinylCutter && profile.language != .svgFile }

    /// Where the pointer is now (blade position plus the laser offset), cutter mm.
    var cutterPointer: Vec2 { ManualRegistration.markPosition(head: cutterHead, offset: profile.laserOffset) }

    /// The fit from the confirmed marks, whether or not it is switched on.
    var manualRegistrationFit: Affine? {
        let design = manualRegistrationDesign
        let known = manualMarks.keys.sorted().filter { design.indices.contains($0) }
        guard !known.isEmpty else { return nil }
        return ManualRegistration.fit(design: known.map { design[$0] }, measured: known.map { manualMarks[$0]! })
    }

    /// The correction applied to the next cut, when manual registration is on and has marks.
    var manualRegistrationTransform: Affine? {
        guard useManualRegistration, canJogCutter else { return nil }
        return manualRegistrationFit
    }

    /// Largest disagreement between the fit and the confirmed marks, mm (0 with fewer than three marks).
    var manualRegistrationResidual: Double {
        guard let t = manualRegistrationFit else { return 0 }
        let design = manualRegistrationDesign
        let known = manualMarks.keys.sorted().filter { design.indices.contains($0) }
        return ManualRegistration.maxResidual(t, design: known.map { design[$0] }, measured: known.map { manualMarks[$0]! })
    }

    /// Where mark `index` should be on the cutter: from the marks confirmed so far, or, before any, assuming the
    /// cutter's origin was set on mark 1.
    func predictedMarkPosition(_ index: Int) -> Vec2? {
        let design = manualRegistrationDesign
        guard design.indices.contains(index) else { return nil }
        if let p = ManualRegistration.predicted(mark: index, design: design, confirmed: manualMarks) { return p }
        return design[index] - design[0]
    }

    // MARK: Moving the head

    /// Sends the head (blade up) to `head`, cutter mm from the origin.
    func moveCutterHead(to head: Vec2, with cutter: CutterSender) {
        guard canJogCutter, let text = ManualRegistration.moveCommand(to: head, profile: profile) else { return }
        cutterHead = head
        cutter.sendMove(text, profile: profile)
    }

    /// Moves the head `cutterJogStep` mm in a screen direction (x right, y down as on the canvas).
    func jogCutter(_ dir: Vec2, multiplier: Double = 1, with cutter: CutterSender) {
        let d = ManualRegistration.jogDelta(dir, step: cutterJogStep * multiplier, profile: profile)
        moveCutterHead(to: cutterHead + d, with: cutter)
    }

    /// Moves the pointer onto where mark `index` should be.
    func goToMark(_ index: Int, with cutter: CutterSender) {
        guard let p = predictedMarkPosition(index) else { return }
        moveCutterHead(to: ManualRegistration.headPosition(pointerAt: p, offset: profile.laserOffset), with: cutter)
    }

    /// Records the pointer's position as mark `index`, then moves on to the next mark not yet confirmed.
    func confirmMark(_ index: Int, with cutter: CutterSender) {
        manualMarks[index] = cutterPointer
        if manualMarks.count >= 2 { useManualRegistration = true }
        let count = manualRegistrationDesign.count
        if let next = (0..<count).map({ (index + 1 + $0) % count }).first(where: { manualMarks[$0] == nil }) {
            goToMark(next, with: cutter)
        }
    }

    func clearManualMarks() {
        manualMarks = [:]
        useManualRegistration = false
    }

    // MARK: Laser offset calibration

    /// Cuts a small cross with the blade where the head is, on scrap media.
    func cutLaserCalibrationCross(with cutter: CutterSender) {
        guard canJogCutter, let text = ManualRegistration.calibrationCross(at: cutterHead, profile: profile) else { return }
        laserCalibrationCross = cutterHead
        cutter.sendMove(text, profile: profile)
    }

    /// The pointer is on the cross's centre: the laser offset is the cross position less the head position.
    func finishLaserCalibration() {
        guard let cross = laserCalibrationCross else { return }
        profile.hasLaserPointer = true
        profile.laserOffset = ManualRegistration.calibratedOffset(cut: cross, head: cutterHead)
        laserCalibrationCross = nil
        // Marks measured with the old offset are now wrong.
        clearManualMarks()
    }
}
