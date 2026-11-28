// Camera registration math for KerfSender on macOS, in plain C so it builds for 10.12 and can be tested
// with any C compiler (senders/mac/Tests/camera_math_test.c). Ported from KerfKutter's
// Sources/KerfCore/CameraCalibration.swift and Checkerboard.swift; the Windows sender has the same code in C#
// (senders/windows/KerfSender/CameraCore.cs).
//
// Pipeline: raw camera pixel -> lens undistortion -> homography -> machine millimetres.

#ifndef KS_CAMERA_MATH_H
#define KS_CAMERA_MATH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { double x, y; } KSV2;

static inline KSV2 ks_v2(double x, double y) { KSV2 v = { x, y }; return v; }

/// Solves A x = b for a square n×n row-major A. Returns 1 on success.
int ks_solve(const double *a, const double *b, int n, double *x);

typedef struct { double m[9]; } KSHomography;

int ks_h_apply(const KSHomography *h, KSV2 p, KSV2 *out);
int ks_h_invert(const KSHomography *h, KSHomography *out);
/// Least-squares homography taking src[i] to dst[i] (n >= 4, not all on a line).
int ks_h_fit(const KSV2 *src, const KSV2 *dst, int n, KSHomography *out);

/// Focal length, centre and distortion (radial k1–k3, tangential p1, p2) for one picture size.
typedef struct {
    int width, height;
    double fx, fy, cx, cy, k1, k2, k3, p1, p2;
    double rms;
    int views;
} KSLens;

KSV2 ks_lens_distort(const KSLens *l, KSV2 p);
KSV2 ks_lens_undistort(const KSLens *l, KSV2 d);
KSV2 ks_lens_undistort_pixel(const KSLens *l, KSV2 q);
KSV2 ks_lens_distort_pixel(const KSLens *l, KSV2 q);
/// The lens at another picture size of the same shape. Returns 0 when the shape differs.
int ks_lens_scaled(const KSLens *l, int w, int h, KSLens *out);
double ks_lens_covered_r2(const KSLens *l);
double ks_lens_corner_distortion(const KSLens *l);

/// Checkerboard corners found in one picture (arrays are malloc'd; free with ks_board_free).
typedef struct {
    KSV2 *image;
    KSV2 *board;
    int count;
    int width, height;
} KSBoardView;

/// Finds a board with cols × rows inner corners in an 8-bit grayscale picture. Returns 1 when found.
int ks_board_detect(const uint8_t *gray, int w, int h, int cols, int rows, KSBoardView *out);
void ks_board_free(KSBoardView *v);

enum { KS_MIN_VIEWS = 3 };
/// Calibrates a lens from n views (all the same picture size). Returns 1 on success.
int ks_lens_calibrate(const KSBoardView *views, int n, KSLens *out);

/// Otsu threshold of `count` values.
int ks_otsu(const uint8_t *values, int count);
/// The centre of the dark mark near p. Returns 1 when there's a clear mark.
int ks_snap_to_mark(const uint8_t *gray, int w, int h, KSV2 p, double radius, KSV2 *out);
/// Alignment homography from clicked (undistorted) pixels to bed mm, with its errors in mm.
int ks_fit_alignment(const KSV2 *image, const KSV2 *bed, int n, KSHomography *out, double *rms, double *maxErr);
/// Predicts where unclicked marks are from clicked ones (affine from 3, perspective from 4+).
/// clicked[i] says whether clicks[i] is set; on return have[i] says whether out[i] was predicted.
void ks_predict_marks(const KSV2 *marks, int n, const KSV2 *clicks, const int *clicked, KSV2 *out, int *have);

/// A camera's lens and its alignment to the bed.
typedef struct {
    int hasLens;
    KSLens lens;
    int hasAlignment;
    int alignWidth, alignHeight;
    KSHomography imageToBed;
    double rms, maxErr;
    double date; // seconds since 1970
    // Filled by ks_setup_prepare:
    int prepared;
    int hasLensAtAlignment;
    KSLens lensAtAlignment;
    KSHomography bedToImage;
    double coveredR2;
} KSSetup;

/// Must be called after changing the lens or alignment.
void ks_setup_prepare(KSSetup *s);
/// Raw pixel (picture w×h) to machine mm.
int ks_setup_image_to_bed(const KSSetup *s, KSV2 q, int w, int h, KSV2 *bed);
/// Machine mm to raw pixel (picture w×h). Returns 0 where the camera can't see it.
int ks_setup_bed_to_image(const KSSetup *s, KSV2 bed, int w, int h, KSV2 *q);

#ifdef __cplusplus
}
#endif

#endif
