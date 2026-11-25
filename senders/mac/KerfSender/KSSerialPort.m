#import "KerfSender.h"
#import <IOKit/serial/ioss.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

@implementation KSSerialPort {
    int _fd;
    dispatch_source_t _reader;
    dispatch_queue_t _queue;
}

+ (NSArray<NSString *> *)availablePorts {
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/dev" error:nil] ?: @[];
    NSMutableArray *ports = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasPrefix:@"cu."]) continue;
        if ([name containsString:@"Bluetooth"] || [name containsString:@"debug-console"]) continue;
        [ports addObject:[@"/dev/" stringByAppendingString:name]];
    }
    return [ports sortedArrayUsingSelector:@selector(compare:)];
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _fd = -1;
        _queue = dispatch_queue_create("KerfSender.serial", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (BOOL)isOpen {
    return _fd >= 0;
}

- (BOOL)openWithBaud:(NSInteger)baud flow:(NSString *)flow error:(NSString **)error {
    if (_fd >= 0) return YES;
    int fd = open(self.path.fileSystemRepresentation, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"Could not open %@: %s", self.path, strerror(errno)];
        return NO;
    }
    ioctl(fd, TIOCEXCL);
    struct termios t;
    tcgetattr(fd, &t);
    cfmakeraw(&t);
    t.c_cflag |= (CLOCAL | CREAD);
    t.c_cflag &= ~(CSIZE | PARENB | CSTOPB | CRTSCTS);
    t.c_cflag |= CS8;
    t.c_iflag &= ~(IXON | IXOFF | IXANY);
    if ([flow isEqualToString:@"hardware"]) t.c_cflag |= CRTSCTS;
    if ([flow isEqualToString:@"software"]) t.c_iflag |= (IXON | IXOFF);
    t.c_cc[VMIN] = 0;
    t.c_cc[VTIME] = 0;
    // On macOS the B constants equal the numeric rate; odd rates (e.g. 250000) need IOSSIOSPEED.
    BOOL standard = cfsetspeed(&t, (speed_t)baud) == 0 && tcsetattr(fd, TCSANOW, &t) == 0;
    if (!standard) {
        cfsetspeed(&t, B9600);
        tcsetattr(fd, TCSANOW, &t);
        speed_t speed = (speed_t)baud;
        if (ioctl(fd, IOSSIOSPEED, &speed) == -1) {
            if (error) *error = [NSString stringWithFormat:@"%@ does not support %ld baud.", self.path, (long)baud];
            close(fd);
            return NO;
        }
    }
    int bits = TIOCM_DTR;
    ioctl(fd, TIOCMBIS, &bits);
    if (![flow isEqualToString:@"hardware"]) {
        bits = TIOCM_RTS;
        ioctl(fd, TIOCMBIS, &bits);
    }
    tcflush(fd, TCIOFLUSH);
    _fd = fd;

    __weak KSSerialPort *weakSelf = self;
    _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(_reader, ^{
        uint8_t buf[1024];
        ssize_t n = read(fd, buf, sizeof buf);
        if (n > 0) {
            NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
            dispatch_async(dispatch_get_main_queue(), ^{
                KSSerialPort *s = weakSelf;
                if (s.isOpen && s.onData) s.onData(data);
            });
        } else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
            // The device was unplugged.
            dispatch_async(dispatch_get_main_queue(), ^{
                KSSerialPort *s = weakSelf;
                if (!s.isOpen) return;
                void (^handler)(void) = s.onClose;
                [s close];
                if (handler) handler();
            });
        }
    });
    dispatch_source_set_cancel_handler(_reader, ^{ close(fd); });
    dispatch_resume(_reader);
    return YES;
}

- (BOOL)writeData:(NSData *)data timeout:(NSTimeInterval)timeout cancel:(BOOL (^)(void))cancel {
    int fd = _fd;
    if (fd < 0) return NO;
    const uint8_t *bytes = data.bytes;
    NSUInteger left = data.length;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (left > 0) {
        ssize_t n = write(fd, bytes, left);
        if (n > 0) {
            bytes += n;
            left -= (NSUInteger)n;
            deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
            continue;
        }
        if (n < 0 && errno != EAGAIN && errno != EINTR) return NO;
        if (cancel && cancel()) return NO;
        if ([deadline timeIntervalSinceNow] < 0) return NO;
        struct pollfd p = { fd, POLLOUT, 0 };
        poll(&p, 1, 200);
    }
    return YES;
}

- (NSInteger)outputQueueLength {
    int n = 0;
    if (_fd < 0 || ioctl(_fd, TIOCOUTQ, &n) != 0) return 0;
    return n;
}

- (void)close {
    if (_fd < 0) return;
    _fd = -1;
    if (_reader) {
        dispatch_source_cancel(_reader); // closes the descriptor
        _reader = nil;
    }
}

@end
