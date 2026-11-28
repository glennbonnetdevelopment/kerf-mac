#import "KerfSender.h"

@interface KSFlippedView : NSView
@end

@implementation KSFlippedView
- (BOOL)isFlipped { return YES; }
@end

static NSTextField *KSLabel(NSString *text) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

static NSButton *KSButton(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bezelStyle = NSBezelStyleRounded;
    return b;
}

@implementation KSAppDelegate {
    NSWindow *_window;
    KSFlippedView *_content;

    NSButton *_openButton, *_cameraButton;
    KSCameraWindowController *_camera;
    NSTextField *_jobTitle, *_jobSummary;

    NSBox *_connectionBox;
    KSFlippedView *_connectionView;
    NSTextField *_kindLabel, *_outputLabel, *_portLabel, *_baudLabel, *_printerLabel, *_flowLabel;
    NSPopUpButton *_kindPopup, *_outputPopup, *_portPopup, *_printerPopup, *_flowPopup;
    NSComboBox *_baudCombo;
    NSButton *_refreshButton;

    NSBox *_controlBox;
    KSFlippedView *_controlView;
    NSButton *_connectButton, *_homeButton, *_unlockButton, *_originButton, *_goOriginButton;
    NSTextField *_statusLabel, *_stepLabel;
    NSPopUpButton *_stepPopup;
    NSArray<NSButton *> *_jogButtons;

    NSButton *_startButton, *_pauseButton, *_stopButton;
    NSProgressIndicator *_progress;
    NSScrollView *_logScroll;
    NSTextView *_log;

    KSGrbl *_grbl;
    KSCutter *_cutter;
    KSJob *_job;
    NSString *_pendingOpen;
}

#pragma mark - Launch

- (void)applicationWillFinishLaunching:(NSNotification *)note {
    [self buildMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _grbl = [[KSGrbl alloc] init];
    _grbl.delegate = self;
    _cutter = [[KSCutter alloc] init];
    __weak KSAppDelegate *weakSelf = self;
    _cutter.onProgress = ^(double f) { [weakSelf setProgress:f]; };
    _cutter.onFinished = ^(NSString *message, BOOL isError) {
        [weakSelf grblLog:message isError:isError];
        [weakSelf updateControls];
    };

    [self buildWindow];
    [self refreshPorts:nil];
    [self updateMachineFields];
    [self updateControls];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (_pendingOpen) [self openJobAtPath:_pendingOpen];
    _pendingOpen = nil;
}

- (BOOL)application:(NSApplication *)app openFile:(NSString *)path {
    if (!_window) {
        _pendingOpen = path;
        return YES;
    }
    return [self openJobAtPath:path];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    if (_grbl.isRunning || _cutter.isSending) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"A job is still running.";
        a.informativeText = @"Stop it and quit?";
        a.alertStyle = NSAlertStyleWarning;
        [a addButtonWithTitle:@"Stop and Quit"];
        [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] != NSAlertFirstButtonReturn) return NSTerminateCancel;
        if (_grbl.isRunning) [_grbl realtime:0x18];
        [_cutter cancel];
    }
    [self saveSettings];
    [_grbl close];
    return NSTerminateNow;
}

#pragma mark - Menu

- (void)buildMenu {
    NSMenu *bar = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"KerfSender"];
    [appMenu addItemWithTitle:@"About KerfSender" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide KerfSender" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *others = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    others.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit KerfSender" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Open Job…" action:@selector(openJob:) keyEquivalent:@"o"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    [bar addItem:fileItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [bar addItem:editItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *cameraItem = [windowMenu addItemWithTitle:@"Camera…" action:@selector(showCamera:) keyEquivalent:@"c"];
    cameraItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    cameraItem.target = self;
    windowItem.submenu = windowMenu;
    [bar addItem:windowItem];
    NSApp.windowsMenu = windowMenu;

    NSApp.mainMenu = bar;
}

#pragma mark - Window

- (void)buildWindow {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 660)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"KerfSender";
    _window.contentMinSize = NSMakeSize(700, 520);
    _window.delegate = self;
    _window.releasedWhenClosed = NO;
    [_window center];
    _window.frameAutosaveName = @"KerfSenderMain";
    _content = [[KSFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 720, 660)];
    _window.contentView = _content;
    [_window registerForDraggedTypes:@[ NSFilenamesPboardType ]];

    // Job header
    _openButton = KSButton(@"Open Job…", self, @selector(openJob:));
    _jobTitle = KSLabel(@"No job open");
    _jobTitle.font = [NSFont boldSystemFontOfSize:15];
    _jobSummary = KSLabel(@"Open a .kerfjob exported from KerfKutter, or drop one on this window.");
    _jobSummary.textColor = [NSColor secondaryLabelColor];
    _jobSummary.font = [NSFont systemFontOfSize:11];
    _cameraButton = KSButton(@"Camera…", self, @selector(showCamera:));
    _cameraButton.toolTip = @"Line the job up on the material with a camera above the bed";
    for (NSView *v in @[ _openButton, _jobTitle, _jobSummary, _cameraButton ]) [_content addSubview:v];

    // Connection
    _connectionBox = [[NSBox alloc] init];
    _connectionBox.title = @"Connection";
    _connectionView = [[KSFlippedView alloc] init];
    _connectionBox.contentView = _connectionView;
    _kindLabel = KSLabel(@"Machine type:");
    _kindPopup = [[NSPopUpButton alloc] init];
    [_kindPopup addItemsWithTitles:@[ @"GRBL laser", @"GRBL CNC router", @"Vinyl cutter (HPGL)", @"Vinyl cutter (GP-GL)" ]];
    _kindPopup.target = self;
    _kindPopup.action = @selector(machineChanged:);
    _outputLabel = KSLabel(@"Send to:");
    _outputPopup = [[NSPopUpButton alloc] init];
    [_outputPopup addItemsWithTitles:@[ @"Serial (USB) port", @"Printer queue" ]];
    _outputPopup.target = self;
    _outputPopup.action = @selector(machineChanged:);
    _portLabel = KSLabel(@"Port:");
    _portPopup = [[NSPopUpButton alloc] init];
    _portPopup.target = self;
    _portPopup.action = @selector(controlsChanged:);
    _refreshButton = KSButton(@"Refresh", self, @selector(refreshPorts:));
    _baudLabel = KSLabel(@"Baud rate:");
    _baudCombo = [[NSComboBox alloc] init];
    [_baudCombo addItemsWithObjectValues:@[ @"9600", @"19200", @"38400", @"57600", @"115200", @"250000" ]];
    _baudCombo.stringValue = @"115200";
    _printerLabel = KSLabel(@"Printer queue:");
    _printerPopup = [[NSPopUpButton alloc] init];
    _printerPopup.target = self;
    _printerPopup.action = @selector(controlsChanged:);
    _flowLabel = KSLabel(@"Flow control:");
    _flowPopup = [[NSPopUpButton alloc] init];
    [_flowPopup addItemsWithTitles:@[ @"None", @"RTS/CTS (hardware)", @"XON/XOFF (software)" ]];
    for (NSView *v in @[ _kindLabel, _kindPopup, _outputLabel, _outputPopup, _portLabel, _portPopup, _refreshButton,
                         _baudLabel, _baudCombo, _printerLabel, _printerPopup, _flowLabel, _flowPopup ]) {
        [_connectionView addSubview:v];
    }
    [_content addSubview:_connectionBox];

    // Machine control
    _controlBox = [[NSBox alloc] init];
    _controlBox.title = @"Machine control";
    _controlView = [[KSFlippedView alloc] init];
    _controlBox.contentView = _controlView;
    _connectButton = KSButton(@"Connect", self, @selector(toggleConnection:));
    _homeButton = KSButton(@"Home", self, @selector(home:));
    _unlockButton = KSButton(@"Unlock", self, @selector(unlock:));
    _originButton = KSButton(@"Set origin here", self, @selector(setOrigin:));
    _goOriginButton = KSButton(@"Go to origin", self, @selector(goToOrigin:));
    _statusLabel = KSLabel(@"Disconnected");
    _statusLabel.font = [NSFont userFixedPitchFontOfSize:12];
    _stepLabel = KSLabel(@"Jog step:");
    _stepPopup = [[NSPopUpButton alloc] init];
    [_stepPopup addItemsWithTitles:@[ @"0.1 mm", @"1 mm", @"10 mm", @"50 mm" ]];
    [_stepPopup selectItemAtIndex:2];
    NSMutableArray *jogs = [NSMutableArray array];
    NSArray *titles = @[ @"Y+", @"X−", @"X+", @"Y−", @"Z+", @"Z−" ];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSButton *b = KSButton(titles[i], self, @selector(jog:));
        b.tag = (NSInteger)i;
        [jogs addObject:b];
    }
    _jogButtons = jogs;
    for (NSView *v in @[ _connectButton, _homeButton, _unlockButton, _originButton, _goOriginButton, _statusLabel,
                         _stepLabel, _stepPopup ]) {
        [_controlView addSubview:v];
    }
    for (NSButton *b in _jogButtons) [_controlView addSubview:b];
    [_content addSubview:_controlBox];

    // Run
    _startButton = KSButton(@"Start", self, @selector(start:));
    _startButton.keyEquivalent = @"\r";
    _pauseButton = KSButton(@"Pause", self, @selector(pauseResume:));
    _stopButton = KSButton(@"Stop", self, @selector(stop:));
    _progress = [[NSProgressIndicator alloc] init];
    _progress.indeterminate = NO;
    _progress.minValue = 0;
    _progress.maxValue = 1;
    _progress.style = NSProgressIndicatorBarStyle;
    for (NSView *v in @[ _startButton, _pauseButton, _stopButton, _progress ]) [_content addSubview:v];

    _logScroll = [[NSScrollView alloc] init];
    _logScroll.hasVerticalScroller = YES;
    _logScroll.borderType = NSBezelBorder;
    _log = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 680, 200)];
    _log.editable = NO;
    _log.font = [NSFont userFixedPitchFontOfSize:11];
    _log.autoresizingMask = NSViewWidthSizable;
    _log.textContainer.widthTracksTextView = YES;
    _logScroll.documentView = _log;
    [_content addSubview:_logScroll];

    [self layout];
}

- (void)windowDidResize:(NSNotification *)note {
    [self layout];
}

/// Lays everything out top-down in the flipped content view.
- (void)layout {
    CGFloat W = _content.bounds.size.width, H = _content.bounds.size.height;
    CGFloat m = 16, y = 14;

    _openButton.frame = NSMakeRect(m - 6, y, 120, 32);
    CGFloat textRight = _cameraButton.hidden ? W - m : W - m - 112;
    _cameraButton.frame = NSMakeRect(W - m - 104, y, 110, 32);
    _jobTitle.frame = NSMakeRect(140, y - 2, textRight - 140, 22);
    _jobSummary.frame = NSMakeRect(140, y + 20, textRight - 140, 16);
    y += 48;

    // Connection box contents (flipped, relative to the box).
    CGFloat c1 = 8, c2 = 118, c3 = 350, c4 = 456, row = 30;
    _kindLabel.frame = NSMakeRect(c1, 10, 108, 18);
    _kindPopup.frame = NSMakeRect(c2, 4, 220, 26);
    _outputLabel.frame = NSMakeRect(c3, 10, 104, 18);
    _outputPopup.frame = NSMakeRect(c4, 4, 200, 26);
    _portLabel.frame = NSMakeRect(c1, 10 + row, 108, 18);
    _portPopup.frame = NSMakeRect(c2, 4 + row, 140, 26);
    _refreshButton.frame = NSMakeRect(c2 + 142, 3 + row, 84, 28);
    _baudLabel.frame = NSMakeRect(c3, 10 + row, 104, 18);
    _baudCombo.frame = NSMakeRect(c4, 6 + row, 110, 24);
    _printerLabel.frame = NSMakeRect(c1, 10 + 2 * row, 108, 18);
    _printerPopup.frame = NSMakeRect(c2, 4 + 2 * row, 220, 26);
    _flowLabel.frame = NSMakeRect(c3, 10 + 2 * row, 104, 18);
    _flowPopup.frame = NSMakeRect(c4, 4 + 2 * row, 200, 26);
    // When the printer row is hidden, move the flow control up beside the port.
    if (_printerPopup.hidden && !_portPopup.hidden) {
        _flowLabel.frame = NSMakeRect(c1, 10 + 2 * row, 108, 18);
        _flowPopup.frame = NSMakeRect(c2, 4 + 2 * row, 220, 26);
    }
    if (_portPopup.hidden) {
        _printerLabel.frame = NSMakeRect(c1, 10 + row, 108, 18);
        _printerPopup.frame = NSMakeRect(c2, 4 + row, 220, 26);
    }
    BOOL threeRows = !_flowPopup.hidden && !_portPopup.hidden;
    CGFloat boxH = (threeRows ? 3 : 2) * row + 34;
    _connectionBox.frame = NSMakeRect(m - 4, y, W - 2 * m + 8, boxH);
    y += boxH + 6;

    if (!_controlBox.hidden) {
        CGFloat x = 6;
        for (NSButton *b in @[ _connectButton, _homeButton, _unlockButton, _originButton, _goOriginButton ]) {
            [b sizeToFit];
            NSRect f = b.frame;
            f.size.width = MAX(f.size.width + 12, 76);
            f.origin = NSMakePoint(x, 4);
            b.frame = f;
            x += f.size.width + 2;
        }
        _statusLabel.frame = NSMakeRect(10, 44, 420, 18);
        _stepLabel.frame = NSMakeRect(10, 78, 70, 18);
        _stepPopup.frame = NSMakeRect(80, 72, 100, 26);
        CGFloat bw = W - 2 * m + 8, jx = bw - 210, js = 46;
        NSPoint spots[6] = { { jx + js, 4 }, { jx, 36 }, { jx + 2 * js, 36 }, { jx + js, 68 }, { jx + 3 * js + 16, 4 }, { jx + 3 * js + 16, 68 } };
        for (NSUInteger i = 0; i < _jogButtons.count; i++) {
            _jogButtons[i].frame = NSMakeRect(spots[i].x, spots[i].y, js, 30);
        }
        _controlBox.frame = NSMakeRect(m - 4, y, bw, 130);
        y += 136;
    }

    _startButton.frame = NSMakeRect(m - 6, y, 130, 32);
    _pauseButton.frame = NSMakeRect(m + 126, y, 96, 32);
    _stopButton.frame = NSMakeRect(_pauseButton.hidden ? m + 126 : m + 224, y, 86, 32);
    CGFloat px = NSMaxX(_stopButton.frame) + 12;
    _progress.frame = NSMakeRect(px, y + 8, W - px - m, 20);
    y += 42;

    _logScroll.frame = NSMakeRect(m, y, W - 2 * m, MAX(80, H - y - m));
}

#pragma mark - Drag and drop

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [sender.draggingPasteboard.types containsObject:NSFilenamesPboardType] ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray *files = [sender.draggingPasteboard propertyListForType:NSFilenamesPboardType];
    return files.count > 0 && [self openJobAtPath:files.firstObject];
}

#pragma mark - State

- (BOOL)isCutter { return _kindPopup.indexOfSelectedItem >= 2; }
- (BOOL)isCnc { return _kindPopup.indexOfSelectedItem == 1; }
- (BOOL)usesPrinter { return self.isCutter && _outputPopup.indexOfSelectedItem == 1; }

- (void)updateMachineFields {
    BOOL cutter = self.isCutter, printer = self.usesPrinter;
    _outputLabel.hidden = _outputPopup.hidden = !cutter;
    _flowLabel.hidden = _flowPopup.hidden = !cutter || printer;
    _printerLabel.hidden = _printerPopup.hidden = !printer;
    _portLabel.hidden = _portPopup.hidden = _refreshButton.hidden = printer;
    _baudLabel.hidden = _baudCombo.hidden = printer;
    _controlBox.hidden = cutter;
    _cameraButton.hidden = cutter;
    _jogButtons[4].hidden = _jogButtons[5].hidden = !self.isCnc;
    _pauseButton.hidden = cutter;
    if (cutter && _grbl.isConnected) [_grbl close];
    [self layout];
}

- (void)updateControls {
    BOOL running = _grbl.isRunning || _cutter.isSending;
    BOOL connected = _grbl.isConnected;
    BOOL haveJob = _job != nil && _job.data.length > 0;
    BOOL havePort = _portPopup.selectedItem != nil && _portPopup.selectedItem.enabled;

    _connectButton.title = connected ? @"Disconnect" : @"Connect";
    _connectButton.enabled = !running && (connected || havePort);
    for (NSButton *b in @[ _homeButton, _unlockButton, _originButton, _goOriginButton ]) b.enabled = connected && !running;
    for (NSButton *b in _jogButtons) b.enabled = connected && !running;

    _kindPopup.enabled = _outputPopup.enabled = _flowPopup.enabled = !running;
    _portPopup.enabled = _refreshButton.enabled = _printerPopup.enabled = _baudCombo.enabled = !running && !connected;
    _openButton.enabled = !running;

    if (self.isCutter) {
        BOOL target = self.usesPrinter ? _printerPopup.selectedItem.enabled && _printerPopup.selectedItem != nil : havePort;
        _startButton.title = @"Send to cutter";
        _startButton.enabled = haveJob && !running && target;
        _stopButton.enabled = _cutter.isSending;
    } else {
        _startButton.title = @"Start";
        _startButton.enabled = haveJob && connected && !running;
        _pauseButton.enabled = _grbl.isRunning;
        _pauseButton.title = _grbl.isPaused ? @"Resume" : @"Pause";
        _stopButton.enabled = connected;
    }
    [_camera machineChanged];
    [self layout];
}

- (void)setProgress:(double)fraction {
    _progress.doubleValue = MAX(0, MIN(1, fraction));
}

#pragma mark - Actions

- (void)machineChanged:(id)sender {
    [self updateMachineFields];
    [self updateControls];
}

- (void)controlsChanged:(id)sender {
    [self updateControls];
}

- (void)refreshPorts:(id)sender {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *current = _portPopup.titleOfSelectedItem ?: [d stringForKey:@"port"];
    NSArray *ports = [KSSerialPort availablePorts];
    [_portPopup removeAllItems];
    if (ports.count == 0) {
        [_portPopup addItemWithTitle:@"No ports found"];
        _portPopup.lastItem.enabled = NO;
        _portPopup.autoenablesItems = NO;
    } else {
        [_portPopup addItemsWithTitles:ports];
        if (current && [ports containsObject:current]) {
            [_portPopup selectItemWithTitle:current];
        } else {
            for (NSString *p in ports) {
                if ([p containsString:@"usb"] || [p containsString:@"wch"] || [p containsString:@"SLAB"]) {
                    [_portPopup selectItemWithTitle:p];
                    break;
                }
            }
        }
    }

    NSString *printer = _printerPopup.titleOfSelectedItem ?: [d stringForKey:@"printer"];
    NSArray *queues = [KSCutter printerQueues];
    [_printerPopup removeAllItems];
    if (queues.count == 0) {
        [_printerPopup addItemWithTitle:@"No printer queues"];
        _printerPopup.lastItem.enabled = NO;
        _printerPopup.autoenablesItems = NO;
    } else {
        [_printerPopup addItemsWithTitles:queues];
        if (printer && [queues containsObject:printer]) [_printerPopup selectItemWithTitle:printer];
    }
    [self updateControls];
}

- (void)openJob:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = [KSJob fileTypes];
    panel.allowsOtherFileTypes = YES;
    panel.message = @"Choose a .kerfjob exported from KerfKutter, or a G-code or plotter file.";
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) [self openJobAtPath:panel.URL.path];
    }];
}

- (BOOL)openJobAtPath:(NSString *)path {
    if (_grbl.isRunning || _cutter.isSending) {
        [self alert:@"A job is running." info:@"Wait for it to finish, or stop it, before opening another."];
        return NO;
    }
    NSString *error = nil;
    KSJob *job = [KSJob jobWithContentsOfFile:path error:&error];
    if (!job) {
        [self alert:[NSString stringWithFormat:@"Could not open %@.", path.lastPathComponent] info:error ?: @""];
        return NO;
    }
    _job = job;
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:path]];
    _jobTitle.stringValue = job.name;
    _jobSummary.stringValue = job.summary;
    _window.title = [job.name stringByAppendingString:@" — KerfSender"];
    _window.representedFilename = path;

    if (_grbl.isConnected && !job.usesGrbl) [_grbl close];
    [_kindPopup selectItemAtIndex:job.kind];
    [_outputPopup selectItemAtIndex:job.printerOutput ? 1 : 0];
    [_flowPopup selectItemAtIndex:[job.flowControl isEqualToString:@"hardware"] ? 1
                                 : [job.flowControl isEqualToString:@"software"] ? 2 : 0];
    if (!_grbl.isConnected) _baudCombo.stringValue = [NSString stringWithFormat:@"%ld", (long)job.baudRate];
    [self setProgress:0];
    [self grblLog:[NSString stringWithFormat:@"Opened %@: %@", path.lastPathComponent, job.summary] isError:NO];
    if (!job.fromKerfKutter) {
        [self grblLog:@"This is a plain file, so check the machine type and connection settings before starting." isError:NO];
    }
    [self updateMachineFields];
    [self updateControls];
    [_camera jobOpened:job];
    return YES;
}

- (NSInteger)baudOr:(NSInteger)fallback {
    NSInteger b = _baudCombo.stringValue.integerValue;
    return b > 0 ? b : fallback;
}

- (void)toggleConnection:(id)sender {
    if (_grbl.isConnected) {
        [_grbl close];
    } else {
        NSString *port = _portPopup.titleOfSelectedItem;
        if (!port || !_portPopup.selectedItem.enabled) return;
        NSInteger buffer = _job && _job.usesGrbl ? _job.rxBufferSize : 127;
        if ([_grbl openPort:port baud:[self baudOr:115200] bufferSize:buffer]) {
            [[NSUserDefaults standardUserDefaults] setObject:port forKey:@"port"];
        }
    }
    [self updateControls];
}

- (void)home:(id)sender { [_grbl send:@"$H"]; }
- (void)unlock:(id)sender { [_grbl send:@"$X"]; }
- (void)setOrigin:(id)sender { [_grbl send:self.isCnc ? @"G10 L20 P1 X0 Y0 Z0" : @"G10 L20 P1 X0 Y0"]; }
- (void)goToOrigin:(id)sender { [_grbl send:@"$J=G90 G21 X0 Y0 F3000"]; }

- (void)jog:(NSButton *)sender {
    double steps[4] = { 0.1, 1, 10, 50 };
    NSInteger i = MAX(0, _stepPopup.indexOfSelectedItem);
    double step = steps[MIN(3, i)];
    NSString *move;
    switch (sender.tag) {
        case 0: move = [NSString stringWithFormat:@"Y%g F3000", step]; break;
        case 1: move = [NSString stringWithFormat:@"X%g F3000", -step]; break;
        case 2: move = [NSString stringWithFormat:@"X%g F3000", step]; break;
        case 3: move = [NSString stringWithFormat:@"Y%g F3000", -step]; break;
        case 4: move = [NSString stringWithFormat:@"Z%g F300", step]; break;
        default: move = [NSString stringWithFormat:@"Z%g F300", -step]; break;
    }
    [_grbl send:[@"$J=G91 G21 " stringByAppendingString:move]];
}

- (void)start:(id)sender {
    if (!_job) return;
    [self setProgress:0];
    if (self.isCutter) {
        if (_job.usesGrbl && ![self confirm:@"This job is G-code, but the machine type is a vinyl cutter." info:@"Send it anyway?"]) return;
        NSData *data = [_job.data dataUsingEncoding:NSUTF8StringEncoding];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (self.usesPrinter) {
            NSString *queue = _printerPopup.titleOfSelectedItem;
            [d setObject:queue forKey:@"printer"];
            [self grblLog:[NSString stringWithFormat:@"Sending %lu bytes to printer queue %@…", (unsigned long)data.length, queue] isError:NO];
            [_cutter sendData:data toQueue:queue];
        } else {
            NSString *port = _portPopup.titleOfSelectedItem;
            [d setObject:port forKey:@"port"];
            NSInteger f = _flowPopup.indexOfSelectedItem;
            NSString *flow = f == 1 ? @"hardware" : f == 2 ? @"software" : @"none";
            [self grblLog:[NSString stringWithFormat:@"Sending %lu bytes to %@…", (unsigned long)data.length, port] isError:NO];
            [_cutter sendData:data toPort:port baud:[self baudOr:9600] flow:flow];
        }
    } else {
        if (!_job.usesGrbl && ![self confirm:@"This job is plotter data, not G-code." info:@"Send it to the GRBL machine anyway?"]) return;
        if ([_grbl.state hasPrefix:@"Alarm"]) {
            [self alert:@"The machine is in an alarm state." info:@"Home it, or Unlock it, before starting."];
            return;
        }
        NSArray<NSString *> *lines = _job.gcodeLines;
        if (_camera.placementActive) {
            NSString *error = nil;
            NSArray<NSString *> *placed = [_camera placedLinesForJob:_job error:&error];
            if (!placed) {
                [self alert:@"The job can't be placed with the camera." info:error ?: @""];
                return;
            }
            [self grblLog:[NSString stringWithFormat:@"Running the job as placed with the camera: %@.", _camera.placementDescription] isError:NO];
            lines = placed;
        }
        [_grbl run:lines];
    }
    [self updateControls];
}

- (void)pauseResume:(id)sender {
    if (_grbl.isPaused) [_grbl resume];
    else [_grbl pause];
    [self updateControls];
}

- (void)stop:(id)sender {
    if (self.isCutter) [_cutter cancel];
    else [_grbl stop];
    [self updateControls];
}

- (void)saveSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (_portPopup.selectedItem.enabled && _portPopup.titleOfSelectedItem) [d setObject:_portPopup.titleOfSelectedItem forKey:@"port"];
    if (_printerPopup.selectedItem.enabled && _printerPopup.titleOfSelectedItem) [d setObject:_printerPopup.titleOfSelectedItem forKey:@"printer"];
}

- (void)alert:(NSString *)message info:(NSString *)info {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = message;
    a.informativeText = info;
    a.alertStyle = NSAlertStyleWarning;
    [a runModal];
}

- (BOOL)confirm:(NSString *)message info:(NSString *)info {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = message;
    a.informativeText = info;
    a.alertStyle = NSAlertStyleWarning;
    [a addButtonWithTitle:@"Send"];
    [a addButtonWithTitle:@"Cancel"];
    return [a runModal] == NSAlertFirstButtonReturn;
}

#pragma mark - Camera

- (void)showCamera:(id)sender {
    if (!_camera) {
        _camera = [[KSCameraWindowController alloc] initWithHost:self];
        [_camera jobOpened:_job];
    }
    [_camera showWindow:nil];
}

- (KSJob *)cameraCurrentJob { return _job; }
- (BOOL)cameraMachineIsLaser { return _kindPopup.indexOfSelectedItem == 0; }
- (KSGrbl *)cameraGrbl { return _grbl; }
- (void)cameraLog:(NSString *)text isError:(BOOL)isError { [self grblLog:text isError:isError]; }

#pragma mark - KSGrblDelegate

- (void)grblLog:(NSString *)text isError:(BOOL)isError {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  %@%@\n", [f stringFromDate:[NSDate date]], isError ? @"! " : @"", text];
    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont userFixedPitchFontOfSize:11],
        NSForegroundColorAttributeName : isError ? [NSColor systemRedColor] : [NSColor textColor],
    };
    NSTextStorage *storage = _log.textStorage;
    if (storage.length > 200000) [storage deleteCharactersInRange:NSMakeRange(0, storage.length - 100000)];
    [storage appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:attrs]];
    [_log scrollRangeToVisible:NSMakeRange(storage.length, 0)];
}

- (void)grblStatus:(NSString *)text {
    _statusLabel.stringValue = text;
}

- (void)grblProgress:(double)fraction {
    [self setProgress:fraction];
}

- (void)grblChanged {
    [self updateControls];
}

@end
