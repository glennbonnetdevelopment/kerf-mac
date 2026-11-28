#import "KerfSender.h"
#import "KSCameraMath.h"
#import <AVFoundation/AVFoundation.h>

// Camera registration for lasers: calibrate the lens, align the camera to the bed with a burned target,
// then move the job's outline onto the material in the picture. Start in the main window runs it as placed.
// Same workflow and maths as KerfKutter's View › Camera and the Windows sender's Camera window.

#pragma mark - Frames

/// One camera picture, BGRA, rows top to bottom, packed (4 × width bytes per row).
@interface KSCameraFrame : NSObject
@property (nonatomic) int width, height;
@property (nonatomic, strong) NSData *bgra;
@property (nonatomic) NSUInteger sequence;
/// 8-bit grayscale, made on first use.
- (const uint8_t *)gray;
- (nullable NSImage *)image;
@end

@implementation KSCameraFrame {
    NSData *_gray;
    NSImage *_image;
}

- (const uint8_t *)gray {
    if (!_gray) {
        NSMutableData *g = [NSMutableData dataWithLength:(NSUInteger)(_width * _height)];
        const uint8_t *s = _bgra.bytes;
        uint8_t *o = g.mutableBytes;
        for (int i = 0; i < _width * _height; i++, s += 4) o[i] = (uint8_t)((s[0] * 29 + s[1] * 150 + s[2] * 77) >> 8);
        _gray = g;
    }
    return _gray.bytes;
}

- (NSImage *)image {
    if (!_image) {
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)_bgra);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGImageRef cg = CGImageCreate((size_t)_width, (size_t)_height, 8, 32, (size_t)_width * 4, space,
                                      kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL, false, kCGRenderingIntentDefault);
        if (cg) {
            _image = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(_width, _height)];
            CGImageRelease(cg);
        }
        CGColorSpaceRelease(space);
        CGDataProviderRelease(provider);
    }
    return _image;
}

@end

#pragma mark - Capture

@interface KSCameraCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, readonly) BOOL isRunning;
@end

@implementation KSCameraCapture {
    AVCaptureSession *_session;
    dispatch_queue_t _queue;
    KSCameraFrame *_latest;
    NSUInteger _sequence;
}

+ (NSArray<AVCaptureDevice *> *)devices {
    return [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
}

- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("KerfSender.camera", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)startWithDevice:(AVCaptureDevice *)device error:(NSString **)error {
    [self stop];
    NSError *e = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&e];
    if (!input) {
        if (error) *error = [NSString stringWithFormat:@"Could not open %@: %@", device.localizedName, e.localizedDescription ?: @""];
        return NO;
    }
    AVCaptureSession *s = [[AVCaptureSession alloc] init];
    [s beginConfiguration];
    if (![s canAddInput:input]) {
        [s commitConfiguration];
        if (error) *error = [NSString stringWithFormat:@"%@ is busy in another app.", device.localizedName];
        return NO;
    }
    [s addInput:input];
    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    output.alwaysDiscardsLateVideoFrames = YES;
    [output setSampleBufferDelegate:self queue:_queue];
    if ([s canAddOutput:output]) [s addOutput:output];
    [KSCameraCapture chooseBestFormat:device];
    [s commitConfiguration];
    _session = s;
    @synchronized(self) { _latest = nil; }
    dispatch_async(_queue, ^{ [s startRunning]; });
    _isRunning = YES;
    return YES;
}

/// The largest picture up to 1920 × 1080: enough detail for calibration without slowing an older Mac down.
+ (void)chooseBestFormat:(AVCaptureDevice *)device {
    AVCaptureDeviceFormat *best = nil;
    long bestArea = 0;
    for (AVCaptureDeviceFormat *f in device.formats) {
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        BOOL fast = NO;
        for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) if (r.maxFrameRate >= 5) fast = YES;
        long area = (long)d.width * d.height;
        if (fast && d.width <= 1920 && d.height <= 1080 && area > bestArea) { best = f; bestArea = area; }
    }
    if (best && [device lockForConfiguration:nil]) {
        device.activeFormat = best;
        [device unlockForConfiguration];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    int w = (int)CVPixelBufferGetWidth(pb), h = (int)CVPixelBufferGetHeight(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    NSMutableData *data = nil;
    if (base && w > 0 && h > 0) {
        data = [NSMutableData dataWithLength:(NSUInteger)(w * h * 4)];
        uint8_t *o = data.mutableBytes;
        for (int y = 0; y < h; y++) memcpy(o + (size_t)y * w * 4, base + (size_t)y * stride, (size_t)w * 4);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!data) return;
    KSCameraFrame *f = [[KSCameraFrame alloc] init];
    f.width = w;
    f.height = h;
    f.bgra = data;
    @synchronized(self) {
        f.sequence = ++_sequence;
        _latest = f;
    }
}

- (KSCameraFrame *)latest {
    @synchronized(self) { return _latest; }
}

- (void)stop {
    AVCaptureSession *s = _session;
    _session = nil;
    _isRunning = NO;
    if (s) dispatch_async(_queue, ^{ [s stopRunning]; });
}

@end

#pragma mark - Picture view

@interface KSCameraView : NSView
@property (nonatomic, weak) KSCameraWindowController *owner;
@end

@interface KSCameraWindowController ()
- (void)drawPicture:(NSRect)bounds;
- (void)pictureMouseDown:(NSEvent *)event;
- (void)pictureMouseDragged:(NSEvent *)event;
@end

@implementation KSCameraView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect { [self.owner drawPicture:self.bounds]; }
- (void)mouseDown:(NSEvent *)event { [self.owner pictureMouseDown:event]; }
- (void)mouseDragged:(NSEvent *)event { [self.owner pictureMouseDragged:event]; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:[NSCursor crosshairCursor]]; }
@end

@interface KSFlippedStackHolder : NSView
@end
@implementation KSFlippedStackHolder
- (BOOL)isFlipped { return YES; }
@end

#pragma mark - Controls

static NSTextField *KSNote(NSString *text) {
    NSTextField *l = [NSTextField wrappingLabelWithString:text];
    l.font = [NSFont systemFontOfSize:11];
    l.textColor = [NSColor secondaryLabelColor];
    l.preferredMaxLayoutWidth = 320;
    l.selectable = NO;
    return l;
}

static NSTextField *KSHeading(NSString *text) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont boldSystemFontOfSize:12];
    return l;
}

static NSButton *KSCamButton(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

static NSStackView *KSRow(NSArray<NSView *> *views) {
    NSStackView *r = [NSStackView stackViewWithViews:views];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.spacing = 6;
    return r;
}

@interface KSCameraWindowController () <NSTabViewDelegate>
@end

@implementation KSCameraWindowController {
    __weak id<KSCameraHost> _host;
    KSCameraCapture *_capture;
    NSArray<AVCaptureDevice *> *_devices;
    NSString *_deviceID;
    KSSetup _setup;
    KSCameraFrame *_frame, *_snapshot;
    NSTimer *_timer;

    NSPopUpButton *_cameraPopup;
    NSButton *_startButton, *_refreshButton;
    NSTextField *_cameraStatus;
    KSCameraView *_picture;
    NSTabView *_tabs;

    // Lens
    NSTextField *_boardCols, *_boardRows, *_lensStatus;
    NSButton *_captureBoardButton, *_calibrateButton, *_clearViewsButton, *_forgetLensButton;
    NSMutableArray<NSValue *> *_boardViews; // KSBoardView in NSValue (pointer to malloc'd copy)
    NSData *_lastCorners;
    NSDate *_lastCornersTime;
    BOOL _detecting;

    // Alignment
    NSTextField *_markCols, *_markRows, *_bedW, *_bedH, *_margin, *_markSize, *_speed, *_power, *_sMax;
    NSButton *_burnButton, *_snapshotButton, *_liveButton, *_undoButton, *_clearClicksButton, *_findRestButton, *_saveAlignButton, *_forgetAlignButton;
    NSTextField *_clickStatus, *_fitStatus;
    NSMutableData *_clicks;   // KSV2 per mark
    NSMutableData *_clicked;  // int per mark
    NSInteger _pick;
    double _burnWcoX, _burnWcoY;
    BOOL _haveBurnWco;

    // Placement
    NSTextField *_moveX, *_moveY, *_turn, *_placeStatus;
    NSButton *_useCheck, *_resetButton;
    KSJob *_toolpathJob;
    KSToolpath *_toolpath;
    BOOL _dragging;
    KSV2 _dragFrom;
}

- (instancetype)initWithHost:(id<KSCameraHost>)host {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1080, 700)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    if ((self = [super initWithWindow:w])) {
        _host = host;
        _boardViews = [NSMutableArray array];
        _clicks = [NSMutableData data];
        _clicked = [NSMutableData data];
        w.title = @"Camera — KerfSender";
        w.contentMinSize = NSMakeSize(900, 600);
        w.releasedWhenClosed = NO;
        w.delegate = self;
        [w center];
        w.frameAutosaveName = @"KerfSenderCamera";
        [self buildWindow];
        [self loadTarget];
        [self refreshDevices:nil];
        [self updateAll];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    [_capture stop];
    [self clearBoardViews];
}

#pragma mark Layout

- (NSTextField *)number:(double)value {
    NSTextField *f = [[NSTextField alloc] init];
    NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
    nf.numberStyle = NSNumberFormatterDecimalStyle;
    nf.maximumFractionDigits = 2;
    nf.usesGroupingSeparator = NO;
    f.formatter = nf;
    f.doubleValue = value;
    f.alignment = NSTextAlignmentRight;
    f.target = self;
    f.action = @selector(fieldChanged:);
    [f.widthAnchor constraintEqualToConstant:80].active = YES;
    return f;
}

- (NSView *)field:(NSString *)title box:(NSTextField *)box unit:(NSString *)unit {
    NSTextField *l = [NSTextField labelWithString:title];
    [l.widthAnchor constraintEqualToConstant:150].active = YES;
    NSTextField *u = [NSTextField labelWithString:unit];
    u.textColor = [NSColor secondaryLabelColor];
    return KSRow(@[ l, box, u ]);
}

- (NSView *)pageWithViews:(NSArray<NSView *> *)views {
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    KSFlippedStackHolder *doc = [[KSFlippedStackHolder alloc] init];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(10, 10, 10, 10);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:stack];
    scroll.documentView = doc;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
        [doc.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [doc.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
    ]];
    return scroll;
}

- (void)buildWindow {
    NSView *content = self.window.contentView;
    CGFloat W = content.bounds.size.width, H = content.bounds.size.height, side = 380;

    NSTextField *cameraLabel = [NSTextField labelWithString:@"Camera:"];
    cameraLabel.frame = NSMakeRect(12, H - 32, 60, 18);
    cameraLabel.autoresizingMask = NSViewMinYMargin;
    _cameraPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(72, H - 38, 260, 26)];
    _cameraPopup.target = self;
    _cameraPopup.action = @selector(cameraChosen:);
    _cameraPopup.autoresizingMask = NSViewMinYMargin;
    _refreshButton = KSCamButton(@"Refresh", self, @selector(refreshDevices:));
    _refreshButton.frame = NSMakeRect(336, H - 40, 90, 30);
    _refreshButton.autoresizingMask = NSViewMinYMargin;
    _startButton = KSCamButton(@"Start camera", self, @selector(toggleCamera:));
    _startButton.frame = NSMakeRect(428, H - 40, 130, 30);
    _startButton.autoresizingMask = NSViewMinYMargin;
    _cameraStatus = [NSTextField labelWithString:@""];
    _cameraStatus.textColor = [NSColor secondaryLabelColor];
    _cameraStatus.frame = NSMakeRect(566, H - 32, W - 580, 18);
    _cameraStatus.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
    for (NSView *v in @[ cameraLabel, _cameraPopup, _refreshButton, _startButton, _cameraStatus ]) [content addSubview:v];

    _picture = [[KSCameraView alloc] initWithFrame:NSMakeRect(10, 10, W - side - 26, H - 58)];
    _picture.owner = self;
    _picture.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_picture];

    _tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(W - side - 10, 6, side, H - 50)];
    _tabs.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    _tabs.delegate = self;
    NSTabViewItem *lens = [[NSTabViewItem alloc] initWithIdentifier:@"lens"];
    lens.label = @"1. Lens";
    lens.view = [self pageWithViews:[self lensControls]];
    NSTabViewItem *align = [[NSTabViewItem alloc] initWithIdentifier:@"align"];
    align.label = @"2. Alignment";
    align.view = [self pageWithViews:[self alignmentControls]];
    NSTabViewItem *place = [[NSTabViewItem alloc] initWithIdentifier:@"place"];
    place.label = @"3. Place job";
    place.view = [self pageWithViews:[self placeControls]];
    for (NSTabViewItem *i in @[ lens, align, place ]) [_tabs addTabViewItem:i];
    [content addSubview:_tabs];
}

- (NSArray<NSView *> *)lensControls {
    _boardCols = [self number:9];
    _boardRows = [self number:6];
    _captureBoardButton = KSCamButton(@"Capture board", self, @selector(captureBoard:));
    _clearViewsButton = KSCamButton(@"Clear views", self, @selector(clearViews:));
    _calibrateButton = KSCamButton(@"Calibrate lens", self, @selector(calibrateLens:));
    _forgetLensButton = KSCamButton(@"Forget lens", self, @selector(forgetLens:));
    _lensStatus = KSNote(@"");
    return @[
        KSNote(@"Optional, but it makes the picture line up much better near the edges. Print a checkerboard (any size of squares), lay it flat under the camera and capture it in 8 to 15 places: middle, every edge and every corner, some of them tilted."),
        [self field:@"Inner corners across" box:_boardCols unit:@""],
        [self field:@"Inner corners down" box:_boardRows unit:@""],
        KSNote(@"Count where four squares meet: a board of 10 × 7 squares has 9 × 6."),
        KSRow(@[ _captureBoardButton, _clearViewsButton ]),
        KSRow(@[ _calibrateButton, _forgetLensButton ]),
        _lensStatus,
    ];
}

- (NSArray<NSView *> *)alignmentControls {
    _markCols = [self number:3];
    _markRows = [self number:3];
    _bedW = [self number:400];
    _bedH = [self number:400];
    _margin = [self number:40];
    _markSize = [self number:12];
    _speed = [self number:1500];
    _power = [self number:25];
    _sMax = [self number:1000];
    _burnButton = KSCamButton(@"Burn target…", self, @selector(burnTarget:));
    _snapshotButton = KSCamButton(@"Take snapshot", self, @selector(takeSnapshot:));
    _liveButton = KSCamButton(@"Back to live", self, @selector(backToLive:));
    _undoButton = KSCamButton(@"Undo last", self, @selector(undoClick:));
    _clearClicksButton = KSCamButton(@"Clear", self, @selector(clearClicksAction:));
    _findRestButton = KSCamButton(@"Find the rest", self, @selector(findRest:));
    _saveAlignButton = KSCamButton(@"Save alignment", self, @selector(saveAlignment:));
    _saveAlignButton.keyEquivalent = @"\r";
    _forgetAlignButton = KSCamButton(@"Forget alignment", self, @selector(forgetAlignment:));
    _clickStatus = KSNote(@"");
    _fitStatus = KSNote(@"");
    return @[
        KSNote(@"Burn marks at known places on the bed, then click them in a snapshot. Do it again if the camera or its mount moves. Calibrate the lens first if you're going to."),
        KSHeading(@"Burn the target"),
        KSNote(@"Home the laser, then cover the bed with scrap card or plywood the camera can see, at the height you usually work."),
        [self field:@"Marks across (2–5)" box:_markCols unit:@""],
        [self field:@"Marks down (2–5)" box:_markRows unit:@""],
        [self field:@"Bed width" box:_bedW unit:@"mm"],
        [self field:@"Bed height" box:_bedH unit:@"mm"],
        [self field:@"Edge margin" box:_margin unit:@"mm"],
        [self field:@"Mark size" box:_markSize unit:@"mm"],
        [self field:@"Speed" box:_speed unit:@"mm/min"],
        [self field:@"Power" box:_power unit:@"%"],
        [self field:@"Full power S value" box:_sMax unit:@"($30)"],
        _burnButton,
        KSHeading(@"Click the marks"),
        KSRow(@[ _snapshotButton, _liveButton ]),
        KSNote(@"Mark 1 has a small inner ring and is the one nearest X 0, Y 0; mark 2 is next to it along X. Clicks snap to the mark's centre; hold Option to place one exactly. After three marks, Find the rest finds the others."),
        _clickStatus,
        KSRow(@[ _undoButton, _clearClicksButton, _findRestButton ]),
        KSHeading(@"Save"),
        _fitStatus,
        KSRow(@[ _saveAlignButton, _forgetAlignButton ]),
    ];
}

- (NSArray<NSView *> *)placeControls {
    _moveX = [self number:0];
    _moveY = [self number:0];
    _turn = [self number:0];
    _useCheck = [NSButton checkboxWithTitle:@"Run the job where it's placed" target:self action:@selector(useChanged:)];
    _resetButton = KSCamButton(@"Reset", self, @selector(resetPlacement:));
    _placeStatus = KSNote(@"");
    return @[
        KSNote(@"The job's outline is drawn on the picture where it will burn. Drag it onto the material, or type a move and a turn."),
        [self field:@"Move X" box:_moveX unit:@"mm"],
        [self field:@"Move Y" box:_moveY unit:@"mm"],
        [self field:@"Turn" box:_turn unit:@"°"],
        _resetButton,
        _useCheck,
        _placeStatus,
        KSNote(@"The red cross is the laser head, from the machine's position reports, so you can check the alignment: jog the head and it should follow."),
    ];
}

#pragma mark Camera

- (void)refreshDevices:(id)sender {
    NSString *current = _deviceID ?: [[NSUserDefaults standardUserDefaults] stringForKey:@"lastCamera"];
    _devices = [KSCameraCapture devices];
    [_cameraPopup removeAllItems];
    for (AVCaptureDevice *d in _devices) [_cameraPopup addItemWithTitle:d.localizedName];
    NSInteger index = -1;
    for (NSUInteger i = 0; i < _devices.count; i++) if ([_devices[i].uniqueID isEqualToString:current]) index = (NSInteger)i;
    if (index < 0 && _devices.count > 0) {
        // Prefer an external (USB) camera over the built-in one.
        index = 0;
        for (NSUInteger i = 0; i < _devices.count; i++) {
            if (![_devices[i].localizedName.lowercaseString containsString:@"facetime"]) { index = (NSInteger)i; break; }
        }
    }
    if (_devices.count == 0) {
        [_cameraPopup addItemWithTitle:@"No camera found"];
        _cameraPopup.lastItem.enabled = NO;
        _cameraPopup.autoenablesItems = NO;
        [self selectDevice:nil];
    } else {
        [_cameraPopup selectItemAtIndex:index];
        [self selectDevice:_devices[(NSUInteger)index]];
    }
    [self updateAll];
}

- (void)cameraChosen:(id)sender {
    NSInteger i = _cameraPopup.indexOfSelectedItem;
    if (i >= 0 && i < (NSInteger)_devices.count) [self selectDevice:_devices[(NSUInteger)i]];
    [self updateAll];
}

- (AVCaptureDevice *)device {
    for (AVCaptureDevice *d in _devices) if ([d.uniqueID isEqualToString:_deviceID]) return d;
    return nil;
}

- (void)selectDevice:(AVCaptureDevice *)d {
    if (d && [d.uniqueID isEqualToString:_deviceID]) return;
    BOOL wasRunning = _capture.isRunning;
    [self stopCamera];
    _deviceID = d.uniqueID;
    [self loadSetup];
    [self clearBoardViews];
    _lensStatus.stringValue = @"";
    _snapshot = nil;
    [self clearClicks];
    if (wasRunning && d) [self startCamera];
}

- (void)toggleCamera:(id)sender {
    if (_capture.isRunning) [self stopCamera];
    else [self startCamera];
    [self updateAll];
}

- (void)startCamera {
    AVCaptureDevice *d = self.device;
    if (!d) return;
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) [self startCamera];
                    else self->_cameraStatus.stringValue = @"Camera access was turned down.";
                    [self updateAll];
                });
            }];
            return;
        }
        if (status != AVAuthorizationStatusAuthorized) {
            _cameraStatus.stringValue = @"KerfSender isn't allowed to use the camera: turn it on in System Preferences › Security & Privacy › Camera.";
            return;
        }
    }
    if (!_capture) _capture = [[KSCameraCapture alloc] init];
    NSString *error = nil;
    if (![_capture startWithDevice:d error:&error]) {
        _cameraStatus.stringValue = error ?: @"The camera couldn't start.";
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:d.uniqueID forKey:@"lastCamera"];
    _cameraStatus.stringValue = @"Starting…";
    if (!_timer) {
        _timer = [NSTimer timerWithTimeInterval:0.08 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

- (void)stopCamera {
    [_timer invalidate];
    _timer = nil;
    [_capture stop];
    _cameraStatus.stringValue = @"";
}

- (void)tick:(NSTimer *)t {
    KSCameraFrame *f = [_capture latest];
    if (!f || f == _frame) return;
    BOOL first = _frame == nil;
    _frame = f;
    _cameraStatus.stringValue = [NSString stringWithFormat:@"%d × %d", f.width, f.height];
    if (!_snapshot) _picture.needsDisplay = YES;
    if (first) [self updateAll];
    else [self updatePlaceStatus];
}

- (KSCameraFrame *)shown { return _snapshot ?: _frame; }

- (void)windowWillClose:(NSNotification *)note {
    [self stopCamera];
    [self saveTarget];
    [self updateAll];
}

#pragma mark Storage

- (void)loadSetup {
    memset(&_setup, 0, sizeof _setup);
    if (!_deviceID) return;
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"cameraSetups"];
    NSDictionary *d = all[_deviceID];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSArray *l = d[@"lens"];
    if ([l isKindOfClass:[NSArray class]] && l.count >= 13) {
        KSLens lens = { [l[0] intValue], [l[1] intValue], [l[2] doubleValue], [l[3] doubleValue], [l[4] doubleValue], [l[5] doubleValue],
                        [l[6] doubleValue], [l[7] doubleValue], [l[8] doubleValue], [l[9] doubleValue], [l[10] doubleValue], [l[11] doubleValue], [l[12] intValue] };
        _setup.hasLens = 1;
        _setup.lens = lens;
    }
    NSArray *a = d[@"align"];
    if ([a isKindOfClass:[NSArray class]] && a.count >= 14) {
        _setup.hasAlignment = 1;
        _setup.alignWidth = [a[0] intValue];
        _setup.alignHeight = [a[1] intValue];
        for (int i = 0; i < 9; i++) _setup.imageToBed.m[i] = [a[2 + (NSUInteger)i] doubleValue];
        _setup.rms = [a[11] doubleValue];
        _setup.maxErr = [a[12] doubleValue];
        _setup.date = [a[13] doubleValue];
    }
    ks_setup_prepare(&_setup);
}

- (void)saveSetup {
    ks_setup_prepare(&_setup);
    if (!_deviceID) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *all = [[ud dictionaryForKey:@"cameraSetups"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (_setup.hasLens) {
        KSLens l = _setup.lens;
        d[@"lens"] = @[ @(l.width), @(l.height), @(l.fx), @(l.fy), @(l.cx), @(l.cy), @(l.k1), @(l.k2), @(l.k3), @(l.p1), @(l.p2), @(l.rms), @(l.views) ];
    }
    if (_setup.hasAlignment) {
        NSMutableArray *a = [NSMutableArray arrayWithObjects:@(_setup.alignWidth), @(_setup.alignHeight), nil];
        for (int i = 0; i < 9; i++) [a addObject:@(_setup.imageToBed.m[i])];
        [a addObjectsFromArray:@[ @(_setup.rms), @(_setup.maxErr), @(_setup.date) ]];
        d[@"align"] = a;
    }
    all[_deviceID] = d;
    [ud setObject:all forKey:@"cameraSetups"];
}

- (void)loadTarget {
    NSDictionary *t = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"cameraTarget"];
    NSDictionary *fields = @{ @"columns" : _markCols, @"rows" : _markRows, @"margin" : _margin, @"markSize" : _markSize,
                              @"speed" : _speed, @"power" : _power, @"sMax" : _sMax, @"bedWidth" : _bedW, @"bedHeight" : _bedH };
    for (NSString *k in fields) {
        id v = t[k];
        if ([v isKindOfClass:[NSNumber class]]) ((NSTextField *)fields[k]).doubleValue = [v doubleValue];
    }
    if ([t[@"burnWcoX"] isKindOfClass:[NSNumber class]] && [t[@"burnWcoY"] isKindOfClass:[NSNumber class]]) {
        _burnWcoX = [t[@"burnWcoX"] doubleValue];
        _burnWcoY = [t[@"burnWcoY"] doubleValue];
        _haveBurnWco = YES;
    }
    [self clearClicks];
}

- (void)saveTarget {
    NSMutableDictionary *t = [@{ @"columns" : @(self.markColumns), @"rows" : @(self.markRowCount), @"margin" : @(_margin.doubleValue),
                                 @"markSize" : @(_markSize.doubleValue), @"speed" : @(_speed.doubleValue), @"power" : @(_power.doubleValue),
                                 @"sMax" : @(_sMax.doubleValue), @"bedWidth" : @(_bedW.doubleValue), @"bedHeight" : @(_bedH.doubleValue) } mutableCopy];
    if (_haveBurnWco) {
        t[@"burnWcoX"] = @(_burnWcoX);
        t[@"burnWcoY"] = @(_burnWcoY);
    }
    [[NSUserDefaults standardUserDefaults] setObject:t forKey:@"cameraTarget"];
}

#pragma mark Lens

- (void)clearBoardViews {
    for (NSValue *v in _boardViews) {
        KSBoardView *b = v.pointerValue;
        ks_board_free(b);
        free(b);
    }
    [_boardViews removeAllObjects];
}

- (void)captureBoard:(id)sender {
    KSCameraFrame *f = _frame;
    if (!f || _detecting) return;
    if (_boardViews.count > 0) {
        KSBoardView *first = _boardViews[0].pointerValue;
        if (first->width != f.width || first->height != f.height) [self clearBoardViews];
    }
    int cols = (int)lround(_boardCols.doubleValue), rows = (int)lround(_boardRows.doubleValue);
    _detecting = YES;
    _lensStatus.stringValue = @"Looking for the board…";
    [self updateAll];
    const uint8_t *gray = f.gray;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        KSBoardView *view = calloc(1, sizeof(KSBoardView));
        int ok = ks_board_detect(gray, f.width, f.height, cols, rows, view);
        (void)f; // keeps the frame (and its gray bytes) alive until detection ends
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_detecting = NO;
            if (!ok) {
                free(view);
                self->_lensStatus.stringValue = @"The board wasn't found. Check the corner counts, and that the whole board is in the picture, evenly lit and in focus.";
            } else {
                [self->_boardViews addObject:[NSValue valueWithPointer:view]];
                self->_lastCorners = [NSData dataWithBytes:view->image length:sizeof(KSV2) * (size_t)view->count];
                self->_lastCornersTime = [NSDate date];
                NSUInteger n = self->_boardViews.count;
                self->_lensStatus.stringValue = [NSString stringWithFormat:@"Board found (%lu view%@). Move it somewhere else and capture again.",
                                                 (unsigned long)n, n == 1 ? @"" : @"s"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    self->_picture.needsDisplay = YES;
                });
            }
            [self updateAll];
        });
    });
}

- (void)clearViews:(id)sender {
    [self clearBoardViews];
    _lastCorners = nil;
    [self updateAll];
}

- (void)calibrateLens:(id)sender {
    int n = (int)_boardViews.count;
    if (n < KS_MIN_VIEWS) return;
    KSBoardView *views = malloc(sizeof(KSBoardView) * (size_t)n);
    for (int i = 0; i < n; i++) views[i] = *(KSBoardView *)_boardViews[(NSUInteger)i].pointerValue;
    KSLens lens;
    [[NSCursor operationNotAllowedCursor] push];
    int ok = ks_lens_calibrate(views, n, &lens);
    [NSCursor pop];
    free(views);
    if (!ok) {
        _lensStatus.stringValue = @"Calibration failed. Clear the views and capture the board again in more places.";
        return;
    }
    NSMutableString *msg = [NSMutableString string];
    if (_setup.hasAlignment) {
        // An alignment made through the old lens no longer fits.
        _setup.hasAlignment = 0;
        [msg appendString:@"The alignment was cleared because the lens changed; align again. "];
    }
    _setup.hasLens = 1;
    _setup.lens = lens;
    [msg appendFormat:@"Lens calibrated from %d views: corners fit within %.2f px. Distortion at the corners %.1f%%.",
                      lens.views, lens.rms, ks_lens_corner_distortion(&lens) * 100];
    if (lens.rms > 1.0) [msg appendString:@" That's a loose fit: capture more views, keeping the board still and flat."];
    _lensStatus.stringValue = msg;
    [self saveSetup];
    [self updateAll];
}

- (void)forgetLens:(id)sender {
    _setup.hasLens = 0;
    [self saveSetup];
    _lensStatus.stringValue = @"Lens forgotten.";
    [self updateAll];
}

#pragma mark Alignment

- (int)markColumns { return MAX(2, MIN(5, (int)lround(_markCols.doubleValue))); }
- (int)markRowCount { return MAX(2, MIN(5, (int)lround(_markRows.doubleValue))); }
- (int)markCount { return self.markColumns * self.markRowCount; }

/// Mark centres in work coordinates, numbered along X, then Y.
- (KSV2)markWork:(int)k {
    double bw = _bedW.doubleValue, bh = _bedH.doubleValue;
    double m = MAX(0, MIN(_margin.doubleValue, MIN(bw, bh) / 2 - 5));
    int c = self.markColumns, r = self.markRowCount;
    int i = k % c, j = k / c;
    return ks_v2(m + (bw - 2 * m) * i / (c - 1), m + (bh - 2 * m) * j / (r - 1));
}

- (KSV2)markMachine:(int)k {
    KSGrbl *g = [_host cameraGrbl];
    KSV2 p = [self markWork:k];
    return ks_v2(p.x + (_haveBurnWco ? _burnWcoX : g.wcoX), p.y + (_haveBurnWco ? _burnWcoY : g.wcoY));
}

- (KSV2 *)clickPoints { return _clicks.mutableBytes; }
- (int *)clickFlags { return _clicked.mutableBytes; }

- (void)clearClicks {
    int n = self.markCount;
    _clicks.length = 0;
    _clicks.length = sizeof(KSV2) * (size_t)n;
    _clicked.length = 0;
    _clicked.length = sizeof(int) * (size_t)n;
    _pick = 0;
}

- (int)clickedCount {
    int n = 0;
    for (int i = 0; i < self.markCount && i < (int)(_clicked.length / sizeof(int)); i++) n += self.clickFlags[i] ? 1 : 0;
    return n;
}

- (void)fieldChanged:(id)sender {
    if (sender == _markCols || sender == _markRows || sender == _margin || sender == _bedW || sender == _bedH) [self clearClicks];
    if (sender == _moveX || sender == _moveY || sender == _turn) _useCheck.state = self.placed ? NSControlStateValueOn : NSControlStateValueOff;
    [self saveTarget];
    [self updateAll];
}

- (void)burnTarget:(id)sender {
    KSGrbl *g = [_host cameraGrbl];
    int n = self.markCount;
    NSMutableArray *marks = [NSMutableArray array];
    double minX = DBL_MAX, maxX = -DBL_MAX, minY = DBL_MAX, maxY = -DBL_MAX;
    for (int k = 0; k < n; k++) {
        KSV2 m = [self markWork:k];
        [marks addObject:[NSValue valueWithPoint:NSMakePoint(m.x, m.y)]];
        minX = MIN(minX, m.x); maxX = MAX(maxX, m.x); minY = MIN(minY, m.y); maxY = MAX(maxY, m.y);
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Burn the alignment target?";
    a.informativeText = [NSString stringWithFormat:@"The laser will burn %d marks between X %.0f–%.0f and Y %.0f–%.0f mm (work coordinates, so home the machine, or set the origin at machine home, first), at %.0f%% power. Stay with the machine.",
                                                   n, minX, maxX, minY, maxY, _power.doubleValue];
    a.alertStyle = NSAlertStyleWarning;
    [a addButtonWithTitle:@"Burn"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    _burnWcoX = g.wcoX;
    _burnWcoY = g.wcoY;
    _haveBurnWco = YES;
    [self saveTarget];
    [self clearClicks];
    [g run:[KSToolpath targetGcodeForMarks:marks size:_markSize.doubleValue feed:_speed.doubleValue power:_power.doubleValue sMax:_sMax.doubleValue]];
    [self updateAll];
}

- (void)takeSnapshot:(id)sender {
    if (!_frame) return;
    _snapshot = _frame;
    [self clearClicks];
    [self updateAll];
}

- (void)backToLive:(id)sender {
    _snapshot = nil;
    [self clearClicks];
    [self updateAll];
}

- (void)undoClick:(id)sender {
    int n = self.markCount, last = -1;
    for (int i = (int)MIN(_pick, (NSInteger)n) - 1; i >= 0; i--) if (self.clickFlags[i]) { last = i; break; }
    if (last < 0) for (int i = n - 1; i >= 0; i--) if (self.clickFlags[i]) { last = i; break; }
    if (last < 0) return;
    self.clickFlags[last] = 0;
    _pick = last;
    [self updateAll];
}

- (void)clearClicksAction:(id)sender {
    [self clearClicks];
    [self updateAll];
}

- (double)snapRadius:(KSCameraFrame *)f {
    int n = self.markCount, a = -1, b = -1;
    for (int i = 0; i < n; i++) if (self.clickFlags[i]) { if (a < 0) a = i; else if (b < 0) { b = i; break; } }
    if (b >= 0) {
        KSV2 ma = [self markWork:a], mb = [self markWork:b];
        double mm = hypot(ma.x - mb.x, ma.y - mb.y);
        KSV2 pa = self.clickPoints[a], pb = self.clickPoints[b];
        if (mm > 1) return MAX(6, hypot(pa.x - pb.x, pa.y - pb.y) / mm * _markSize.doubleValue * 0.75);
    }
    return f.width * 0.03;
}

- (void)nextPick {
    int n = self.markCount;
    _pick = n;
    for (int i = 0; i < n; i++) if (!self.clickFlags[i]) { _pick = i; break; }
}

- (void)clickMarkAt:(KSV2)q snap:(BOOL)snap {
    KSCameraFrame *f = _snapshot;
    if (!f || _pick >= self.markCount) return;
    KSV2 p = q, s;
    if (snap && ks_snap_to_mark(f.gray, f.width, f.height, q, [self snapRadius:f], &s)) p = s;
    self.clickPoints[_pick] = p;
    self.clickFlags[_pick] = 1;
    [self nextPick];
    [self updateAll];
}

- (void)findRest:(id)sender {
    KSCameraFrame *f = _snapshot;
    if (!f) return;
    int n = self.markCount;
    KSV2 *marks = malloc(sizeof(KSV2) * (size_t)n), *guess = malloc(sizeof(KSV2) * (size_t)n);
    int *have = malloc(sizeof(int) * (size_t)n);
    for (int k = 0; k < n; k++) marks[k] = [self markWork:k];
    ks_predict_marks(marks, n, self.clickPoints, self.clickFlags, guess, have);
    double radius = [self snapRadius:f] * 1.5;
    int missed = 0;
    for (int k = 0; k < n; k++) {
        if (self.clickFlags[k] || !have[k]) continue;
        KSV2 s;
        if (ks_snap_to_mark(f.gray, f.width, f.height, guess[k], radius, &s)) {
            self.clickPoints[k] = s;
            self.clickFlags[k] = 1;
        } else missed++;
    }
    free(marks); free(guess); free(have);
    [self nextPick];
    if (missed > 0) [_host cameraLog:[NSString stringWithFormat:@"Camera: %d mark(s) weren't found; click them yourself.", missed] isError:NO];
    [self updateAll];
}

- (BOOL)alignmentFit:(KSHomography *)h rms:(double *)rms max:(double *)maxErr {
    KSCameraFrame *f = _snapshot;
    if (!f) return NO;
    KSLens lens;
    BOOL useLens = _setup.hasLens && ks_lens_scaled(&_setup.lens, f.width, f.height, &lens);
    int n = self.markCount, k = 0;
    KSV2 *img = malloc(sizeof(KSV2) * (size_t)n), *bed = malloc(sizeof(KSV2) * (size_t)n);
    for (int i = 0; i < n; i++) {
        if (!self.clickFlags[i]) continue;
        img[k] = useLens ? ks_lens_undistort_pixel(&lens, self.clickPoints[i]) : self.clickPoints[i];
        bed[k] = [self markMachine:i];
        k++;
    }
    BOOL ok = ks_fit_alignment(img, bed, k, h, rms, maxErr);
    free(img);
    free(bed);
    return ok;
}

- (void)saveAlignment:(id)sender {
    KSCameraFrame *f = _snapshot;
    KSHomography h;
    double rms, maxErr;
    if (!f || ![self alignmentFit:&h rms:&rms max:&maxErr]) return;
    KSLens scaled;
    if (_setup.hasLens && !ks_lens_scaled(&_setup.lens, f.width, f.height, &scaled)) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"The camera's picture size changed since the lens was calibrated.";
        a.informativeText = @"Calibrate the lens again.";
        [a runModal];
        return;
    }
    _setup.hasAlignment = 1;
    _setup.alignWidth = f.width;
    _setup.alignHeight = f.height;
    _setup.imageToBed = h;
    _setup.rms = rms;
    _setup.maxErr = maxErr;
    _setup.date = [[NSDate date] timeIntervalSince1970];
    [self saveSetup];
    _snapshot = nil;
    [self clearClicks];
    [_host cameraLog:[NSString stringWithFormat:@"Camera aligned: marks within %.2f mm on average (worst %.2f mm).", rms, maxErr] isError:NO];
    [_tabs selectTabViewItemAtIndex:2];
    [self updateAll];
}

- (void)forgetAlignment:(id)sender {
    _setup.hasAlignment = 0;
    [self saveSetup];
    [self updateAll];
}

#pragma mark Placement

- (BOOL)placed { return _moveX.doubleValue != 0 || _moveY.doubleValue != 0 || _turn.doubleValue != 0; }

- (void)setPlacementX:(double)x y:(double)y turn:(double)t {
    _moveX.doubleValue = round(x * 10) / 10;
    _moveY.doubleValue = round(y * 10) / 10;
    _turn.doubleValue = round(t * 10) / 10;
}

- (KSToolpath *)toolpath {
    KSJob *job = [_host cameraCurrentJob];
    if (!job || !job.usesGrbl) {
        _toolpath = nil;
        _toolpathJob = nil;
        return nil;
    }
    if (job != _toolpathJob) {
        _toolpathJob = job;
        _toolpath = [KSToolpath toolpathFromLines:job.gcodeLines];
        [self setPlacementX:0 y:0 turn:0];
        _useCheck.state = NSControlStateValueOff;
    }
    return _toolpath;
}

- (BOOL)placementActive {
    KSToolpath *tp = self.toolpath;
    return _useCheck.state == NSControlStateValueOn && self.placed && tp && !tp.isEmpty;
}

- (NSString *)placementDescription {
    return [NSString stringWithFormat:@"moved X %.1f mm, Y %.1f mm, turned %.1f°", _moveX.doubleValue, _moveY.doubleValue, _turn.doubleValue];
}

- (NSArray<NSString *> *)placedLinesForJob:(KSJob *)job error:(NSString **)error {
    KSToolpath *tp = self.toolpath;
    if (!tp || tp.isEmpty) {
        if (error) *error = @"The job has no moves to place.";
        return nil;
    }
    return [KSToolpath transformLines:job.gcodeLines pivotX:(tp.minX + tp.maxX) / 2 pivotY:(tp.minY + tp.maxY) / 2
                              degrees:_turn.doubleValue dx:_moveX.doubleValue dy:_moveY.doubleValue error:error];
}

- (void)useChanged:(id)sender { [self updateAll]; }

- (void)resetPlacement:(id)sender {
    [self setPlacementX:0 y:0 turn:0];
    _useCheck.state = NSControlStateValueOff;
    [self updateAll];
}

- (void)updatePlaceStatus {
    if ([_tabs indexOfTabViewItem:_tabs.selectedTabViewItem] != 2) return;
    KSToolpath *tp = self.toolpath;
    KSGrbl *g = [_host cameraGrbl];
    NSString *s;
    if (!_setup.hasAlignment) s = @"Align the camera first (step 2).";
    else if (![_host cameraCurrentJob]) s = @"Open a job in the main window.";
    else if (!tp) s = @"This job isn't G-code, so it can't be placed with the camera.";
    else if (tp.isEmpty) s = @"The job has no burning moves to show.";
    else if (tp.hasRelativeMoves) s = @"The job uses relative moves (G91), so it can't be moved here.";
    else {
        NSMutableString *m = [NSMutableString stringWithFormat:@"Job: %.1f × %.1f mm.", tp.maxX - tp.minX, tp.maxY - tp.minY];
        if (!g.isConnected) [m appendString:@" Connect the machine so the outline uses its current origin."];
        else if (!g.hasWorkOffset) [m appendString:@" Waiting for the machine to report its origin…"];
        if (self.placementActive) [m appendString:@" Start in the main window runs it as placed."];
        s = m;
    }
    if (![_placeStatus.stringValue isEqualToString:s]) _placeStatus.stringValue = s;
}

#pragma mark Drawing

typedef struct { double scale, offX, offY; } KSFit;

- (BOOL)fit:(KSFit *)fit {
    KSCameraFrame *f = self.shown;
    NSSize b = _picture.bounds.size;
    if (!f || f.width <= 0 || f.height <= 0) return NO;
    double s = MIN(b.width / f.width, b.height / f.height);
    if (s <= 0) return NO;
    fit->scale = s;
    fit->offX = (b.width - f.width * s) / 2;
    fit->offY = (b.height - f.height * s) / 2;
    return YES;
}

static NSPoint KSToView(KSFit f, KSV2 p) { return NSMakePoint(f.offX + (p.x + 0.5) * f.scale, f.offY + (p.y + 0.5) * f.scale); }
static KSV2 KSToImage(KSFit f, NSPoint v) { return ks_v2((v.x - f.offX) / f.scale - 0.5, (v.y - f.offY) / f.scale - 0.5); }

- (void)drawPicture:(NSRect)bounds {
    [[NSColor colorWithWhite:0.16 alpha:1] setFill];
    NSRectFill(bounds);
    KSCameraFrame *f = self.shown;
    KSFit fit;
    if (!f || ![self fit:&fit]) {
        NSString *t = _devices.count == 0 ? @"No camera found. Plug in the USB camera and press Refresh." : @"Press Start camera.";
        NSDictionary *attrs = @{ NSForegroundColorAttributeName : [NSColor colorWithWhite:0.85 alpha:1], NSFontAttributeName : [NSFont systemFontOfSize:13] };
        NSSize sz = [t sizeWithAttributes:attrs];
        [t drawAtPoint:NSMakePoint((bounds.size.width - sz.width) / 2, (bounds.size.height - sz.height) / 2) withAttributes:attrs];
        return;
    }
    [f.image drawInRect:NSMakeRect(fit.offX, fit.offY, f.width * fit.scale, f.height * fit.scale) fromRect:NSZeroRect
              operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
    NSInteger tab = [_tabs indexOfTabViewItem:_tabs.selectedTabViewItem];
    if (tab == 0 && _lastCorners && -[_lastCornersTime timeIntervalSinceNow] < 4) {
        [[NSColor greenColor] setStroke];
        const KSV2 *c = _lastCorners.bytes;
        for (NSUInteger i = 0; i < _lastCorners.length / sizeof(KSV2); i++) {
            NSPoint v = KSToView(fit, c[i]);
            NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(v.x - 4, v.y - 4, 8, 8)];
            p.lineWidth = 2;
            [p stroke];
        }
    }
    if (tab == 1 && _snapshot) [self drawClicks:fit];
    if (tab == 2) [self drawJob:fit frame:f];
    if (_setup.hasAlignment && tab != 1) [self drawHead:fit frame:f];
}

- (void)drawClicks:(KSFit)fit {
    NSColor *orange = [NSColor orangeColor];
    [orange setStroke];
    NSDictionary *attrs = @{ NSForegroundColorAttributeName : orange, NSFontAttributeName : [NSFont boldSystemFontOfSize:11] };
    for (int i = 0; i < self.markCount; i++) {
        if (!self.clickFlags[i]) continue;
        NSPoint v = KSToView(fit, self.clickPoints[i]);
        NSBezierPath *p = [NSBezierPath bezierPath];
        p.lineWidth = 2;
        [p moveToPoint:NSMakePoint(v.x - 8, v.y)];
        [p lineToPoint:NSMakePoint(v.x + 8, v.y)];
        [p moveToPoint:NSMakePoint(v.x, v.y - 8)];
        [p lineToPoint:NSMakePoint(v.x, v.y + 8)];
        [p stroke];
        [[NSString stringWithFormat:@"%d", i + 1] drawAtPoint:NSMakePoint(v.x + 6, v.y + 3) withAttributes:attrs];
    }
}

- (void)drawHead:(KSFit)fit frame:(KSCameraFrame *)f {
    KSGrbl *g = [_host cameraGrbl];
    if (!g.hasMachinePosition) return;
    KSV2 q;
    if (!ks_setup_bed_to_image(&_setup, ks_v2(g.machineX, g.machineY), f.width, f.height, &q)) return;
    NSPoint v = KSToView(fit, q);
    [[NSColor redColor] setStroke];
    NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(v.x - 7, v.y - 7, 14, 14)];
    [p moveToPoint:NSMakePoint(v.x - 12, v.y)];
    [p lineToPoint:NSMakePoint(v.x + 12, v.y)];
    [p moveToPoint:NSMakePoint(v.x, v.y - 12)];
    [p lineToPoint:NSMakePoint(v.x, v.y + 12)];
    p.lineWidth = 2;
    [p stroke];
}

/// Work point -> placed -> machine -> picture -> view. NO where the camera can't see it.
- (BOOL)viewPoint:(KSV2)p centre:(KSV2)c ca:(double)ca sa:(double)sa fit:(KSFit)fit frame:(KSCameraFrame *)f out:(NSPoint *)out {
    KSGrbl *g = [_host cameraGrbl];
    double dx = p.x - c.x, dy = p.y - c.y;
    KSV2 w = ks_v2(c.x + dx * ca - dy * sa + _moveX.doubleValue, c.y + dx * sa + dy * ca + _moveY.doubleValue);
    KSV2 q;
    if (!ks_setup_bed_to_image(&_setup, ks_v2(w.x + g.wcoX, w.y + g.wcoY), f.width, f.height, &q)) return NO;
    *out = KSToView(fit, q);
    return YES;
}

- (void)strokePoints:(const KSV2 *)pts count:(NSUInteger)n centre:(KSV2)c ca:(double)ca sa:(double)sa fit:(KSFit)fit
               frame:(KSCameraFrame *)f densify:(BOOL)densify path:(NSBezierPath *)path {
    BOOL down = NO;
    NSPoint v;
    for (NSUInteger i = 0; i < n; i++) {
        if (densify && i > 0) {
            double len = hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
            int steps = MIN(200, (int)(len / 4));
            for (int k = 1; k < steps; k++) {
                double t = (double)k / steps;
                KSV2 m = ks_v2(pts[i - 1].x + (pts[i].x - pts[i - 1].x) * t, pts[i - 1].y + (pts[i].y - pts[i - 1].y) * t);
                if ([self viewPoint:m centre:c ca:ca sa:sa fit:fit frame:f out:&v]) {
                    if (down) [path lineToPoint:v]; else [path moveToPoint:v];
                    down = YES;
                } else down = NO;
            }
        }
        if ([self viewPoint:pts[i] centre:c ca:ca sa:sa fit:fit frame:f out:&v]) {
            if (down) [path lineToPoint:v]; else [path moveToPoint:v];
            down = YES;
        } else down = NO;
    }
}

- (void)drawJob:(KSFit)fit frame:(KSCameraFrame *)f {
    KSToolpath *tp = self.toolpath;
    if (!tp || tp.isEmpty || !_setup.hasAlignment) return;
    KSV2 c = ks_v2((tp.minX + tp.maxX) / 2, (tp.minY + tp.maxY) / 2);
    double a = _turn.doubleValue * M_PI / 180, ca = cos(a), sa = sin(a);
    BOOL curved = _setup.hasLensAtAlignment;
    KSV2 box[5] = { { tp.minX, tp.minY }, { tp.maxX, tp.minY }, { tp.maxX, tp.maxY }, { tp.minX, tp.maxY }, { tp.minX, tp.minY } };
    NSBezierPath *outline = [NSBezierPath bezierPath];
    [self strokePoints:box count:5 centre:c ca:ca sa:sa fit:fit frame:f densify:YES path:outline];
    CGFloat dash[2] = { 5, 4 };
    [outline setLineDash:dash count:2 phase:0];
    outline.lineWidth = 1;
    [[NSColor colorWithRed:1 green:0.86 blue:0 alpha:0.85] setStroke];
    [outline stroke];
    if (tp.pointCount <= 150000) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        for (NSData *b in tp.burns)
            [self strokePoints:b.bytes count:b.length / sizeof(KSV2) centre:c ca:ca sa:sa fit:fit frame:f densify:curved path:path];
        path.lineWidth = 1.5;
        [[NSColor colorWithRed:0 green:0.78 blue:1 alpha:0.9] setStroke];
        [path stroke];
    }
}

#pragma mark Mouse

- (BOOL)eventToBed:(NSEvent *)event bed:(KSV2 *)bed {
    KSCameraFrame *f = self.shown;
    KSFit fit;
    if (!f || ![self fit:&fit]) return NO;
    NSPoint v = [_picture convertPoint:event.locationInWindow fromView:nil];
    return ks_setup_image_to_bed(&_setup, KSToImage(fit, v), f.width, f.height, bed);
}

- (void)pictureMouseDown:(NSEvent *)event {
    KSFit fit;
    if (![self fit:&fit]) return;
    NSInteger tab = [_tabs indexOfTabViewItem:_tabs.selectedTabViewItem];
    _dragging = NO;
    if (tab == 1 && _snapshot) {
        KSV2 q = KSToImage(fit, [_picture convertPoint:event.locationInWindow fromView:nil]);
        if (q.x < 0 || q.y < 0 || q.x >= _snapshot.width || q.y >= _snapshot.height) return;
        [self clickMarkAt:q snap:(event.modifierFlags & NSEventModifierFlagOption) == 0];
    } else if (tab == 2 && _setup.hasAlignment && self.toolpath) {
        KSV2 b;
        if ([self eventToBed:event bed:&b]) {
            _dragging = YES;
            _dragFrom = b;
        }
    }
}

- (void)pictureMouseDragged:(NSEvent *)event {
    if (!_dragging) return;
    KSV2 b;
    if (![self eventToBed:event bed:&b]) return;
    double dx = b.x - _dragFrom.x, dy = b.y - _dragFrom.y;
    _dragFrom = b;
    // Keep the unrounded drag in the fields' values by applying the rounding only for display.
    _moveX.doubleValue = _moveX.doubleValue + dx;
    _moveY.doubleValue = _moveY.doubleValue + dy;
    _useCheck.state = self.placed ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateAll];
}

#pragma mark Updates

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item {
    [self updateAll];
}

- (void)jobOpened:(KSJob *)job {
    if (job.bedWidth > 0 && job.bedHeight > 0) {
        _bedW.doubleValue = job.bedWidth;
        _bedH.doubleValue = job.bedHeight;
        [self clearClicks];
    }
    [self updateAll];
}

- (void)machineChanged {
    if (self.window.visible) [self updateAll];
}

- (void)updateAll {
    BOOL running = _capture.isRunning;
    KSGrbl *g = [_host cameraGrbl];
    _startButton.title = running ? @"Stop camera" : @"Start camera";
    _startButton.enabled = self.device != nil;

    _captureBoardButton.enabled = running && _frame && !_detecting;
    NSUInteger views = _boardViews.count;
    _calibrateButton.enabled = views >= KS_MIN_VIEWS;
    _calibrateButton.title = views > 0 ? [NSString stringWithFormat:@"Calibrate lens (%lu views)", (unsigned long)views] : @"Calibrate lens";
    _clearViewsButton.enabled = views > 0;
    _forgetLensButton.enabled = _setup.hasLens;
    if (_lensStatus.stringValue.length == 0) {
        _lensStatus.stringValue = _setup.hasLens ? [NSString stringWithFormat:@"Lens calibrated (%d views, %.2f px).", _setup.lens.views, _setup.lens.rms]
                                                 : @"Not calibrated.";
    }

    BOOL laser = [_host cameraMachineIsLaser];
    _burnButton.enabled = laser && g.isConnected && !g.isRunning;
    _snapshotButton.title = _snapshot ? @"Retake snapshot" : @"Take snapshot";
    _snapshotButton.enabled = running && _frame;
    _liveButton.enabled = _snapshot != nil;
    int clicked = self.clickedCount, n = self.markCount;
    _undoButton.enabled = _clearClicksButton.enabled = clicked > 0;
    _findRestButton.enabled = _snapshot && clicked >= 3 && clicked < n;
    if (!_snapshot) {
        _clickStatus.stringValue = laser ? @"Take a snapshot once the target is burned."
                                         : @"Pick GRBL laser as the machine type in the main window to burn the target.";
    } else if (_pick < n) {
        KSV2 m = [self markWork:(int)_pick];
        _clickStatus.stringValue = [NSString stringWithFormat:@"Click mark %ld of %d (X %.0f, Y %.0f).", (long)_pick + 1, n, m.x, m.y];
    } else {
        _clickStatus.stringValue = @"All marks clicked.";
    }
    KSHomography h;
    double rms = 0, maxErr = 0;
    BOOL fitted = [self alignmentFit:&h rms:&rms max:&maxErr];
    _saveAlignButton.enabled = fitted;
    if (fitted) {
        NSString *s = [NSString stringWithFormat:@"The marks fit within %.2f mm on average (worst %.2f mm).", rms, maxErr];
        if (maxErr > 1.5) s = [s stringByAppendingString:@" A big error usually means a mark was clicked out of order, or the lens needs calibrating."];
        _fitStatus.stringValue = s;
        _fitStatus.textColor = maxErr > 1.5 ? [NSColor orangeColor] : [NSColor secondaryLabelColor];
    } else {
        _fitStatus.textColor = [NSColor secondaryLabelColor];
        if (_setup.hasAlignment) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateStyle = NSDateFormatterMediumStyle;
            df.timeStyle = NSDateFormatterShortStyle;
            _fitStatus.stringValue = [NSString stringWithFormat:@"Aligned %@ (marks within %.2f mm). Click at least 4 marks to align again.",
                                      [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:_setup.date]], _setup.rms];
        } else {
            _fitStatus.stringValue = @"Not aligned. Click at least 4 marks.";
        }
    }
    _forgetAlignButton.enabled = _setup.hasAlignment;

    KSToolpath *tp = self.toolpath;
    BOOL canPlace = _setup.hasAlignment && tp && !tp.isEmpty && !tp.hasRelativeMoves;
    _moveX.enabled = _moveY.enabled = _turn.enabled = _resetButton.enabled = _useCheck.enabled = canPlace;
    [self updatePlaceStatus];
    _picture.needsDisplay = YES;
}

@end
