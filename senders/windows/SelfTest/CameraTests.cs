using System;
using System.Collections.Generic;
using System.Diagnostics;
using KerfSender;

/// <summary>Checks the camera math on synthetic pictures from a known camera.</summary>
static class CameraTests
{
    // A webcam-like camera: 1280×720, noticeable barrel distortion.
    const int W = 1280, H = 720;
    static readonly LensModel Truth = new LensModel { ImageWidth = W, ImageHeight = H, Fx = 900, Fy = 900, Cx = 652, Cy = 351, K1 = -0.28, K2 = 0.09 };

    public static void Run(Action<bool, string> check)
    {
        HomographyRoundTrip(check);
        LensRoundTrip(check);
        Calibration(check);
        Alignment(check);
        Toolpath(check);
        Storage(check);
    }

    static void HomographyRoundTrip(Action<bool, string> check)
    {
        var truth = new Homography(new[] { 0.31, 0.02, 12.0, -0.015, 0.29, 30.0, 0.00002, -0.00001, 1.0 });
        var src = new List<V2>();
        var dst = new List<V2>();
        for (int i = 0; i < 9; i++)
        {
            var p = new V2(100 + 130 * (i % 3), 80 + 240 * (i / 3));
            V2 q;
            truth.Apply(p, out q);
            src.Add(p);
            dst.Add(q);
        }
        var fit = Homography.Fit(src, dst);
        double worst = 0;
        for (int i = 0; i < src.Count; i++) { V2 q; fit.Apply(src[i], out q); worst = Math.Max(worst, q.Dist(dst[i])); }
        check(worst < 1e-6, "homography fit reproduces its points (" + worst.ToString("E1") + ")");
        V2 back;
        fit.Inverted.Apply(dst[4], out back);
        check(back.Dist(src[4]) < 1e-6, "homography inverse");
    }

    static void LensRoundTrip(Action<bool, string> check)
    {
        var p = new V2(40, 690);
        var u = Truth.UndistortPixel(p);
        check(Truth.DistortPixel(u).Dist(p) < 1e-6, "lens undistort then distort returns the pixel");
        var half = Truth.Scaled(640, 360);
        check(half != null && Math.Abs(half.Fx - 450) < 1e-9, "lens scales with the picture");
        check(Truth.Scaled(640, 480) == null, "lens refuses a different picture shape");
    }

    /// <summary>Renders a board of (cols+1)×(rows+1) unit squares, seen by the true camera at a pose.</summary>
    static GrayImage RenderBoard(int cols, int rows, double rx, double ry, double rz, double tx, double ty, double tz)
    {
        var R = Rot(rx, ry, rz);
        var px = new byte[W * H];
        for (int v = 0; v < H; v++)
            for (int u = 0; u < W; u++)
            {
                int sum = 0;
                for (int s = 0; s < 4; s++)
                {
                    double uu = u - 0.25 + 0.5 * (s % 2), vv = v - 0.25 + 0.5 * (s / 2);
                    var n = Truth.Undistort(new V2((uu - Truth.Cx) / Truth.Fx, (vv - Truth.Cy) / Truth.Fy));
                    // Solve bx*R0 + by*R1 - s*ray = -t.
                    var a = new[] { R[0], R[1], -n.X, R[3], R[4], -n.Y, R[6], R[7], -1.0 };
                    var inv = Invert(a);
                    double bx = -(inv[0] * tx + inv[1] * ty + inv[2] * tz);
                    double by = -(inv[3] * tx + inv[4] * ty + inv[5] * tz);
                    int val;
                    if (bx < -2 || by < -2 || bx > cols + 1 || by > rows + 1) val = 120;
                    else if (bx < -1 || by < -1 || bx > cols || by > rows) val = 235;
                    else val = (((int)Math.Floor(bx) + (int)Math.Floor(by)) & 1) == 0 ? 30 : 230;
                    sum += val;
                }
                px[v * W + u] = (byte)(sum / 4);
            }
        return new GrayImage(W, H, px);
    }

    static double[] Rot(double rx, double ry, double rz)
    {
        double cx = Math.Cos(rx), sx = Math.Sin(rx), cy = Math.Cos(ry), sy = Math.Sin(ry), cz = Math.Cos(rz), sz = Math.Sin(rz);
        var Rx = new[] { 1, 0, 0, 0, cx, -sx, 0, sx, cx };
        var Ry = new[] { cy, 0, sy, 0, 1, 0, -sy, 0, cy };
        var Rz = new[] { cz, -sz, 0, sz, cz, 0, 0, 0, 1 };
        return Mul(Rz, Mul(Ry, Rx));
    }

    static double[] Mul(double[] a, double[] b)
    {
        var o = new double[9];
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) o[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
        return o;
    }

    static double[] Invert(double[] m)
    {
        double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
        double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g, det = a * A + b * B + c * C;
        var inv = new[] { A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d };
        for (int k = 0; k < 9; k++) inv[k] /= det;
        return inv;
    }

    static void Calibration(Action<bool, string> check)
    {
        const int cols = 9, rows = 6;
        var poses = new[]
        {
            new[] { 0.05, -0.1, 0.02, -4.5, -2.5, 14.0 },
            new[] { -0.35, 0.1, -0.1, -3.5, -2.2, 13.0 },
            new[] { 0.3, 0.3, 0.15, -6.0, -3.0, 15.0 },
            new[] { 0.0, -0.4, -0.2, -1.5, -3.5, 13.5 },
            new[] { 0.25, -0.25, 0.3, -7.5, -1.5, 16.0 },
            new[] { -0.2, 0.35, 0.05, -4.0, -2.5, 13.5 },
        };
        var views = new List<CheckerboardView>();
        var sw = Stopwatch.StartNew();
        int found = 0;
        double worstCorner = 0;
        foreach (var p in poses)
        {
            var img = RenderBoard(cols, rows, p[0], p[1], p[2], p[3], p[4], p[5]);
            var view = CheckerboardDetector.Detect(img, cols, rows);
            if (view == null) continue;
            found++;
            views.Add(view);
        }
        double detectMs = sw.ElapsedMilliseconds;
        check(found == poses.Length, "checkerboard found in " + found + " of " + poses.Length + " pictures (" + (detectMs / Math.Max(1, poses.Length)).ToString("0") + " ms each)");
        if (views.Count > 0)
        {
            var v = views[0];
            check(v.ImagePoints.Length == cols * rows, "all " + cols * rows + " corners found");
        }
        sw.Restart();
        var lens = LensCalibration.Calibrate(views);
        check(lens != null, "lens calibrates (" + sw.ElapsedMilliseconds + " ms)");
        if (lens == null) return;
        check(lens.RmsError < 0.3, "corner fit error " + lens.RmsError.ToString("0.000") + " px");
        check(Math.Abs(lens.Fx - Truth.Fx) / Truth.Fx < 0.03, "focal length " + lens.Fx.ToString("0.0") + " (true " + Truth.Fx + ")");
        // Compare the correction itself across the picture rather than the coefficients.
        double worst = 0;
        foreach (var q in new[] { new V2(250, 200), new V2(1000, 120), new V2(250, 500), new V2(1050, 520), new V2(640, 100), new V2(640, 360) })
        {
            var mine = lens.UndistortPixel(q);
            var truth = Truth.UndistortPixel(q);
            // Both are ideal pixels for slightly different focal lengths; compare in normalised units scaled back.
            var a = new V2((mine.X - lens.Cx) / lens.Fx, (mine.Y - lens.Cy) / lens.Fy);
            var b = new V2((truth.X - Truth.Cx) / Truth.Fx, (truth.Y - Truth.Cy) / Truth.Fy);
            worst = Math.Max(worst, (a - b).Length * Truth.Fx);
        }
        check(worst < 3, "undistortion matches the true lens within " + worst.ToString("0.00") + " px where the boards were");
    }

    static void Alignment(Action<bool, string> check)
    {
        // A camera looking down at a 400×400 bed: bed mm to ideal pixel.
        var bedToIdeal = new Homography(new[] { 2.2, 0.05, 210.0, -0.04, 2.15, -60.0, 0.00003, 0.00002, 1.0 });
        var marks = CameraTarget.MarkCentres(40, 40, 360, 360, 3, 3);
        check(marks.Count == 9 && marks[1].X == 200 && marks[3].Y == 200, "target marks are numbered along X, then Y");

        // Render the burned target as the camera sees it.
        var px = new byte[W * H];
        for (int i = 0; i < px.Length; i++) px[i] = 210;
        var paths = CameraTarget.Paths(marks, 12);
        foreach (var path in paths)
            for (int k = 0; k + 1 < path.Count; k++)
                for (double t = 0; t <= 1; t += 0.02)
                {
                    var b = path[k] + (path[k + 1] - path[k]) * t;
                    V2 ideal;
                    bedToIdeal.Apply(b, out ideal);
                    var raw = Truth.DistortPixel(ideal);
                    for (int dy = -1; dy <= 1; dy++)
                        for (int dx = -1; dx <= 1; dx++)
                        {
                            int x = (int)Math.Round(raw.X) + dx, y = (int)Math.Round(raw.Y) + dy;
                            if (x >= 0 && y >= 0 && x < W && y < H) px[y * W + x] = 40;
                        }
                }
        var img = new GrayImage(W, H, px);

        var clicks = new List<V2>();
        var trueRaw = new List<V2>();
        double worstSnap = 0;
        foreach (var m in marks)
        {
            V2 ideal;
            bedToIdeal.Apply(m, out ideal);
            var raw = Truth.DistortPixel(ideal);
            trueRaw.Add(raw);
            V2 snapped;
            bool ok = CameraTarget.SnapToMark(img, raw + new V2(6, -5), 28, out snapped);
            if (!ok) { worstSnap = 99; continue; }
            worstSnap = Math.Max(worstSnap, snapped.Dist(raw));
            clicks.Add(snapped);
        }
        check(worstSnap < 1.0, "clicks snap to the mark centres (worst " + worstSnap.ToString("0.00") + " px)");

        // Predict the rest from the first three clicks.
        var partial = new V2?[marks.Count];
        partial[0] = trueRaw[0]; partial[1] = trueRaw[1]; partial[3] = trueRaw[3];
        var guess = CameraTarget.Predict(marks, partial);
        double worstGuess = 0;
        for (int i = 0; i < marks.Count; i++) if (guess[i].HasValue) worstGuess = Math.Max(worstGuess, guess[i].Value.Dist(trueRaw[i]));
        check(guess[8].HasValue && worstGuess < 40, "the remaining marks are predicted from three clicks (within " + worstGuess.ToString("0") + " px)");

        if (clicks.Count != marks.Count) return;
        var setup = new CameraSetup { Lens = Truth };
        var undist = new List<V2>();
        foreach (var c in clicks) undist.Add(Truth.UndistortPixel(c));
        double rms, max;
        var h = CameraTarget.Fit(undist, marks, out rms, out max);
        check(h != null && max < 0.5, "alignment fits the marks within " + max.ToString("0.00") + " mm");
        setup.Alignment = new BedAlignment { ImageWidth = W, ImageHeight = H, ImageToBed = h, RmsError = rms, MaxError = max, Date = DateTime.UtcNow };

        V2 bed, back;
        var probe = new V2(123, 287);
        check(setup.BedToImage(probe, W, H, out back) && setup.ImageToBed(back, W, H, out bed) && bed.Dist(probe) < 1e-3,
              "bed → picture → bed round trip");
        check(setup.BedToImage(probe, W / 2, H / 2, out back) && setup.ImageToBed(back, W / 2, H / 2, out bed) && bed.Dist(probe) < 1e-3,
              "the mapping works at half the picture size");

        var target = CameraTarget.GCode(marks, 12, 1500, 25, 1000);
        check(target.Contains("M4 S0") && target.Exists(l => l.Contains("S250 F1500")), "target G-code burns at 25% of S1000");
    }

    static void Toolpath(Action<bool, string> check)
    {
        var lines = new List<string>
        {
            "; Kerf job", "G90", "G21", "M5", "M4 S0",
            "G0 X10 Y10", "G1 X30 Y10 S500 F1200", "G1 X30 Y20", "G1 X10 Y20", "G1 X10 Y10",
            "G0 X50 Y50", "G1 X60 S0", "G1 X70 S300", "G1 X80 S300", "M5",
        };
        var tp = GcodeToolpath.Read(lines);
        check(tp.Burns.Count == 2, "toolpath has the square and the raster run: " + tp.Burns.Count);
        check(tp.MinX == 10 && tp.MaxX == 80 && tp.MinY == 10 && tp.MaxY == 50, "toolpath bounds");
        check(tp.Burns[1].Count == 2, "collinear raster moves merge into one segment");

        string error;
        var moved = GcodeToolpath.Transform(lines, new V2(20, 15), 90, new V2(100, 0), out error);
        check(moved != null && moved[6] == "G1 X125 Y25 S500 F1200", "turned and moved line: " + (moved == null ? error : moved[6]));
        check(moved[11] == "G1 X85 Y55 S0", "single-axis line gets both axes: " + moved[11]);
        check(moved[0] == "; Kerf job" && moved[4] == "M4 S0", "lines without positions are unchanged");
        var back = GcodeToolpath.Read(moved);
        check(Math.Abs(back.MinX - 85) < 1e-9 && Math.Abs(back.MaxX - 125) < 1e-9, "moved toolpath bounds");

        var arc = GcodeToolpath.Transform(new[] { "G2 X10 Y0 I5 J0" }, new V2(0, 0), 90, new V2(0, 0), out error);
        check(arc[0] == "G2 X0 Y10 I0 J5", "arc centre offsets turn with the job: " + arc[0]);
        check(GcodeToolpath.Transform(new[] { "G91", "G1 X5" }, new V2(), 0, new V2(1, 1), out error) == null && error != null,
              "relative jobs are refused");
    }

    static void Storage(Action<bool, string> check)
    {
        var s = new CameraSetup { Lens = Truth, Alignment = new BedAlignment { ImageWidth = W, ImageHeight = H, ImageToBed = Homography.Identity, RmsError = 0.2, MaxError = 0.4, Date = new DateTime(2026, 11, 28, 10, 0, 0, DateTimeKind.Utc) } };
        var back = CameraSetup.Parse(s.Serialize());
        check(back.Lens != null && back.Lens.K1 == Truth.K1 && back.Lens.Cx == Truth.Cx, "lens survives saving");
        check(back.Alignment != null && back.Alignment.MaxError == 0.4 && back.Alignment.Date.Year == 2026, "alignment survives saving");
    }
}
