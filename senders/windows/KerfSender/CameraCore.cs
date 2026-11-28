using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

// Camera registration for lasers, ported from KerfKutter (Sources/KerfCore/CameraCalibration.swift and
// Checkerboard.swift). A fixed camera above the bed shows the material; the job's outline is drawn on the
// picture so it can be moved onto the material before it runs. Two calibrations make that line up:
//  1. Lens: a checkerboard seen in several positions measures the lens's barrel distortion (LensModel).
//  2. Alignment: marks burned at known bed positions and clicked in a snapshot give the perspective
//     mapping from the (undistorted) picture to machine coordinates (BedAlignment).
// Everything here is UI-free so the self-test can run it on any OS.

namespace KerfSender
{
    public struct V2
    {
        public double X, Y;
        public V2(double x, double y) { X = x; Y = y; }
        public static V2 operator +(V2 a, V2 b) { return new V2(a.X + b.X, a.Y + b.Y); }
        public static V2 operator -(V2 a, V2 b) { return new V2(a.X - b.X, a.Y - b.Y); }
        public static V2 operator *(V2 a, double s) { return new V2(a.X * s, a.Y * s); }
        public static V2 operator /(V2 a, double s) { return new V2(a.X / s, a.Y / s); }
        public double Length { get { return Math.Sqrt(X * X + Y * Y); } }
        public double Dist(V2 o) { return (this - o).Length; }
        public double Dot(V2 o) { return X * o.X + Y * o.Y; }
        public double Cross(V2 o) { return X * o.Y - Y * o.X; }
        public V2 Normalized { get { double l = Length; return l > 0 ? this / l : this; } }
        public bool IsFinite { get { return !double.IsNaN(X) && !double.IsInfinity(X) && !double.IsNaN(Y) && !double.IsInfinity(Y); } }
        public override string ToString() { return X.ToString("0.###", CultureInfo.InvariantCulture) + "," + Y.ToString("0.###", CultureInfo.InvariantCulture); }
    }

    static class LinAlg
    {
        /// <summary>Solves A x = b for a square n×n row-major A (Gaussian elimination, partial pivoting).</summary>
        public static double[] Solve(double[] a, double[] b, int n)
        {
            if (n <= 0 || a.Length != n * n || b.Length != n) return null;
            var m = (double[])a.Clone();
            var r = (double[])b.Clone();
            double scale = 1e-300;
            foreach (double v in m) scale = Math.Max(scale, Math.Abs(v));
            for (int col = 0; col < n; col++)
            {
                int pivot = col;
                double best = Math.Abs(m[col * n + col]);
                for (int row = col + 1; row < n; row++)
                    if (Math.Abs(m[row * n + col]) > best) { best = Math.Abs(m[row * n + col]); pivot = row; }
                if (!(best > scale * 1e-15)) return null;
                if (pivot != col)
                {
                    for (int k = 0; k < n; k++) { double t = m[col * n + k]; m[col * n + k] = m[pivot * n + k]; m[pivot * n + k] = t; }
                    double tr = r[col]; r[col] = r[pivot]; r[pivot] = tr;
                }
                double d = m[col * n + col];
                for (int row = col + 1; row < n; row++)
                {
                    double f = m[row * n + col] / d;
                    if (f == 0) continue;
                    for (int k = col; k < n; k++) m[row * n + k] -= f * m[col * n + k];
                    r[row] -= f * r[col];
                }
            }
            var x = new double[n];
            for (int row = n - 1; row >= 0; row--)
            {
                double s = r[row];
                for (int k = row + 1; k < n; k++) s -= m[row * n + k] * x[k];
                x[row] = s / m[row * n + row];
            }
            foreach (double v in x) if (double.IsNaN(v) || double.IsInfinity(v)) return null;
            return x;
        }

        public static double[] Mul3(double[] a, double[] b)
        {
            var o = new double[9];
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++)
                    o[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
            return o;
        }

        public static double[] Invert3(double[] m)
        {
            double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
            double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
            double det = a * A + b * B + c * C;
            double size = 0;
            foreach (double v in m) size = Math.Max(size, Math.Abs(v));
            if (!(Math.Abs(det) > 1e-14 * Math.Max(1e-300, size * size * size))) return null;
            var inv = new[] { A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d };
            for (int k = 0; k < 9; k++) inv[k] /= det;
            return inv;
        }
    }

    /// <summary>A plane-to-plane perspective mapping (3×3, row-major).</summary>
    public sealed class Homography
    {
        public readonly double[] M;
        public Homography(double[] m) { M = m; }
        public static Homography Identity { get { return new Homography(new double[] { 1, 0, 0, 0, 1, 0, 0, 0, 1 }); } }

        public bool Apply(V2 p, out V2 q)
        {
            double w = M[6] * p.X + M[7] * p.Y + M[8];
            if (Math.Abs(w) <= 1e-12) { q = new V2(); return false; }
            q = new V2((M[0] * p.X + M[1] * p.Y + M[2]) / w, (M[3] * p.X + M[4] * p.Y + M[5]) / w);
            return true;
        }

        public Homography Inverted { get { var i = LinAlg.Invert3(M); return i == null ? null : new Homography(i); } }

        /// <summary>The mapping that applies this first, then o.</summary>
        public Homography Then(Homography o) { return new Homography(LinAlg.Mul3(o.M, M)); }

        /// <summary>Least-squares homography taking each src point to its dst point (at least 4, not all on a line).</summary>
        public static Homography Fit(IList<V2> src, IList<V2> dst)
        {
            if (src.Count != dst.Count || src.Count < 4) return null;
            Homography ts, td;
            var ns = Normalize(src, out ts);
            var nd = Normalize(dst, out td);
            if (ns == null || nd == null) return null;
            var ata = new double[64];
            var atb = new double[8];
            var row = new double[8];
            for (int k = 0; k < ns.Length; k++)
            {
                V2 p = ns[k], q = nd[k];
                for (int pass = 0; pass < 2; pass++)
                {
                    double rhs;
                    if (pass == 0) { row[0] = p.X; row[1] = p.Y; row[2] = 1; row[3] = 0; row[4] = 0; row[5] = 0; row[6] = -q.X * p.X; row[7] = -q.X * p.Y; rhs = q.X; }
                    else { row[0] = 0; row[1] = 0; row[2] = 0; row[3] = p.X; row[4] = p.Y; row[5] = 1; row[6] = -q.Y * p.X; row[7] = -q.Y * p.Y; rhs = q.Y; }
                    for (int i = 0; i < 8; i++)
                    {
                        atb[i] += row[i] * rhs;
                        for (int j = 0; j < 8; j++) ata[i * 8 + j] += row[i] * row[j];
                    }
                }
            }
            var h = LinAlg.Solve(ata, atb, 8);
            var tdInv = td.Inverted;
            if (h == null || tdInv == null) return null;
            var hm = new double[9];
            Array.Copy(h, hm, 8);
            hm[8] = 1;
            var result = ts.Then(new Homography(hm)).Then(tdInv);
            double s = Math.Abs(result.M[8]) > 1e-12 ? result.M[8] : 1;
            var outM = new double[9];
            for (int i = 0; i < 9; i++) outM[i] = result.M[i] / s;
            return new Homography(outM);
        }

        static V2[] Normalize(IList<V2> pts, out Homography t)
        {
            var c = new V2();
            foreach (var p in pts) c = c + p;
            c = c / pts.Count;
            double mean = 0;
            foreach (var p in pts) mean += p.Dist(c);
            mean /= pts.Count;
            t = null;
            if (!(mean > 1e-12)) return null;
            double s = Math.Sqrt(2) / mean;
            t = new Homography(new[] { s, 0, -s * c.X, 0, s, -s * c.Y, 0, 0, 1 });
            var o = new V2[pts.Count];
            for (int i = 0; i < o.Length; i++) o[i] = (pts[i] - c) * s;
            return o;
        }
    }

    /// <summary>A camera's focal length, centre and lens distortion (radial k1–k3, tangential p1, p2) for one picture size.</summary>
    public sealed class LensModel
    {
        public int ImageWidth, ImageHeight;
        public double Fx, Fy, Cx, Cy, K1, K2, K3, P1, P2;
        public double RmsError;
        public int Views;

        public LensModel Copy() { return (LensModel)MemberwiseClone(); }

        public V2 Distort(V2 p)
        {
            double x = p.X, y = p.Y, r2 = x * x + y * y;
            double radial = 1 + r2 * (K1 + r2 * (K2 + r2 * K3));
            return new V2(x * radial + 2 * P1 * x * y + P2 * (r2 + 2 * x * x), y * radial + P1 * (r2 + 2 * y * y) + 2 * P2 * x * y);
        }

        public V2 Undistort(V2 d)
        {
            V2 p = d;
            for (int it = 0; it < 40; it++)
            {
                double x = p.X, y = p.Y, r2 = x * x + y * y;
                double radial = 1 + r2 * (K1 + r2 * (K2 + r2 * K3));
                if (Math.Abs(radial) <= 1e-6) break;
                double dx = 2 * P1 * x * y + P2 * (r2 + 2 * x * x);
                double dy = P1 * (r2 + 2 * y * y) + 2 * P2 * x * y;
                var next = new V2((d.X - dx) / radial, (d.Y - dy) / radial);
                double moved = next.Dist(p);
                p = next;
                if (moved < 1e-12) break;
            }
            return p;
        }

        public V2 UndistortPixel(V2 q)
        {
            V2 n = Undistort(new V2((q.X - Cx) / Fx, (q.Y - Cy) / Fy));
            return new V2(n.X * Fx + Cx, n.Y * Fy + Cy);
        }

        public V2 DistortPixel(V2 q)
        {
            V2 d = Distort(new V2((q.X - Cx) / Fx, (q.Y - Cy) / Fy));
            return new V2(d.X * Fx + Cx, d.Y * Fy + Cy);
        }

        /// <summary>The same lens at another picture size of the same shape, or null when the shape differs.</summary>
        public LensModel Scaled(int w, int h)
        {
            if (ImageWidth <= 0 || ImageHeight <= 0 || w <= 0 || h <= 0) return null;
            if (w == ImageWidth && h == ImageHeight) return this;
            double sx = (double)w / ImageWidth, sy = (double)h / ImageHeight;
            if (!(Math.Abs(sx - sy) / Math.Max(sx, sy) < 0.01)) return null;
            var o = Copy();
            o.ImageWidth = w; o.ImageHeight = h;
            o.Fx *= sx; o.Fy *= sy;
            o.Cx = (Cx + 0.5) * sx - 0.5;
            o.Cy = (Cy + 0.5) * sy - 0.5;
            o.RmsError *= sx;
            return o;
        }

        /// <summary>The largest squared normalised radius the picture covers once undistorted.</summary>
        public double CoveredRadius2
        {
            get
            {
                double w = ImageWidth - 1, h = ImageHeight - 1, r2 = 0;
                var pts = new[] { new V2(0, 0), new V2(w, 0), new V2(0, h), new V2(w, h), new V2(w / 2, 0), new V2(w / 2, h), new V2(0, h / 2), new V2(w, h / 2) };
                foreach (var q in pts)
                {
                    var n = Undistort(new V2((q.X - Cx) / Fx, (q.Y - Cy) / Fy));
                    r2 = Math.Max(r2, n.X * n.X + n.Y * n.Y);
                }
                return r2;
            }
        }

        /// <summary>How strong the distortion is at the picture's corner, as a fraction of its distance from the centre.</summary>
        public double CornerDistortion
        {
            get
            {
                var n = new V2(-Cx / Fx, -Cy / Fy);
                var d = Distort(n);
                return (d.Length - n.Length) / Math.Max(1e-9, n.Length);
            }
        }
    }

    /// <summary>The corners of a checkerboard found in one picture.</summary>
    public sealed class CheckerboardView
    {
        public V2[] ImagePoints, BoardPoints;
        public int ImageWidth, ImageHeight;
    }

    /// <summary>Measures a lens from several checkerboard views (Levenberg–Marquardt on all corners at once).</summary>
    public static class LensCalibration
    {
        public const int MinimumViews = 3;

        public static LensModel Calibrate(IList<CheckerboardView> views)
        {
            var usable = new List<CheckerboardView>();
            foreach (var v in views) if (v.ImagePoints.Length >= 6 && v.ImagePoints.Length == v.BoardPoints.Length) usable.Add(v);
            if (usable.Count < MinimumViews) return null;
            int w = usable[0].ImageWidth, h = usable[0].ImageHeight;
            foreach (var v in usable) if (v.ImageWidth != w || v.ImageHeight != h) return null;

            double cx0 = (w - 1) / 2.0, cy0 = (h - 1) / 2.0;
            var hs = new List<Homography>();
            foreach (var v in usable)
            {
                var hm = Homography.Fit(v.BoardPoints, v.ImagePoints);
                if (hm == null) return null;
                hs.Add(hm);
            }
            double f0 = InitialFocal(hs, cx0, cy0, w, h);
            var prm = new List<double> { f0, cx0, cy0, 0, 0, 0, 0, 0 };
            foreach (var hm in hs) prm.AddRange(InitialPose(hm, f0, cx0, cy0));
            var p = prm.ToArray();
            var free = new bool[p.Length];
            for (int i = 0; i < free.Length; i++) free[i] = true;
            bool many = usable.Count >= 4;
            free[1] = free[2] = free[5] = free[6] = many;
            free[7] = usable.Count >= 6;

            double cost;
            var solved = LevenbergMarquardt(usable, p, free, 150, out cost);
            if (solved == null) return null;
            int count = 0;
            foreach (var v in usable) count += v.ImagePoints.Length;
            double rms = Math.Sqrt(cost / Math.Max(1, count));
            if (!(solved[0] > 0) || double.IsNaN(rms) || double.IsInfinity(rms)) return null;
            return new LensModel
            {
                ImageWidth = w, ImageHeight = h, Fx = solved[0], Fy = solved[0], Cx = solved[1], Cy = solved[2],
                K1 = solved[3], K2 = solved[4], K3 = solved[7], P1 = solved[5], P2 = solved[6], RmsError = rms, Views = usable.Count,
            };
        }

        static double InitialFocal(List<Homography> hs, double cx, double cy, int width, int height)
        {
            double size = Math.Max(width, height);
            var est = new List<double>();
            foreach (var hm in hs)
            {
                var m = (double[])hm.M.Clone();
                for (int k = 0; k < 3; k++) { m[k] -= cx * m[6 + k]; m[3 + k] -= cy * m[6 + k]; }
                double h10 = m[0], h11 = m[3], h12 = m[6], h20 = m[1], h21 = m[4], h22 = m[7];
                double n1 = h10 * h10 + h11 * h11, n2 = h20 * h20 + h21 * h21;
                double zScale = (n1 + n2) / (size * size);
                double den1 = h12 * h22;
                if (Math.Abs(den1) > zScale * 1e-3) { double f2 = -(h10 * h20 + h11 * h21) / den1; if (f2 > 0) est.Add(Math.Sqrt(f2)); }
                double den2 = h12 * h12 - h22 * h22;
                if (Math.Abs(den2) > zScale * 1e-3) { double f2 = -(n1 - n2) / den2; if (f2 > 0) est.Add(Math.Sqrt(f2)); }
            }
            var sane = est.FindAll(f => f > size * 0.15 && f < size * 6);
            sane.Sort();
            return sane.Count == 0 ? size * 0.8 : sane[sane.Count / 2];
        }

        static double[] InitialPose(Homography hm, double f, double cx, double cy)
        {
            var m = (double[])hm.M.Clone();
            for (int k = 0; k < 3; k++) { m[k] = (m[k] - cx * m[6 + k]) / f; m[3 + k] = (m[3 + k] - cy * m[6 + k]) / f; }
            double[] h1 = { m[0], m[3], m[6] }, h2 = { m[1], m[4], m[7] }, h3 = { m[2], m[5], m[8] };
            Func<double[], double> norm = v => Math.Sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
            double lambda = 2 / Math.Max(1e-12, norm(h1) + norm(h2));
            if (h3[2] * lambda < 0) lambda = -lambda;
            var r1 = new[] { h1[0] * lambda, h1[1] * lambda, h1[2] * lambda };
            var r2 = new[] { h2[0] * lambda, h2[1] * lambda, h2[2] * lambda };
            var t = new[] { h3[0] * lambda, h3[1] * lambda, h3[2] * lambda };
            double n1 = Math.Max(1e-12, norm(r1));
            var u1 = new[] { r1[0] / n1, r1[1] / n1, r1[2] / n1 };
            double d = u1[0] * r2[0] + u1[1] * r2[1] + u1[2] * r2[2];
            r2 = new[] { r2[0] - d * u1[0], r2[1] - d * u1[1], r2[2] - d * u1[2] };
            double n2 = Math.Max(1e-12, norm(r2));
            var u2 = new[] { r2[0] / n2, r2[1] / n2, r2[2] / n2 };
            var u3 = new[] { u1[1] * u2[2] - u1[2] * u2[1], u1[2] * u2[0] - u1[0] * u2[2], u1[0] * u2[1] - u1[1] * u2[0] };
            var rot = new[] { u1[0], u2[0], u3[0], u1[1], u2[1], u3[1], u1[2], u2[2], u3[2] };
            var r = Rodrigues(rot);
            return new[] { r[0], r[1], r[2], t[0], t[1], t[2] };
        }

        static double[] RotationMatrix(double rx, double ry, double rz)
        {
            double th = Math.Sqrt(rx * rx + ry * ry + rz * rz);
            if (th < 1e-12) return new[] { 1, -rz, ry, rz, 1, -rx, -ry, rx, 1 };
            double kx = rx / th, ky = ry / th, kz = rz / th, c = Math.Cos(th), s = Math.Sin(th), v = 1 - c;
            return new[] { c + kx * kx * v, kx * ky * v - kz * s, kx * kz * v + ky * s,
                           ky * kx * v + kz * s, c + ky * ky * v, ky * kz * v - kx * s,
                           kz * kx * v - ky * s, kz * ky * v + kx * s, c + kz * kz * v };
        }

        static double[] Rodrigues(double[] r)
        {
            double cosT = Math.Max(-1, Math.Min(1, (r[0] + r[4] + r[8] - 1) / 2));
            double th = Math.Acos(cosT);
            if (th < 1e-9) return new double[3];
            if (th > Math.PI - 1e-6)
            {
                double kx = Math.Sqrt(Math.Max(0, (r[0] + 1) / 2)), ky = Math.Sqrt(Math.Max(0, (r[4] + 1) / 2)), kz = Math.Sqrt(Math.Max(0, (r[8] + 1) / 2));
                if (kx >= ky && kx >= kz) { if (r[1] < 0) ky = -ky; if (r[2] < 0) kz = -kz; }
                else if (ky >= kz) { if (r[1] < 0) kx = -kx; if (r[5] < 0) kz = -kz; }
                else { if (r[2] < 0) kx = -kx; if (r[5] < 0) ky = -ky; }
                return new[] { kx * th, ky * th, kz * th };
            }
            double s = 2 * Math.Sin(th);
            return new[] { (r[7] - r[5]) / s * th, (r[2] - r[6]) / s * th, (r[3] - r[1]) / s * th };
        }

        const int Intrinsics = 8;

        static bool Project(V2 b, double[] p, int pose, out V2 q)
        {
            var rot = RotationMatrix(p[pose], p[pose + 1], p[pose + 2]);
            double x = rot[0] * b.X + rot[1] * b.Y + p[pose + 3];
            double y = rot[3] * b.X + rot[4] * b.Y + p[pose + 4];
            double z = rot[6] * b.X + rot[7] * b.Y + p[pose + 5];
            q = new V2();
            if (!(z > 1e-9)) return false;
            var lens = new LensModel { Fx = p[0], Fy = p[0], Cx = p[1], Cy = p[2], K1 = p[3], K2 = p[4], K3 = p[7], P1 = p[5], P2 = p[6] };
            var d = lens.Distort(new V2(x / z, y / z));
            q = new V2(d.X * p[0] + p[1], d.Y * p[0] + p[2]);
            return true;
        }

        static double[] Residuals(CheckerboardView v, double[] p, int index)
        {
            int pose = Intrinsics + 6 * index;
            var o = new double[v.ImagePoints.Length * 2];
            for (int k = 0; k < v.ImagePoints.Length; k++)
            {
                V2 r;
                if (Project(v.BoardPoints[k], p, pose, out r)) { o[2 * k] = r.X - v.ImagePoints[k].X; o[2 * k + 1] = r.Y - v.ImagePoints[k].Y; }
                else { o[2 * k] = 1e4; o[2 * k + 1] = 1e4; }
            }
            return o;
        }

        static double Cost(List<CheckerboardView> views, double[] p)
        {
            double c = 0;
            for (int v = 0; v < views.Count; v++) foreach (double r in Residuals(views[v], p, v)) c += r * r;
            return c;
        }

        static double[] LevenbergMarquardt(List<CheckerboardView> views, double[] start, bool[] free, int iterations, out double cost)
        {
            var p = (double[])start.Clone();
            cost = Cost(views, p);
            if (double.IsNaN(cost) || double.IsInfinity(cost)) return null;
            double lambda = 1e-3;
            var freeIdx = new List<int>();
            for (int i = 0; i < free.Length; i++) if (free[i]) freeIdx.Add(i);
            int n = freeIdx.Count;
            var position = new int[p.Length];
            for (int i = 0; i < position.Length; i++) position[i] = -1;
            for (int k = 0; k < n; k++) position[freeIdx[k]] = k;

            for (int iter = 0; iter < iterations; iter++)
            {
                var jtj = new double[n * n];
                var jtr = new double[n];
                for (int v = 0; v < views.Count; v++)
                {
                    var baseR = Residuals(views[v], p, v);
                    int pose = Intrinsics + 6 * v;
                    var columns = freeIdx.FindAll(i => i < Intrinsics || (i >= pose && i < pose + 6));
                    var derivs = new double[columns.Count][];
                    for (int c = 0; c < columns.Count; c++)
                    {
                        int i = columns[c];
                        var q = (double[])p.Clone();
                        double step = 1e-6 * Math.Max(1, Math.Abs(p[i]));
                        q[i] += step;
                        var moved = Residuals(views[v], q, v);
                        var dv = new double[moved.Length];
                        for (int k = 0; k < moved.Length; k++) dv[k] = (moved[k] - baseR[k]) / step;
                        derivs[c] = dv;
                    }
                    for (int a = 0; a < columns.Count; a++)
                    {
                        int ka = position[columns[a]];
                        double g = 0;
                        for (int k = 0; k < baseR.Length; k++) g += derivs[a][k] * baseR[k];
                        jtr[ka] += g;
                        for (int b = a; b < columns.Count; b++)
                        {
                            int kb = position[columns[b]];
                            double s = 0;
                            for (int k = 0; k < baseR.Length; k++) s += derivs[a][k] * derivs[b][k];
                            jtj[ka * n + kb] += s;
                            if (kb != ka) jtj[kb * n + ka] += s;
                        }
                    }
                }
                bool improved = false;
                while (lambda < 1e12)
                {
                    var a = (double[])jtj.Clone();
                    for (int k = 0; k < n; k++) a[k * n + k] += lambda * Math.Max(jtj[k * n + k], 1e-9);
                    var negJtr = new double[n];
                    for (int k = 0; k < n; k++) negJtr[k] = -jtr[k];
                    var delta = LinAlg.Solve(a, negJtr, n);
                    if (delta == null) { lambda *= 10; continue; }
                    var q = (double[])p.Clone();
                    for (int k = 0; k < n; k++) q[freeIdx[k]] += delta[k];
                    double c = Cost(views, q);
                    if (!double.IsNaN(c) && !double.IsInfinity(c) && c < cost)
                    {
                        double gain = cost - c;
                        p = q;
                        cost = c;
                        lambda = Math.Max(1e-9, lambda / 3);
                        improved = gain > 1e-12 * Math.Max(1, cost);
                        break;
                    }
                    lambda *= 4;
                }
                if (!improved) break;
            }
            return p;
        }
    }

    /// <summary>An 8-bit grayscale picture, rows top to bottom.</summary>
    public sealed class GrayImage
    {
        public readonly int Width, Height;
        public readonly byte[] Pixels;
        public GrayImage(int w, int h, byte[] px) { Width = w; Height = h; Pixels = px; }

        public byte this[int x, int y]
        {
            get { return Pixels[Math.Min(Height - 1, Math.Max(0, y)) * Width + Math.Min(Width - 1, Math.Max(0, x))]; }
        }

        /// <summary>From packed 24-bit BGR rows (stride bytes apart, top row first).</summary>
        public static GrayImage FromBgr24(byte[] src, int w, int h, int stride, bool bottomUp)
        {
            var o = new byte[w * h];
            for (int y = 0; y < h; y++)
            {
                int row = (bottomUp ? h - 1 - y : y) * stride;
                for (int x = 0; x < w; x++)
                {
                    int p = row + x * 3;
                    o[y * w + x] = (byte)((src[p] * 29 + src[p + 1] * 150 + src[p + 2] * 77) >> 8);
                }
            }
            return new GrayImage(w, h, o);
        }

        public GrayImage Downscaled(int factor)
        {
            if (factor <= 1) return this;
            int w = Math.Max(1, Width / factor), h = Math.Max(1, Height / factor);
            var o = new byte[w * h];
            int area = factor * factor;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int s = 0;
                    for (int dy = 0; dy < factor; dy++)
                    {
                        int row = (y * factor + dy) * Width + x * factor;
                        for (int dx = 0; dx < factor; dx++) s += Pixels[row + dx];
                    }
                    o[y * w + x] = (byte)(s / area);
                }
            return new GrayImage(w, h, o);
        }
    }

    /// <summary>Finds the inner corners of a printed checkerboard in a picture, for lens calibration.</summary>
    public static class CheckerboardDetector
    {
        public static CheckerboardView Detect(GrayImage image, int columns, int rows)
        {
            if (columns < 3 || rows < 3 || image.Width < 32 || image.Height < 32) return null;
            int longest = Math.Max(image.Width, image.Height);
            var factors = new List<int>();
            foreach (int target in new[] { 800, 1300, 520 })
            {
                int f = Math.Max(1, (int)Math.Round((double)longest / target));
                if (!factors.Contains(f)) factors.Add(f);
            }
            foreach (int f in factors)
            {
                var small = image.Downscaled(f);
                var smooth = ToFloat(small);
                foreach (double sigma in new[] { 1.2, 2.0, 3.2 })
                {
                    var blurred = Blur(smooth, small.Width, small.Height, sigma);
                    var found = Candidates(blurred, small.Width, small.Height, sigma);
                    if (found.Count < columns * rows) continue;
                    V2[] pts, board;
                    double spacing;
                    if (!Assemble(found, columns, rows, out pts, out board, out spacing)) continue;
                    double scale = f;
                    var full = new V2[pts.Length];
                    for (int i = 0; i < pts.Length; i++) full[i] = new V2((pts[i].X + 0.5) * scale - 0.5, (pts[i].Y + 0.5) * scale - 0.5);
                    var refined = Refine(image, full, Math.Max(3, (int)(spacing * scale * 0.3)));
                    return new CheckerboardView { ImagePoints = refined, BoardPoints = board, ImageWidth = image.Width, ImageHeight = image.Height };
                }
            }
            return null;
        }

        static float[] ToFloat(GrayImage img)
        {
            var o = new float[img.Pixels.Length];
            for (int i = 0; i < o.Length; i++) o[i] = img.Pixels[i];
            return o;
        }

        internal static float[] Blur(float[] src, int w, int h, double sigma)
        {
            int r = Math.Max(1, (int)Math.Ceiling(sigma * 3));
            var k = new float[2 * r + 1];
            float sum = 0;
            for (int i = -r; i <= r; i++) { k[i + r] = (float)Math.Exp(-(double)(i * i) / (2 * sigma * sigma)); sum += k[i + r]; }
            for (int i = 0; i < k.Length; i++) k[i] /= sum;
            var tmp = new float[w * h];
            var o = new float[w * h];
            for (int y = 0; y < h; y++)
            {
                int row = y * w;
                for (int x = 0; x < w; x++)
                {
                    float s = 0;
                    for (int j = 0; j < k.Length; j++) { int xx = Math.Min(w - 1, Math.Max(0, x + j - r)); s += src[row + xx] * k[j]; }
                    tmp[row + x] = s;
                }
            }
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    float s = 0;
                    for (int j = 0; j < k.Length; j++) { int yy = Math.Min(h - 1, Math.Max(0, y + j - r)); s += tmp[yy * w + x] * k[j]; }
                    o[y * w + x] = s;
                }
            return o;
        }

        static List<V2> Candidates(float[] f, int w, int h, double sigma)
        {
            var result = new List<V2>();
            if (w <= 8 || h <= 8) return result;
            var resp = new float[w * h];
            float maxR = 0;
            for (int y = 1; y < h - 1; y++)
                for (int x = 1; x < w - 1; x++)
                {
                    int i = y * w + x;
                    float c = f[i];
                    float dxx = f[i - 1] - 2 * c + f[i + 1];
                    float dyy = f[i - w] - 2 * c + f[i + w];
                    float dxy = (f[i - w - 1] + f[i + w + 1] - f[i - w + 1] - f[i + w - 1]) / 4;
                    float r = dxy * dxy - dxx * dyy;
                    if (r > 0) { resp[i] = r; if (r > maxR) maxR = r; }
                }
            if (maxR <= 0) return result;
            float threshold = maxR * 0.02f;
            int rad = Math.Max(2, (int)Math.Round(sigma * 1.5));
            double ring = Math.Max(3.0, sigma * 2.5);
            int margin = rad + (int)Math.Ceiling(ring) + 1;
            if (w <= 2 * margin + 1 || h <= 2 * margin + 1) return result;
            var found = new List<KeyValuePair<V2, float>>();
            for (int y = margin; y < h - margin; y++)
                for (int x = margin; x < w - margin; x++)
                {
                    float r = resp[y * w + x];
                    if (!(r > threshold)) continue;
                    bool isMax = true;
                    for (int dy = -rad; dy <= rad && isMax; dy++)
                        for (int dx = -rad; dx <= rad; dx++)
                        {
                            if (dx == 0 && dy == 0) continue;
                            float o = resp[(y + dy) * w + x + dx];
                            if (o > r || (o == r && (dy < 0 || (dy == 0 && dx < 0)))) { isMax = false; break; }
                        }
                    if (!isMax || !RingAlternates(f, w, h, x, y, ring)) continue;
                    float l = resp[y * w + x - 1], rr = resp[y * w + x + 1], u = resp[(y - 1) * w + x], d = resp[(y + 1) * w + x];
                    float denX = l - 2 * r + rr, denY = u - 2 * r + d;
                    double ox = denX < 0 ? Math.Max(-0.5, Math.Min(0.5, 0.5 * (l - rr) / denX)) : 0;
                    double oy = denY < 0 ? Math.Max(-0.5, Math.Min(0.5, 0.5 * (u - d) / denY)) : 0;
                    found.Add(new KeyValuePair<V2, float>(new V2(x + ox, y + oy), r));
                }
            // Stable sort by strength, strongest first.
            var order = new List<int>();
            for (int i = 0; i < found.Count; i++) order.Add(i);
            order.Sort((a, b) => { int c = found[b].Value.CompareTo(found[a].Value); return c != 0 ? c : a.CompareTo(b); });
            for (int i = 0; i < Math.Min(1500, order.Count); i++) result.Add(found[order[i]].Key);
            return result;
        }

        static bool RingAlternates(float[] f, int w, int h, int x, int y, double radius)
        {
            const int n = 32;
            var v = new float[n];
            float lo = float.MaxValue, hi = float.MinValue;
            for (int k = 0; k < n; k++)
            {
                double a = (double)k / n * 2 * Math.PI;
                v[k] = Sample(f, w, h, x + Math.Cos(a) * radius, y + Math.Sin(a) * radius);
                lo = Math.Min(lo, v[k]); hi = Math.Max(hi, v[k]);
            }
            if (!(hi - lo > 30)) return false;
            float mid = (lo + hi) / 2;
            var bright = new bool[n];
            for (int k = 0; k < n; k++) bright[k] = v[k] > mid;
            int start = -1;
            for (int k = 0; k < n; k++) if (bright[k] != bright[(k + n - 1) % n]) { start = k; break; }
            if (start < 0) return false;
            int changes = 0, run = 0, shortest = n;
            for (int step = 0; step < n; step++)
            {
                int k = (start + step) % n;
                run++;
                if (bright[k] != bright[(k + 1) % n]) { changes++; shortest = Math.Min(shortest, run); run = 0; }
            }
            return changes == 4 && shortest >= 3;
        }

        static float Sample(float[] f, int w, int h, double x, double y)
        {
            double xc = Math.Min(w - 1, Math.Max(0, x)), yc = Math.Min(h - 1, Math.Max(0, y));
            int x0 = Math.Min(w - 2, (int)xc), y0 = Math.Min(h - 2, (int)yc);
            float ax = (float)(xc - x0), ay = (float)(yc - y0);
            int i = y0 * w + x0;
            float top = f[i] * (1 - ax) + f[i + 1] * ax;
            float bottom = f[i + w] * (1 - ax) + f[i + w + 1] * ax;
            return top * (1 - ay) + bottom * ay;
        }

        static long Key(int i, int j) { return ((long)j << 32) ^ (uint)i; }

        static bool Assemble(List<V2> pts, int columns, int rows, out V2[] points, out V2[] board, out double spacing)
        {
            points = null; board = null; spacing = 0;
            int need = columns * rows;
            if (pts.Count < need) return false;
            var centroid = new V2();
            foreach (var p in pts) centroid = centroid + p;
            centroid = centroid / pts.Count;
            var seedsAll = new List<int>();
            for (int i = 0; i < pts.Count; i++) seedsAll.Add(i);
            seedsAll.Sort((a, b) => { int c = pts[a].Dist(centroid).CompareTo(pts[b].Dist(centroid)); return c != 0 ? c : a.CompareTo(b); });
            int biggest = Math.Max(columns, rows), smallest = Math.Min(columns, rows);

            for (int si = 0; si < Math.Min(25, seedsAll.Count); si++)
            {
                int seed = seedsAll[si];
                V2 s = pts[seed];
                var order = new List<int>();
                for (int i = 0; i < pts.Count; i++) if (i != seed) order.Add(i);
                order.Sort((a, b) => { int c = pts[a].Dist(s).CompareTo(pts[b].Dist(s)); return c != 0 ? c : a.CompareTo(b); });
                if (order.Count == 0) continue;
                int n1 = order[0];
                V2 v1 = pts[n1] - s;
                if (!(v1.Length > 2)) continue;
                int n2 = -1;
                for (int k = 0; k < Math.Min(8, order.Count); k++)
                {
                    V2 v = pts[order[k]] - s;
                    double ratio = v.Length / v1.Length;
                    if (ratio > 0.6 && ratio < 1.6 && Math.Abs(v.Normalized.Dot(v1.Normalized)) < 0.5) { n2 = order[k]; break; }
                }
                if (n2 < 0) continue;

                var grid = new Dictionary<long, int>();
                var gi = new Dictionary<long, int[]>();
                Action<int, int, int> put = (i, j, idx) => { grid[Key(i, j)] = idx; gi[Key(i, j)] = new[] { i, j }; };
                put(0, 0, seed); put(1, 0, n1); put(0, 1, n2);
                var used = new HashSet<int> { seed, n1, n2 };
                bool growing = true, tooBig = false;
                while (growing && !tooBig)
                {
                    growing = false;
                    var frontier = new List<int[]>();
                    var seen = new HashSet<long>();
                    foreach (var ij in gi.Values)
                        foreach (var d in new[] { new[] { 1, 0 }, new[] { -1, 0 }, new[] { 0, 1 }, new[] { 0, -1 } })
                        {
                            int ni = ij[0] + d[0], nj = ij[1] + d[1];
                            long key = Key(ni, nj);
                            if (!grid.ContainsKey(key) && seen.Add(key)) frontier.Add(new[] { ni, nj });
                        }
                    frontier.Sort((a, b) => a[1] != b[1] ? a[1].CompareTo(b[1]) : a[0].CompareTo(b[0]));
                    foreach (var k in frontier)
                    {
                        V2 guess; double sp;
                        if (!Predict(k[0], k[1], grid, pts, out guess, out sp) || !(sp > 1)) continue;
                        int hit = -1; double hd = double.MaxValue;
                        for (int q = 0; q < pts.Count; q++)
                        {
                            if (used.Contains(q)) continue;
                            double dd = pts[q].Dist(guess);
                            if (dd < hd) { hd = dd; hit = q; }
                        }
                        if (hit < 0 || !(hd < 0.3 * sp)) continue;
                        put(k[0], k[1], hit);
                        used.Add(hit);
                        growing = true;
                    }
                    int iMn = int.MaxValue, iMx = int.MinValue, jMn = int.MaxValue, jMx = int.MinValue;
                    foreach (var ij in gi.Values) { iMn = Math.Min(iMn, ij[0]); iMx = Math.Max(iMx, ij[0]); jMn = Math.Min(jMn, ij[1]); jMx = Math.Max(jMx, ij[1]); }
                    int gw0 = iMx - iMn + 1, gh0 = jMx - jMn + 1;
                    if (Math.Max(gw0, gh0) > biggest || Math.Min(gw0, gh0) > smallest) tooBig = true;
                }
                if (tooBig) continue;
                int iMin = int.MaxValue, iMax = int.MinValue, jMin = int.MaxValue, jMax = int.MinValue;
                foreach (var ij in gi.Values) { iMin = Math.Min(iMin, ij[0]); iMax = Math.Max(iMax, ij[0]); jMin = Math.Min(jMin, ij[1]); jMax = Math.Max(jMax, ij[1]); }
                int gw = iMax - iMin + 1, gh = jMax - jMin + 1;
                if (grid.Count != need || gw * gh != need || !((gw == columns && gh == rows) || (gw == rows && gh == columns))) continue;

                int im = iMin, jm = jMin;
                Func<int, int, V2> at = (i, j) => pts[grid[Key(i + im, j + jm)]];
                V2 ax = at(1, 0) - at(0, 0), ay = at(0, 1) - at(0, 0);
                bool mirror = ax.Cross(ay) < 0;
                var outPts = new V2[need];
                var outBoard = new V2[need];
                var spacings = new List<double>();
                int idxOut = 0;
                for (int j = 0; j < gh; j++)
                    for (int i = 0; i < gw; i++)
                    {
                        int src = mirror ? gw - 1 - i : i;
                        outPts[idxOut] = at(src, j);
                        outBoard[idxOut] = new V2(i, j);
                        idxOut++;
                        if (i > 0) spacings.Add(at(src, j).Dist(at(mirror ? src + 1 : src - 1, j)));
                    }
                spacings.Sort();
                points = outPts; board = outBoard; spacing = spacings[spacings.Count / 2];
                return true;
            }
            return false;
        }

        static bool Predict(int ki, int kj, Dictionary<long, int> grid, List<V2> pts, out V2 guess, out double spacing)
        {
            var sum = new V2();
            spacing = 0;
            int n = 0, a, b, c;
            foreach (var d in new[] { new[] { 1, 0 }, new[] { -1, 0 }, new[] { 0, 1 }, new[] { 0, -1 } })
            {
                if (grid.TryGetValue(Key(ki - d[0], kj - d[1]), out a) && grid.TryGetValue(Key(ki - 2 * d[0], kj - 2 * d[1]), out b))
                {
                    sum = sum + pts[a] * 2 - pts[b];
                    spacing += pts[a].Dist(pts[b]);
                    n++;
                }
            }
            if (n == 0)
            {
                foreach (var d in new[] { new[] { 1, 1 }, new[] { 1, -1 }, new[] { -1, 1 }, new[] { -1, -1 } })
                {
                    if (grid.TryGetValue(Key(ki - d[0], kj), out a) && grid.TryGetValue(Key(ki, kj - d[1]), out b) &&
                        grid.TryGetValue(Key(ki - d[0], kj - d[1]), out c))
                    {
                        sum = sum + pts[a] + pts[b] - pts[c];
                        spacing += Math.Min(pts[a].Dist(pts[c]), pts[b].Dist(pts[c]));
                        n++;
                    }
                }
            }
            guess = n > 0 ? sum / n : new V2();
            if (n == 0) return false;
            spacing /= n;
            return true;
        }

        static V2[] Refine(GrayImage img, V2[] pts, int hw)
        {
            int w = img.Width, h = img.Height;
            var g = Blur(ToFloat(img), w, h, 1.0);
            double sigma2 = 2 * Math.Pow(hw * 0.6, 2);
            var o = new V2[pts.Length];
            for (int n = 0; n < pts.Length; n++)
            {
                V2 p = pts[n], q = p;
                for (int it = 0; it < 15; it++)
                {
                    double a11 = 0, a12 = 0, a22 = 0, b1 = 0, b2 = 0;
                    int cxI = (int)Math.Round(q.X, MidpointRounding.AwayFromZero), cyI = (int)Math.Round(q.Y, MidpointRounding.AwayFromZero);
                    for (int dy = -hw; dy <= hw; dy++)
                    {
                        int y = cyI + dy;
                        if (y <= 0 || y >= h - 1) continue;
                        for (int dx = -hw; dx <= hw; dx++)
                        {
                            int x = cxI + dx;
                            if (x <= 0 || x >= w - 1) continue;
                            int i = y * w + x;
                            double gx = (g[i + 1] - g[i - 1]) / 2.0, gy = (g[i + w] - g[i - w]) / 2.0;
                            double wgt = Math.Exp(-(double)(dx * dx + dy * dy) / sigma2);
                            double gxx = gx * gx * wgt, gxy = gx * gy * wgt, gyy = gy * gy * wgt;
                            a11 += gxx; a12 += gxy; a22 += gyy;
                            b1 += gxx * x + gxy * y;
                            b2 += gxy * x + gyy * y;
                        }
                    }
                    double det = a11 * a22 - a12 * a12;
                    if (!(det > 1e-9 * Math.Max(1, a11 * a22))) break;
                    var next = new V2((a22 * b1 - a12 * b2) / det, (a11 * b2 - a12 * b1) / det);
                    if (!(next.Dist(p) <= hw)) break;
                    double moved = next.Dist(q);
                    q = next;
                    if (moved < 0.01) break;
                }
                o[n] = q;
            }
            return o;
        }
    }

    /// <summary>The perspective mapping from the undistorted picture to machine coordinates (mm).</summary>
    public sealed class BedAlignment
    {
        public int ImageWidth, ImageHeight;
        public Homography ImageToBed;
        public double RmsError, MaxError;
        public DateTime Date;
    }

    /// <summary>Everything known about one camera: its lens and how its picture sits on the bed.</summary>
    public sealed class CameraSetup
    {
        public LensModel Lens;
        public BedAlignment Alignment;

        public LensModel LensAt(int w, int h) { return Lens == null ? null : Lens.Scaled(w, h); }

        /// <summary>A raw picture pixel (at w×h) to machine mm.</summary>
        public bool ImageToBed(V2 q, int w, int h, out V2 bed)
        {
            bed = new V2();
            var a = Alignment;
            if (a == null) return false;
            double sx = (double)a.ImageWidth / w, sy = (double)a.ImageHeight / h;
            var raw = new V2((q.X + 0.5) * sx - 0.5, (q.Y + 0.5) * sy - 0.5);
            var lens = LensAt(a.ImageWidth, a.ImageHeight);
            var ideal = lens != null ? lens.UndistortPixel(raw) : raw;
            return a.ImageToBed.Apply(ideal, out bed);
        }

        Homography toImage;
        Homography toImageFor;

        /// <summary>Machine mm to a raw picture pixel (at w×h). False where the camera can't see it.</summary>
        public bool BedToImage(V2 bed, int w, int h, out V2 q)
        {
            q = new V2();
            var a = Alignment;
            if (a == null) return false;
            if (toImageFor != a.ImageToBed) { toImage = a.ImageToBed.Inverted; toImageFor = a.ImageToBed; }
            if (toImage == null) return false;
            V2 ideal;
            if (!toImage.Apply(bed, out ideal)) return false;
            var raw = ideal;
            var lens = LensAt(a.ImageWidth, a.ImageHeight);
            if (lens != null)
            {
                double nx = (ideal.X - lens.Cx) / lens.Fx, ny = (ideal.Y - lens.Cy) / lens.Fy;
                if (nx * nx + ny * ny > CoveredFor(lens) * 1.02) return false;
                raw = lens.DistortPixel(ideal);
            }
            double sx = (double)w / a.ImageWidth, sy = (double)h / a.ImageHeight;
            q = new V2((raw.X + 0.5) * sx - 0.5, (raw.Y + 0.5) * sy - 0.5);
            return q.IsFinite;
        }

        LensModel coveredLens;
        double covered;
        double CoveredFor(LensModel l)
        {
            if (!ReferenceEquals(l, coveredLens) || coveredLens == null)
            {
                covered = l.CoveredRadius2;
                coveredLens = l;
            }
            return covered;
        }

        // Saved as "key=value" lines.
        public string Serialize()
        {
            var sb = new StringBuilder();
            Func<double, string> f = v => v.ToString("R", CultureInfo.InvariantCulture);
            if (Lens != null)
            {
                var l = Lens;
                sb.Append("lens=").Append(string.Join(" ", new[] { l.ImageWidth.ToString(CultureInfo.InvariantCulture), l.ImageHeight.ToString(CultureInfo.InvariantCulture),
                    f(l.Fx), f(l.Fy), f(l.Cx), f(l.Cy), f(l.K1), f(l.K2), f(l.K3), f(l.P1), f(l.P2), f(l.RmsError), l.Views.ToString(CultureInfo.InvariantCulture) })).Append('\n');
            }
            if (Alignment != null)
            {
                var a = Alignment;
                var parts = new List<string> { a.ImageWidth.ToString(CultureInfo.InvariantCulture), a.ImageHeight.ToString(CultureInfo.InvariantCulture) };
                foreach (double v in a.ImageToBed.M) parts.Add(f(v));
                parts.Add(f(a.RmsError)); parts.Add(f(a.MaxError));
                parts.Add(a.Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture));
                sb.Append("align=").Append(string.Join(" ", parts.ToArray())).Append('\n');
            }
            return sb.ToString();
        }

        public static CameraSetup Parse(string text)
        {
            var s = new CameraSetup();
            if (text == null) return s;
            foreach (string raw in text.Split('\n'))
            {
                string line = raw.Trim();
                int eq = line.IndexOf('=');
                if (eq < 0) continue;
                string key = line.Substring(0, eq);
                string[] v = line.Substring(eq + 1).Split(' ');
                try
                {
                    if (key == "lens" && v.Length >= 13)
                    {
                        s.Lens = new LensModel
                        {
                            ImageWidth = int.Parse(v[0], CultureInfo.InvariantCulture), ImageHeight = int.Parse(v[1], CultureInfo.InvariantCulture),
                            Fx = D(v[2]), Fy = D(v[3]), Cx = D(v[4]), Cy = D(v[5]), K1 = D(v[6]), K2 = D(v[7]), K3 = D(v[8]),
                            P1 = D(v[9]), P2 = D(v[10]), RmsError = D(v[11]), Views = int.Parse(v[12], CultureInfo.InvariantCulture),
                        };
                    }
                    else if (key == "align" && v.Length >= 14)
                    {
                        var m = new double[9];
                        for (int i = 0; i < 9; i++) m[i] = D(v[2 + i]);
                        DateTime date;
                        DateTime.TryParse(v.Length > 13 ? v[13] : "", CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out date);
                        s.Alignment = new BedAlignment
                        {
                            ImageWidth = int.Parse(v[0], CultureInfo.InvariantCulture), ImageHeight = int.Parse(v[1], CultureInfo.InvariantCulture),
                            ImageToBed = new Homography(m), RmsError = D(v[11]), MaxError = D(v[12]), Date = date,
                        };
                    }
                }
                catch (FormatException) { }
            }
            return s;
        }

        static double D(string s) { return double.Parse(s, NumberStyles.Float, CultureInfo.InvariantCulture); }
    }

    /// <summary>The burned target that ties the camera to the bed.</summary>
    public static class CameraTarget
    {
        /// <summary>Mark centres spread evenly over the area, numbered along X first, then Y.</summary>
        public static List<V2> MarkCentres(double minX, double minY, double maxX, double maxY, int columns, int rows)
        {
            int c = Math.Max(2, columns), r = Math.Max(2, rows);
            var o = new List<V2>();
            for (int j = 0; j < r; j++)
                for (int i = 0; i < c; i++)
                    o.Add(new V2(minX + (maxX - minX) * i / (c - 1), minY + (maxY - minY) * j / (r - 1)));
            return o;
        }

        /// <summary>Each mark is a cross in a circle; mark 1 also gets a small inner ring.</summary>
        public static List<List<V2>> Paths(IList<V2> marks, double size)
        {
            double r = Math.Max(1, size / 2);
            var o = new List<List<V2>>();
            for (int k = 0; k < marks.Count; k++)
            {
                V2 m = marks[k];
                o.Add(new List<V2> { new V2(m.X - r, m.Y), new V2(m.X + r, m.Y) });
                o.Add(new List<V2> { new V2(m.X, m.Y - r), new V2(m.X, m.Y + r) });
                o.Add(Circle(m, r * 0.75, 0.3));
                if (k == 0) o.Add(Circle(m, r * 0.35, 0.2));
            }
            return o;
        }

        static List<V2> Circle(V2 c, double r, double step)
        {
            int n = Math.Max(12, (int)Math.Ceiling(2 * Math.PI * r / step));
            var o = new List<V2>();
            for (int i = 0; i <= n; i++)
            {
                double a = 2 * Math.PI * i / n;
                o.Add(new V2(c.X + r * Math.Cos(a), c.Y + r * Math.Sin(a)));
            }
            return o;
        }

        /// <summary>G-code that burns the target at absolute positions (G90) in the current work coordinates.</summary>
        public static List<string> GCode(IList<V2> marks, double size, double feed, double powerPercent, double sMax)
        {
            double s = Math.Max(0, Math.Min(100, powerPercent)) / 100 * sMax;
            var o = new List<string> { "; KerfSender camera target", "G90", "G21", "M5", "M4 S0" };
            foreach (var path in Paths(marks, size))
            {
                o.Add("G0 X" + Fmt(path[0].X) + " Y" + Fmt(path[0].Y));
                for (int i = 1; i < path.Count; i++)
                    o.Add("G1 X" + Fmt(path[i].X) + " Y" + Fmt(path[i].Y) + (i == 1 ? " S" + Fmt(s) + " F" + Fmt(Math.Max(1, feed)) : ""));
            }
            o.Add("M5");
            o.Add("G0 X0 Y0");
            return o;
        }

        public static string Fmt(double v)
        {
            string t = v.ToString("0.###", CultureInfo.InvariantCulture);
            return t == "-0" ? "0" : t;
        }

        /// <summary>Homography from clicked marks (undistorted pixels) to where they were burned (mm), with its errors.</summary>
        public static Homography Fit(IList<V2> image, IList<V2> bed, out double rms, out double max)
        {
            rms = 0; max = 0;
            if (image.Count != bed.Count || image.Count < 4) return null;
            var h = Homography.Fit(image, bed);
            if (h == null) return null;
            double sum = 0;
            for (int i = 0; i < image.Count; i++)
            {
                V2 p;
                if (!h.Apply(image[i], out p)) return null;
                double e = p.Dist(bed[i]);
                sum += e * e;
                max = Math.Max(max, e);
            }
            rms = Math.Sqrt(sum / image.Count);
            return h;
        }

        public static int Otsu(byte[] values, int count)
        {
            var hist = new int[256];
            for (int i = 0; i < count; i++) hist[values[i]]++;
            double total = count, sumAll = 0;
            for (int i = 0; i < 256; i++) sumAll += i * (double)hist[i];
            double sumB = 0, wB = 0, best = -1;
            int threshold = 128;
            for (int t = 0; t < 256; t++)
            {
                wB += hist[t];
                if (wB == 0) continue;
                double wF = total - wB;
                if (wF == 0) break;
                sumB += t * (double)hist[t];
                double mB = sumB / wB, mF = (sumAll - sumB) / wF;
                double between = wB * wF * (mB - mF) * (mB - mF);
                if (between > best) { best = between; threshold = t + 1; }
            }
            return threshold;
        }

        /// <summary>The centre of the dark mark near a point, from the dark pixels' balance point, re-centred a few times.</summary>
        public static bool SnapToMark(GrayImage img, V2 point, double radius, out V2 result)
        {
            result = point;
            int rad = Math.Max(4, (int)Math.Round(radius));
            V2 c = point;
            var values = new byte[(2 * rad + 1) * (2 * rad + 1)];
            for (int it = 0; it < 6; it++)
            {
                int x0 = Math.Max(0, (int)c.X - rad), x1 = Math.Min(img.Width - 1, (int)c.X + rad);
                int y0 = Math.Max(0, (int)c.Y - rad), y1 = Math.Min(img.Height - 1, (int)c.Y + rad);
                if (x1 <= x0 + 2 || y1 <= y0 + 2) return false;
                int n = 0;
                byte lo = 255, hi = 0;
                for (int y = y0; y <= y1; y++)
                    for (int x = x0; x <= x1; x++)
                    {
                        byte v = img[x, y];
                        values[n++] = v;
                        if (v < lo) lo = v;
                        if (v > hi) hi = v;
                    }
                if (hi - lo < 25) return false;
                double t = Otsu(values, n);
                double sx = 0, sy = 0, sw = 0, r2 = (double)rad * rad;
                for (int y = y0; y <= y1; y++)
                    for (int x = x0; x <= x1; x++)
                    {
                        double dx = x - c.X, dy = y - c.Y;
                        if (dx * dx + dy * dy > r2) continue;
                        double v = img[x, y];
                        if (v < t) { double wgt = t - v; sx += x * wgt; sy += y * wgt; sw += wgt; }
                    }
                if (sw <= 0) return false;
                var next = new V2(sx / sw, sy / sw);
                double moved = next.Dist(c);
                c = next;
                if (moved < 0.05) break;
            }
            if (c.Dist(point) > radius * 1.5) return false;
            result = c;
            return true;
        }

        /// <summary>
        /// Where the marks not clicked yet should be in the picture, from those that are: an affine fit for three
        /// clicked marks, a perspective fit for four or more. Null entries stay null when there's too little to go on.
        /// </summary>
        public static V2?[] Predict(IList<V2> marks, IList<V2?> clicks)
        {
            var bed = new List<V2>();
            var img = new List<V2>();
            for (int i = 0; i < Math.Min(marks.Count, clicks.Count); i++)
                if (clicks[i].HasValue) { bed.Add(marks[i]); img.Add(clicks[i].Value); }
            var o = new V2?[marks.Count];
            if (bed.Count < 3) return o;
            Func<V2, V2?> map = null;
            if (bed.Count >= 4)
            {
                var h = Homography.Fit(bed, img);
                if (h != null) map = p => { V2 q; return h.Apply(p, out q) ? q : (V2?)null; };
            }
            if (map == null)
            {
                // Affine from the first three, which must not be in a line.
                V2 a = bed[0], b = bed[1], c = bed[2];
                double det = (b - a).Cross(c - a);
                if (Math.Abs(det) < 1e-6) return o;
                V2 ia = img[0], ib = img[1], ic = img[2];
                map = p =>
                {
                    V2 d = p - a;
                    double u = d.Cross(c - a) / det, v = (b - a).Cross(d) / det;
                    return ia + (ib - ia) * u + (ic - ia) * v;
                };
            }
            for (int i = 0; i < marks.Count; i++)
                if (i >= clicks.Count || !clicks[i].HasValue) o[i] = map(marks[i]);
            return o;
        }
    }

    /// <summary>
    /// The job's toolpath read back from its G-code, and the same G-code moved and turned to a new place on the bed.
    /// Positions are in work coordinates (what the G-code says); add the work offset for machine coordinates.
    /// </summary>
    public sealed class GcodeToolpath
    {
        public readonly List<List<V2>> Burns = new List<List<V2>>();
        public double MinX = double.MaxValue, MinY = double.MaxValue, MaxX = double.MinValue, MaxY = double.MinValue;
        public bool HasRelativeMoves;
        public int PointCount;
        public bool IsEmpty { get { return MinX > MaxX; } }
        public V2 Centre { get { return new V2((MinX + MaxX) / 2, (MinY + MaxY) / 2); } }

        sealed class Word { public char Letter; public string Text; public double Value; }

        static List<Word> Words(string code)
        {
            var o = new List<Word>();
            int i = 0, n = code.Length;
            while (i < n)
            {
                char ch = char.ToUpperInvariant(code[i]);
                if (ch < 'A' || ch > 'Z') { i++; continue; }
                int j = i + 1;
                while (j < n && (code[j] == ' ' || code[j] == '\t')) j++;
                int s = j;
                while (j < n && (char.IsDigit(code[j]) || code[j] == '.' || code[j] == '-' || code[j] == '+')) j++;
                double v;
                double.TryParse(code.Substring(s, j - s), NumberStyles.Float, CultureInfo.InvariantCulture, out v);
                o.Add(new Word { Letter = ch, Text = code.Substring(s, j - s), Value = v });
                i = j;
            }
            return o;
        }

        /// <summary>A line without comments, or null when it's blank or a $ command.</summary>
        static string Code(string line)
        {
            var c = GrblStreamer.Clean(line);
            if (c == null || c.StartsWith("$")) return null;
            return c;
        }

        static bool Has(List<Word> w, char letter, double value)
        {
            foreach (var x in w) if (x.Letter == letter && Math.Abs(x.Value - value) < 1e-9) return true;
            return false;
        }

        /// <summary>Reads the burning moves (G1/G2/G3 with the laser on). Straight runs along a line are merged.</summary>
        public static GcodeToolpath Read(IList<string> lines)
        {
            var t = new GcodeToolpath();
            double x = 0, y = 0, sVal = 0;
            bool relative = false, sSeen = false, on = true;
            int motion = 0;
            List<V2> current = null;
            foreach (string raw in lines)
            {
                var code = Code(raw);
                if (code == null) continue;
                var w = Words(code);
                bool skipXY = false;
                foreach (var wd in w)
                {
                    if (wd.Letter == 'G')
                    {
                        int g = (int)Math.Round(wd.Value * 10);
                        if (g == 0 || g == 10 || g == 20 || g == 30) motion = g / 10;
                        else if (g == 900) relative = false;
                        else if (g == 910) { relative = true; t.HasRelativeMoves = true; }
                        else if (g == 530 || g == 280 || g == 300 || g == 100 || g == 920 || g == 921 || g == 922 || g == 923) skipXY = true;
                    }
                    else if (wd.Letter == 'M')
                    {
                        if (wd.Value == 3 || wd.Value == 4) on = true;
                        else if (wd.Value == 5) on = false;
                    }
                    else if (wd.Letter == 'S') { sVal = wd.Value; sSeen = true; }
                }
                if (skipXY) { current = null; continue; }
                double nx = x, ny = y;
                bool moved = false;
                foreach (var wd in w)
                {
                    if (wd.Letter == 'X') { nx = relative ? x + wd.Value : wd.Value; moved = true; }
                    else if (wd.Letter == 'Y') { ny = relative ? y + wd.Value : wd.Value; moved = true; }
                }
                if (!moved) continue;
                bool burn = motion != 0 && on && (!sSeen || sVal > 0);
                if (burn)
                {
                    if (current == null) { current = new List<V2> { new V2(x, y) }; t.Burns.Add(current); t.Extend(x, y); }
                    var p = new V2(nx, ny);
                    int c = current.Count;
                    if (c >= 2)
                    {
                        V2 a = current[c - 2], b = current[c - 1];
                        V2 d1 = b - a, d2 = p - b;
                        if (Math.Abs(d1.Cross(d2)) < 1e-6 * Math.Max(1, d1.Length * d2.Length) && d1.Dot(d2) > 0) current[c - 1] = p;
                        else current.Add(p);
                    }
                    else current.Add(p);
                    t.Extend(nx, ny);
                }
                else current = null;
                x = nx; y = ny;
            }
            foreach (var b in t.Burns) t.PointCount += b.Count;
            return t;
        }

        void Extend(double x, double y)
        {
            MinX = Math.Min(MinX, x); MaxX = Math.Max(MaxX, x);
            MinY = Math.Min(MinY, y); MaxY = Math.Max(MaxY, y);
        }

        /// <summary>
        /// Rewrites the G-code with every X/Y position (and arc centre offset) turned by `degrees` about `pivot`
        /// and then moved by `shift`. Lines without positions pass through unchanged. Fails (null) for relative
        /// (G91) moves, which can't be placed safely.
        /// </summary>
        public static List<string> Transform(IList<string> lines, V2 pivot, double degrees, V2 shift, out string error)
        {
            error = null;
            double a = degrees * Math.PI / 180, ca = Math.Cos(a), sa = Math.Sin(a);
            Func<V2, V2> map = p => { V2 d = p - pivot; return new V2(pivot.X + d.X * ca - d.Y * sa + shift.X, pivot.Y + d.X * sa + d.Y * ca + shift.Y); };
            var o = new List<string>(lines.Count);
            double x = 0, y = 0;
            foreach (string raw in lines)
            {
                var code = Code(raw);
                if (code == null) { o.Add(raw); continue; }
                var w = Words(code);
                bool skipXY = false;
                foreach (var wd in w)
                {
                    if (wd.Letter == 'G')
                    {
                        int g = (int)Math.Round(wd.Value * 10);
                        if (g == 910) { error = "The job uses relative moves (G91), so it can't be placed with the camera."; return null; }
                        if (g == 530 || g == 280 || g == 300 || g == 100 || g == 920 || g == 921 || g == 922 || g == 923) skipXY = true;
                    }
                }
                bool hasX = false, hasY = false, hasIJ = false;
                double nx = x, ny = y, ii = 0, jj = 0;
                foreach (var wd in w)
                {
                    if (wd.Letter == 'X') { hasX = true; nx = wd.Value; }
                    else if (wd.Letter == 'Y') { hasY = true; ny = wd.Value; }
                    else if (wd.Letter == 'I') { hasIJ = true; ii = wd.Value; }
                    else if (wd.Letter == 'J') { hasIJ = true; jj = wd.Value; }
                }
                if (skipXY || (!hasX && !hasY && !hasIJ)) { o.Add(raw); continue; }
                var p = map(new V2(nx, ny));
                var sb = new StringBuilder();
                bool wroteXY = false;
                foreach (var wd in w)
                {
                    if (wd.Letter == 'X' || wd.Letter == 'Y')
                    {
                        if (!wroteXY) { sb.Append(sb.Length > 0 ? " " : "").Append("X").Append(CameraTarget.Fmt(p.X)).Append(" Y").Append(CameraTarget.Fmt(p.Y)); wroteXY = true; }
                    }
                    else if (wd.Letter == 'I' || wd.Letter == 'J')
                    {
                        if (wd.Letter == 'I' || !w.Exists(q => q.Letter == 'I'))
                        {
                            double ri = ii * ca - jj * sa, rj = ii * sa + jj * ca;
                            sb.Append(sb.Length > 0 ? " " : "").Append("I").Append(CameraTarget.Fmt(ri)).Append(" J").Append(CameraTarget.Fmt(rj));
                        }
                    }
                    else sb.Append(sb.Length > 0 ? " " : "").Append(wd.Letter).Append(wd.Text);
                }
                if (!wroteXY && (hasX || hasY)) sb.Append(" X").Append(CameraTarget.Fmt(p.X)).Append(" Y").Append(CameraTarget.Fmt(p.Y));
                o.Add(sb.ToString());
                if (hasX || hasY) { x = nx; y = ny; }
            }
            return o;
        }
    }
}
