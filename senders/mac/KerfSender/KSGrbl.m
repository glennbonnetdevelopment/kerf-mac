#import "KerfSender.h"

#pragma mark - Streamer

@implementation KSGrblStreamer {
    NSInteger _bufferSize;
    NSMutableArray<NSString *> *_queue;
    NSInteger _next;
    NSMutableArray<NSNumber *> *_inFlight;
    NSInteger _bufferUsed;
}

- (instancetype)initWithBufferSize:(NSInteger)size {
    if ((self = [super init])) {
        _bufferSize = size > 0 ? size : 127;
        _queue = [NSMutableArray array];
        _inFlight = [NSMutableArray array];
    }
    return self;
}

- (void)enqueue:(NSArray<NSString *> *)lines {
    for (NSString *l in lines) {
        NSString *c = [KSJob cleanGcodeLine:l];
        if (c) [_queue addObject:c];
    }
}

- (NSInteger)total { return (NSInteger)_queue.count; }
- (NSInteger)pending { return (NSInteger)_queue.count - _next; }
- (NSInteger)inFlightCount { return (NSInteger)_inFlight.count; }
- (BOOL)isIdle { return _next >= (NSInteger)_queue.count && _inFlight.count == 0; }

- (NSArray<NSString *> *)takeSendable {
    NSMutableArray *out = [NSMutableArray array];
    while (_next < (NSInteger)_queue.count) {
        NSString *line = _queue[(NSUInteger)_next];
        NSInteger len = (NSInteger)[line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
        // An over-long line is still sent once the buffer is empty.
        if (_bufferUsed + len > _bufferSize && !(_inFlight.count == 0 && out.count == 0)) break;
        [out addObject:line];
        [_inFlight addObject:@(len)];
        _bufferUsed += len;
        _next++;
    }
    return out;
}

- (BOOL)acknowledge:(BOOL)isError {
    if (_inFlight.count == 0) return NO;
    _bufferUsed -= _inFlight.firstObject.integerValue;
    [_inFlight removeObjectAtIndex:0];
    _acknowledged++;
    if (isError) _errors++;
    return YES;
}

- (void)reset {
    [_queue removeAllObjects];
    _next = 0;
    [_inFlight removeAllObjects];
    _bufferUsed = 0;
    _acknowledged = 0;
    _errors = 0;
}

@end

#pragma mark - Connection

@implementation KSGrbl {
    KSSerialPort *_port;
    KSGrblStreamer *_streamer;
    NSMutableString *_rx;
    NSTimer *_statusTimer;
    NSInteger _jobFirstAck, _jobLineCount;
    NSDate *_jobStarted;
    double _wco[3];
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = @"Disconnected";
        _rx = [NSMutableString string];
        _streamer = [[KSGrblStreamer alloc] initWithBufferSize:127];
    }
    return self;
}

- (BOOL)isConnected { return _port != nil; }

- (void)log:(NSString *)text error:(BOOL)isError { [self.delegate grblLog:text isError:isError]; }

- (BOOL)openPort:(NSString *)path baud:(NSInteger)baud bufferSize:(NSInteger)size {
    if (_port) return YES;
    KSSerialPort *p = [[KSSerialPort alloc] initWithPath:path];
    NSString *error = nil;
    if (![p openWithBaud:baud flow:@"none" error:&error]) {
        [self log:error error:YES];
        return NO;
    }
    __weak KSGrbl *weakSelf = self;
    p.onData = ^(NSData *data) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        [weakSelf receive:text];
    };
    p.onClose = ^{ [weakSelf handleDisconnect:@"The machine was disconnected."]; };
    _port = p;
    _streamer = [[KSGrblStreamer alloc] initWithBufferSize:size];
    [_rx setString:@""];
    _state = @"Connecting";
    [self log:[NSString stringWithFormat:@"Opened %@ at %ld baud", path, (long)baud] error:NO];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    // GRBL boards often reset when the port opens; ask for build info once it is up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.isConnected) [weakSelf send:@"$I"];
    });
    [self.delegate grblChanged];
    return YES;
}

- (void)poll:(NSTimer *)timer {
    [self realtime:'?'];
}

- (void)close {
    [self handleDisconnect:@"Disconnected."];
}

- (void)handleDisconnect:(NSString *)reason {
    if (!_port) return;
    [_statusTimer invalidate];
    _statusTimer = nil;
    _port.onClose = nil;
    _port.onData = nil;
    [_port close];
    _port = nil;
    _isRunning = NO;
    _isPaused = NO;
    [_streamer reset];
    _state = @"Disconnected";
    [self log:reason error:NO];
    [self.delegate grblStatus:_state];
    [self.delegate grblChanged];
}

- (void)receive:(NSString *)text {
    if (!_port || !text) return;
    [_rx appendString:text];
    while (YES) {
        NSRange nl = [_rx rangeOfString:@"\n"];
        if (nl.location == NSNotFound) break;
        NSString *line = [[_rx substringToIndex:nl.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [_rx deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
        if (line.length) [self handle:line];
    }
}

static NSInteger KSCode(NSString *line) {
    NSRange colon = [line rangeOfString:@":"];
    return colon.location == NSNotFound ? 0 : [[line substringFromIndex:colon.location + 1] integerValue];
}

- (void)handle:(NSString *)line {
    if ([line isEqualToString:@"ok"]) {
        [_streamer acknowledge:NO];
        if (!_isRunning) [self log:@"ok" error:NO];
        [self pump];
    } else if ([line hasPrefix:@"error:"]) {
        [_streamer acknowledge:YES];
        [self log:[NSString stringWithFormat:@"%@ %@", line, [KSGrbl errorText:KSCode(line)]] error:YES];
        [self pump];
    } else if ([line hasPrefix:@"ALARM:"]) {
        [self log:[NSString stringWithFormat:@"%@ %@", line, [KSGrbl alarmText:KSCode(line)]] error:YES];
        if (_isRunning) {
            _isRunning = NO;
            _isPaused = NO;
            [_streamer reset];
            [self log:@"Job stopped by alarm." error:YES];
            [self.delegate grblChanged];
        }
    } else if ([line hasPrefix:@"<"] && [line hasSuffix:@">"]) {
        [self parseStatus:[line substringWithRange:NSMakeRange(1, line.length - 2)]];
    } else if ([line hasPrefix:@"Grbl "] || [line hasPrefix:@"GrblHAL "]) {
        [self log:line error:NO];
        [_streamer reset];
        if (_isRunning) {
            _isRunning = NO;
            _isPaused = NO;
            [self log:@"The controller reset; the job has stopped." error:YES];
            [self.delegate grblChanged];
        }
    } else {
        [self log:line error:NO];
    }

    if (_isRunning) {
        NSInteger done = _streamer.acknowledged - _jobFirstAck;
        [self.delegate grblProgress:_jobLineCount > 0 ? MIN(1.0, (double)done / (double)_jobLineCount) : 1.0];
        if (_streamer.isIdle) {
            _isRunning = NO;
            _isPaused = NO;
            NSInteger secs = (NSInteger)(-[_jobStarted timeIntervalSinceNow]);
            [self log:[NSString stringWithFormat:@"Job finished in %@ with %ld error(s).", [KSJob formatDuration:secs], (long)_streamer.errors]
                error:_streamer.errors > 0];
            [self.delegate grblChanged];
        }
    }
}

- (void)parseStatus:(NSString *)body {
    NSArray<NSString *> *fields = [body componentsSeparatedByString:@"|"];
    NSString *state = fields.firstObject ?: @"";
    NSArray<NSString *> *mpos = nil, *wpos = nil;
    for (NSString *f in fields) {
        NSRange colon = [f rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [f substringToIndex:colon.location];
        NSArray<NSString *> *v = [[f substringFromIndex:colon.location + 1] componentsSeparatedByString:@","];
        if ([key isEqualToString:@"MPos"]) mpos = v;
        else if ([key isEqualToString:@"WPos"]) wpos = v;
        else if ([key isEqualToString:@"WCO"]) {
            for (NSUInteger i = 0; i < 3; i++) _wco[i] = i < v.count ? v[i].doubleValue : 0;
        }
    }
    double pos[3] = { 0, 0, 0 };
    NSUInteger axes = 0;
    if (wpos) {
        axes = MIN((NSUInteger)3, wpos.count);
        for (NSUInteger i = 0; i < axes; i++) pos[i] = wpos[i].doubleValue;
    } else if (mpos) {
        axes = MIN((NSUInteger)3, mpos.count);
        for (NSUInteger i = 0; i < axes; i++) pos[i] = mpos[i].doubleValue - _wco[i];
    }
    BOOL changed = ![state isEqualToString:_state];
    _state = [state copy];
    NSMutableString *s = [NSMutableString stringWithString:state];
    if (axes >= 2) [s appendFormat:@"    X %.2f   Y %.2f", pos[0], pos[1]];
    if (axes >= 3) [s appendFormat:@"   Z %.2f", pos[2]];
    [self.delegate grblStatus:s];
    if (changed) [self.delegate grblChanged];
}

- (void)pump {
    if (!_port) return;
    NSArray<NSString *> *lines = [_streamer takeSendable];
    if (lines.count == 0) return;
    if (!_isRunning) {
        for (NSString *l in lines) [self log:[@"> " stringByAppendingString:l] error:NO];
    }
    NSString *text = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    if (![_port writeData:[text dataUsingEncoding:NSUTF8StringEncoding] timeout:2 cancel:nil]) {
        [self log:@"Write failed." error:YES];
        [self handleDisconnect:@"The machine was disconnected."];
    }
}

- (void)send:(NSString *)line {
    if (!_port) return;
    [_streamer enqueue:@[ line ]];
    [self pump];
}

- (void)realtime:(uint8_t)byte {
    if (!_port) return;
    if (![_port writeData:[NSData dataWithBytes:&byte length:1] timeout:1 cancel:nil]) {
        [self handleDisconnect:@"The machine was disconnected."];
    }
}

- (void)run:(NSArray<NSString *> *)lines {
    if (!_port || _isRunning) return;
    NSInteger before = _streamer.total;
    [_streamer enqueue:lines];
    _jobLineCount = _streamer.total - before;
    // Lines already queued before the job are acknowledged first.
    _jobFirstAck = _streamer.acknowledged + (_streamer.pending - _jobLineCount) + _streamer.inFlightCount;
    _jobStarted = [NSDate date];
    _isRunning = YES;
    _isPaused = NO;
    [self log:[NSString stringWithFormat:@"Job started: %ld lines", (long)_jobLineCount] error:NO];
    [self.delegate grblProgress:0];
    [self.delegate grblChanged];
    [self pump];
}

- (void)pause {
    [self realtime:'!'];
    _isPaused = YES;
    [self.delegate grblChanged];
}

- (void)resume {
    [self realtime:'~'];
    _isPaused = NO;
    [self.delegate grblChanged];
}

/// Stops at once: feed hold, then a soft reset (which also turns the laser or spindle off).
- (void)stop {
    [self realtime:'!'];
    __weak KSGrbl *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf realtime:0x18];
    });
    [_streamer reset];
    if (_isRunning) [self log:@"Job stopped. Re-home or re-check the origin before the next job." error:NO];
    _isRunning = NO;
    _isPaused = NO;
    [self.delegate grblChanged];
}

+ (NSString *)errorText:(NSInteger)code {
    switch (code) {
        case 1: return @"G-code word missing a letter";
        case 2: return @"Numeric value format is not valid";
        case 3: return @"'$' command not recognised";
        case 8: return @"Command needs the machine to be idle";
        case 9: return @"G-code locked out during alarm or jog; unlock first";
        case 15: return @"Jog target exceeds machine travel";
        case 20: return @"Unsupported G-code command";
        case 22: return @"Feed rate has not been set";
        default: return @"";
    }
}

+ (NSString *)alarmText:(NSInteger)code {
    switch (code) {
        case 1: return @"Hard limit triggered; re-home the machine";
        case 2: return @"Motion target exceeds machine travel";
        case 3: return @"Reset while in motion; re-home recommended";
        case 6: case 7: case 8: case 9: return @"Homing failed";
        default: return @"";
    }
}

@end
