// KerfSender for macOS 10.12 Sierra and later.
// Plain Objective-C and AppKit (no Swift, no storyboards) so it builds for 10.12 with
// command-line clang from any recent Xcode. See senders/README.md.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KSMachineKind) {
    KSMachineGrblLaser = 0,
    KSMachineCncRouter = 1,
    KSMachineCutterHPGL = 2,
    KSMachineCutterGPGL = 3,
};

#pragma mark - Job

/// A job to send: a .kerfjob from KerfKutter, or a plain G-code / HPGL file.
@interface KSJob : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *machineName;
@property (nonatomic) KSMachineKind kind;
@property (nonatomic) NSInteger baudRate;
@property (nonatomic, copy) NSString *flowControl; // none, hardware, software
@property (nonatomic) NSInteger rxBufferSize;
@property (nonatomic) BOOL printerOutput;
@property (nonatomic) NSInteger estimatedSeconds;
@property (nonatomic, copy) NSString *data;
@property (nonatomic) BOOL fromKerfKutter;
@property (nonatomic, readonly) BOOL usesGrbl;

+ (nullable KSJob *)jobWithContentsOfFile:(NSString *)path error:(NSString *_Nullable *_Nullable)error;
+ (NSArray<NSString *> *)fileTypes;
+ (nullable NSString *)cleanGcodeLine:(NSString *)line;
+ (NSString *)formatDuration:(NSInteger)seconds;
- (NSArray<NSString *> *)gcodeLines;
- (NSString *)summary;
@end

#pragma mark - Serial port

@interface KSSerialPort : NSObject
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) BOOL isOpen;
/// Called on the main queue with received bytes.
@property (nonatomic, copy, nullable) void (^onData)(NSData *data);
/// Called on the main queue when the device goes away.
@property (nonatomic, copy, nullable) void (^onClose)(void);

+ (NSArray<NSString *> *)availablePorts;
- (instancetype)initWithPath:(NSString *)path;
/// flow: "none", "hardware" or "software".
- (BOOL)openWithBaud:(NSInteger)baud flow:(NSString *)flow error:(NSString *_Nullable *_Nullable)error;
/// Writes everything, waiting up to `timeout` seconds for the device to accept it.
/// `cancel` (optional) is polled while waiting. Returns NO on error or timeout.
- (BOOL)writeData:(NSData *)data timeout:(NSTimeInterval)timeout cancel:(BOOL (^_Nullable)(void))cancel;
/// Bytes still waiting in the driver's output queue.
- (NSInteger)outputQueueLength;
- (void)close;
@end

#pragma mark - GRBL

/// Character-counting streaming: keeps GRBL's receive buffer full without overflowing it.
@interface KSGrblStreamer : NSObject
- (instancetype)initWithBufferSize:(NSInteger)size;
- (void)enqueue:(NSArray<NSString *> *)lines;
- (NSArray<NSString *> *)takeSendable;
- (BOOL)acknowledge:(BOOL)isError;
- (void)reset;
@property (nonatomic, readonly) NSInteger total, pending, inFlightCount, acknowledged, errors;
@property (nonatomic, readonly) BOOL isIdle;
@end

@protocol KSGrblDelegate <NSObject>
- (void)grblLog:(NSString *)text isError:(BOOL)isError;
- (void)grblStatus:(NSString *)text;
- (void)grblProgress:(double)fraction;
- (void)grblChanged; // connection, running or paused state changed
@end

@interface KSGrbl : NSObject
@property (nonatomic, weak, nullable) id<KSGrblDelegate> delegate;
@property (nonatomic, readonly) BOOL isConnected, isRunning, isPaused;
@property (nonatomic, readonly, copy) NSString *state;
- (BOOL)openPort:(NSString *)path baud:(NSInteger)baud bufferSize:(NSInteger)size;
- (void)close;
- (void)send:(NSString *)line;
- (void)realtime:(uint8_t)byte;
- (void)run:(NSArray<NSString *> *)lines;
- (void)pause;
- (void)resume;
- (void)stop;
@end

#pragma mark - Vinyl cutter

@interface KSCutter : NSObject
@property (nonatomic, readonly) BOOL isSending;
@property (nonatomic, copy, nullable) void (^onProgress)(double fraction);
@property (nonatomic, copy, nullable) void (^onFinished)(NSString *message, BOOL isError);
+ (NSArray<NSString *> *)printerQueues;
- (void)sendData:(NSData *)data toPort:(NSString *)path baud:(NSInteger)baud flow:(NSString *)flow;
- (void)sendData:(NSData *)data toQueue:(NSString *)queue;
- (void)cancel;
@end

#pragma mark - App

@interface KSAppDelegate : NSObject <NSApplicationDelegate, KSGrblDelegate, NSWindowDelegate>
@end

NS_ASSUME_NONNULL_END
