// Checks reading a job's toolpath back from G-code and moving it (KSToolpath). Run with: senders/mac/build.sh test
#import "KerfSender.h"
#import "KSCameraMath.h"

static int failures;

static void check(BOOL ok, NSString *what) {
    printf("%s%s\n", ok ? "ok   " : "FAIL ", what.UTF8String);
    if (!ok) failures++;
}

int main(void) {
    @autoreleasepool {
        NSArray *lines = @[ @"; Kerf job", @"G90", @"G21", @"M5", @"M4 S0",
                            @"G0 X10 Y10", @"G1 X30 Y10 S500 F1200", @"G1 X30 Y20", @"G1 X10 Y20", @"G1 X10 Y10",
                            @"G0 X50 Y50", @"G1 X60 S0", @"G1 X70 S300", @"G1 X80 S300", @"M5" ];
        KSToolpath *tp = [KSToolpath toolpathFromLines:lines];
        check(tp.burns.count == 2, [NSString stringWithFormat:@"toolpath has the square and the raster run: %lu", (unsigned long)tp.burns.count]);
        check(tp.minX == 10 && tp.maxX == 80 && tp.minY == 10 && tp.maxY == 50, @"toolpath bounds");
        check(tp.burns.count == 2 && tp.burns[1].length / sizeof(KSV2) == 2, @"collinear raster moves merge into one segment");

        NSString *error = nil;
        NSArray *moved = [KSToolpath transformLines:lines pivotX:20 pivotY:15 degrees:90 dx:100 dy:0 error:&error];
        check([moved[6] isEqualToString:@"G1 X125 Y25 S500 F1200"], [@"turned and moved line: " stringByAppendingString:moved ? moved[6] : error]);
        check([moved[11] isEqualToString:@"G1 X85 Y55 S0"], [@"single-axis line gets both axes: " stringByAppendingString:moved[11]]);
        check([moved[0] isEqualToString:@"; Kerf job"] && [moved[4] isEqualToString:@"M4 S0"], @"lines without positions are unchanged");
        KSToolpath *back = [KSToolpath toolpathFromLines:moved];
        check(fabs(back.minX - 85) < 1e-9 && fabs(back.maxX - 125) < 1e-9, @"moved toolpath bounds");

        NSArray *arc = [KSToolpath transformLines:@[ @"G2 X10 Y0 I5 J0" ] pivotX:0 pivotY:0 degrees:90 dx:0 dy:0 error:&error];
        check([arc[0] isEqualToString:@"G2 X0 Y10 I0 J5"], [@"arc centre offsets turn with the job: " stringByAppendingString:arc[0]]);
        error = nil;
        check([KSToolpath transformLines:@[ @"G91", @"G1 X5" ] pivotX:0 pivotY:0 degrees:0 dx:1 dy:1 error:&error] == nil && error != nil,
              @"relative jobs are refused");

        NSArray *marks = @[ [NSValue valueWithPoint:NSMakePoint(40, 40)], [NSValue valueWithPoint:NSMakePoint(200, 40)] ];
        NSArray *target = [KSToolpath targetGcodeForMarks:marks size:12 feed:1500 power:25 sMax:1000];
        BOOL burns = NO;
        for (NSString *l in target) if ([l hasSuffix:@"S250 F1500"]) burns = YES;
        check([target containsObject:@"M4 S0"] && burns, @"target G-code burns at 25% of S1000");
        printf(failures == 0 ? "All checks passed.\n" : "%d check(s) failed.\n", failures);
    }
    return failures == 0 ? 0 : 1;
}
