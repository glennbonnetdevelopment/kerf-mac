import Foundation
import XCTest
@testable import KerfCore

final class CameraTests: XCTestCase {
    // MARK: Homography

    func testHomographyFitRecoversMapping() throws {
        let truth = Homography([1.2, 0.1, 30, -0.05, 0.9, 12, 0.0004, -0.0002, 1])
        let src = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 80), Vec2(0, 80), Vec2(50, 40), Vec2(20, 70)]
        let dst = src.map { truth.apply($0)! }
        let fit = try XCTUnwrap(Homography.fit(from: src, to: dst))
        for p in [Vec2(10, 10), Vec2(90, 5), Vec2(33, 77)] {
            XCTAssertEqual(fit.apply(p)!.distance(to: truth.apply(p)!), 0, accuracy: 1e-6)
        }
        let inv = try XCTUnwrap(fit.inverted)
        XCTAssertEqual(inv.apply(fit.apply(Vec2(42, 17))!)!.distance(to: Vec2(42, 17)), 0, accuracy: 1e-6)
        XCTAssertNil(Homography.fit(from: [Vec2(0, 0), Vec2(1, 1), Vec2(2, 2), Vec2(3, 3)],
                                    to: [Vec2(0, 0), Vec2(1, 1), Vec2(2, 2), Vec2(3, 3)]))
    }

    // MARK: Lens

    func testLensDistortionRoundTrip() {
        let lens = LensModel(imageWidth: 1280, imageHeight: 720, fx: 900, fy: 900, cx: 640, cy: 360,
                             k1: -0.28, k2: 0.09, k3: -0.01, p1: 0.001, p2: -0.0005)
        for q in [Vec2(0, 0), Vec2(1279, 719), Vec2(640, 10), Vec2(300, 500)] {
            let ideal = lens.undistortPixel(q)
            XCTAssertEqual(lens.distortPixel(ideal).distance(to: q), 0, accuracy: 1e-6)
        }
        // Barrel distortion pulls the corners in, so straightening pushes them out.
        XCTAssertGreaterThan(lens.undistortPixel(Vec2(0, 0)).distance(to: Vec2(640, 360)), Vec2(0, 0).distance(to: Vec2(640, 360)))
        XCTAssertLessThan(lens.cornerDistortion, 0)
        let half = try! XCTUnwrap(lens.scaled(toWidth: 640, height: 360))
        XCTAssertEqual(half.fx, 450, accuracy: 1e-9)
        XCTAssertNil(lens.scaled(toWidth: 640, height: 480))
    }

    /// Board views seen through a known lens, as `LensCalibration` would get them from the detector.
    private func syntheticViews(noise: Double = 0) -> (LensModel, [CheckerboardView]) {
        let truth = LensModel(imageWidth: 1280, imageHeight: 720, fx: 900, fy: 900, cx: 652, cy: 351,
                              k1: -0.25, k2: 0.08, k3: 0, p1: 0.0008, p2: -0.0004)
        let intr = [truth.fx, truth.cx, truth.cy, truth.k1, truth.k2, truth.p1, truth.p2, truth.k3]
        let poses: [[Double]] = [
            [0.35, 0.05, 0.02, -4, -2.5, 14],
            [-0.3, 0.1, -0.05, -5, -3, 13],
            [0.05, 0.4, 0.1, -3, -2, 15],
            [0.2, -0.35, 0.25, -4.5, -1.5, 14],
            [0.0, 0.0, 0.5, -2, -4, 16],
            [-0.25, -0.2, -0.15, -6, -3.5, 13],
            [0.1, 0.3, -0.3, -1, -1, 12],
            [-0.15, -0.35, 0.05, -7, -2, 15],
        ]
        var rng = SystemRandomNumberGenerator()
        var views: [CheckerboardView] = []
        for pose in poses {
            var img: [Vec2] = [], board: [Vec2] = []
            for j in 0..<6 {
                for i in 0..<9 {
                    let b = Vec2(Double(i), Double(j))
                    var q = LensCalibration.project(b, intr + pose, pose: 8)!
                    if noise > 0 {
                        q = q + Vec2(Double.random(in: -noise...noise, using: &rng), Double.random(in: -noise...noise, using: &rng))
                    }
                    XCTAssertTrue(q.x > 0 && q.y > 0 && q.x < 1279 && q.y < 719, "corner off the picture: \(q)")
                    img.append(q)
                    board.append(b)
                }
            }
            views.append(CheckerboardView(imagePoints: img, boardPoints: board, imageWidth: 1280, imageHeight: 720))
        }
        return (truth, views)
    }

    func testLensCalibrationRecoversCamera() throws {
        let (truth, views) = syntheticViews()
        let lens = try XCTUnwrap(LensCalibration.calibrate(views))
        XCTAssertLessThan(lens.rmsError, 0.01)
        XCTAssertEqual(lens.fx, truth.fx, accuracy: 3)
        XCTAssertEqual(lens.k1, truth.k1, accuracy: 0.01)
        XCTAssertEqual(lens.views, views.count)
        // What matters: straightening the corners of the picture lands where the true lens would.
        for q in [Vec2(0, 0), Vec2(1279, 0), Vec2(0, 719), Vec2(1279, 719), Vec2(300, 200)] {
            let a = truth.undistort(normalized: Vec2((q.x - truth.cx) / truth.fx, (q.y - truth.cy) / truth.fy))
            let b = lens.undistort(normalized: Vec2((q.x - lens.cx) / lens.fx, (q.y - lens.cy) / lens.fy))
            XCTAssertEqual(a.distance(to: b) * truth.fx, 0, accuracy: 1.5)
        }
    }

    func testLensCalibrationToleratesNoise() throws {
        let (_, views) = syntheticViews(noise: 0.3)
        let lens = try XCTUnwrap(LensCalibration.calibrate(views))
        XCTAssertLessThan(lens.rmsError, 0.4)
        XCTAssertEqual(lens.k1, -0.25, accuracy: 0.04)
    }

    func testLensCalibrationNeedsThreeViews() {
        let (_, views) = syntheticViews()
        XCTAssertNil(LensCalibration.calibrate(Array(views.prefix(2))))
    }

    // MARK: Checkerboard detection

    /// Renders a 10 × 7-square board (9 × 6 inner corners) through `h` (board squares to pixels).
    private func renderBoard(width: Int, height: Int, _ h: Homography) -> GrayImage {
        let inv = h.inverted!
        var px = [UInt8](repeating: 0, count: width * height)
        let offsets = [Vec2(-0.25, -0.25), Vec2(0.25, -0.25), Vec2(-0.25, 0.25), Vec2(0.25, 0.25)]
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for o in offsets {
                    let b = inv.apply(Vec2(Double(x) + o.x, Double(y) + o.y))!
                    if b.x >= -1, b.x < 9, b.y >= -1, b.y < 6 {
                        sum += (Int(b.x.rounded(.down)) + Int(b.y.rounded(.down))) % 2 == 0 ? 25 : 225
                    } else {
                        sum += 215
                    }
                }
                px[y * width + x] = UInt8(sum / 4)
            }
        }
        return GrayImage(width: width, height: height, pixels: px)
    }

    func testDetectsCheckerboardCorners() throws {
        let h = try XCTUnwrap(Homography.fit(from: [Vec2(-1, -1), Vec2(9, -1), Vec2(9, 6), Vec2(-1, 6)],
                                             to: [Vec2(120, 100), Vec2(690, 135), Vec2(655, 520), Vec2(140, 475)]))
        let img = renderBoard(width: 800, height: 600, h)
        let view = try XCTUnwrap(CheckerboardDetector.detect(img, columns: 9, rows: 6))
        XCTAssertEqual(view.imagePoints.count, 54)
        XCTAssertEqual(Set(view.boardPoints).count, 54)
        for j in 0..<6 {
            for i in 0..<9 {
                let expected = h.apply(Vec2(Double(i), Double(j)))!
                let nearest = view.imagePoints.map { $0.distance(to: expected) }.min()!
                XCTAssertLessThan(nearest, 0.3, "corner \(i),\(j)")
            }
        }
        // The labels must be one consistent grid, not mirrored.
        let fit = try XCTUnwrap(Homography.fit(from: view.boardPoints, to: view.imagePoints))
        for (b, q) in zip(view.boardPoints, view.imagePoints) {
            XCTAssertLessThan(fit.apply(b)!.distance(to: q), 0.5)
        }
        let ax = view.imagePoints[1] - view.imagePoints[0]
        let rowLength = view.boardPoints.filter { $0.y == 0 }.count
        let ay = view.imagePoints[rowLength] - view.imagePoints[0]
        XCTAssertGreaterThan(ax.cross(ay), 0)
    }

    func testNoCheckerboardInBlankPicture() {
        let img = GrayImage(width: 320, height: 240, pixels: [UInt8](repeating: 200, count: 320 * 240))
        XCTAssertNil(CheckerboardDetector.detect(img, columns: 9, rows: 6))
    }

    // MARK: Alignment

    func testTargetMarksAndPaths() {
        let marks = CameraAlignment.markCentres(in: Rect2(minX: 50, minY: 40, maxX: 350, maxY: 340), columns: 3, rows: 3)
        XCTAssertEqual(marks.count, 9)
        XCTAssertEqual(marks[0], Vec2(50, 40))
        XCTAssertEqual(marks[2], Vec2(350, 40))
        XCTAssertEqual(marks[4], Vec2(200, 190))
        XCTAssertEqual(marks[8], Vec2(350, 340))
        let paths = CameraAlignment.targetPaths(marks: marks, size: 10)
        // Two strokes and a ring per mark, plus the inner ring on mark 1.
        XCTAssertEqual(paths.count, 9 * 3 + 1)
        XCTAssertEqual(paths.bounds.minX, 45, accuracy: 1e-9)
    }

    func testAlignmentMapsPictureToBed() throws {
        let lens = LensModel(imageWidth: 1280, imageHeight: 720, fx: 800, fy: 800, cx: 640, cy: 360, k1: -0.2, k2: 0.05)
        // True ideal-pixel → bed mapping.
        let bedFromIdeal = Homography([0.32, 0.01, -15, -0.008, 0.33, -8, 0.00002, 0.00001, 1])
        let idealFromBed = bedFromIdeal.inverted!
        let marks = CameraAlignment.markCentres(in: Rect2(minX: 40, minY: 40, maxX: 360, maxY: 200), columns: 3, rows: 3)
        // What the person clicks: the raw (distorted) picture positions of each mark.
        let clicked = marks.map { lens.distortPixel(idealFromBed.apply($0)!) }
        let ideal = clicked.map { lens.undistortPixel($0) }
        let fit = try XCTUnwrap(CameraAlignment.fit(image: ideal, bed: marks))
        XCTAssertLessThan(fit.rms, 1e-6)
        let setup = CameraSetup(lens: lens, alignment: BedAlignment(imageWidth: 1280, imageHeight: 720, imageToBed: fit.homography,
                                                                     profileID: nil, rmsError: fit.rms, maxError: fit.max))
        for (q, m) in zip(clicked, marks) {
            XCTAssertEqual(try XCTUnwrap(setup.imageToBed(q, width: 1280, height: 720)).distance(to: m), 0, accuracy: 1e-6)
        }
        // Half-size frames from the same camera map the same way.
        let half = Vec2((clicked[4].x + 0.5) / 2 - 0.5, (clicked[4].y + 0.5) / 2 - 0.5)
        XCTAssertEqual(try XCTUnwrap(setup.imageToBed(half, width: 640, height: 360)).distance(to: marks[4]), 0, accuracy: 1e-6)

        // The bed picture samples the camera at the right place.
        let remap = try XCTUnwrap(setup.bedRemap(area: Rect2(minX: 0, minY: 0, maxX: 400, maxY: 240), mmPerPixel: 1,
                                                 sourceWidth: 1280, sourceHeight: 720))
        XCTAssertEqual(remap.width, 400)
        XCTAssertEqual(remap.height, 240)
        let src = try XCTUnwrap(remap.source(x: 199, y: 119))
        XCTAssertEqual(src.distance(to: lens.distortPixel(idealFromBed.apply(Vec2(199.5, 119.5))!)), 0, accuracy: 1e-2)
    }

    func testAlignmentNeedsFourMarks() {
        XCTAssertNil(CameraAlignment.fit(image: [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)], bed: [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)]))
    }

    func testSnapsToBurnedMark() throws {
        let centre = Vec2(201.3, 187.6)
        var px = [UInt8](repeating: 210, count: 400 * 400)
        for y in 0..<400 {
            for x in 0..<400 {
                // Supersampled cross in a circle, 60 px across with 3 px lines.
                var dark = 0
                for (ox, oy) in [(-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)] {
                    let dx = Double(x) + ox - centre.x, dy = Double(y) + oy - centre.y
                    let r = (dx * dx + dy * dy).squareRoot()
                    if (abs(dx) < 1.5 && abs(dy) < 30) || (abs(dy) < 1.5 && abs(dx) < 30) || abs(r - 22.5) < 1.5 { dark += 1 }
                }
                px[y * 400 + x] = UInt8(210 - dark * 40)
            }
        }
        let img = GrayImage(width: 400, height: 400, pixels: px)
        let snapped = try XCTUnwrap(CameraAlignment.snapToMark(img, near: Vec2(195, 193), radius: 40))
        XCTAssertEqual(snapped.distance(to: centre), 0, accuracy: 0.3)
        XCTAssertNil(CameraAlignment.snapToMark(GrayImage(width: 100, height: 100, pixels: [UInt8](repeating: 128, count: 10_000)),
                                                near: Vec2(50, 50), radius: 20))
    }

    // MARK: Remap and trace

    func testRemapCopiesAndMarksUnseenTransparent() {
        // A 4×2 BGRA source with distinct blue values.
        var src = [UInt8](repeating: 0, count: 4 * 2 * 4)
        for i in 0..<8 { src[i * 4] = UInt8(i * 30); src[i * 4 + 3] = 255 }
        let remap = CameraRemap(width: 2, height: 1, sourceWidth: 4, sourceHeight: 2) { x, _ in
            x == 0 ? Vec2(2, 1) : nil
        }
        let out = src.withUnsafeBytes { remap.apply(bgra: $0, width: 4, height: 2, bytesPerRow: 16) }
        XCTAssertEqual(out[0], 6 * 30)
        XCTAssertEqual(out[3], 255)
        XCTAssertEqual(Array(out[4..<8]), [0, 0, 0, 0])
    }

    func testTraceFindsDarkShapeWithHole() {
        let w = 100, h = 80
        var gray = [UInt8](repeating: 230, count: w * h)
        for y in 20..<60 { for x in 10..<70 { gray[y * w + x] = 20 } }
        for y in 30..<50 { for x in 30..<50 { gray[y * w + x] = 230 } }
        gray[5 * w + 90] = 10 // a speck
        let t = CameraTrace.otsuThreshold(gray)
        XCTAssertTrue(t > 20 && t <= 230)
        let loops = CameraTrace.trace(gray: gray, seen: nil, width: w, height: h, origin: Vec2(100, 200), cell: 0.5,
                                      options: .init(threshold: t, minimumArea: 1, smoothing: 0))
        XCTAssertEqual(loops.count, 2)
        let outer = loops.max { abs($0.signedArea) < abs($1.signedArea) }!
        XCTAssertEqual(abs(outer.signedArea), 30 * 20, accuracy: 1)
        XCTAssertEqual(outer.bounds.minX, 105, accuracy: 1e-9)
        XCTAssertEqual(outer.bounds.minY, 210, accuracy: 1e-9)
        // Limited to a region that misses the shape.
        XCTAssertTrue(CameraTrace.trace(gray: gray, seen: nil, width: w, height: h, origin: Vec2(100, 200), cell: 0.5,
                                        region: Rect2(minX: 140, minY: 200, maxX: 150, maxY: 205), options: .init(threshold: t)).isEmpty)
    }

    func testGrayscaleKeepsUnseenPixelsOut() {
        let bgra: [UInt8] = [10, 20, 30, 255, 0, 0, 0, 0]
        let (gray, seen) = CameraTrace.grayscale(bgra: bgra, width: 2, height: 1)
        XCTAssertEqual(seen, [true, false])
        XCTAssertEqual(gray[1], 255)
        XCTAssertLessThan(gray[0], 40)
    }

    func testSetupRoundTripsThroughJSON() throws {
        let setup = CameraSetup(lens: LensModel(imageWidth: 640, imageHeight: 480, fx: 500, fy: 500, cx: 320, cy: 240, k1: -0.1),
                                alignment: BedAlignment(imageWidth: 640, imageHeight: 480, imageToBed: .identity, profileID: UUID(),
                                                        rmsError: 0.2, maxError: 0.4))
        let data = try JSONEncoder().encode(setup)
        XCTAssertEqual(try JSONDecoder().decode(CameraSetup.self, from: data), setup)
    }
}
