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
/// Work area in mm from the KerfKutter profile (0 for plain files).
@property (nonatomic) double bedWidth, bedHeight;
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
/// Work coordinate offset (machine = work + offset) from GRBL's WCO reports; zero until one arrives.
@property (nonatomic, readonly) double wcoX, wcoY;
@property (nonatomic, readonly) BOOL hasWorkOffset;
/// The head's last reported position in machine coordinates.
@property (nonatomic, readonly) double machineX, machineY;
@property (nonatomic, readonly) BOOL hasMachinePosition;
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

#pragma mark - Camera

/// The burning moves of a G-code job (G1/G2/G3 with the laser on), in work coordinates.
@interface KSToolpath : NSObject
/// Each entry holds packed KSV2 points (x, y doubles).
@property (nonatomic, readonly) NSArray<NSData *> *burns;
@property (nonatomic, readonly) double minX, minY, maxX, maxY;
@property (nonatomic, readonly) BOOL hasRelativeMoves, isEmpty;
@property (nonatomic, readonly) NSInteger pointCount;
+ (KSToolpath *)toolpathFromLines:(NSArray<NSString *> *)lines;
/// The lines with every X/Y (and arc I/J) turned by `degrees` about (px, py), then moved by (dx, dy).
/// Returns nil for jobs with relative (G91) moves.
+ (nullable NSArray<NSString *> *)transformLines:(NSArray<NSString *> *)lines pivotX:(double)px pivotY:(double)py
                                         degrees:(double)degrees dx:(double)dx dy:(double)dy error:(NSString *_Nullable *_Nullable)error;
/// G-code burning the alignment target (each mark a cross in a circle; mark 1 has an inner ring).
+ (NSArray<NSString *> *)targetGcodeForMarks:(NSArray<NSValue *> *)marks size:(double)size feed:(double)feed
                                       power:(double)powerPercent sMax:(double)sMax;
+ (NSString *)format:(double)v;
@end

@class KSCameraWindowController;

@protocol KSCameraHost <NSObject>
- (nullable KSJob *)cameraCurrentJob;
- (BOOL)cameraMachineIsLaser;
- (KSGrbl *)cameraGrbl;
- (void)cameraLog:(NSString *)text isError:(BOOL)isError;
@end

@interface KSCameraWindowController : NSWindowController <NSWindowDelegate>
- (instancetype)initWithHost:(id<KSCameraHost>)host;
/// True when Start should run the placed copy of the job.
@property (nonatomic, readonly) BOOL placementActive;
@property (nonatomic, readonly) NSString *placementDescription;
- (nullable NSArray<NSString *> *)placedLinesForJob:(KSJob *)job error:(NSString *_Nullable *_Nullable)error;
- (void)jobOpened:(nullable KSJob *)job;
- (void)machineChanged;
@end

#pragma mark - App

@interface KSAppDelegate : NSObject <NSApplicationDelegate, KSGrblDelegate, NSWindowDelegate, KSCameraHost>
@end

NS_ASSUME_NONNULL_END
