// Checks KSCameraMath on synthetic pictures from a known camera. Runs anywhere:
//     cc -O2 -std=c99 -I senders/mac/KerfSender senders/mac/KerfSender/KSCameraMath.c senders/mac/Tests/camera_math_test.c -lm -o /tmp/camtest && /tmp/camtest
// senders/mac/build.sh test does the same.

#define _POSIX_C_SOURCE 200809L
#include "KSCameraMath.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <time.h>

static int failures;

static void check(int ok, const char *what) {
    printf("%s%s\n", ok ? "ok   " : "FAIL ", what);
    if (!ok) failures++;
}

enum { W = 1280, H = 720 };
static const KSLens truth = { W, H, 900, 900, 652, 351, -0.28, 0.09, 0, 0, 0, 0, 0 };

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static void mul(const double *a, const double *b, double *o) {
    double t[9];
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) t[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    memcpy(o, t, sizeof t);
}

static void rot(double rx, double ry, double rz, double *o) {
    double cx = cos(rx), sx = sin(rx), cy = cos(ry), sy = sin(ry), cz = cos(rz), sz = sin(rz);
    double Rx[9] = { 1, 0, 0, 0, cx, -sx, 0, sx, cx };
    double Ry[9] = { cy, 0, sy, 0, 1, 0, -sy, 0, cy };
    double Rz[9] = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 };
    double t[9];
    mul(Ry, Rx, t);
    mul(Rz, t, o);
}

static void invert(const double *m, double *o) {
    double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g, det = a * A + b * B + c * C;
    double inv[9] = { A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d };
    for (int k = 0; k < 9; k++) o[k] = inv[k] / det;
}

/// A board with cols × rows inner corners (squares from -1 to cols) seen by the true camera.
static uint8_t *render_board(int cols, int rows, const double *pose) {
    double R[9];
    rot(pose[0], pose[1], pose[2], R);
    double tx = pose[3], ty = pose[4], tz = pose[5];
    uint8_t *px = malloc(W * H);
    for (int v = 0; v < H; v++)
        for (int u = 0; u < W; u++) {
            int sum = 0;
            for (int s = 0; s < 4; s++) {
                double uu = u - 0.25 + 0.5 * (s % 2), vv = v - 0.25 + 0.5 * (s / 2);
                KSV2 n = ks_lens_undistort(&truth, ks_v2((uu - truth.cx) / truth.fx, (vv - truth.cy) / truth.fy));
                double a[9] = { R[0], R[1], -n.x, R[3], R[4], -n.y, R[6], R[7], -1.0 }, inv[9];
                invert(a, inv);
                double bx = -(inv[0] * tx + inv[1] * ty + inv[2] * tz);
                double by = -(inv[3] * tx + inv[4] * ty + inv[5] * tz);
                int val;
                if (bx < -2 || by < -2 || bx > cols + 1 || by > rows + 1) val = 120;
                else if (bx < -1 || by < -1 || bx > cols || by > rows) val = 235;
                else val = ((((int)floor(bx) + (int)floor(by)) & 1) == 0) ? 30 : 230;
                sum += val;
            }
            px[v * W + u] = (uint8_t)(sum / 4);
        }
    return px;
}

static void test_homography(void) {
    KSHomography t = { { 0.31, 0.02, 12.0, -0.015, 0.29, 30.0, 0.00002, -0.00001, 1.0 } };
    KSV2 src[9], dst[9];
    for (int i = 0; i < 9; i++) {
        src[i] = ks_v2(100 + 130 * (i % 3), 80 + 240 * (i / 3));
        ks_h_apply(&t, src[i], &dst[i]);
    }
    KSHomography fit, inv;
    int ok = ks_h_fit(src, dst, 9, &fit);
    double worst = 0;
    for (int i = 0; i < 9 && ok; i++) {
        KSV2 q;
        ks_h_apply(&fit, src[i], &q);
        worst = fmax(worst, hypot(q.x - dst[i].x, q.y - dst[i].y));
    }
    check(ok && worst < 1e-6, "homography fit reproduces its points");
    KSV2 back;
    check(ks_h_invert(&fit, &inv) && ks_h_apply(&inv, dst[4], &back) && hypot(back.x - src[4].x, back.y - src[4].y) < 1e-6, "homography inverse");
}

static void test_lens(void) {
    KSV2 p = ks_v2(40, 690);
    KSV2 u = ks_lens_undistort_pixel(&truth, p);
    KSV2 d = ks_lens_distort_pixel(&truth, u);
    check(hypot(d.x - p.x, d.y - p.y) < 1e-6, "lens undistort then distort returns the pixel");
    KSLens half;
    check(ks_lens_scaled(&truth, 640, 360, &half) && fabs(half.fx - 450) < 1e-9, "lens scales with the picture");
    check(!ks_lens_scaled(&truth, 640, 480, &half), "lens refuses a different picture shape");
}

static void test_calibration(void) {
    enum { COLS = 9, ROWS = 6, POSES = 6 };
    double poses[POSES][6] = {
        { 0.05, -0.1, 0.02, -4.5, -2.5, 14.0 },
        { -0.35, 0.1, -0.1, -3.5, -2.2, 13.0 },
        { 0.3, 0.3, 0.15, -6.0, -3.0, 15.0 },
        { 0.0, -0.4, -0.2, -1.5, -3.5, 13.5 },
        { 0.25, -0.25, 0.3, -7.5, -1.5, 16.0 },
        { -0.2, 0.35, 0.05, -4.0, -2.5, 13.5 },
    };
    KSBoardView views[POSES];
    int found = 0;
    double t0 = now_ms();
    for (int i = 0; i < POSES; i++) {
        uint8_t *img = render_board(COLS, ROWS, poses[i]);
        if (ks_board_detect(img, W, H, COLS, ROWS, &views[found])) found++;
        free(img);
    }
    char msg[200];
    snprintf(msg, sizeof msg, "checkerboard found in %d of %d pictures (%.0f ms each with rendering)", found, POSES, (now_ms() - t0) / POSES);
    check(found == POSES, msg);
    check(found > 0 && views[0].count == COLS * ROWS, "all 54 corners found");
    KSLens lens;
    t0 = now_ms();
    int ok = ks_lens_calibrate(views, found, &lens);
    snprintf(msg, sizeof msg, "lens calibrates (%.0f ms)", now_ms() - t0);
    check(ok, msg);
    if (ok) {
        snprintf(msg, sizeof msg, "corner fit error %.3f px", lens.rms);
        check(lens.rms < 0.3, msg);
        snprintf(msg, sizeof msg, "focal length %.1f (true 900)", lens.fx);
        check(fabs(lens.fx - truth.fx) / truth.fx < 0.03, msg);
        KSV2 probes[6] = { { 250, 200 }, { 1000, 120 }, { 250, 500 }, { 1050, 520 }, { 640, 100 }, { 640, 360 } };
        double worst = 0;
        for (int i = 0; i < 6; i++) {
            KSV2 a = ks_lens_undistort_pixel(&lens, probes[i]), b = ks_lens_undistort_pixel(&truth, probes[i]);
            double ax = (a.x - lens.cx) / lens.fx, ay = (a.y - lens.cy) / lens.fy;
            double bx = (b.x - truth.cx) / truth.fx, by = (b.y - truth.cy) / truth.fy;
            worst = fmax(worst, hypot(ax - bx, ay - by) * truth.fx);
        }
        snprintf(msg, sizeof msg, "undistortion matches the true lens within %.2f px where the boards were", worst);
        check(worst < 3, msg);
    }
    for (int i = 0; i < found; i++) ks_board_free(&views[i]);
}

static void stamp(uint8_t *px, KSV2 raw) {
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) {
            int x = (int)lround(raw.x) + dx, y = (int)lround(raw.y) + dy;
            if (x >= 0 && y >= 0 && x < W && y < H) px[y * W + x] = 40;
        }
}

static void test_alignment(void) {
    KSHomography bedToIdeal = { { 2.2, 0.05, 210.0, -0.04, 2.15, -60.0, 0.00003, 0.00002, 1.0 } };
    KSV2 marks[9];
    for (int j = 0; j < 3; j++)
        for (int i = 0; i < 3; i++) marks[j * 3 + i] = ks_v2(40 + 160 * i, 40 + 160 * j);
    uint8_t *px = malloc(W * H);
    memset(px, 210, W * H);
    for (int k = 0; k < 9; k++) {
        double r = 6;
        KSV2 m = marks[k];
        for (double t = -r; t <= r; t += 0.12) {
            KSV2 ideal, raw;
            ks_h_apply(&bedToIdeal, ks_v2(m.x + t, m.y), &ideal);
            raw = ks_lens_distort_pixel(&truth, ideal);
            stamp(px, raw);
            ks_h_apply(&bedToIdeal, ks_v2(m.x, m.y + t), &ideal);
            raw = ks_lens_distort_pixel(&truth, ideal);
            stamp(px, raw);
        }
        for (double a = 0; a < 2 * M_PI; a += 0.02) {
            KSV2 ideal;
            ks_h_apply(&bedToIdeal, ks_v2(m.x + 0.75 * r * cos(a), m.y + 0.75 * r * sin(a)), &ideal);
            stamp(px, ks_lens_distort_pixel(&truth, ideal));
        }
    }
    KSV2 clicks[9], trueRaw[9];
    double worstSnap = 0;
    int all = 1;
    for (int k = 0; k < 9; k++) {
        KSV2 ideal;
        ks_h_apply(&bedToIdeal, marks[k], &ideal);
        trueRaw[k] = ks_lens_distort_pixel(&truth, ideal);
        if (!ks_snap_to_mark(px, W, H, ks_v2(trueRaw[k].x + 6, trueRaw[k].y - 5), 28, &clicks[k])) { all = 0; continue; }
        worstSnap = fmax(worstSnap, hypot(clicks[k].x - trueRaw[k].x, clicks[k].y - trueRaw[k].y));
    }
    char msg[200];
    snprintf(msg, sizeof msg, "clicks snap to the mark centres (worst %.2f px)", worstSnap);
    check(all && worstSnap < 1.0, msg);

    int clicked[9] = { 1, 1, 0, 1, 0, 0, 0, 0, 0 }, have[9];
    KSV2 guess[9];
    ks_predict_marks(marks, 9, trueRaw, clicked, guess, have);
    double worstGuess = 0;
    for (int k = 0; k < 9; k++) if (have[k]) worstGuess = fmax(worstGuess, hypot(guess[k].x - trueRaw[k].x, guess[k].y - trueRaw[k].y));
    snprintf(msg, sizeof msg, "the remaining marks are predicted from three clicks (within %.0f px)", worstGuess);
    check(have[8] && worstGuess < 40, msg);

    KSV2 undist[9];
    for (int k = 0; k < 9; k++) undist[k] = ks_lens_undistort_pixel(&truth, clicks[k]);
    KSHomography h;
    double rms = 0, maxErr = 0;
    int ok = ks_fit_alignment(undist, marks, 9, &h, &rms, &maxErr);
    snprintf(msg, sizeof msg, "alignment fits the marks within %.2f mm", maxErr);
    check(ok && maxErr < 0.5, msg);

    KSSetup s;
    memset(&s, 0, sizeof s);
    s.hasLens = 1;
    s.lens = truth;
    s.hasAlignment = 1;
    s.alignWidth = W;
    s.alignHeight = H;
    s.imageToBed = h;
    ks_setup_prepare(&s);
    KSV2 probe = ks_v2(123, 287), q, bed;
    check(ks_setup_bed_to_image(&s, probe, W, H, &q) && ks_setup_image_to_bed(&s, q, W, H, &bed) && hypot(bed.x - probe.x, bed.y - probe.y) < 1e-3,
          "bed -> picture -> bed round trip");
    check(ks_setup_bed_to_image(&s, probe, W / 2, H / 2, &q) && ks_setup_image_to_bed(&s, q, W / 2, H / 2, &bed) && hypot(bed.x - probe.x, bed.y - probe.y) < 1e-3,
          "the mapping works at half the picture size");
    free(px);
}

int main(void) {
    test_homography();
    test_lens();
    test_calibration();
    test_alignment();
    printf(failures == 0 ? "All checks passed.\n" : "%d check(s) failed.\n", failures);
    return failures == 0 ? 0 : 1;
}
