#import "KerfSender.h"
#import "KSCameraMath.h"

// Reads a job's toolpath back from its G-code and writes it moved and turned to a new place on the bed.
// Same rules as senders/windows/KerfSender/CameraCore.cs (GcodeToolpath).

typedef struct {
    char letter;
    double value;
    const char *text; // number text, not NUL-terminated
    int textLength;
} KSWord;

/// Splits a code line (no comments) into letter + number words. Returns the count (at most max).
static int KSWords(const char *s, KSWord *out, int max) {
    int n = 0;
    size_t i = 0, len = strlen(s);
    while (i < len && n < max) {
        char ch = (char)toupper((unsigned char)s[i]);
        if (ch < 'A' || ch > 'Z') { i++; continue; }
        size_t j = i + 1;
        while (j < len && (s[j] == ' ' || s[j] == '\t')) j++;
        size_t start = j;
        while (j < len && (isdigit((unsigned char)s[j]) || s[j] == '.' || s[j] == '-' || s[j] == '+')) j++;
        char buf[64];
        size_t tl = MIN(j - start, sizeof buf - 1);
        memcpy(buf, s + start, tl);
        buf[tl] = 0;
        out[n].letter = ch;
        out[n].value = tl ? strtod(buf, NULL) : 0;
        out[n].text = s + start;
        out[n].textLength = (int)(j - start);
        n++;
        i = j;
    }
    return n;
}

/// G codes after which X/Y are not a move to a place on the bed.
static BOOL KSSkipsXY(int g10) {
    return g10 == 530 || g10 == 280 || g10 == 300 || g10 == 100 || g10 == 920 || g10 == 921 || g10 == 922 || g10 == 923;
}

@implementation KSToolpath {
    NSMutableArray<NSMutableData *> *_burns;
}

- (NSArray<NSData *> *)burns { return _burns; }
- (BOOL)isEmpty { return _minX > _maxX; }

static NSString *KSCode(NSString *line) {
    NSString *c = [KSJob cleanGcodeLine:line];
    return (c && ![c hasPrefix:@"$"]) ? c : nil;
}

+ (KSToolpath *)toolpathFromLines:(NSArray<NSString *> *)lines {
    KSToolpath *t = [[KSToolpath alloc] init];
    t->_burns = [NSMutableArray array];
    t->_minX = t->_minY = DBL_MAX;
    t->_maxX = t->_maxY = -DBL_MAX;
    double x = 0, y = 0, sVal = 0;
    BOOL relative = NO, sSeen = NO, on = YES;
    int motion = 0;
    NSMutableData *current = nil;
    KSWord w[64];
    for (NSString *raw in lines) {
        NSString *code = KSCode(raw);
        if (!code) continue;
        int n = KSWords(code.UTF8String, w, 64);
        BOOL skip = NO;
        for (int k = 0; k < n; k++) {
            if (w[k].letter == 'G') {
                int g = (int)lround(w[k].value * 10);
                if (g == 0 || g == 10 || g == 20 || g == 30) motion = g / 10;
                else if (g == 900) relative = NO;
                else if (g == 910) { relative = YES; t->_hasRelativeMoves = YES; }
                else if (KSSkipsXY(g)) skip = YES;
            } else if (w[k].letter == 'M') {
                if (w[k].value == 3 || w[k].value == 4) on = YES;
                else if (w[k].value == 5) on = NO;
            } else if (w[k].letter == 'S') {
                sVal = w[k].value;
                sSeen = YES;
            }
        }
        if (skip) { current = nil; continue; }
        double nx = x, ny = y;
        BOOL moved = NO;
        for (int k = 0; k < n; k++) {
            if (w[k].letter == 'X') { nx = relative ? x + w[k].value : w[k].value; moved = YES; }
            else if (w[k].letter == 'Y') { ny = relative ? y + w[k].value : w[k].value; moved = YES; }
        }
        if (!moved) continue;
        BOOL burn = motion != 0 && on && (!sSeen || sVal > 0);
        if (burn) {
            if (!current) {
                current = [NSMutableData data];
                KSV2 start = ks_v2(x, y);
                [current appendBytes:&start length:sizeof start];
                [t->_burns addObject:current];
                [t extendX:x y:y];
            }
            KSV2 p = ks_v2(nx, ny);
            NSUInteger c = current.length / sizeof(KSV2);
            KSV2 *pts = current.mutableBytes;
            BOOL merged = NO;
            if (c >= 2) {
                KSV2 a = pts[c - 2], b = pts[c - 1];
                double d1x = b.x - a.x, d1y = b.y - a.y, d2x = p.x - b.x, d2y = p.y - b.y;
                double cross = d1x * d2y - d1y * d2x, dot = d1x * d2x + d1y * d2y;
                double l1 = hypot(d1x, d1y), l2 = hypot(d2x, d2y);
                if (fabs(cross) < 1e-6 * MAX(1, l1 * l2) && dot > 0) { pts[c - 1] = p; merged = YES; }
            }
            if (!merged) [current appendBytes:&p length:sizeof p];
            [t extendX:nx y:ny];
        } else {
            current = nil;
        }
        x = nx;
        y = ny;
    }
    NSInteger count = 0;
    for (NSData *b in t->_burns) count += (NSInteger)(b.length / sizeof(KSV2));
    t->_pointCount = count;
    return t;
}

- (void)extendX:(double)x y:(double)y {
    _minX = MIN(_minX, x);
    _maxX = MAX(_maxX, x);
    _minY = MIN(_minY, y);
    _maxY = MAX(_maxY, y);
}

+ (NSString *)format:(double)v {
    NSString *s = [NSString stringWithFormat:@"%.3f", v];
    while ([s hasSuffix:@"0"]) s = [s substringToIndex:s.length - 1];
    if ([s hasSuffix:@"."]) s = [s substringToIndex:s.length - 1];
    if ([s isEqualToString:@"-0"]) s = @"0";
    return s;
}

+ (NSArray<NSString *> *)transformLines:(NSArray<NSString *> *)lines pivotX:(double)px pivotY:(double)py
                                degrees:(double)degrees dx:(double)dx dy:(double)dy error:(NSString **)error {
    double a = degrees * M_PI / 180, ca = cos(a), sa = sin(a);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:lines.count];
    double x = 0, y = 0;
    KSWord w[64];
    for (NSString *raw in lines) {
        NSString *code = KSCode(raw);
        if (!code) { [out addObject:raw]; continue; }
        const char *cs = code.UTF8String;
        int n = KSWords(cs, w, 64);
        BOOL skip = NO, hasX = NO, hasY = NO, hasI = NO, hasIJ = NO;
        double nx = x, ny = y, ii = 0, jj = 0;
        for (int k = 0; k < n; k++) {
            char L = w[k].letter;
            if (L == 'G') {
                int g = (int)lround(w[k].value * 10);
                if (g == 910) {
                    if (error) *error = @"The job uses relative moves (G91), so it can't be placed with the camera.";
                    return nil;
                }
                if (KSSkipsXY(g)) skip = YES;
            } else if (L == 'X') { hasX = YES; nx = w[k].value; }
            else if (L == 'Y') { hasY = YES; ny = w[k].value; }
            else if (L == 'I') { hasI = hasIJ = YES; ii = w[k].value; }
            else if (L == 'J') { hasIJ = YES; jj = w[k].value; }
        }
        if (skip || (!hasX && !hasY && !hasIJ)) { [out addObject:raw]; continue; }
        double ddx = nx - px, ddy = ny - py;
        double qx = px + ddx * ca - ddy * sa + dx, qy = py + ddx * sa + ddy * ca + dy;
        NSMutableString *s = [NSMutableString string];
        BOOL wroteXY = NO;
        for (int k = 0; k < n; k++) {
            char L = w[k].letter;
            if (L == 'X' || L == 'Y') {
                if (!wroteXY) {
                    [s appendFormat:@"%@X%@ Y%@", s.length ? @" " : @"", [self format:qx], [self format:qy]];
                    wroteXY = YES;
                }
            } else if (L == 'I' || L == 'J') {
                if (L == 'I' || !hasI) {
                    double ri = ii * ca - jj * sa, rj = ii * sa + jj * ca;
                    [s appendFormat:@"%@I%@ J%@", s.length ? @" " : @"", [self format:ri], [self format:rj]];
                }
            } else {
                NSString *num = [[NSString alloc] initWithBytes:w[k].text length:(NSUInteger)w[k].textLength encoding:NSUTF8StringEncoding] ?: @"";
                [s appendFormat:@"%@%c%@", s.length ? @" " : @"", L, num];
            }
        }
        [out addObject:s];
        if (hasX || hasY) { x = nx; y = ny; }
    }
    return out;
}

+ (NSArray<NSString *> *)targetGcodeForMarks:(NSArray<NSValue *> *)marks size:(double)size feed:(double)feed
                                       power:(double)powerPercent sMax:(double)sMax {
    double s = MAX(0, MIN(100, powerPercent)) / 100 * sMax;
    double r = MAX(1, size / 2);
    NSMutableArray *out = [NSMutableArray arrayWithObjects:@"; KerfSender camera target", @"G90", @"G21", @"M5", @"M4 S0", nil];
    NSString *burn = [NSString stringWithFormat:@" S%@ F%@", [self format:s], [self format:MAX(1, feed)]];
    void (^path)(const KSV2 *, int) = ^(const KSV2 *p, int n) {
        [out addObject:[NSString stringWithFormat:@"G0 X%@ Y%@", [self format:p[0].x], [self format:p[0].y]]];
        for (int i = 1; i < n; i++)
            [out addObject:[NSString stringWithFormat:@"G1 X%@ Y%@%@", [self format:p[i].x], [self format:p[i].y], i == 1 ? burn : @""]];
    };
    void (^circle)(KSV2, double, double) = ^(KSV2 c, double rad, double step) {
        int n = MAX(12, (int)ceil(2 * M_PI * rad / step));
        KSV2 *p = malloc(sizeof(KSV2) * (size_t)(n + 1));
        for (int i = 0; i <= n; i++) {
            double a = 2 * M_PI * i / n;
            p[i] = ks_v2(c.x + rad * cos(a), c.y + rad * sin(a));
        }
        path(p, n + 1);
        free(p);
    };
    for (NSUInteger k = 0; k < marks.count; k++) {
        NSPoint m = marks[k].pointValue;
        KSV2 h[2] = { ks_v2(m.x - r, m.y), ks_v2(m.x + r, m.y) };
        KSV2 v[2] = { ks_v2(m.x, m.y - r), ks_v2(m.x, m.y + r) };
        path(h, 2);
        path(v, 2);
        circle(ks_v2(m.x, m.y), r * 0.75, 0.3);
        if (k == 0) circle(ks_v2(m.x, m.y), r * 0.35, 0.2);
    }
    [out addObject:@"M5"];
    [out addObject:@"G0 X0 Y0"];
    return out;
}

@end
