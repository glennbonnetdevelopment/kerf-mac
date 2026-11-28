#import "KerfSender.h"

static const NSInteger KSSupportedJobVersion = 1;

@implementation KSJob

- (instancetype)init {
    if ((self = [super init])) {
        _name = @"";
        _path = @"";
        _machineName = @"";
        _kind = KSMachineGrblLaser;
        _baudRate = 115200;
        _flowControl = @"none";
        _rxBufferSize = 127;
        _data = @"";
    }
    return self;
}

- (BOOL)usesGrbl {
    return self.kind == KSMachineGrblLaser || self.kind == KSMachineCncRouter;
}

+ (NSArray<NSString *> *)fileTypes {
    return @[ @"kerfjob", @"gc", @"gcode", @"nc", @"ngc", @"tap", @"plt", @"hpgl", @"hpg" ];
}

static NSString *KSString(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSInteger KSInteger(NSDictionary *d, NSString *key, NSInteger fallback) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? (NSInteger)llround([v doubleValue]) : fallback;
}

+ (KSJob *)jobWithContentsOfFile:(NSString *)path error:(NSString **)error {
    NSData *raw = [NSData dataWithContentsOfFile:path];
    if (!raw) {
        if (error) *error = @"The file could not be read.";
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding];
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"﻿"]) trimmed = [trimmed substringFromIndex:1];

    KSJob *job = nil;
    if ([ext isEqualToString:@"kerfjob"] || [trimmed hasPrefix:@"{"]) {
        job = [self jobFromKerfJob:raw error:error];
        if (!job) return nil;
    } else {
        job = [[KSJob alloc] init];
        job.data = text ?: @"";
        NSString *head = [trimmed substringToIndex:MIN((NSUInteger)200, trimmed.length)].uppercaseString;
        BOOL plotter = [@[ @"plt", @"hpgl", @"hpg" ] containsObject:ext] || [head hasPrefix:@"IN;"] ||
                       [head hasPrefix:@"IN "] || [head hasPrefix:@"PU"] || [head hasPrefix:@"\x1B."];
        if (plotter) {
            job.kind = KSMachineCutterHPGL;
            job.machineName = @"Vinyl cutter";
            job.baudRate = 9600;
            job.flowControl = @"software";
        } else {
            job.kind = KSMachineGrblLaser;
            job.machineName = @"GRBL machine";
        }
    }
    job.path = path;
    if (job.name.length == 0) job.name = path.lastPathComponent.stringByDeletingPathExtension;
    return job;
}

+ (KSJob *)jobFromKerfJob:(NSData *)raw error:(NSString **)error {
    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:raw options:0 error:&jsonError];
    if (![root isKindOfClass:[NSDictionary class]] || ![KSString(root, @"format") isEqualToString:@"kerfjob"]) {
        if (error) *error = @"This is not a KerfKutter job file.";
        return nil;
    }
    NSInteger version = KSInteger(root, @"version", 1);
    if (version > KSSupportedJobVersion) {
        if (error) *error = [NSString stringWithFormat:@"This job was made by a newer KerfKutter (job format %ld). Please update KerfSender.", (long)version];
        return nil;
    }
    NSDictionary *m = root[@"machine"];
    if (![m isKindOfClass:[NSDictionary class]]) {
        if (error) *error = @"The job file has no machine settings.";
        return nil;
    }
    KSJob *job = [[KSJob alloc] init];
    job.fromKerfKutter = YES;
    job.name = KSString(root, @"name") ?: @"";
    job.estimatedSeconds = KSInteger(root, @"estimatedSeconds", 0);
    job.data = KSString(root, @"data") ?: @"";
    job.machineName = KSString(m, @"name") ?: @"Machine";
    NSString *kind = KSString(m, @"kind");
    NSString *language = KSString(m, @"language");
    if ([kind isEqualToString:@"grblLaser"]) {
        job.kind = KSMachineGrblLaser;
    } else if ([kind isEqualToString:@"cncRouter"]) {
        job.kind = KSMachineCncRouter;
    } else if ([kind isEqualToString:@"vinylCutter"]) {
        job.kind = [language isEqualToString:@"gpgl"] ? KSMachineCutterGPGL : KSMachineCutterHPGL;
    } else {
        if (error) *error = [NSString stringWithFormat:@"Unknown machine type '%@'.", kind ?: @""];
        return nil;
    }
    job.baudRate = KSInteger(m, @"baudRate", job.usesGrbl ? 115200 : 9600);
    job.flowControl = KSString(m, @"flowControl") ?: @"none";
    job.rxBufferSize = KSInteger(m, @"rxBufferSize", 127);
    job.printerOutput = [KSString(m, @"output") isEqualToString:@"printerQueue"];
    id bw = m[@"bedWidth"], bh = m[@"bedHeight"];
    if ([bw isKindOfClass:[NSNumber class]] && [bh isKindOfClass:[NSNumber class]]) {
        job.bedWidth = [bw doubleValue];
        job.bedHeight = [bh doubleValue];
    }
    return job;
}

+ (NSString *)cleanGcodeLine:(NSString *)line {
    NSString *s = line;
    NSRange semi = [s rangeOfString:@";"];
    if (semi.location != NSNotFound) s = [s substringToIndex:semi.location];
    while (YES) {
        NSRange open = [s rangeOfString:@"("];
        if (open.location == NSNotFound) break;
        NSRange close = [s rangeOfString:@")" options:0 range:NSMakeRange(open.location, s.length - open.location)];
        if (close.location == NSNotFound) break;
        s = [s stringByReplacingCharactersInRange:NSMakeRange(open.location, NSMaxRange(close) - open.location) withString:@""];
    }
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length ? s : nil;
}

- (NSArray<NSString *> *)gcodeLines {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *raw in [self.data componentsSeparatedByString:@"\n"]) {
        NSString *c = [KSJob cleanGcodeLine:raw];
        if (c) [out addObject:c];
    }
    return out;
}

+ (NSString *)formatDuration:(NSInteger)s {
    if (s < 60) return [NSString stringWithFormat:@"%ld s", (long)s];
    if (s < 3600) return [NSString stringWithFormat:@"%ld min %ld s", (long)(s / 60), (long)(s % 60)];
    return [NSString stringWithFormat:@"%ld h %ld min", (long)(s / 3600), (long)(s % 3600 / 60)];
}

- (NSString *)summary {
    NSMutableString *s = [NSMutableString stringWithString:self.machineName];
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    if (self.usesGrbl) {
        [s appendFormat:@" · %@ lines", [f stringFromNumber:@(self.gcodeLines.count)]];
    } else {
        [s appendFormat:@" · %@ · %@ bytes", self.kind == KSMachineCutterGPGL ? @"GP-GL" : @"HPGL",
                        [f stringFromNumber:@([self.data lengthOfBytesUsingEncoding:NSUTF8StringEncoding])]];
    }
    if (self.estimatedSeconds > 0) [s appendFormat:@" · about %@", [KSJob formatDuration:self.estimatedSeconds]];
    if (!self.fromKerfKutter) [s appendString:@" · plain file, check the settings below"];
    return s;
}

@end
