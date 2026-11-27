#import "KerfSender.h"
#include <stdatomic.h>

@implementation KSCutter {
    atomic_bool _cancel;
}

+ (NSArray<NSString *> *)printerQueues {
    // "lpstat -a" lists every queue as "<name> accepting requests since …" on all CUPS versions.
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/lpstat";
    task.arguments = @[ @"-a" ];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return @[];
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray *queues = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *name = [[line componentsSeparatedByString:@" "] firstObject];
        if (name.length && ![queues containsObject:name]) [queues addObject:name];
    }
    return queues;
}

- (void)cancel {
    atomic_store(&_cancel, true);
}

- (void)finish:(NSString *)message error:(BOOL)isError {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_isSending = NO;
        if (self.onFinished) self.onFinished(message, isError);
    });
}

- (void)progress:(double)fraction {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onProgress) self.onProgress(fraction);
    });
}

- (void)sendData:(NSData *)data toPort:(NSString *)path baud:(NSInteger)baud flow:(NSString *)flow {
    if (_isSending) return;
    _isSending = YES;
    atomic_store(&_cancel, false);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        KSSerialPort *port = [[KSSerialPort alloc] initWithPath:path];
        NSString *error = nil;
        if (![port openWithBaud:baud flow:flow error:&error]) {
            [self finish:error error:YES];
            return;
        }
        BOOL (^cancelled)(void) = ^BOOL { return atomic_load(&self->_cancel); };
        NSUInteger offset = 0, total = data.length;
        NSString *outcome = [NSString stringWithFormat:@"Sent %lu bytes to %@.", (unsigned long)total, path];
        BOOL failed = NO;
        while (offset < total) {
            if (cancelled()) {
                outcome = @"Stopped. The cutter may finish the commands already in its buffer.";
                break;
            }
            NSUInteger n = MIN((NSUInteger)256, total - offset);
            // The cutter may hold us off with flow control while it cuts; allow a minute per chunk.
            if (![port writeData:[data subdataWithRange:NSMakeRange(offset, n)] timeout:60 cancel:cancelled]) {
                if (cancelled()) {
                    outcome = @"Stopped. The cutter may finish the commands already in its buffer.";
                } else {
                    outcome = @"The cutter stopped accepting data. Check it is online, and the baud rate and flow control.";
                    failed = YES;
                }
                break;
            }
            offset += n;
            // Keep the progress bar honest: wait for the driver to hand most bytes on.
            while (!cancelled() && port.outputQueueLength > 512) usleep(20000);
            [self progress:(double)offset / (double)total];
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
        while (!failed && !cancelled() && port.outputQueueLength > 0 && deadline.timeIntervalSinceNow > 0) usleep(50000);
        [port close];
        [self finish:outcome error:failed];
    });
}

- (void)sendData:(NSData *)data toQueue:(NSString *)queue {
    if (_isSending) return;
    _isSending = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"kerfsender-%@.plt", [NSUUID UUID].UUIDString]];
        if (![data writeToFile:tmp atomically:YES]) {
            [self finish:@"Could not write a temporary file." error:YES];
            return;
        }
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/lp";
        task.arguments = @[ @"-d", queue, @"-o", @"raw", tmp ];
        NSPipe *err = [NSPipe pipe];
        task.standardError = err;
        task.standardOutput = [NSPipe pipe];
        NSString *message = nil;
        @try {
            [task launch];
            NSData *errData = [err.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            if (task.terminationStatus != 0) {
                NSString *text = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
                message = [@"lp failed: " stringByAppendingString:
                           [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            }
        } @catch (NSException *e) {
            message = e.reason ?: @"Could not run lp.";
        }
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        if (!message) [self progress:1];
        [self finish:message ?: [NSString stringWithFormat:@"Sent to printer queue %@.", queue] error:message != nil];
    });
}

@end
