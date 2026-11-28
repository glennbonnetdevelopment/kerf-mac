// See KSCameraMath.h. Kept step for step with the Swift original so results match KerfKutter.

#include "KSCameraMath.h"

#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static double dmin(double a, double b) { return a < b ? a : b; }
static double dmax(double a, double b) { return a > b ? a : b; }
static int imin(int a, int b) { return a < b ? a : b; }
static int imax(int a, int b) { return a > b ? a : b; }
static KSV2 vadd(KSV2 a, KSV2 b) { return ks_v2(a.x + b.x, a.y + b.y); }
static KSV2 vsub(KSV2 a, KSV2 b) { return ks_v2(a.x - b.x, a.y - b.y); }
static KSV2 vmul(KSV2 a, double s) { return ks_v2(a.x * s, a.y * s); }
static double vlen(KSV2 a) { return sqrt(a.x * a.x + a.y * a.y); }
static double vdist(KSV2 a, KSV2 b) { return vlen(vsub(a, b)); }
static double vdot(KSV2 a, KSV2 b) { return a.x * b.x + a.y * b.y; }
static double vcross(KSV2 a, KSV2 b) { return a.x * b.y - a.y * b.x; }
static KSV2 vnorm(KSV2 a) { double l = vlen(a); return l > 0 ? vmul(a, 1 / l) : a; }
static int finite2(KSV2 a) { return isfinite(a.x) && isfinite(a.y); }

// MARK: - Linear algebra

int ks_solve(const double *a, const double *b, int n, double *x) {
    if (n <= 0) return 0;
    double *m = malloc(sizeof(double) * (size_t)(n * n));
    double *r = malloc(sizeof(double) * (size_t)n);
    if (!m || !r) { free(m); free(r); return 0; }
    memcpy(m, a, sizeof(double) * (size_t)(n * n));
    memcpy(r, b, sizeof(double) * (size_t)n);
    double scale = 1e-300;
    for (int i = 0; i < n * n; i++) scale = dmax(scale, fabs(m[i]));
    int ok = 1;
    for (int col = 0; col < n && ok; col++) {
        int pivot = col;
        double best = fabs(m[col * n + col]);
        for (int row = col + 1; row < n; row++)
            if (fabs(m[row * n + col]) > best) { best = fabs(m[row * n + col]); pivot = row; }
        if (!(best > scale * 1e-15)) { ok = 0; break; }
        if (pivot != col) {
            for (int k = 0; k < n; k++) { double t = m[col * n + k]; m[col * n + k] = m[pivot * n + k]; m[pivot * n + k] = t; }
            double t = r[col]; r[col] = r[pivot]; r[pivot] = t;
        }
        double d = m[col * n + col];
        for (int row = col + 1; row < n; row++) {
            double f = m[row * n + col] / d;
            if (f == 0) continue;
            for (int k = col; k < n; k++) m[row * n + k] -= f * m[col * n + k];
            r[row] -= f * r[col];
        }
    }
    if (ok) {
        for (int row = n - 1; row >= 0; row--) {
            double s = r[row];
            for (int k = row + 1; k < n; k++) s -= m[row * n + k] * x[k];
            x[row] = s / m[row * n + row];
        }
        for (int i = 0; i < n; i++) if (!isfinite(x[i])) ok = 0;
    }
    free(m);
    free(r);
    return ok;
}

static void mul3(const double *a, const double *b, double *o) {
    double t[9];
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) t[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    memcpy(o, t, sizeof t);
}

static int invert3(const double *m, double *o) {
    double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
    double det = a * A + b * B + c * C;
    double size = 0;
    for (int k = 0; k < 9; k++) size = dmax(size, fabs(m[k]));
    if (!(fabs(det) > 1e-14 * dmax(1e-300, size * size * size))) return 0;
    double inv[9] = { A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d };
    for (int k = 0; k < 9; k++) o[k] = inv[k] / det;
    return 1;
}

// MARK: - Homography

int ks_h_apply(const KSHomography *h, KSV2 p, KSV2 *out) {
    const double *m = h->m;
    double w = m[6] * p.x + m[7] * p.y + m[8];
    if (fabs(w) <= 1e-12) return 0;
    *out = ks_v2((m[0] * p.x + m[1] * p.y + m[2]) / w, (m[3] * p.x + m[4] * p.y + m[5]) / w);
    return 1;
}

int ks_h_invert(const KSHomography *h, KSHomography *out) { return invert3(h->m, out->m); }

static int normalize_points(const KSV2 *pts, int n, KSV2 *o, double t[9]) {
    KSV2 c = { 0, 0 };
    for (int i = 0; i < n; i++) c = vadd(c, pts[i]);
    c = vmul(c, 1.0 / n);
    double mean = 0;
    for (int i = 0; i < n; i++) mean += vdist(pts[i], c);
    mean /= n;
    if (!(mean > 1e-12)) return 0;
    double s = sqrt(2.0) / mean;
    double tt[9] = { s, 0, -s * c.x, 0, s, -s * c.y, 0, 0, 1 };
    memcpy(t, tt, sizeof tt);
    for (int i = 0; i < n; i++) o[i] = vmul(vsub(pts[i], c), s);
    return 1;
}

int ks_h_fit(const KSV2 *src, const KSV2 *dst, int n, KSHomography *out) {
    if (n < 4) return 0;
    KSV2 *ns = malloc(sizeof(KSV2) * (size_t)n), *nd = malloc(sizeof(KSV2) * (size_t)n);
    double ts[9], td[9];
    int ok = ns && nd && normalize_points(src, n, ns, ts) && normalize_points(dst, n, nd, td);
    double ata[64] = { 0 }, atb[8] = { 0 }, h[8];
    if (ok) {
        for (int k = 0; k < n; k++) {
            KSV2 p = ns[k], q = nd[k];
            double rows[2][8] = {
                { p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y },
                { 0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y },
            };
            double rhs[2] = { q.x, q.y };
            for (int r = 0; r < 2; r++)
                for (int i = 0; i < 8; i++) {
                    atb[i] += rows[r][i] * rhs[r];
                    for (int j = 0; j < 8; j++) ata[i * 8 + j] += rows[r][i] * rows[r][j];
                }
        }
        ok = ks_solve(ata, atb, 8, h);
    }
    double tdInv[9];
    if (ok) ok = invert3(td, tdInv);
    if (ok) {
        double hm[9] = { h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1 };
        double r[9];
        // ts, then hm, then tdInv: tdInv · hm · ts.
        mul3(hm, ts, r);
        mul3(tdInv, r, r);
        double s = fabs(r[8]) > 1e-12 ? r[8] : 1;
        for (int i = 0; i < 9; i++) out->m[i] = r[i] / s;
    }
    free(ns);
    free(nd);
    return ok;
}

// MARK: - Lens

KSV2 ks_lens_distort(const KSLens *l, KSV2 p) {
    double x = p.x, y = p.y, r2 = x * x + y * y;
    double radial = 1 + r2 * (l->k1 + r2 * (l->k2 + r2 * l->k3));
    return ks_v2(x * radial + 2 * l->p1 * x * y + l->p2 * (r2 + 2 * x * x),
                 y * radial + l->p1 * (r2 + 2 * y * y) + 2 * l->p2 * x * y);
}

KSV2 ks_lens_undistort(const KSLens *l, KSV2 d) {
    KSV2 p = d;
    for (int it = 0; it < 40; it++) {
        double x = p.x, y = p.y, r2 = x * x + y * y;
        double radial = 1 + r2 * (l->k1 + r2 * (l->k2 + r2 * l->k3));
        if (fabs(radial) <= 1e-6) break;
        double dx = 2 * l->p1 * x * y + l->p2 * (r2 + 2 * x * x);
        double dy = l->p1 * (r2 + 2 * y * y) + 2 * l->p2 * x * y;
        KSV2 next = ks_v2((d.x - dx) / radial, (d.y - dy) / radial);
        double moved = vdist(next, p);
        p = next;
        if (moved < 1e-12) break;
    }
    return p;
}

KSV2 ks_lens_undistort_pixel(const KSLens *l, KSV2 q) {
    KSV2 n = ks_lens_undistort(l, ks_v2((q.x - l->cx) / l->fx, (q.y - l->cy) / l->fy));
    return ks_v2(n.x * l->fx + l->cx, n.y * l->fy + l->cy);
}

KSV2 ks_lens_distort_pixel(const KSLens *l, KSV2 q) {
    KSV2 d = ks_lens_distort(l, ks_v2((q.x - l->cx) / l->fx, (q.y - l->cy) / l->fy));
    return ks_v2(d.x * l->fx + l->cx, d.y * l->fy + l->cy);
}

int ks_lens_scaled(const KSLens *l, int w, int h, KSLens *out) {
    if (l->width <= 0 || l->height <= 0 || w <= 0 || h <= 0) return 0;
    *out = *l;
    if (w == l->width && h == l->height) return 1;
    double sx = (double)w / l->width, sy = (double)h / l->height;
    if (!(fabs(sx - sy) / dmax(sx, sy) < 0.01)) return 0;
    out->width = w;
    out->height = h;
    out->fx *= sx;
    out->fy *= sy;
    out->cx = (l->cx + 0.5) * sx - 0.5;
    out->cy = (l->cy + 0.5) * sy - 0.5;
    out->rms *= sx;
    return 1;
}

double ks_lens_covered_r2(const KSLens *l) {
    double w = l->width - 1, h = l->height - 1, r2 = 0;
    KSV2 pts[8] = { { 0, 0 }, { w, 0 }, { 0, h }, { w, h }, { w / 2, 0 }, { w / 2, h }, { 0, h / 2 }, { w, h / 2 } };
    for (int i = 0; i < 8; i++) {
        KSV2 n = ks_lens_undistort(l, ks_v2((pts[i].x - l->cx) / l->fx, (pts[i].y - l->cy) / l->fy));
        r2 = dmax(r2, n.x * n.x + n.y * n.y);
    }
    return r2;
}

double ks_lens_corner_distortion(const KSLens *l) {
    KSV2 n = ks_v2(-l->cx / l->fx, -l->cy / l->fy);
    KSV2 d = ks_lens_distort(l, n);
    return (vlen(d) - vlen(n)) / dmax(1e-9, vlen(n));
}

// MARK: - Lens calibration

static void rotation_matrix(double rx, double ry, double rz, double *o) {
    double th = sqrt(rx * rx + ry * ry + rz * rz);
    if (th < 1e-12) {
        double r[9] = { 1, -rz, ry, rz, 1, -rx, -ry, rx, 1 };
        memcpy(o, r, sizeof r);
        return;
    }
    double kx = rx / th, ky = ry / th, kz = rz / th, c = cos(th), s = sin(th), v = 1 - c;
    double r[9] = { c + kx * kx * v, kx * ky * v - kz * s, kx * kz * v + ky * s,
                    ky * kx * v + kz * s, c + ky * ky * v, ky * kz * v - kx * s,
                    kz * kx * v - ky * s, kz * ky * v + kx * s, c + kz * kz * v };
    memcpy(o, r, sizeof r);
}

static void rodrigues(const double *r, double *o) {
    double cosT = dmax(-1, dmin(1, (r[0] + r[4] + r[8] - 1) / 2));
    double th = acos(cosT);
    if (th < 1e-9) { o[0] = o[1] = o[2] = 0; return; }
    if (th > M_PI - 1e-6) {
        double kx = sqrt(dmax(0, (r[0] + 1) / 2)), ky = sqrt(dmax(0, (r[4] + 1) / 2)), kz = sqrt(dmax(0, (r[8] + 1) / 2));
        if (kx >= ky && kx >= kz) { if (r[1] < 0) ky = -ky; if (r[2] < 0) kz = -kz; }
        else if (ky >= kz) { if (r[1] < 0) kx = -kx; if (r[5] < 0) kz = -kz; }
        else { if (r[2] < 0) kx = -kx; if (r[5] < 0) ky = -ky; }
        o[0] = kx * th; o[1] = ky * th; o[2] = kz * th;
        return;
    }
    double s = 2 * sin(th);
    o[0] = (r[7] - r[5]) / s * th;
    o[1] = (r[2] - r[6]) / s * th;
    o[2] = (r[3] - r[1]) / s * th;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

static double initial_focal(const KSHomography *hs, int n, double cx, double cy, int width, int height) {
    double size = imax(width, height);
    double *est = malloc(sizeof(double) * (size_t)(2 * n + 1));
    int count = 0;
    for (int v = 0; v < n; v++) {
        double m[9];
        memcpy(m, hs[v].m, sizeof m);
        for (int k = 0; k < 3; k++) { m[k] -= cx * m[6 + k]; m[3 + k] -= cy * m[6 + k]; }
        double h10 = m[0], h11 = m[3], h12 = m[6], h20 = m[1], h21 = m[4], h22 = m[7];
        double n1 = h10 * h10 + h11 * h11, n2 = h20 * h20 + h21 * h21;
        double zScale = (n1 + n2) / (size * size);
        double den1 = h12 * h22;
        if (fabs(den1) > zScale * 1e-3) { double f2 = -(h10 * h20 + h11 * h21) / den1; if (f2 > 0) est[count++] = sqrt(f2); }
        double den2 = h12 * h12 - h22 * h22;
        if (fabs(den2) > zScale * 1e-3) { double f2 = -(n1 - n2) / den2; if (f2 > 0) est[count++] = sqrt(f2); }
    }
    int sane = 0;
    for (int i = 0; i < count; i++) if (est[i] > size * 0.15 && est[i] < size * 6) est[sane++] = est[i];
    qsort(est, (size_t)sane, sizeof(double), cmp_double);
    double f = sane == 0 ? size * 0.8 : est[sane / 2];
    free(est);
    return f;
}

static double norm3(const double *v) { return sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); }

static void initial_pose(const KSHomography *hm, double f, double cx, double cy, double *o) {
    double m[9];
    memcpy(m, hm->m, sizeof m);
    for (int k = 0; k < 3; k++) { m[k] = (m[k] - cx * m[6 + k]) / f; m[3 + k] = (m[3 + k] - cy * m[6 + k]) / f; }
    double h1[3] = { m[0], m[3], m[6] }, h2[3] = { m[1], m[4], m[7] }, h3[3] = { m[2], m[5], m[8] };
    double lambda = 2 / dmax(1e-12, norm3(h1) + norm3(h2));
    if (h3[2] * lambda < 0) lambda = -lambda;
    double r1[3], r2[3], t[3];
    for (int k = 0; k < 3; k++) { r1[k] = h1[k] * lambda; r2[k] = h2[k] * lambda; t[k] = h3[k] * lambda; }
    double n1 = dmax(1e-12, norm3(r1));
    double u1[3] = { r1[0] / n1, r1[1] / n1, r1[2] / n1 };
    double d = u1[0] * r2[0] + u1[1] * r2[1] + u1[2] * r2[2];
    for (int k = 0; k < 3; k++) r2[k] -= d * u1[k];
    double n2 = dmax(1e-12, norm3(r2));
    double u2[3] = { r2[0] / n2, r2[1] / n2, r2[2] / n2 };
    double u3[3] = { u1[1] * u2[2] - u1[2] * u2[1], u1[2] * u2[0] - u1[0] * u2[2], u1[0] * u2[1] - u1[1] * u2[0] };
    double rot[9] = { u1[0], u2[0], u3[0], u1[1], u2[1], u3[1], u1[2], u2[2], u3[2] };
    double r[3];
    rodrigues(rot, r);
    o[0] = r[0]; o[1] = r[1]; o[2] = r[2]; o[3] = t[0]; o[4] = t[1]; o[5] = t[2];
}

enum { INTRINSICS = 8 };

static int project(KSV2 b, const double *p, int pose, KSV2 *q) {
    double rot[9];
    rotation_matrix(p[pose], p[pose + 1], p[pose + 2], rot);
    double x = rot[0] * b.x + rot[1] * b.y + p[pose + 3];
    double y = rot[3] * b.x + rot[4] * b.y + p[pose + 4];
    double z = rot[6] * b.x + rot[7] * b.y + p[pose + 5];
    if (!(z > 1e-9)) return 0;
    KSLens lens = { 0, 0, p[0], p[0], p[1], p[2], p[3], p[4], p[7], p[5], p[6], 0, 0 };
    KSV2 d = ks_lens_distort(&lens, ks_v2(x / z, y / z));
    *q = ks_v2(d.x * p[0] + p[1], d.y * p[0] + p[2]);
    return 1;
}

static void residuals(const KSBoardView *v, const double *p, int index, double *o) {
    int pose = INTRINSICS + 6 * index;
    for (int k = 0; k < v->count; k++) {
        KSV2 r;
        if (project(v->board[k], p, pose, &r)) { o[2 * k] = r.x - v->image[k].x; o[2 * k + 1] = r.y - v->image[k].y; }
        else { o[2 * k] = 1e4; o[2 * k + 1] = 1e4; }
    }
}

static double total_cost(const KSBoardView *views, int nv, const double *p, double *scratch) {
    double c = 0;
    for (int v = 0; v < nv; v++) {
        residuals(&views[v], p, v, scratch);
        for (int k = 0; k < 2 * views[v].count; k++) c += scratch[k] * scratch[k];
    }
    return c;
}

static int levenberg_marquardt(const KSBoardView *views, int nv, double *p, int np, const int *free_, int iterations, double *costOut) {
    int maxCorners = 0;
    for (int v = 0; v < nv; v++) maxCorners = imax(maxCorners, views[v].count);
    int nr = 2 * maxCorners;
    double *scratch = malloc(sizeof(double) * (size_t)nr);
    double *base = malloc(sizeof(double) * (size_t)nr);
    double *derivs = malloc(sizeof(double) * (size_t)(nr * 14));
    int *freeIdx = malloc(sizeof(int) * (size_t)np);
    int *position = malloc(sizeof(int) * (size_t)np);
    double *q = malloc(sizeof(double) * (size_t)np);
    int n = 0;
    for (int i = 0; i < np; i++) { position[i] = -1; if (free_[i]) { position[i] = n; freeIdx[n++] = i; } }
    double *jtj = malloc(sizeof(double) * (size_t)(n * n));
    double *jtr = malloc(sizeof(double) * (size_t)n);
    double *a = malloc(sizeof(double) * (size_t)(n * n));
    double *neg = malloc(sizeof(double) * (size_t)n);
    double *delta = malloc(sizeof(double) * (size_t)n);
    int ok = scratch && base && derivs && freeIdx && position && q && jtj && jtr && a && neg && delta;
    double cost = ok ? total_cost(views, nv, p, scratch) : NAN;
    if (!isfinite(cost)) ok = 0;
    double lambda = 1e-3;
    int columns[14];

    for (int iter = 0; ok && iter < iterations; iter++) {
        memset(jtj, 0, sizeof(double) * (size_t)(n * n));
        memset(jtr, 0, sizeof(double) * (size_t)n);
        for (int v = 0; v < nv; v++) {
            int len = 2 * views[v].count;
            residuals(&views[v], p, v, base);
            int pose = INTRINSICS + 6 * v;
            int nc = 0;
            for (int k = 0; k < n; k++) {
                int i = freeIdx[k];
                if (i < INTRINSICS || (i >= pose && i < pose + 6)) columns[nc++] = i;
            }
            for (int c = 0; c < nc; c++) {
                int i = columns[c];
                memcpy(q, p, sizeof(double) * (size_t)np);
                double step = 1e-6 * dmax(1, fabs(p[i]));
                q[i] += step;
                residuals(&views[v], q, v, scratch);
                for (int k = 0; k < len; k++) derivs[c * nr + k] = (scratch[k] - base[k]) / step;
            }
            for (int ca = 0; ca < nc; ca++) {
                int ka = position[columns[ca]];
                double g = 0;
                for (int k = 0; k < len; k++) g += derivs[ca * nr + k] * base[k];
                jtr[ka] += g;
                for (int cb = ca; cb < nc; cb++) {
                    int kb = position[columns[cb]];
                    double s = 0;
                    for (int k = 0; k < len; k++) s += derivs[ca * nr + k] * derivs[cb * nr + k];
                    jtj[ka * n + kb] += s;
                    if (kb != ka) jtj[kb * n + ka] += s;
                }
            }
        }
        int improved = 0;
        while (lambda < 1e12) {
            memcpy(a, jtj, sizeof(double) * (size_t)(n * n));
            for (int k = 0; k < n; k++) { a[k * n + k] += lambda * dmax(jtj[k * n + k], 1e-9); neg[k] = -jtr[k]; }
            if (!ks_solve(a, neg, n, delta)) { lambda *= 10; continue; }
            memcpy(q, p, sizeof(double) * (size_t)np);
            for (int k = 0; k < n; k++) q[freeIdx[k]] += delta[k];
            double c = total_cost(views, nv, q, scratch);
            if (isfinite(c) && c < cost) {
                double gain = cost - c;
                memcpy(p, q, sizeof(double) * (size_t)np);
                cost = c;
                lambda = dmax(1e-9, lambda / 3);
                improved = gain > 1e-12 * dmax(1, cost);
                break;
            }
            lambda *= 4;
        }
        if (!improved) break;
    }
    *costOut = cost;
    free(scratch); free(base); free(derivs); free(freeIdx); free(position); free(q);
    free(jtj); free(jtr); free(a); free(neg); free(delta);
    return ok;
}

int ks_lens_calibrate(const KSBoardView *views, int n, KSLens *out) {
    KSBoardView *usable = malloc(sizeof(KSBoardView) * (size_t)(n > 0 ? n : 1));
    int nu = 0;
    for (int i = 0; i < n; i++) if (views[i].count >= 6) usable[nu++] = views[i];
    int ok = nu >= KS_MIN_VIEWS;
    int w = ok ? usable[0].width : 0, h = ok ? usable[0].height : 0;
    for (int i = 0; ok && i < nu; i++) if (usable[i].width != w || usable[i].height != h) ok = 0;
    KSHomography *hs = malloc(sizeof(KSHomography) * (size_t)(nu > 0 ? nu : 1));
    for (int i = 0; ok && i < nu; i++) ok = ks_h_fit(usable[i].board, usable[i].image, usable[i].count, &hs[i]);
    if (!ok) { free(usable); free(hs); return 0; }

    double cx0 = (w - 1) / 2.0, cy0 = (h - 1) / 2.0;
    double f0 = initial_focal(hs, nu, cx0, cy0, w, h);
    int np = INTRINSICS + 6 * nu;
    double *p = calloc((size_t)np, sizeof(double));
    int *free_ = malloc(sizeof(int) * (size_t)np);
    p[0] = f0; p[1] = cx0; p[2] = cy0;
    for (int i = 0; i < nu; i++) initial_pose(&hs[i], f0, cx0, cy0, p + INTRINSICS + 6 * i);
    for (int i = 0; i < np; i++) free_[i] = 1;
    int many = nu >= 4;
    free_[1] = free_[2] = free_[5] = free_[6] = many;
    free_[7] = nu >= 6;

    double cost = 0;
    ok = levenberg_marquardt(usable, nu, p, np, free_, 150, &cost);
    int count = 0;
    for (int i = 0; i < nu; i++) count += usable[i].count;
    double rms = sqrt(cost / imax(1, count));
    if (ok && p[0] > 0 && isfinite(rms)) {
        KSLens l = { w, h, p[0], p[0], p[1], p[2], p[3], p[4], p[7], p[5], p[6], rms, nu };
        *out = l;
    } else ok = 0;
    free(p); free(free_); free(usable); free(hs);
    return ok;
}

// MARK: - Checkerboard detection

void ks_board_free(KSBoardView *v) {
    free(v->image);
    free(v->board);
    v->image = v->board = NULL;
    v->count = 0;
}

static float *blur(const float *src, int w, int h, double sigma) {
    int r = imax(1, (int)ceil(sigma * 3));
    int kn = 2 * r + 1;
    float *k = malloc(sizeof(float) * (size_t)kn);
    float sum = 0;
    for (int i = -r; i <= r; i++) { k[i + r] = (float)exp(-(double)(i * i) / (2 * sigma * sigma)); sum += k[i + r]; }
    for (int i = 0; i < kn; i++) k[i] /= sum;
    float *tmp = malloc(sizeof(float) * (size_t)(w * h));
    float *o = malloc(sizeof(float) * (size_t)(w * h));
    for (int y = 0; y < h; y++) {
        int row = y * w;
        for (int x = 0; x < w; x++) {
            float s = 0;
            for (int j = 0; j < kn; j++) { int xx = imin(w - 1, imax(0, x + j - r)); s += src[row + xx] * k[j]; }
            tmp[row + x] = s;
        }
    }
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            float s = 0;
            for (int j = 0; j < kn; j++) { int yy = imin(h - 1, imax(0, y + j - r)); s += tmp[yy * w + x] * k[j]; }
            o[y * w + x] = s;
        }
    free(k);
    free(tmp);
    return o;
}

static float sample(const float *f, int w, int h, double x, double y) {
    double xc = dmin(w - 1, dmax(0, x)), yc = dmin(h - 1, dmax(0, y));
    int x0 = imin(w - 2, (int)xc), y0 = imin(h - 2, (int)yc);
    float ax = (float)(xc - x0), ay = (float)(yc - y0);
    int i = y0 * w + x0;
    float top = f[i] * (1 - ax) + f[i + 1] * ax;
    float bottom = f[i + w] * (1 - ax) + f[i + w + 1] * ax;
    return top * (1 - ay) + bottom * ay;
}

static int ring_alternates(const float *f, int w, int h, int x, int y, double radius) {
    enum { N = 32 };
    float v[N], lo = FLT_MAX, hi = -FLT_MAX;
    for (int k = 0; k < N; k++) {
        double a = (double)k / N * 2 * M_PI;
        v[k] = sample(f, w, h, x + cos(a) * radius, y + sin(a) * radius);
        if (v[k] < lo) lo = v[k];
        if (v[k] > hi) hi = v[k];
    }
    if (!(hi - lo > 30)) return 0;
    float mid = (lo + hi) / 2;
    int bright[N];
    for (int k = 0; k < N; k++) bright[k] = v[k] > mid;
    int start = -1;
    for (int k = 0; k < N; k++) if (bright[k] != bright[(k + N - 1) % N]) { start = k; break; }
    if (start < 0) return 0;
    int changes = 0, run = 0, shortest = N;
    for (int step = 0; step < N; step++) {
        int k = (start + step) % N;
        run++;
        if (bright[k] != bright[(k + 1) % N]) { changes++; if (run < shortest) shortest = run; run = 0; }
    }
    return changes == 4 && shortest >= 3;
}

typedef struct { KSV2 p; float r; int index; } Candidate;

static int cmp_candidate(const void *a, const void *b) {
    const Candidate *x = a, *y = b;
    if (x->r != y->r) return x->r > y->r ? -1 : 1;
    return x->index - y->index;
}

/// Saddle points confirmed by a light/dark/light/dark ring. Returns the count written to out (max 1500).
static int candidates(const float *f, int w, int h, double sigma, KSV2 *out) {
    if (w <= 8 || h <= 8) return 0;
    float *resp = calloc((size_t)(w * h), sizeof(float));
    float maxR = 0;
    for (int y = 1; y < h - 1; y++)
        for (int x = 1; x < w - 1; x++) {
            int i = y * w + x;
            float c = f[i];
            float dxx = f[i - 1] - 2 * c + f[i + 1];
            float dyy = f[i - w] - 2 * c + f[i + w];
            float dxy = (f[i - w - 1] + f[i + w + 1] - f[i - w + 1] - f[i + w - 1]) / 4;
            float r = dxy * dxy - dxx * dyy;
            if (r > 0) { resp[i] = r; if (r > maxR) maxR = r; }
        }
    if (maxR <= 0) { free(resp); return 0; }
    float threshold = maxR * 0.02f;
    int rad = imax(2, (int)lround(sigma * 1.5));
    double ring = dmax(3.0, sigma * 2.5);
    int margin = rad + (int)ceil(ring) + 1;
    if (w <= 2 * margin + 1 || h <= 2 * margin + 1) { free(resp); return 0; }
    int cap = 4096, count = 0;
    Candidate *found = malloc(sizeof(Candidate) * (size_t)cap);
    for (int y = margin; y < h - margin; y++)
        for (int x = margin; x < w - margin; x++) {
            float r = resp[y * w + x];
            if (!(r > threshold)) continue;
            int isMax = 1;
            for (int dy = -rad; dy <= rad && isMax; dy++)
                for (int dx = -rad; dx <= rad; dx++) {
                    if (dx == 0 && dy == 0) continue;
                    float o = resp[(y + dy) * w + x + dx];
                    if (o > r || (o == r && (dy < 0 || (dy == 0 && dx < 0)))) { isMax = 0; break; }
                }
            if (!isMax || !ring_alternates(f, w, h, x, y, ring)) continue;
            float l = resp[y * w + x - 1], rr = resp[y * w + x + 1], u = resp[(y - 1) * w + x], d = resp[(y + 1) * w + x];
            float denX = l - 2 * r + rr, denY = u - 2 * r + d;
            double ox = denX < 0 ? dmax(-0.5, dmin(0.5, 0.5 * (l - rr) / denX)) : 0;
            double oy = denY < 0 ? dmax(-0.5, dmin(0.5, 0.5 * (u - d) / denY)) : 0;
            if (count == cap) { cap *= 2; found = realloc(found, sizeof(Candidate) * (size_t)cap); }
            found[count].p = ks_v2(x + ox, y + oy);
            found[count].r = r;
            found[count].index = count;
            count++;
        }
    qsort(found, (size_t)count, sizeof(Candidate), cmp_candidate);
    int n = imin(1500, count);
    for (int i = 0; i < n; i++) out[i] = found[i].p;
    free(found);
    free(resp);
    return n;
}

typedef struct {
    int span, off;  // grid cells are indexed (i + off, j + off) in a span × span table
    int *cell;      // point index, or -1
} Grid;

static int *grid_at(Grid *g, int i, int j) {
    int a = i + g->off, b = j + g->off;
    if (a < 0 || b < 0 || a >= g->span || b >= g->span) return NULL;
    return &g->cell[b * g->span + a];
}

static int grid_get(Grid *g, int i, int j) {
    int *c = grid_at(g, i, j);
    return c ? *c : -1;
}

static int predict(Grid *g, int ki, int kj, const KSV2 *pts, KSV2 *guess, double *spacing) {
    KSV2 sum = { 0, 0 };
    double sp = 0;
    int n = 0;
    static const int d4[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
    for (int k = 0; k < 4; k++) {
        int a = grid_get(g, ki - d4[k][0], kj - d4[k][1]), b = grid_get(g, ki - 2 * d4[k][0], kj - 2 * d4[k][1]);
        if (a >= 0 && b >= 0) {
            sum = vadd(sum, vsub(vmul(pts[a], 2), pts[b]));
            sp += vdist(pts[a], pts[b]);
            n++;
        }
    }
    if (n == 0) {
        static const int dd[4][2] = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } };
        for (int k = 0; k < 4; k++) {
            int a = grid_get(g, ki - dd[k][0], kj), b = grid_get(g, ki, kj - dd[k][1]), c = grid_get(g, ki - dd[k][0], kj - dd[k][1]);
            if (a >= 0 && b >= 0 && c >= 0) {
                sum = vsub(vadd(vadd(sum, pts[a]), pts[b]), pts[c]);
                sp += dmin(vdist(pts[a], pts[c]), vdist(pts[b], pts[c]));
                n++;
            }
        }
    }
    if (n == 0) return 0;
    *guess = vmul(sum, 1.0 / n);
    *spacing = sp / n;
    return 1;
}

typedef struct { double d; int index; } Ranked;

static int cmp_ranked(const void *a, const void *b) {
    const Ranked *x = a, *y = b;
    if (x->d != y->d) return x->d < y->d ? -1 : 1;
    return x->index - y->index;
}

static int assemble(const KSV2 *pts, int np, int columns, int rows, KSV2 *points, KSV2 *board, double *spacingOut) {
    int need = columns * rows;
    if (np < need) return 0;
    KSV2 centroid = { 0, 0 };
    for (int i = 0; i < np; i++) centroid = vadd(centroid, pts[i]);
    centroid = vmul(centroid, 1.0 / np);
    Ranked *seeds = malloc(sizeof(Ranked) * (size_t)np);
    Ranked *order = malloc(sizeof(Ranked) * (size_t)np);
    for (int i = 0; i < np; i++) { seeds[i].d = vdist(pts[i], centroid); seeds[i].index = i; }
    qsort(seeds, (size_t)np, sizeof(Ranked), cmp_ranked);
    int biggest = imax(columns, rows), smallest = imin(columns, rows);
    Grid g;
    g.off = biggest + 2;
    g.span = 2 * g.off + 1;
    g.cell = malloc(sizeof(int) * (size_t)(g.span * g.span));
    char *used = malloc((size_t)np);
    int (*frontier)[2] = malloc(sizeof(int[2]) * (size_t)(g.span * g.span));
    double *spacings = malloc(sizeof(double) * (size_t)need);
    int success = 0;

    for (int si = 0; si < imin(25, np) && !success; si++) {
        int seed = seeds[si].index;
        KSV2 s = pts[seed];
        int no = 0;
        for (int i = 0; i < np; i++) if (i != seed) { order[no].d = vdist(pts[i], s); order[no].index = i; no++; }
        qsort(order, (size_t)no, sizeof(Ranked), cmp_ranked);
        if (no == 0) continue;
        int n1 = order[0].index;
        KSV2 v1 = vsub(pts[n1], s);
        if (!(vlen(v1) > 2)) continue;
        int n2 = -1;
        for (int k = 0; k < imin(8, no); k++) {
            KSV2 v = vsub(pts[order[k].index], s);
            double ratio = vlen(v) / vlen(v1);
            if (ratio > 0.6 && ratio < 1.6 && fabs(vdot(vnorm(v), vnorm(v1))) < 0.5) { n2 = order[k].index; break; }
        }
        if (n2 < 0) continue;

        for (int i = 0; i < g.span * g.span; i++) g.cell[i] = -1;
        memset(used, 0, (size_t)np);
        *grid_at(&g, 0, 0) = seed; *grid_at(&g, 1, 0) = n1; *grid_at(&g, 0, 1) = n2;
        used[seed] = used[n1] = used[n2] = 1;
        int count = 3, iMin = 0, iMax = 1, jMin = 0, jMax = 1;
        int growing = 1, tooBig = 0;
        while (growing && !tooBig) {
            growing = 0;
            // Empty cells next to filled ones, in (j, i) order, from the grid as it is now.
            int nf = 0;
            for (int j = jMin - 1; j <= jMax + 1; j++)
                for (int i = iMin - 1; i <= iMax + 1; i++) {
                    int *c = grid_at(&g, i, j);
                    if (!c || *c >= 0) continue;
                    if (grid_get(&g, i + 1, j) >= 0 || grid_get(&g, i - 1, j) >= 0 || grid_get(&g, i, j + 1) >= 0 || grid_get(&g, i, j - 1) >= 0) {
                        frontier[nf][0] = i;
                        frontier[nf][1] = j;
                        nf++;
                    }
                }
            for (int f = 0; f < nf; f++) {
                int ki = frontier[f][0], kj = frontier[f][1];
                KSV2 guess;
                double sp;
                if (!predict(&g, ki, kj, pts, &guess, &sp) || !(sp > 1)) continue;
                int hit = -1;
                double hd = DBL_MAX;
                for (int q = 0; q < np; q++) {
                    if (used[q]) continue;
                    double dd = vdist(pts[q], guess);
                    if (dd < hd) { hd = dd; hit = q; }
                }
                if (hit < 0 || !(hd < 0.3 * sp)) continue;
                int *c = grid_at(&g, ki, kj);
                if (!c) continue;
                *c = hit;
                used[hit] = 1;
                count++;
                iMin = imin(iMin, ki); iMax = imax(iMax, ki); jMin = imin(jMin, kj); jMax = imax(jMax, kj);
                growing = 1;
            }
            int gw0 = iMax - iMin + 1, gh0 = jMax - jMin + 1;
            if (imax(gw0, gh0) > biggest || imin(gw0, gh0) > smallest) tooBig = 1;
        }
        if (tooBig) continue;
        int gw = iMax - iMin + 1, gh = jMax - jMin + 1;
        if (count != need || gw * gh != need || !((gw == columns && gh == rows) || (gw == rows && gh == columns))) continue;

#define AT(i, j) pts[grid_get(&g, (i) + iMin, (j) + jMin)]
        KSV2 ax = vsub(AT(1, 0), AT(0, 0)), ay = vsub(AT(0, 1), AT(0, 0));
        int mirror = vcross(ax, ay) < 0;
        int k = 0, ns = 0;
        for (int j = 0; j < gh; j++)
            for (int i = 0; i < gw; i++) {
                int src = mirror ? gw - 1 - i : i;
                points[k] = AT(src, j);
                board[k] = ks_v2(i, j);
                k++;
                if (i > 0) spacings[ns++] = vdist(AT(src, j), AT(mirror ? src + 1 : src - 1, j));
            }
#undef AT
        qsort(spacings, (size_t)ns, sizeof(double), cmp_double);
        *spacingOut = spacings[ns / 2];
        success = 1;
    }
    free(seeds); free(order); free(g.cell); free(used); free(frontier); free(spacings);
    return success;
}

static void refine(const uint8_t *img, int w, int h, KSV2 *pts, int n, int hw) {
    float *src = malloc(sizeof(float) * (size_t)(w * h));
    for (int i = 0; i < w * h; i++) src[i] = img[i];
    float *g = blur(src, w, h, 1.0);
    free(src);
    double sigma2 = 2 * pow(hw * 0.6, 2);
    for (int k = 0; k < n; k++) {
        KSV2 p = pts[k], q = p;
        for (int it = 0; it < 15; it++) {
            double a11 = 0, a12 = 0, a22 = 0, b1 = 0, b2 = 0;
            int cxI = (int)round(q.x), cyI = (int)round(q.y);
            for (int dy = -hw; dy <= hw; dy++) {
                int y = cyI + dy;
                if (y <= 0 || y >= h - 1) continue;
                for (int dx = -hw; dx <= hw; dx++) {
                    int x = cxI + dx;
                    if (x <= 0 || x >= w - 1) continue;
                    int i = y * w + x;
                    double gx = (g[i + 1] - g[i - 1]) / 2.0, gy = (g[i + w] - g[i - w]) / 2.0;
                    double wgt = exp(-(double)(dx * dx + dy * dy) / sigma2);
                    double gxx = gx * gx * wgt, gxy = gx * gy * wgt, gyy = gy * gy * wgt;
                    a11 += gxx; a12 += gxy; a22 += gyy;
                    b1 += gxx * x + gxy * y;
                    b2 += gxy * x + gyy * y;
                }
            }
            double det = a11 * a22 - a12 * a12;
            if (!(det > 1e-9 * dmax(1, a11 * a22))) break;
            KSV2 next = ks_v2((a22 * b1 - a12 * b2) / det, (a11 * b2 - a12 * b1) / det);
            if (!(vdist(next, p) <= hw)) break;
            double moved = vdist(next, q);
            q = next;
            if (moved < 0.01) break;
        }
        pts[k] = q;
    }
    free(g);
}

static uint8_t *downscale(const uint8_t *px, int w, int h, int factor, int *ow, int *oh) {
    int sw = imax(1, w / factor), sh = imax(1, h / factor);
    uint8_t *o = malloc((size_t)(sw * sh));
    int area = factor * factor;
    for (int y = 0; y < sh; y++)
        for (int x = 0; x < sw; x++) {
            int s = 0;
            for (int dy = 0; dy < factor; dy++) {
                const uint8_t *row = px + (y * factor + dy) * w + x * factor;
                for (int dx = 0; dx < factor; dx++) s += row[dx];
            }
            o[y * sw + x] = (uint8_t)(s / area);
        }
    *ow = sw;
    *oh = sh;
    return o;
}

int ks_board_detect(const uint8_t *gray, int w, int h, int cols, int rows, KSBoardView *out) {
    memset(out, 0, sizeof *out);
    if (cols < 3 || rows < 3 || w < 32 || h < 32) return 0;
    int longest = imax(w, h);
    int factors[3], nf = 0;
    int targets[3] = { 800, 1300, 520 };
    for (int t = 0; t < 3; t++) {
        int f = imax(1, (int)lround((double)longest / targets[t]));
        int dup = 0;
        for (int k = 0; k < nf; k++) if (factors[k] == f) dup = 1;
        if (!dup) factors[nf++] = f;
    }
    int need = cols * rows;
    KSV2 *found = malloc(sizeof(KSV2) * 1500);
    KSV2 *points = malloc(sizeof(KSV2) * (size_t)need);
    KSV2 *board = malloc(sizeof(KSV2) * (size_t)need);
    double sigmas[3] = { 1.2, 2.0, 3.2 };
    int ok = 0;
    for (int fi = 0; fi < nf && !ok; fi++) {
        int f = factors[fi], sw, sh;
        uint8_t *small = f > 1 ? downscale(gray, w, h, f, &sw, &sh) : NULL;
        const uint8_t *s8 = small ? small : gray;
        if (!small) { sw = w; sh = h; }
        float *smooth = malloc(sizeof(float) * (size_t)(sw * sh));
        for (int i = 0; i < sw * sh; i++) smooth[i] = s8[i];
        for (int si = 0; si < 3 && !ok; si++) {
            float *blurred = blur(smooth, sw, sh, sigmas[si]);
            int n = candidates(blurred, sw, sh, sigmas[si], found);
            double spacing = 0;
            if (n >= need && assemble(found, n, cols, rows, points, board, &spacing)) {
                for (int i = 0; i < need; i++) points[i] = ks_v2((points[i].x + 0.5) * f - 0.5, (points[i].y + 0.5) * f - 0.5);
                refine(gray, w, h, points, need, imax(3, (int)(spacing * f * 0.3)));
                ok = 1;
            }
            free(blurred);
        }
        free(smooth);
        free(small);
    }
    free(found);
    if (ok) {
        out->image = points;
        out->board = board;
        out->count = need;
        out->width = w;
        out->height = h;
    } else {
        free(points);
        free(board);
    }
    return ok;
}

// MARK: - Alignment

int ks_otsu(const uint8_t *values, int count) {
    int hist[256] = { 0 };
    for (int i = 0; i < count; i++) hist[values[i]]++;
    double total = count, sumAll = 0;
    for (int i = 0; i < 256; i++) sumAll += i * (double)hist[i];
    double sumB = 0, wB = 0, best = -1;
    int threshold = 128;
    for (int t = 0; t < 256; t++) {
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

static uint8_t px_at(const uint8_t *g, int w, int h, int x, int y) {
    return g[imin(h - 1, imax(0, y)) * w + imin(w - 1, imax(0, x))];
}

int ks_snap_to_mark(const uint8_t *gray, int w, int h, KSV2 point, double radius, KSV2 *out) {
    int rad = imax(4, (int)lround(radius));
    KSV2 c = point;
    uint8_t *values = malloc((size_t)((2 * rad + 1) * (2 * rad + 1)));
    int ok = 1;
    for (int it = 0; it < 6 && ok; it++) {
        int x0 = imax(0, (int)c.x - rad), x1 = imin(w - 1, (int)c.x + rad);
        int y0 = imax(0, (int)c.y - rad), y1 = imin(h - 1, (int)c.y + rad);
        if (x1 <= x0 + 2 || y1 <= y0 + 2) { ok = 0; break; }
        int n = 0;
        uint8_t lo = 255, hi = 0;
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++) {
                uint8_t v = px_at(gray, w, h, x, y);
                values[n++] = v;
                if (v < lo) lo = v;
                if (v > hi) hi = v;
            }
        if (hi - lo < 25) { ok = 0; break; }
        double t = ks_otsu(values, n);
        double sx = 0, sy = 0, sw = 0, r2 = (double)rad * rad;
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++) {
                double dx = x - c.x, dy = y - c.y;
                if (dx * dx + dy * dy > r2) continue;
                double v = px_at(gray, w, h, x, y);
                if (v < t) { double wgt = t - v; sx += x * wgt; sy += y * wgt; sw += wgt; }
            }
        if (sw <= 0) { ok = 0; break; }
        KSV2 next = ks_v2(sx / sw, sy / sw);
        double moved = vdist(next, c);
        c = next;
        if (moved < 0.05) break;
    }
    free(values);
    if (!ok || vdist(c, point) > radius * 1.5) return 0;
    *out = c;
    return 1;
}

int ks_fit_alignment(const KSV2 *image, const KSV2 *bed, int n, KSHomography *out, double *rms, double *maxErr) {
    if (n < 4 || !ks_h_fit(image, bed, n, out)) return 0;
    double sum = 0, worst = 0;
    for (int i = 0; i < n; i++) {
        KSV2 p;
        if (!ks_h_apply(out, image[i], &p)) return 0;
        double e = vdist(p, bed[i]);
        sum += e * e;
        worst = dmax(worst, e);
    }
    *rms = sqrt(sum / n);
    *maxErr = worst;
    return 1;
}

void ks_predict_marks(const KSV2 *marks, int n, const KSV2 *clicks, const int *clicked, KSV2 *out, int *have) {
    KSV2 *bed = malloc(sizeof(KSV2) * (size_t)(n > 0 ? n : 1)), *img = malloc(sizeof(KSV2) * (size_t)(n > 0 ? n : 1));
    int k = 0;
    for (int i = 0; i < n; i++) {
        have[i] = 0;
        if (clicked[i]) { bed[k] = marks[i]; img[k] = clicks[i]; k++; }
    }
    if (k >= 3) {
        KSHomography hm;
        int useH = k >= 4 && ks_h_fit(bed, img, k, &hm);
        KSV2 a = bed[0], b = bed[1], c = bed[2];
        double det = vcross(vsub(b, a), vsub(c, a));
        if (useH || fabs(det) >= 1e-6) {
            for (int i = 0; i < n; i++) {
                if (clicked[i]) continue;
                if (useH) {
                    have[i] = ks_h_apply(&hm, marks[i], &out[i]);
                } else {
                    KSV2 d = vsub(marks[i], a);
                    double u = vcross(d, vsub(c, a)) / det, v = vcross(vsub(b, a), d) / det;
                    out[i] = vadd(vadd(img[0], vmul(vsub(img[1], img[0]), u)), vmul(vsub(img[2], img[0]), v));
                    have[i] = 1;
                }
            }
        }
    }
    free(bed);
    free(img);
}

// MARK: - Setup

void ks_setup_prepare(KSSetup *s) {
    s->prepared = 1;
    s->hasLensAtAlignment = 0;
    if (s->hasAlignment) {
        if (!ks_h_invert(&s->imageToBed, &s->bedToImage)) s->hasAlignment = 0;
        if (s->hasLens && ks_lens_scaled(&s->lens, s->alignWidth, s->alignHeight, &s->lensAtAlignment)) {
            s->hasLensAtAlignment = 1;
            s->coveredR2 = ks_lens_covered_r2(&s->lensAtAlignment);
        }
    }
}

int ks_setup_image_to_bed(const KSSetup *s, KSV2 q, int w, int h, KSV2 *bed) {
    if (!s->hasAlignment || !s->prepared || w <= 0 || h <= 0) return 0;
    double sx = (double)s->alignWidth / w, sy = (double)s->alignHeight / h;
    KSV2 raw = ks_v2((q.x + 0.5) * sx - 0.5, (q.y + 0.5) * sy - 0.5);
    KSV2 ideal = s->hasLensAtAlignment ? ks_lens_undistort_pixel(&s->lensAtAlignment, raw) : raw;
    return ks_h_apply(&s->imageToBed, ideal, bed);
}

int ks_setup_bed_to_image(const KSSetup *s, KSV2 bed, int w, int h, KSV2 *q) {
    if (!s->hasAlignment || !s->prepared || w <= 0 || h <= 0) return 0;
    KSV2 ideal;
    if (!ks_h_apply(&s->bedToImage, bed, &ideal)) return 0;
    KSV2 raw = ideal;
    if (s->hasLensAtAlignment) {
        const KSLens *l = &s->lensAtAlignment;
        double nx = (ideal.x - l->cx) / l->fx, ny = (ideal.y - l->cy) / l->fy;
        if (nx * nx + ny * ny > s->coveredR2 * 1.02) return 0;
        raw = ks_lens_distort_pixel(l, ideal);
    }
    double sx = (double)w / s->alignWidth, sy = (double)h / s->alignHeight;
    *q = ks_v2((raw.x + 0.5) * sx - 0.5, (raw.y + 0.5) * sy - 0.5);
    return finite2(*q);
}
