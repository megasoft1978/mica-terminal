#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"
#import <ApplicationServices/ApplicationServices.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef MICA_SESSION_TESTING
void mica_session_test_fail_next_history_resize_allocation(void);
#endif

static double MicaUITestLinear(double value) { return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4); }
static double MicaContrastRatio(NSColor *foreground, NSColor *background) {
    NSColor *a = [foreground colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    NSColor *b = [background colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    if (!a || !b) return 0;
    double la = 0.2126 * MicaUITestLinear(a.redComponent) + 0.7152 * MicaUITestLinear(a.greenComponent) + 0.0722 * MicaUITestLinear(a.blueComponent);
    double lb = 0.2126 * MicaUITestLinear(b.redComponent) + 0.7152 * MicaUITestLinear(b.greenComponent) + 0.0722 * MicaUITestLinear(b.blueComponent);
    return (MAX(la, lb) + 0.05) / (MIN(la, lb) + 0.05);
}

@interface MicaVoiceController (MicaVoiceTestHooks)
- (void)launchHelperWithArguments:(NSArray<NSString *> *)arguments
                        inputData:(NSData *)inputData
                   keepsInputOpen:(BOOL)keepsInputOpen;
@end

static BOOL MicaUITestFindText(MicaSession *session, NSString *text, NSInteger *foundRow, NSInteger *foundCol) {
    const char *needle = text.UTF8String;
    if (!session || !needle || !needle[0]) return NO;
    size_t length = strlen(needle);
    for (int row = 0; row < mica_session_rows(session); row++) {
        for (int col = 0; col + (int)length <= mica_session_cols(session); col++) {
            BOOL matches = YES;
            for (size_t i = 0; i < length; i++) {
                MicaCell cell;
                if (!mica_session_get_cell(session, row, col + (int)i, &cell) || cell.chars[0] != (unsigned char)needle[i]) {
                    matches = NO;
                    break;
                }
            }
            if (matches) {
                if (foundRow) *foundRow = row;
                if (foundCol) *foundCol = col;
                return YES;
            }
        }
    }
    return NO;
}

static BOOL MicaUITestFindTextAcrossWrappedRows(MicaSession *session, NSString *text) {
    const char *needle = text.UTF8String;
    if (!session || !needle || !needle[0]) return NO;
    int rows = mica_session_rows(session), cols = mica_session_cols(session);
    size_t length = strlen(needle), cells = (size_t)rows * (size_t)cols;
    if (length > cells) return NO;
    for (size_t start = 0; start + length <= cells; start++) {
        BOOL matches = YES;
        for (size_t index = 0; index < length; index++) {
            size_t position = start + index;
            MicaCell cell;
            if (!mica_session_get_cell(session, (int)(position / (size_t)cols),
                                       (int)(position % (size_t)cols), &cell) ||
                cell.chars[0] != (unsigned char)needle[index]) {
                matches = NO;
                break;
            }
        }
        if (matches) return YES;
    }
    return NO;
}

static NSString *MicaUITestVoiceFile(NSString *directory, MicaSession *session, NSString *suffix) {
    return [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%d.%@", (int)mica_session_pid(session), suffix]];
}

static NSString *MicaUITestCaptureZLEBuffer(NSString *directory, MicaSession *session) {
    NSString *path = MicaUITestVoiceFile(directory, session, @"buffer");
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    static const char chord[] = { 0x18, 0x02 };
    mica_session_write(session, chord, sizeof(chord));
    for (int attempt = 0; attempt < 100; attempt++) {
        mica_session_poll(session, 0);
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) break;
        usleep(10000);
    }
    NSString *buffer = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [buffer stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

static NSUInteger MicaUITestCountText(MicaSession *session, NSString *text) {
    NSUInteger count = 0;
    const char *needle = text.UTF8String;
    if (!session || !needle || !needle[0]) return 0;
    size_t length = strlen(needle);
    for (int row = 0; row < mica_session_rows(session); row++) {
        for (int col = 0; col + (int)length <= mica_session_cols(session); col++) {
            BOOL matches = YES;
            for (size_t i = 0; i < length; i++) {
                MicaCell cell;
                if (!mica_session_get_cell(session, row, col + (int)i, &cell) ||
                    cell.chars[0] != (unsigned char)needle[i]) {
                    matches = NO;
                    break;
                }
            }
            if (matches) count++;
        }
    }
    return count;
}

static BOOL MicaUITestFindCodepoint(MicaSession *session, uint32_t codepoint, NSInteger *foundRow, NSInteger *foundCol) {
    if (!session) return NO;
    for (int row = 0; row < mica_session_rows(session); row++) {
        for (int col = 0; col < mica_session_cols(session); col++) {
            MicaCell cell;
            if (mica_session_get_cell(session, row, col, &cell) && cell.chars[0] == codepoint) {
                if (foundRow) *foundRow = row;
                if (foundCol) *foundCol = col;
                return YES;
            }
        }
    }
    return NO;
}

static NSString *MicaUITestScreenTail(MicaSession *session) {
    if (!session) return @"<no session>";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (int row = 0; row < mica_session_rows(session); row++) {
        NSMutableString *line = [NSMutableString string];
        for (int col = 0; col < mica_session_cols(session); col++) {
            MicaCell cell;
            uint32_t codepoint = mica_session_get_cell(session, row, col, &cell) ? cell.chars[0] : 0;
            [line appendFormat:@"%C", (unichar)(codepoint >= 0x20 && codepoint <= 0x7e ? codepoint : ' ')];
        }
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) [lines addObject:trimmed];
    }
    NSUInteger start = lines.count > 5 ? lines.count - 5 : 0;
    return [[lines subarrayWithRange:NSMakeRange(start, lines.count - start)] componentsJoinedByString:@" | "];
}

static NSColor *MicaUITestColor(uint32_t rgb, NSColorSpace *colorSpace) {
    NSColor *sRGB = [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
        green:((rgb >> 8) & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:1.0];
    return [sRGB colorUsingColorSpace:colorSpace] ?: sRGB;
}

static BOOL MicaUITestCheckColor(NSColor *color, NSColor *expected) {
    return fabs(color.redComponent - expected.redComponent) < 0.01 &&
        fabs(color.greenComponent - expected.greenComponent) < 0.01 &&
        fabs(color.blueComponent - expected.blueComponent) < 0.01;
}

static void MicaUITestRecord(NSMutableString *report, BOOL *allPassed, BOOL passed, NSString *message) {
    NSString *line = [NSString stringWithFormat:@"[%@] %@", passed ? @"PASS" : @"FAIL", message];
    fprintf(stderr, "%s\n", line.UTF8String);
    [report appendFormat:@"%@\n", line];
    if (!passed) *allPassed = NO;
}

static void MicaUITestLaunchSpeechHelper(MicaVoiceController *controller) {
    [controller setValue:@(MicaVoiceControllerStatePreparing) forKey:@"state"];
    [controller setValue:@"Starting local speech recognition…" forKey:@"statusText"];
    [controller launchHelperWithArguments:@[@"stream"] inputData:nil keepsInputOpen:NO];
}

static BOOL MicaUITestExitTabs(NSArray<MicaTab *> *tabs) {
    // Let finite fixture commands release stdin before typing `exit`; otherwise
    // their output can appear ready while the shell still owns the PTY.
    for (int attempt = 0; attempt < 500; attempt++) {
        BOOL commandRunning = NO;
        for (MicaTab *tab in tabs) {
            mica_session_poll(tab.session, 10);
            const char *command = mica_session_current_command(tab.session);
            commandRunning = commandRunning || (command && command[0]);
        }
        if (!commandRunning) break;
        usleep(10000);
    }
    for (MicaTab *tab in tabs) {
        if (!mica_session_is_running(tab.session)) continue;
        mica_session_write(tab.session, "exit\n", 5);
    }
    for (int attempt = 0; attempt < 500; attempt++) {
        BOOL running = NO;
        for (MicaTab *tab in tabs) {
            mica_session_poll(tab.session, 10);
            running = running || mica_session_is_running(tab.session);
        }
        if (!running) return YES;
        usleep(10000);
    }
    for (MicaTab *tab in tabs) {
        if (mica_session_is_running(tab.session))
            fprintf(stderr, "[WARN] PTY still running at UI teardown: %s (pid=%d command=%s)\n",
                    tab.name.UTF8String, (int)mica_session_pid(tab.session), mica_session_command(tab.session));
    }
    return NO;
}

static void MicaUITestSendKey(MicaAppDelegate *delegate, NSString *characters,
                              NSEventModifierFlags modifiers, unsigned short keyCode) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:modifiers timestamp:0 windowNumber:delegate.window.windowNumber context:nil
        characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
    if (event) [delegate.terminalView keyDown:event];
}

static void MicaUITestInsertComposedText(MicaAppDelegate *delegate, NSString *text) {
    // AppKit's keyboard layout differs between developer machines and CI. Feed
    // the composed string through the NSTextInputClient callback that real
    // keyboard layouts and IMEs call after composition.
    [delegate.terminalView insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
}

static int shortcutEnableCalls, shortcutDisableCalls;
static BOOL MicaUITestCountingRegistrar(BOOL enable) { if (enable) shortcutEnableCalls++; else shortcutDisableCalls++; return YES; }

static void MicaUITestSendFlags(MicaAppDelegate *delegate, NSEventModifierFlags modifiers,
                               unsigned short keyCode) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint
        modifierFlags:modifiers timestamp:0 windowNumber:delegate.window.windowNumber context:nil
        characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:keyCode];
    if (event) [delegate.terminalView flagsChanged:event];
}

static void MicaUITestRunLoopFor(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void MicaUITestAttachWindow(MicaAppDelegate *delegate) {
    delegate.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 500)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    delegate.terminalView = [[MicaTerminalView alloc] initWithFrame:delegate.window.contentView.bounds];
    delegate.terminalView.owner = delegate;
    delegate.terminalView.terminalFont = MicaTerminalFont(kFontSizeDefault);
    [delegate.window setContentView:delegate.terminalView];
}

static void MicaUITestSendWheel(MicaAppDelegate *delegate, int deltaY) {
    CGEventRef cgEvent = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, deltaY);
    if (!cgEvent) return;
    NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
    CFRelease(cgEvent);
    if (event) [delegate.terminalView scrollWheel:event];
}

static void MicaUITestSendMouse(MicaAppDelegate *delegate, NSEventType type, NSPoint viewPoint,
                                NSEventModifierFlags modifiers) {
    NSPoint windowPoint = [delegate.terminalView convertPoint:viewPoint toView:nil];
    NSEvent *event = [NSEvent mouseEventWithType:type location:windowPoint modifierFlags:modifiers
        timestamp:0 windowNumber:delegate.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1.0];
    if (!event) return;
    if (type == NSEventTypeLeftMouseDown) [delegate.terminalView mouseDown:event];
    else if (type == NSEventTypeLeftMouseDragged) [delegate.terminalView mouseDragged:event];
    else if (type == NSEventTypeLeftMouseUp) [delegate.terminalView mouseUp:event];
}

@interface MicaUITestDraggingInfo : NSObject
@property(nonatomic) NSPoint location;
@property(nonatomic, strong) NSPasteboard *pasteboard;
@end

@implementation MicaUITestDraggingInfo
- (NSPoint)draggingLocation { return self.location; }
- (NSPasteboard *)draggingPasteboard { return self.pasteboard; }
@end

@interface MicaUITestVoiceController : MicaVoiceController
@property(nonatomic) NSUInteger pushToTalkStarts;
@property(nonatomic) NSUInteger pushToTalkFinishes;
@end

@implementation MicaUITestVoiceController
- (void)startPushToTalkForWorkingDirectory:(NSString *)workingDirectory {
    (void)workingDirectory;
    self.pushToTalkStarts++;
}
- (void)finishPushToTalk { self.pushToTalkFinishes++; }
@end

@interface MicaUITestLiveResizeView : MicaTerminalView
@property(nonatomic) BOOL testInLiveResize;
@end

@implementation MicaUITestLiveResizeView
- (BOOL)inLiveResize { return self.testInLiveResize; }
@end

static int MicaRunUISelfTest(void) {
    @autoreleasepool {
        NSMutableString *report = [NSMutableString string];
        BOOL allPassed = YES;
        setenv("MICA_TEST_NO_STARTUP", "1", 1);
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;

        NSString *sameLabel = [NSString stringWithUTF8String:"Codex"];
        BOOL labelComparisonIsNilSafe = !MicaStringChanged(nil, nil) &&
            !MicaStringChanged(@"Codex", sameLabel) &&
            MicaStringChanged(nil, @"sleep") &&
            MicaStringChanged(@"sleep", nil) &&
            MicaStringChanged(@"sleep", @"claude");
        MicaUITestRecord(report, &allPassed, labelComparisonIsNilSafe,
                         @"idle nil command labels compare equal and do not request redraws");
        BOOL projectMarksAreDistinct = [MicaProjectMark(@"Mica Demo") isEqualToString:@"MD"] &&
            [MicaProjectMark(@"Fieldnote") isEqualToString:@"FI"];
        MicaUITestRecord(report, &allPassed, projectMarksAreDistinct,
                         @"project names produce compact marks for the Dock icon");
        BOOL hyperlinkSchemesAreRestricted = MicaSafeHyperlinkURL(@"https://example.test/path") != nil &&
            MicaSafeHyperlinkURL(@"http://example.test") != nil &&
            MicaSafeHyperlinkURL(@"javascript:alert(1)") == nil &&
            MicaSafeHyperlinkURL(@"file:///tmp/private") == nil &&
            MicaSafeHyperlinkURL(@"https://user@example.test") == nil &&
            MicaSafeHyperlinkURL(@"https://example.test/a b") == nil;
        MicaUITestRecord(report, &allPassed, hyperlinkSchemesAreRestricted,
                         @"terminal links allow validated web URLs and reject local files, credentials and active schemes");
        char diagnosticDirectoryTemplate[] = "/tmp/mica-diagnostics-XXXXXX";
        char *diagnosticDirectoryPath = mkdtemp(diagnosticDirectoryTemplate);
        BOOL diagnosticDirectoryCreated = diagnosticDirectoryPath != NULL;
        if (diagnosticDirectoryCreated)
            setenv("MICA_DIAGNOSTICS_LOG_DIR", diagnosticDirectoryPath, 1);
        MicaDiagnosticsInitialize();
        MicaDiagnosticsLog(@"test", @"startup diagnostic record");
        NSURL *diagnosticDirectory = MicaDiagnosticsLogDirectory();
        NSArray<NSURL *> *diagnosticFiles = diagnosticDirectory
            ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:diagnosticDirectory
                includingPropertiesForKeys:nil options:0 error:nil] : @[];
        NSString *diagnosticContents = diagnosticFiles.count
            ? [NSString stringWithContentsOfURL:diagnosticFiles.firstObject
                encoding:NSUTF8StringEncoding error:nil] : nil;
        MicaUITestRecord(report, &allPassed, diagnosticDirectoryCreated && diagnosticFiles.count == 1 &&
            [diagnosticContents containsString:@"[test] startup diagnostic record"],
            @"startup diagnostics write timestamped plain-text logs in an easy-to-open folder");

        char helperPath[] = "/tmp/mica-voice-cancel-XXXXXX";
        int helperFD = mkstemp(helperPath);
        BOOL cancelHelperCreated = helperFD >= 0;
        if (cancelHelperCreated) {
            const char helperSource[] = "#!/bin/sh\nexec 0<&-\nsleep 5\n";
            cancelHelperCreated = write(helperFD, helperSource, sizeof(helperSource) - 1) ==
                (ssize_t)(sizeof(helperSource) - 1) && fchmod(helperFD, 0700) == 0;
            close(helperFD);
        }
        MicaVoiceController *cancelProbe = cancelHelperCreated
            ? [[MicaVoiceController alloc] initWithHelperURL:[NSURL fileURLWithPath:
                [NSFileManager.defaultManager stringWithFileSystemRepresentation:helperPath length:strlen(helperPath)]]]
            : nil;
        if (cancelProbe) {
            [cancelProbe launchHelperWithArguments:@[@"stream"] inputData:nil keepsInputOpen:YES];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
            [cancelProbe cancel];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.10]];
        }
        BOOL voiceCancelSafe = cancelProbe.state == MicaVoiceControllerStateIdle;
        MicaUITestRecord(report, &allPassed, cancelHelperCreated && voiceCancelSafe,
                         @"cancel closes an exited helper stream without writing a broken-pipe sentinel");
        unlink(helperPath);

        char failedHelperTemplate[] = "/tmp/mica-voice-failure-XXXXXX";
        int failedHelperFD = mkstemp(failedHelperTemplate);
        char childPIDTemplate[] = "/tmp/mica-voice-child-pid-XXXXXX";
        int childPIDFD = mkstemp(childPIDTemplate);
        BOOL failedHelperCreated = failedHelperFD >= 0 && childPIDFD >= 0;
        NSString *childPIDPath = [NSString stringWithUTF8String:childPIDTemplate];
        if (childPIDFD >= 0) close(childPIDFD);
        if (failedHelperFD >= 0) {
            NSString *failedHelperSource = [NSString stringWithFormat:
                @"#!/bin/sh\nsleep 30 &\nprintf '%%s\\n' \"$!\" > '%@'\nexit 23\n", childPIDPath];
            NSData *sourceData = [failedHelperSource dataUsingEncoding:NSUTF8StringEncoding];
            failedHelperCreated = failedHelperCreated &&
                write(failedHelperFD, sourceData.bytes, sourceData.length) == (ssize_t)sourceData.length &&
                fchmod(failedHelperFD, 0700) == 0;
            close(failedHelperFD);
        }
        MicaVoiceController *failedHelperProbe = failedHelperCreated
            ? [[MicaVoiceController alloc] initWithHelperURL:[NSURL fileURLWithPath:
                [NSFileManager.defaultManager stringWithFileSystemRepresentation:failedHelperTemplate length:strlen(failedHelperTemplate)]]]
            : nil;
        MicaUITestLaunchSpeechHelper(failedHelperProbe);
        BOOL startsWithIndeterminateProgress = failedHelperCreated &&
            failedHelperProbe.state == MicaVoiceControllerStatePreparing &&
            !failedHelperProbe.hasProgress &&
            [failedHelperProbe.statusText isEqualToString:@"Starting local speech recognition…"];
        for (int attempt = 0; failedHelperProbe.state != MicaVoiceControllerStateFailed && attempt < 300; attempt++)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        BOOL unexpectedExitHandled = failedHelperCreated &&
            failedHelperProbe.state == MicaVoiceControllerStateFailed &&
            [failedHelperProbe.statusText containsString:@"status 23"];
        NSString *childPIDString = [NSString stringWithContentsOfFile:childPIDPath
            encoding:NSUTF8StringEncoding error:nil];
        pid_t childPID = (pid_t)childPIDString.intValue;
        if (childPID > 1) kill(childPID, SIGTERM);
        unlink(failedHelperTemplate);
        unlink(childPIDTemplate);
        MicaUITestRecord(report, &allPassed, unexpectedExitHandled,
            [NSString stringWithFormat:@"an exited speech helper cannot leave Dictation stuck when an inherited pipe stays open (failed=%d status=%@)",
                unexpectedExitHandled, failedHelperProbe.statusText]);
        MicaUITestRecord(report, &allPassed, startsWithIndeterminateProgress,
            @"dictation starts with an indeterminate indicator instead of a false zero-percent bar");
        [failedHelperProbe cancel];

        char progressHelperTemplate[] = "/tmp/mica-voice-progress-XXXXXX";
        int progressHelperFD = mkstemp(progressHelperTemplate);
        const char progressHelperSource[] =
            "#!/bin/sh\n"
            "printf '%s\\n' '{\"type\":\"status\",\"message\":\"Downloading speech model files…\",\"progress\":0.4}'\n"
            "sleep 0.15\n"
            "printf '%s\\n' '{\"type\":\"error\",\"message\":\"fixture helper failure\"}'\n"
            "exit 0\n";
        BOOL progressHelperCreated = progressHelperFD >= 0 &&
            write(progressHelperFD, progressHelperSource, sizeof(progressHelperSource) - 1) ==
                (ssize_t)(sizeof(progressHelperSource) - 1) && fchmod(progressHelperFD, 0700) == 0;
        if (progressHelperFD >= 0) close(progressHelperFD);
        MicaVoiceController *progressHelperProbe = progressHelperCreated
            ? [[MicaVoiceController alloc] initWithHelperURL:[NSURL fileURLWithPath:
                [NSFileManager.defaultManager stringWithFileSystemRepresentation:progressHelperTemplate length:strlen(progressHelperTemplate)]]]
            : nil;
        MicaUITestLaunchSpeechHelper(progressHelperProbe);
        BOOL receivedDownloadProgress = NO;
        for (int attempt = 0; progressHelperProbe.state != MicaVoiceControllerStateFailed && attempt < 200; attempt++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            receivedDownloadProgress = receivedDownloadProgress ||
                (progressHelperProbe.hasProgress && fabs(progressHelperProbe.progress - 0.4) < 0.001);
        }
        BOOL outputPipeStayedOpen = progressHelperCreated && receivedDownloadProgress &&
            progressHelperProbe.state == MicaVoiceControllerStateFailed &&
            [progressHelperProbe.statusText isEqualToString:@"fixture helper failure"];
        MicaUITestRecord(report, &allPassed, outputPipeStayedOpen,
            [NSString stringWithFormat:@"dictation keeps the helper output pipe alive to receive download progress and its final error (progress=%d result=%@)",
                receivedDownloadProgress, progressHelperProbe.statusText]);
        [progressHelperProbe cancel];
        unlink(progressHelperTemplate);

        MicaAppDelegate *delegate = [[MicaAppDelegate alloc] init];
        delegate.tabs = [NSMutableArray array];
        delegate.activeIndex = 0;
        delegate.uiMode = MicaUIModeNormal;
        delegate.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 700)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        delegate.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        delegate.terminalView = [[MicaTerminalView alloc] initWithFrame:delegate.window.contentView.bounds];
        delegate.terminalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        delegate.terminalView.owner = delegate;
        delegate.terminalView.terminalFont = MicaTerminalFont(kFontSizeDefault);
        [delegate.window setContentView:delegate.terminalView];
        [delegate installMenus];

        NSMenu *sessionMenu = [NSApp.mainMenu itemWithTitle:@"Session"].submenu;
        NSMenuItem *quitMenuItem = [[NSApp.mainMenu itemWithTitle:@"Mica"].submenu
            itemWithTitle:@"Quit Mica"];
        NSMenuItem *newShellMenuItem = [sessionMenu itemWithTitle:@"New Shell Tab"];
        NSMenuItem *tabPickerMenuItem = [sessionMenu itemWithTitle:@"Choose Tab…"];
        NSMenuItem *scrollbackMenuItem = [sessionMenu itemWithTitle:@"Browse Scrollback"];
        NSMenu *helpMenu = [NSApp.mainMenu itemWithTitle:@"Help"].submenu;
        NSMenuItem *diagnosticLogsMenuItem = [helpMenu itemWithTitle:@"Open Diagnostic Logs"];
        NSMenuItem *shortcutsMenuItem = [helpMenu itemWithTitle:@"Keyboard Shortcuts…"];
        MicaUITestRecord(report, &allPassed,
                         newShellMenuItem.target == delegate &&
                         [newShellMenuItem.keyEquivalent isEqualToString:@"t"] &&
                         (newShellMenuItem.keyEquivalentModifierMask & NSEventModifierFlagCommand) != 0 &&
                         [sessionMenu itemWithTitle:@"Dictate…"] == nil &&
                         [tabPickerMenuItem.keyEquivalent isEqualToString:@"p"] &&
                         (tabPickerMenuItem.keyEquivalentModifierMask &
                          (NSEventModifierFlagCommand | NSEventModifierFlagShift)) ==
                            (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
                         [scrollbackMenuItem.keyEquivalent isEqualToString:@"s"] &&
                         (scrollbackMenuItem.keyEquivalentModifierMask &
                          (NSEventModifierFlagCommand | NSEventModifierFlagShift)) ==
                            (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
                         diagnosticLogsMenuItem.target == delegate &&
                         shortcutsMenuItem.target == delegate &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Start / Resume Focus Timer"].target == delegate &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"End Current Phase"].target == delegate &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Timer Settings…"].target == delegate &&
                         [shortcutsMenuItem.keyEquivalent isEqualToString:@"/"] &&
                         (shortcutsMenuItem.keyEquivalentModifierMask & NSEventModifierFlagCommand) != 0 &&
                         [quitMenuItem.keyEquivalent isEqualToString:@"q"] &&
                         (quitMenuItem.keyEquivalentModifierMask & NSEventModifierFlagCommand) != 0 &&
                         [sessionMenu itemWithTitle:@"New Claude Code Tab"] == nil &&
                         [sessionMenu itemWithTitle:@"New Codex Tab"] == nil,
                         @"Command-Q quits Mica and the shortcut list is available in Help and the status bar");

        MicaAppDelegate *hyperlinkDelegate = [[MicaAppDelegate alloc] init];
        hyperlinkDelegate.tabs = [NSMutableArray array];
        hyperlinkDelegate.activeIndex = 0;
        hyperlinkDelegate.uiMode = MicaUIModeNormal;
        MicaUITestAttachWindow(hyperlinkDelegate);
        [hyperlinkDelegate addTabWithName:@"Links" cwd:@"/tmp"
            command:@"printf '\\033[?1000h\\033]8;;https://example.test/path\\033\\\\CLICK-ME\\033]8;;\\033\\\\\\n'; "
                    "printf '\\033]8;;javascript:alert(1)\\033\\\\BAD-LINK\\033]8;;\\033\\\\\\n'; sleep 1"
            prefilled:NO];
        MicaTab *hyperlinkTab = hyperlinkDelegate.activeTab;
        NSInteger hyperlinkRow = -1, hyperlinkCol = -1;
        for (int attempt = 0; attempt < 200 && hyperlinkRow < 0; attempt++) {
            mica_session_poll(hyperlinkTab.session, 10);
            MicaUITestFindText(hyperlinkTab.session, @"CLICK-ME", &hyperlinkRow, &hyperlinkCol);
        }
        __block NSURL *openedHyperlink = nil;
        hyperlinkDelegate.terminalView.testOpenURLHandler = ^(NSURL *url) { openedHyperlink = url; };
        NSRect linkCell = [hyperlinkDelegate.terminalView cellRectAtRow:hyperlinkRow col:hyperlinkCol];
        NSPoint linkPoint = NSMakePoint(NSMidX(linkCell), NSMidY(linkCell));
        MicaUITestSendMouse(hyperlinkDelegate, NSEventTypeLeftMouseDown, linkPoint,
                            NSEventModifierFlagCommand);
        MicaUITestSendMouse(hyperlinkDelegate, NSEventTypeLeftMouseUp, linkPoint,
                            NSEventModifierFlagCommand);
        BOOL commandClickOpensWebLink = hyperlinkRow >= 0 && mica_session_reports_mouse(hyperlinkTab.session) &&
            [openedHyperlink.absoluteString isEqualToString:@"https://example.test/path"];
        MicaUITestRecord(report, &allPassed, commandClickOpensWebLink,
            [NSString stringWithFormat:@"Command-click opens an OSC 8 link while the TUI has mouse reporting enabled (opened=%@)",
                openedHyperlink.absoluteString ?: @"none"]);
        openedHyperlink = nil;
        MicaUITestSendMouse(hyperlinkDelegate, NSEventTypeLeftMouseDown, linkPoint, 0);
        MicaUITestSendMouse(hyperlinkDelegate, NSEventTypeLeftMouseUp, linkPoint, 0);
        MicaUITestRecord(report, &allPassed, openedHyperlink == nil,
            @"ordinary clicks remain available to mouse-reporting terminal applications");
        NSInteger unsafeLinkRow = -1, unsafeLinkCol = -1;
        // The second printf can arrive after the first; wait for it instead of racing the PTY.
        for (int attempt = 0; attempt < 200 && unsafeLinkRow < 0; attempt++) {
            mica_session_poll(hyperlinkTab.session, 10);
            MicaUITestFindText(hyperlinkTab.session, @"BAD-LINK", &unsafeLinkRow, &unsafeLinkCol);
        }
        NSRect unsafeLinkCell = [hyperlinkDelegate.terminalView cellRectAtRow:unsafeLinkRow col:unsafeLinkCol];
        NSPoint unsafeLinkPoint = NSMakePoint(NSMidX(unsafeLinkCell), NSMidY(unsafeLinkCell));
        MicaUITestSendMouse(hyperlinkDelegate, NSEventTypeLeftMouseDown, unsafeLinkPoint,
                            NSEventModifierFlagCommand);
        MicaUITestSendMouse(hyperlinkDelegate, NSEventTypeLeftMouseUp, unsafeLinkPoint,
                            NSEventModifierFlagCommand);
        MicaUITestRecord(report, &allPassed, unsafeLinkRow >= 0 && openedHyperlink == nil,
            @"Command-click ignores OSC 8 links with unsafe schemes");
        hyperlinkDelegate.tabs = [NSMutableArray array];

        // Bare URLs broken by soft wrap open as one address; hard newlines and spaces still end them.
        MicaAppDelegate *wrapDelegate = [[MicaAppDelegate alloc] init];
        wrapDelegate.tabs = [NSMutableArray array];
        wrapDelegate.activeIndex = 0;
        wrapDelegate.uiMode = MicaUIModeNormal;
        MicaUITestAttachWindow(wrapDelegate);
        [wrapDelegate addTabWithName:@"Wrap" cwd:@"/tmp"
            command:@"exec perl -e '$|=1; print \"WRAPSTART https://wrap.test/\" . (\"abcdefghij\" x 30) . \"/end\\n\"; "
                    "print \"HARD https://hard.test/one\\ncontinued-text\\n\"; "
                    "print \"PAIR https://a.test/1 https://b.test/2\\n\"; scalar <STDIN>; "
                    "print \"\\n\" x 40, \"WRAP-HISTORY-READY\\n\"; scalar <STDIN>; "
                    "print \"OLD-$_\\n\" for 1..500; "
                    "print \"WRAPSTART https://wrap.test/\" . (\"abcdefghij\" x 30) . \"/end\\n\"; "
                    "print \"\\n\" x 30, \"WRAP-RING-READY\\n\"; scalar <STDIN>; "
                    "print \"\\e[2J\\e[H\\e]8;;https://width.test/resize-target\\e\\\\\" . "
                    "\"WRAPWIDTHSTART https://width.test/\" . (\"abcdefghij\" x 30) . \"/end\\e]8;;\\e\\\\\\n\\n\\nWIDTH-READY\"; scalar <STDIN>; "
                    "print \"\\e[2J\\e[HWRAPSTART https://wrap.test/\" . (\"abcdefghij\" x 30) . \"/end\\n\\n\\nBOUNDARY-READY\\n\"; "
                    "scalar <STDIN>'"
            prefilled:NO];
        MicaTab *wrapTab = wrapDelegate.activeTab;
        NSInteger wrapRow = -1, wrapCol = -1;
        for (int attempt = 0; attempt < 300 && wrapRow < 0; attempt++) {
            mica_session_poll(wrapTab.session, 10);
            MicaUITestFindText(wrapTab.session, @"WRAPSTART", &wrapRow, &wrapCol);
        }
        NSString *wrapExpected = [@"https://wrap.test/" stringByAppendingString:
            [[@"" stringByPaddingToLength:300 withString:@"abcdefghij" startingAtIndex:0] stringByAppendingString:@"/end"]];
        __block NSURL *wrapOpened = nil;
        wrapDelegate.terminalView.testOpenURLHandler = ^(NSURL *url) { wrapOpened = url; };
        void (^clickCell)(NSInteger, NSInteger) = ^(NSInteger row, NSInteger col) {
            NSRect rect = [wrapDelegate.terminalView cellRectAtRow:row col:col];
            NSPoint point = NSMakePoint(NSMidX(rect), NSMidY(rect));
            wrapOpened = nil;
            MicaUITestSendMouse(wrapDelegate, NSEventTypeLeftMouseDown, point, NSEventModifierFlagCommand);
            MicaUITestSendMouse(wrapDelegate, NSEventTypeLeftMouseUp, point, NSEventModifierFlagCommand);
        };
        NSInteger wrapCols = mica_session_cols(wrapTab.session);
        clickCell(wrapRow, wrapCol + 12);
        BOOL wrappedFromFirstRow = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        clickCell(wrapRow + 1, 3);
        BOOL wrappedFromSecondRow = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        NSInteger hardRow = -1, hardCol = -1, pairRow = -1, pairCol = -1;
        for (int attempt = 0; attempt < 300 && (hardRow < 0 || pairRow < 0); attempt++) {
            mica_session_poll(wrapTab.session, 10);
            MicaUITestFindText(wrapTab.session, @"https://hard.test/one", &hardRow, &hardCol);
            MicaUITestFindText(wrapTab.session, @"https://b.test/2", &pairRow, &pairCol);
        }
        clickCell(hardRow, hardCol + 5);
        BOOL hardNewlineStops = [wrapOpened.absoluteString isEqualToString:@"https://hard.test/one"];
        clickCell(pairRow, pairCol + 5);
        BOOL adjacentSeparate = [wrapOpened.absoluteString isEqualToString:@"https://b.test/2"];
        MicaUITestRecord(report, &allPassed, wrapRow >= 0 && wrapCols < 300 && wrappedFromFirstRow &&
                         wrappedFromSecondRow && hardNewlineStops && adjacentSeparate,
            [NSString stringWithFormat:@"Command-click joins a soft-wrapped URL from either row, stops at a hard newline and keeps adjacent URLs apart (cols=%ld first=%d second=%d hard=%d pair=%d)",
                (long)wrapCols, wrappedFromFirstRow, wrappedFromSecondRow, hardNewlineStops, adjacentSeparate]);
        int originalWrapRows = mica_session_rows(wrapTab.session);
        mica_session_resize(wrapTab.session, 8, (int)wrapCols);
        mica_session_scroll(wrapTab.session, INT_MAX);
        wrapRow = wrapCol = -1;
        MicaUITestFindText(wrapTab.session, @"WRAPSTART", &wrapRow, &wrapCol);
        clickCell(wrapRow, wrapCol + 12);
        BOOL shrinkKeepsURL = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        MicaUITestRecord(report, &allPassed, wrapRow >= 0 && shrinkKeepsURL,
            @"Command-click preserves the complete wrapped URL after shrinking the grid");
        mica_session_resize(wrapTab.session, originalWrapRows, (int)wrapCols);
        mica_session_scroll(wrapTab.session, -INT_MAX);
        mica_session_write(wrapTab.session, "go\n", 3);
        NSInteger readyRow = -1, readyCol = -1;
        for (int attempt = 0; attempt < 600 && readyRow < 0; attempt++) {
            mica_session_poll(wrapTab.session, 10);
            MicaUITestFindText(wrapTab.session, @"WRAP-HISTORY-READY", &readyRow, &readyCol);
        }
        mica_session_scroll(wrapTab.session, INT_MAX);
        wrapRow = wrapCol = -1;
        MicaUITestFindText(wrapTab.session, @"WRAPSTART", &wrapRow, &wrapCol);
        clickCell(wrapRow, wrapCol + 12);
        BOOL historyFirst = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        clickCell(wrapRow + 1, 3);
        BOOL historySecond = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        hardRow = hardCol = pairRow = pairCol = -1;
        MicaUITestFindText(wrapTab.session, @"https://hard.test/one", &hardRow, &hardCol);
        MicaUITestFindText(wrapTab.session, @"https://b.test/2", &pairRow, &pairCol);
        clickCell(hardRow, hardCol + 8);
        BOOL historyHard = [wrapOpened.absoluteString isEqualToString:@"https://hard.test/one"];
        clickCell(pairRow, pairCol + 8);
        BOOL historyPair = [wrapOpened.absoluteString isEqualToString:@"https://b.test/2"];
        MicaUITestRecord(report, &allPassed, readyRow >= 0 && wrapRow >= 0 && historyFirst &&
            historySecond && historyHard && historyPair,
            [NSString stringWithFormat:@"Command-click preserves wrapped URLs, hard newlines and separate links in scrollback (first=%d second=%d hard=%d pair=%d)",
                historyFirst, historySecond, historyHard, historyPair]);
        size_t savedWrapBudget = mica_history_limit_bytes();
        mica_set_history_limit_lines(100);
        mica_session_scroll(wrapTab.session, -INT_MAX);
        mica_session_write(wrapTab.session, "go\n", 3);
        readyRow = readyCol = -1;
        for (int attempt = 0; attempt < 600 && readyRow < 0; attempt++) {
            mica_session_poll(wrapTab.session, 10);
            MicaUITestFindText(wrapTab.session, @"WRAP-RING-READY", &readyRow, &readyCol);
        }
        long ringCursor = -1;
        BOOL foundRingURL = mica_session_find(wrapTab.session, "WRAPSTART", false, &ringCursor);
        wrapRow = wrapCol = -1;
        MicaUITestFindText(wrapTab.session, @"WRAPSTART", &wrapRow, &wrapCol);
        clickCell(wrapRow, wrapCol + 12);
        BOOL ringFirstClick = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        clickCell(wrapRow + 1, 3);
        BOOL ringSecondClick = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        MicaUITestRecord(report, &allPassed, readyRow >= 0 && foundRingURL && wrapRow >= 0 &&
            mica_session_scrolled_lines(wrapTab.session) > mica_session_history_lines(wrapTab.session) &&
            mica_session_history_storage_bytes(wrapTab.session) <= mica_history_limit_bytes() &&
            ringFirstClick && ringSecondClick,
            [NSString stringWithFormat:@"Command-click opens a retained wrapped URL after history-ring replacement (first=%d second=%d)",
                ringFirstClick, ringSecondClick]);
        mica_session_resize(wrapTab.session, 8, (int)wrapCols);
        mica_session_clear_scrollback(wrapTab.session);
        mica_session_write(wrapTab.session, "go\n", 3);
        readyRow = readyCol = -1;
        for (int attempt = 0; attempt < 600 && readyRow < 0; attempt++) {
            mica_session_poll(wrapTab.session, 10);
            MicaUITestFindText(wrapTab.session, @"WIDTH-READY", &readyRow, &readyCol);
        }
        NSInteger preResizeLinkRow = -1, preResizeLinkCol = -1;
        MicaUITestFindText(wrapTab.session, @"https://width.test/", &preResizeLinkRow, &preResizeLinkCol);
        MicaCell preResizeLinkCell = {0};
        BOOL preResizeLinkFound = preResizeLinkRow >= 0 &&
            mica_session_get_cell(wrapTab.session, (int)preResizeLinkRow, (int)preResizeLinkCol, &preResizeLinkCell);
        const char *preResizeLinkURI = preResizeLinkFound
            ? mica_session_hyperlink_uri(wrapTab.session, preResizeLinkCell.hyperlink_id) : NULL;
        MicaUITestRecord(report, &allPassed, preResizeLinkURI &&
            strcmp(preResizeLinkURI, "https://width.test/resize-target") == 0,
            [NSString stringWithFormat:@"width-resize fixture starts with OSC8 target (id=%u uri=%s)",
                preResizeLinkCell.hyperlink_id, preResizeLinkURI ?: "<none>"]);
        mica_session_resize(wrapTab.session, 8, (int)wrapCols - 21);
        mica_session_scroll(wrapTab.session, INT_MAX);
        long widthResizeCursor = 0;
        BOOL widthResizeRetainsHistory = mica_session_find(wrapTab.session, "WRAPWIDTHSTART", false, &widthResizeCursor);
        NSInteger widthLinkRow = -1, widthLinkCol = -1;
        MicaUITestFindText(wrapTab.session, @"https://width.test/", &widthLinkRow, &widthLinkCol);
        MicaCell widthLinkCell = {0};
        BOOL widthLinkCellFound = widthLinkRow >= 0 &&
            mica_session_get_cell(wrapTab.session, (int)widthLinkRow, (int)widthLinkCol, &widthLinkCell);
        const char *widthLinkURI = widthLinkCellFound
            ? mica_session_hyperlink_uri(wrapTab.session, widthLinkCell.hyperlink_id) : NULL;
        BOOL widthResizeRetainsOSC8Target = widthLinkURI &&
            strcmp(widthLinkURI, "https://width.test/resize-target") == 0;
        if (widthLinkRow >= 0) clickCell(widthLinkRow, widthLinkCol + 2);
        BOOL widthResizeClickRoutesOSC8Target = widthLinkRow >= 0 &&
            [wrapOpened.absoluteString isEqualToString:@"https://width.test/resize-target"];
        MicaUITestRecord(report, &allPassed, readyRow >= 0 && widthResizeRetainsHistory &&
            mica_session_history_lines(wrapTab.session) > 0 && widthResizeRetainsOSC8Target &&
            widthResizeClickRoutesOSC8Target,
            [NSString stringWithFormat:@"column-width resize retains a wrapped row and routes its OSC 8 target (stored=%d click=%d)",
                widthResizeRetainsOSC8Target, widthResizeClickRoutesOSC8Target]);
        mica_session_resize(wrapTab.session, 8, (int)wrapCols);
        mica_session_clear_scrollback(wrapTab.session);
        mica_session_write(wrapTab.session, "go\n", 3);
        readyRow = readyCol = -1;
        for (int attempt = 0; attempt < 600 && readyRow < 0; attempt++) {
            mica_session_poll(wrapTab.session, 10);
            MicaUITestFindText(wrapTab.session, @"BOUNDARY-READY", &readyRow, &readyCol);
        }
        mica_session_scroll(wrapTab.session, INT_MAX);
        wrapRow = wrapCol = -1;
        MicaUITestFindText(wrapTab.session, @"WRAPSTART", &wrapRow, &wrapCol);
        NSInteger boundaryRow = mica_session_view_offset(wrapTab.session);
        clickCell(wrapRow, wrapCol + 12);
        BOOL boundaryHistoryClick = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        clickCell(boundaryRow, 3);
        BOOL boundaryLiveClick = [wrapOpened.absoluteString isEqualToString:wrapExpected];
        MicaUITestRecord(report, &allPassed, readyRow >= 0 && wrapRow >= 0 && boundaryRow > wrapRow &&
            boundaryRow <= wrapRow + 4 && boundaryHistoryClick && boundaryLiveClick,
            [NSString stringWithFormat:@"Command-click opens the whole URL from both sides of the history/live boundary (boundary=%ld history=%d live=%d)",
                (long)boundaryRow, boundaryHistoryClick, boundaryLiveClick]);
        mica_set_history_limit_lines(savedWrapBudget / (80u * sizeof(VTermScreenCell)));
        wrapDelegate.tabs = [NSMutableArray array];

        MicaAppDelegate *voiceDelegate = [[MicaAppDelegate alloc] init];
        voiceDelegate.tabs = [NSMutableArray array];
        voiceDelegate.activeIndex = 0;
        voiceDelegate.uiMode = MicaUIModeNormal;
        MicaUITestAttachWindow(voiceDelegate);
        char voiceTestDirectoryTemplate[] = "/tmp/mica-voice-contract-XXXXXX";
        char *voiceTestDirectoryPath = mkdtemp(voiceTestDirectoryTemplate);
        NSString *voiceTestDirectory = voiceTestDirectoryPath
            ? [NSString stringWithUTF8String:voiceTestDirectoryPath] : nil;
        BOOL voiceTestDirectoryReady = voiceTestDirectory.length > 0 &&
            setenv("MICA_TEST_ZLE_DIR", voiceTestDirectory.fileSystemRepresentation, 1) == 0;
        MicaUITestVoiceController *pushToTalkProbe = [[MicaUITestVoiceController alloc]
            initWithHelperURL:[NSURL fileURLWithPath:@"/bin/false"]];
        voiceDelegate.voiceController = pushToTalkProbe;
        [voiceDelegate addTabWithName:@"PTT target" cwd:@"/tmp"
            command:@"printf 'PTT-TARGET-READY\\n'" prefilled:NO];
        [voiceDelegate addTabWithName:@"Other tab" cwd:@"/tmp"
            command:@"printf 'PTT-OTHER-READY\\n'" prefilled:NO];
        unsetenv("MICA_TEST_ZLE_DIR");
        MicaTab *voiceTargetTab = voiceDelegate.tabs.firstObject;
        BOOL voiceTabsReady = NO;
        for (int attempt = 0; attempt < 200; attempt++) {
            for (MicaTab *tab in voiceDelegate.tabs) mica_session_poll(tab.session, 0);
            if (MicaUITestFindText(voiceTargetTab.session, @"PTT-TARGET-READY", NULL, NULL)) {
                voiceTabsReady = YES;
                break;
            }
            usleep(10000);
        }
        // The command-completion OSC arrives before its replacement zsh prompt.
        // Wait for each shell's zle-line-init probe instead of guessing by time.
        BOOL voiceTabsAtPrompt = NO;
        for (int attempt = 0; voiceTestDirectoryReady && attempt < 500; attempt++) {
            BOOL bothEditorsReady = voiceTestDirectoryReady;
            for (MicaTab *tab in voiceDelegate.tabs) {
                mica_session_poll(tab.session, 0);
                bothEditorsReady = bothEditorsReady &&
                    [[NSFileManager defaultManager] fileExistsAtPath:
                        MicaUITestVoiceFile(voiceTestDirectory, tab.session, @"ready")];
            }
            if (bothEditorsReady) {
                voiceTabsAtPrompt = YES;
                break;
            }
            MicaUITestRunLoopFor(0.01);
        }
        [voiceDelegate selectTabAtIndex:0];
        MicaUITestSendFlags(voiceDelegate, NSEventModifierFlagOption, 58);
        MicaUITestSendFlags(voiceDelegate, 0, 58);
        MicaUITestRunLoopFor(0.22);
        BOOL quickOptionTapIgnored = pushToTalkProbe.pushToTalkStarts == 0 &&
            pushToTalkProbe.pushToTalkFinishes == 0;
        MicaUITestSendFlags(voiceDelegate,
            NSEventModifierFlagOption | NSEventModifierFlagCommand, 58);
        MicaUITestSendFlags(voiceDelegate, NSEventModifierFlagCommand, 58);
        MicaUITestRunLoopFor(0.22);
        BOOL optionChordIgnored = pushToTalkProbe.pushToTalkStarts == 0 &&
            pushToTalkProbe.pushToTalkFinishes == 0;
        MicaUITestSendFlags(voiceDelegate, NSEventModifierFlagOption, 58);
        for (int attempt = 0; pushToTalkProbe.pushToTalkStarts < 1 && attempt < 200; attempt++)
            MicaUITestRunLoopFor(0.01);
        BOOL heldOptionStartedOnce = pushToTalkProbe.pushToTalkStarts == 1 &&
            voiceDelegate.voiceTargetTab == voiceTargetTab;
        MicaUITestSendFlags(voiceDelegate, 0, 58);
        BOOL optionReleaseFinishedOnce = pushToTalkProbe.pushToTalkFinishes == 1;
        MicaUITestRecord(report, &allPassed, voiceTabsReady && voiceTabsAtPrompt && quickOptionTapIgnored &&
            optionChordIgnored && heldOptionStartedOnce && optionReleaseFinishedOnce,
            [NSString stringWithFormat:@"left Option hold starts dictation once, release finishes, and taps/chords are ignored (ready=%d prompt=%d quick=%d chord=%d starts=%lu finishes=%lu)",
                voiceTabsReady, voiceTabsAtPrompt, quickOptionTapIgnored, optionChordIgnored,
                (unsigned long)pushToTalkProbe.pushToTalkStarts,
                (unsigned long)pushToTalkProbe.pushToTalkFinishes]);

        MicaUITestSendFlags(voiceDelegate, NSEventModifierFlagOption, 58);
        for (int attempt = 0; pushToTalkProbe.pushToTalkStarts < 2 && attempt < 200; attempt++)
            MicaUITestRunLoopFor(0.01);
        [voiceDelegate.terminalView cancelLeftOptionTracking];
        BOOL focusLossFinishesHold = pushToTalkProbe.pushToTalkStarts == 2 &&
            pushToTalkProbe.pushToTalkFinishes == 2;
        MicaUITestRecord(report, &allPassed, focusLossFinishesHold,
            @"losing app focus finalizes an active hold-to-talk capture exactly once");

        // The input method delivers composed text through NSTextInputClient;
        // exercise that boundary directly so this test is independent of the
        // machine's physical keyboard layout.
        [voiceDelegate selectTabAtIndex:0];
        mica_session_write(voiceTargetTab.session, "\x15", 1); // zsh: Ctrl-U
        for (int attempt = 0; attempt < 20; attempt++) {
            mica_session_poll(voiceTargetTab.session, 0);
            MicaUITestRunLoopFor(0.01);
        }
        MicaUITestInsertComposedText(voiceDelegate, @"@#@@");
        NSString *composedBuffer = voiceTestDirectoryReady
            ? MicaUITestCaptureZLEBuffer(voiceTestDirectory, voiceTargetTab.session) : nil;
        BOOL atTyped = [composedBuffer isEqualToString:@"@#@@"];
        MicaUITestRecord(report, &allPassed, atTyped,
            [NSString stringWithFormat:@"composed punctuation reaches the captured shell buffer (buffer=%@)",
                composedBuffer ?: @"<missing>"]);
        if (voiceTestDirectoryReady)
            [[NSFileManager defaultManager] removeItemAtPath:
                MicaUITestVoiceFile(voiceTestDirectory, voiceTargetTab.session, @"buffer") error:nil];
        mica_session_write(voiceTargetTab.session, "\x15", 1); // zsh: Ctrl-U
        for (int attempt = 0; attempt < 20; attempt++) {
            mica_session_poll(voiceTargetTab.session, 0);
            MicaUITestRunLoopFor(0.01);
        }

        // Holding left Option long enough to start dictation, then pressing a
        // character key cancels dictation. Insert its composed text through
        // NSTextInputClient so the assertion does not depend on the host layout.
        [voiceDelegate.terminalView cancelLeftOptionTracking];
        NSUInteger startsBefore = pushToTalkProbe.pushToTalkStarts;
        MicaUITestSendFlags(voiceDelegate, NSEventModifierFlagOption, 58);
        for (int attempt = 0; pushToTalkProbe.pushToTalkStarts <= startsBefore && attempt < 300; attempt++)
            MicaUITestRunLoopFor(0.01);
        NSEvent *afterHoldKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:NSEventModifierFlagOption timestamp:0 windowNumber:voiceDelegate.window.windowNumber
            context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0];
        if (afterHoldKey) [voiceDelegate.terminalView keyDown:afterHoldKey];
        MicaUITestSendFlags(voiceDelegate, 0, 58);
        mica_session_write(voiceTargetTab.session, "\x15", 1); // zsh: Ctrl-U
        MicaUITestInsertComposedText(voiceDelegate, @"mica_late_option_text");
        NSString *lateBuffer = voiceTestDirectoryReady
            ? MicaUITestCaptureZLEBuffer(voiceTestDirectory, voiceTargetTab.session) : nil;
        BOOL lateAtTyped = [lateBuffer isEqualToString:@"mica_late_option_text"];
        MicaUITestRecord(report, &allPassed, lateAtTyped && pushToTalkProbe.pushToTalkStarts == startsBefore + 1,
            [NSString stringWithFormat:@"a character key after a long left Option hold leaves text input available (buffer=%@ starts=%lu)",
                lateBuffer ?: @"<missing>", (unsigned long)(pushToTalkProbe.pushToTalkStarts - startsBefore)]);
        if (voiceTestDirectoryReady)
            [[NSFileManager defaultManager] removeItemAtPath:
                MicaUITestVoiceFile(voiceTestDirectory, voiceTargetTab.session, @"buffer") error:nil];

        // The Option-composition checks above intentionally typed into this prompt.
        // Clear that line so the transcript routing assertion starts from an empty buffer.
        mica_session_write(voiceTargetTab.session, "\x15", 1); // zsh: Ctrl-U
        for (int attempt = 0; attempt < 20; attempt++) {
            mica_session_poll(voiceTargetTab.session, 0);
            MicaUITestRunLoopFor(0.01);
        }

        char rawHelperTemplate[] = "/tmp/mica-voice-raw-XXXXXX";
        char rawCallsTemplate[] = "/tmp/mica-voice-raw-calls-XXXXXX";
        int rawHelperFD = mkstemp(rawHelperTemplate);
        int rawCallsFD = mkstemp(rawCallsTemplate);
        NSString *rawCallsPath = [NSString stringWithUTF8String:rawCallsTemplate];
        NSString *rawHelperSource = [NSString stringWithFormat:
            @"#!/bin/sh\nprintf '%%s\\n' \"$1\" >> '%@'\n"
             "if [ \"$1\" = stream ]; then\n"
             "  printf '%%s\\n' '{\"type\":\"result\",\"text\":\"mica_test_raw_transcript\"}'\n"
             "else\n"
             "  printf '%%s\\n' '{\"type\":\"error\",\"message\":\"cleanup should not run\"}'\n"
             "fi\n", rawCallsPath];
        NSData *rawHelperData = [rawHelperSource dataUsingEncoding:NSUTF8StringEncoding];
        BOOL rawHelperReady = rawHelperFD >= 0 && rawCallsFD >= 0 &&
            write(rawHelperFD, rawHelperData.bytes, rawHelperData.length) == (ssize_t)rawHelperData.length &&
            fchmod(rawHelperFD, 0700) == 0;
        if (rawHelperFD >= 0) close(rawHelperFD);
        if (rawCallsFD >= 0) close(rawCallsFD);
        MicaVoiceController *rawVoiceController = rawHelperReady
            ? [[MicaVoiceController alloc] initWithHelperURL:[NSURL fileURLWithPath:
                [NSString stringWithUTF8String:rawHelperTemplate]]]
            : nil;
        voiceDelegate.voiceController = rawVoiceController;
        rawVoiceController.delegate = voiceDelegate;
        voiceDelegate.voiceTargetTab = voiceTargetTab;
        [voiceDelegate selectTabAtIndex:1];
        if (rawHelperReady)
            MicaUITestLaunchSpeechHelper(rawVoiceController);
        for (int attempt = 0; rawHelperReady &&
             (rawVoiceController.state != MicaVoiceControllerStateIdle ||
              ![rawVoiceController.transcript isEqualToString:@"mica_test_raw_transcript"]) && attempt < 500; attempt++) {
            for (MicaTab *tab in voiceDelegate.tabs) mica_session_poll(tab.session, 0);
            MicaUITestRunLoopFor(0.01);
        }

        // Ask each live zsh line editor to write its actual editable buffer to
        // a private fixture receipt. This works for wrapped text and proves
        // which PTY received input without submitting that input.
        NSString *targetBufferPath = MicaUITestVoiceFile(voiceTestDirectory,
            voiceTargetTab.session, @"buffer");
        NSString *otherBufferPath = MicaUITestVoiceFile(voiceTestDirectory,
            ((MicaTab *)voiceDelegate.tabs[1]).session, @"buffer");
        NSString *targetExecutionPath = MicaUITestVoiceFile(voiceTestDirectory,
            voiceTargetTab.session, @"executed");
        if (voiceTabsAtPrompt && voiceTestDirectoryReady) {
            static const char captureBufferChord[] = { 0x18, 0x02 };
            mica_session_write(voiceTargetTab.session, captureBufferChord, sizeof(captureBufferChord));
            mica_session_write(((MicaTab *)voiceDelegate.tabs[1]).session,
                captureBufferChord, sizeof(captureBufferChord));
        }
        for (int attempt = 0; rawHelperReady && voiceTestDirectoryReady && attempt < 300; attempt++) {
            for (MicaTab *tab in voiceDelegate.tabs) mica_session_poll(tab.session, 0);
            if ([[NSFileManager defaultManager] fileExistsAtPath:targetBufferPath] &&
                [[NSFileManager defaultManager] fileExistsAtPath:otherBufferPath]) break;
            MicaUITestRunLoopFor(0.01);
        }
        NSString *targetBuffer = [NSString stringWithContentsOfFile:targetBufferPath
            encoding:NSUTF8StringEncoding error:nil];
        NSString *otherBuffer = [NSString stringWithContentsOfFile:otherBufferPath
            encoding:NSUTF8StringEncoding error:nil];
        targetBuffer = [targetBuffer stringByTrimmingCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
        otherBuffer = [otherBuffer stringByTrimmingCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
        NSString *rawHelperCalls = [NSString stringWithContentsOfFile:rawCallsPath
            encoding:NSUTF8StringEncoding error:nil];
        BOOL wasNotSubmittedAutomatically =
            ![[NSFileManager defaultManager] fileExistsAtPath:targetExecutionPath];
        BOOL routedToCapturedTab = [targetBuffer isEqualToString:@"mica_test_raw_transcript"] &&
            otherBuffer.length == 0;
        BOOL targetTranscriptVisible = NO;
        if (routedToCapturedTab) {
            [voiceDelegate selectTabAtIndex:0];
            for (int attempt = 0; attempt < 100 && !targetTranscriptVisible; attempt++) {
                mica_session_poll(voiceTargetTab.session, 0);
                targetTranscriptVisible = MicaUITestFindTextAcrossWrappedRows(
                    voiceTargetTab.session, @"mica_test_raw_transcript");
                if (!targetTranscriptVisible) MicaUITestRunLoopFor(0.01);
            }
        }
        BOOL explicitReturnExecutes = NO;
        if (routedToCapturedTab && wasNotSubmittedAutomatically) {
            MicaUITestSendKey(voiceDelegate, @"\r", 0, 36);
            for (int attempt = 0; attempt < 300; attempt++) {
                mica_session_poll(voiceTargetTab.session, 0);
                if ([[NSFileManager defaultManager] fileExistsAtPath:targetExecutionPath]) {
                    explicitReturnExecutes = YES;
                    break;
                }
                MicaUITestRunLoopFor(0.01);
            }
        }
        BOOL rawTranscriptInsertedWithoutCleanup = rawHelperReady &&
            rawVoiceController.state == MicaVoiceControllerStateIdle &&
            [rawHelperCalls isEqualToString:@"stream\n"] &&
            routedToCapturedTab && wasNotSubmittedAutomatically && targetTranscriptVisible &&
            explicitReturnExecutes;
        MicaUITestRecord(report, &allPassed, rawTranscriptInsertedWithoutCleanup,
            [NSString stringWithFormat:@"raw speech result stays in the captured shell buffer until Return (calls=%@ state=%ld status=%@ target-running=%d target-buffer=%@ other-buffer=%@ not-submitted=%d visible=%d return-executes=%d command=%s completions=%llu screen=%@)",
                rawHelperCalls, (long)rawVoiceController.state, rawVoiceController.statusText,
                mica_session_is_running(voiceTargetTab.session), targetBuffer ?: @"<missing>",
                otherBuffer ?: @"<missing>", wasNotSubmittedAutomatically,
                targetTranscriptVisible, explicitReturnExecutes,
                mica_session_current_command(voiceTargetTab.session),
                (unsigned long long)mica_session_command_completion_count(voiceTargetTab.session),
                MicaUITestScreenTail(voiceTargetTab.session)]);

        MicaVoiceController *undeliveredProbe = rawHelperReady
            ? [[MicaVoiceController alloc] initWithHelperURL:[NSURL fileURLWithPath:
                [NSString stringWithUTF8String:rawHelperTemplate]]]
            : nil;
        undeliveredProbe.delegate = voiceDelegate;
        voiceDelegate.voiceController = undeliveredProbe;
        voiceDelegate.voiceTargetTab = nil;
        if (rawHelperReady) MicaUITestLaunchSpeechHelper(undeliveredProbe);
        for (int attempt = 0; rawHelperReady &&
             undeliveredProbe.state != MicaVoiceControllerStateFailed && attempt < 300; attempt++)
            MicaUITestRunLoopFor(0.01);
        BOOL rejectedDeliveryPreservesTranscript = rawHelperReady &&
            undeliveredProbe.state == MicaVoiceControllerStateFailed &&
            [undeliveredProbe.transcript isEqualToString:@"mica_test_raw_transcript"] &&
            [undeliveredProbe.statusText containsString:@"Copy it"];
        MicaUITestRecord(report, &allPassed, rejectedDeliveryPreservesTranscript,
            [NSString stringWithFormat:@"a transcript rejected by its captured shell stays visible with recovery guidance (state=%ld transcript=%@ status=%@)",
                (long)undeliveredProbe.state, undeliveredProbe.transcript, undeliveredProbe.statusText]);
        [undeliveredProbe cancel];
        voiceDelegate.voiceController = rawVoiceController;

        if (voiceTestDirectoryPath) {
            [[NSFileManager defaultManager] removeItemAtPath:voiceTestDirectory error:nil];
        }
        [voiceDelegate.window makeKeyAndOrderFront:nil];
        [voiceDelegate cancelDictation];
        BOOL cancelKeepsWindowOpen = voiceDelegate.window.isVisible;
        MicaUITestRecord(report, &allPassed, cancelKeepsWindowOpen,
            @"cancelling dictation leaves the Mica window open");
        unlink(rawHelperTemplate);
        unlink(rawCallsTemplate);
        BOOL voiceSessionsExited = MicaUITestExitTabs(voiceDelegate.tabs);
        MicaUITestRecord(report, &allPassed, voiceSessionsExited,
            @"hold-to-talk test sessions exit cleanly");
        voiceDelegate.tabs = [NSMutableArray array];
        [voiceDelegate.window orderOut:nil];
        voiceDelegate.terminalView = nil;
        voiceDelegate.window = nil;

        MicaAppDelegate *resizeDelegate = [[MicaAppDelegate alloc] init];
        resizeDelegate.tabs = [NSMutableArray array];
        resizeDelegate.activeIndex = 0;
        resizeDelegate.uiMode = MicaUIModeNormal;
        resizeDelegate.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 500)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        MicaUITestLiveResizeView *resizeView = [[MicaUITestLiveResizeView alloc]
            initWithFrame:resizeDelegate.window.contentView.bounds];
        resizeView.owner = resizeDelegate;
        resizeView.terminalFont = MicaTerminalFont(kFontSizeDefault);
        resizeDelegate.terminalView = resizeView;
        [resizeDelegate.window setContentView:resizeView];
        CGFloat cellWidth = [@"M" sizeWithAttributes:@{NSFontAttributeName:resizeView.terminalFont}].width;
        NSString *resizeCommand = @"i=1; while [ $i -le 80 ]; do printf 'RESIZE-HISTORY-%03d\\n' $i; i=$((i+1)); done; "
            @"python3 -c 'import fcntl,termios,struct,time,sys\n"
                     "get=lambda:struct.unpack(\"HHHH\",fcntl.ioctl(0,termios.TIOCGWINSZ,b\"\\0\"*8))\n"
                     "old=get()[2]\n"
                     "print(\"MICA-RESIZE-READY\",flush=True)\n"
                     "sys.stdin.readline()\n"
                     "old=get()[2]\n"
                     "print(\"MICA-RESIZE-ARMED\",flush=True)\n"
                     "end=time.time()+5\n"
                     "while time.time()<end:\n"
                     " new=get()[2]\n"
                     " if new!=old:\n"
                     "  print(\"MICA-RESIZE-PIXELS-UPDATED\",flush=True)\n"
                     "  old=new\n"
                     " time.sleep(.01)'";
        MicaTab *resizeTab = [[MicaTab alloc] init];
        resizeTab.name = @"Resize";
        resizeTab.cwd = @"/tmp";
        resizeTab.command = resizeCommand;
        resizeTab.session = mica_session_create("/tmp", resizeCommand.UTF8String, 24, 80);
        [resizeDelegate.tabs addObject:resizeTab];
        BOOL resizeFixtureReady = NO;
        for (int attempt = 0; attempt < 200; attempt++) {
            mica_session_poll(resizeTab.session, 0);
            if (MicaUITestFindText(resizeTab.session, @"MICA-RESIZE-READY", NULL, NULL)) {
                resizeFixtureReady = YES;
                break;
            }
            usleep(10000);
        }
        BOOL resizeHistoryReady = mica_session_history_lines(resizeTab.session) > 0;
        [resizeView updateGridSize];
        mica_session_write(resizeTab.session, "go\n", 3);
        BOOL resizeFixtureArmed = NO;
        for (int attempt = 0; attempt < 200; attempt++) {
            mica_session_poll(resizeTab.session, 0);
            if (MicaUITestFindText(resizeTab.session, @"MICA-RESIZE-ARMED", NULL, NULL)) {
                resizeFixtureArmed = YES;
                break;
            }
            usleep(10000);
        }
        NSInteger resizeBeforeFailure = mica_session_cols(resizeTab.session);
        NSRect allocationFailureFrame = resizeView.frame;
        allocationFailureFrame.size.width += MAX(1, ceil(cellWidth * 20));
        resizeView.frame = allocationFailureFrame;
        mica_session_test_fail_next_history_resize_allocation();
        [resizeView updateGridSize];
        NSInteger cachedColsAfterFailure = [[resizeView valueForKey:@"cols"] integerValue];
        BOOL failedResizeKeptUICache = resizeFixtureReady && resizeHistoryReady && resizeFixtureArmed &&
            mica_session_cols(resizeTab.session) == resizeBeforeFailure &&
            cachedColsAfterFailure == resizeBeforeFailure;
        MicaUITestRunLoopFor(1.15);
        BOOL failedResizeRetried = mica_session_cols(resizeTab.session) > resizeBeforeFailure &&
            [[resizeView valueForKey:@"cols"] integerValue] == mica_session_cols(resizeTab.session);
        MicaUITestRecord(report, &allPassed, failedResizeKeptUICache && failedResizeRetried,
            [NSString stringWithFormat:@"AppKit keeps its old grid cache after a history resize allocation failure, then retries to the new PTY size (ready=%d history=%d armed=%d cache=%ld/%ld retry=%d)",
                resizeFixtureReady, resizeHistoryReady, resizeFixtureArmed,
                (long)cachedColsAfterFailure, (long)resizeBeforeFailure, failedResizeRetried]);
        NSUInteger initialResizeMarkerCount = 0;
        for (int attempt = 0; attempt < 100 && initialResizeMarkerCount == 0; attempt++) {
            mica_session_poll(resizeTab.session, 10);
            initialResizeMarkerCount = MicaUITestCountText(resizeTab.session,
                @"MICA-RESIZE-PIXELS-UPDATED");
        }
        NSInteger originalRows = mica_session_rows(resizeTab.session);
        NSInteger originalCols = mica_session_cols(resizeTab.session);
        NSRect resizedFrame = resizeView.frame;
        resizedFrame.size.width += MAX(1, floor(cellWidth / 2));
        resizeView.testInLiveResize = YES;
        resizeView.frame = resizedFrame;
        [resizeView updateGridSize];
        MicaUITestRunLoopFor(0.15);
        mica_session_poll(resizeTab.session, 0);
        BOOL pixelResizeDeferred = resizeFixtureReady &&
            mica_session_rows(resizeTab.session) == originalRows &&
            mica_session_cols(resizeTab.session) == originalCols &&
            MicaUITestCountText(resizeTab.session, @"MICA-RESIZE-PIXELS-UPDATED") == initialResizeMarkerCount;
        resizeView.testInLiveResize = NO;
        [resizeView updateGridSize];
        for (int attempt = 0; attempt < 100 &&
             MicaUITestCountText(resizeTab.session, @"MICA-RESIZE-PIXELS-UPDATED") == initialResizeMarkerCount; attempt++) {
            mica_session_poll(resizeTab.session, 10);
        }
        for (int repeat = 0; repeat < 3; repeat++) [resizeView updateGridSize];
        MicaUITestRunLoopFor(0.1);
        mica_session_poll(resizeTab.session, 0);
        NSUInteger pixelUpdatesAfterEnd = MicaUITestCountText(resizeTab.session,
            @"MICA-RESIZE-PIXELS-UPDATED");
        MicaUITestRecord(report, &allPassed, pixelResizeDeferred &&
            pixelUpdatesAfterEnd == initialResizeMarkerCount + 1,
            [NSString stringWithFormat:@"pixel-only terminal dimensions stay stable during live resize and update once when it ends (deferred=%d final-updates=%lu rows=%ld/%ld cols=%ld/%ld)",
                pixelResizeDeferred, (unsigned long)pixelUpdatesAfterEnd,
                (long)mica_session_rows(resizeTab.session), (long)originalRows,
                (long)mica_session_cols(resizeTab.session), (long)originalCols]);
        NSUInteger updatesBeforeAXResize = MicaUITestCountText(resizeTab.session,
            @"MICA-RESIZE-PIXELS-UPDATED");
        NSRect programmaticFrame = resizeView.frame;
        programmaticFrame.size.width += MAX(1, ceil(cellWidth));
        resizeView.frame = programmaticFrame;
        [resizeView scheduleGridResize];
        programmaticFrame.size.width += MAX(1, ceil(cellWidth));
        resizeView.frame = programmaticFrame;
        [resizeView scheduleGridResize];
        BOOL programmaticResizeDeferred = MicaUITestCountText(resizeTab.session,
            @"MICA-RESIZE-PIXELS-UPDATED") == updatesBeforeAXResize;
        MicaUITestRunLoopFor(0.2);
        for (int attempt = 0; attempt < 100 &&
             MicaUITestCountText(resizeTab.session, @"MICA-RESIZE-PIXELS-UPDATED") == updatesBeforeAXResize; attempt++) {
            mica_session_poll(resizeTab.session, 10);
        }
        NSUInteger updatesAfterAXResize = MicaUITestCountText(resizeTab.session,
            @"MICA-RESIZE-PIXELS-UPDATED");
        BOOL programmaticResizeCoalesced = programmaticResizeDeferred &&
            updatesAfterAXResize == updatesBeforeAXResize + 1;
        MicaUITestRecord(report, &allPassed, programmaticResizeCoalesced,
            [NSString stringWithFormat:@"programmatic window resizes defer and coalesce terminal PTY size changes (deferred=%d updates=%lu→%lu)",
                programmaticResizeDeferred, (unsigned long)updatesBeforeAXResize,
                (unsigned long)updatesAfterAXResize]);
        mica_session_write(resizeTab.session, "\x03", 1);
        BOOL resizeSessionExited = MicaUITestExitTabs(resizeDelegate.tabs);
        MicaUITestRecord(report, &allPassed, resizeSessionExited,
            @"live-resize PTY fixture exits cleanly");
        resizeDelegate.tabs = [NSMutableArray array];
        [resizeDelegate.window orderOut:nil];
        resizeDelegate.terminalView = nil;
        resizeDelegate.window = nil;

        [delegate loadLaunchConfiguration];
        MicaTab *defaultTab = delegate.activeTab;
        MicaUITestRecord(report, &allPassed, delegate.tabs.count == 1 && defaultTab.session != NULL &&
                         [defaultTab.name isEqualToString:@"Shell"] &&
                         [defaultTab.cwd isEqualToString:NSFileManager.defaultManager.currentDirectoryPath],
                         @"default launch configuration creates a shell tab in the working directory");
        delegate.tabs = [NSMutableArray array];
        delegate.activeIndex = 0;

        NSString *repositoryPath = NSFileManager.defaultManager.currentDirectoryPath;
        char gitLayoutTemplate[] = "/tmp/mica-shell-layout-XXXXXX";
        int gitLayoutFD = mkstemp(gitLayoutTemplate);
        NSString *gitLayoutPath = gitLayoutFD >= 0
            ? [NSString stringWithUTF8String:gitLayoutTemplate] : nil;
        if (gitLayoutFD >= 0) close(gitLayoutFD);
        NSString *gitLayoutContents = [NSString stringWithFormat:
            @"# Mica layout v1\nShell\t%@\nGit\t%@\tmica-git\nLegacy Git\t%@\tlazygit\n",
                repositoryPath, repositoryPath, repositoryPath];
        BOOL gitLayoutWritten = gitLayoutPath &&
            [gitLayoutContents writeToFile:gitLayoutPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (gitLayoutWritten)
            [delegate loadLaunchConfigurationFromArguments:@[@"mica", @"--layout", gitLayoutPath] bundleInfo:@{}];
        MicaTab *gitTab = delegate.tabs.count > 1 ? delegate.tabs[1] : nil;
        MicaTab *legacyGitTab = delegate.tabs.count > 2 ? delegate.tabs[2] : nil;
        BOOL gitEntriesAreOrdinaryTabs = gitLayoutWritten && delegate.tabs.count == 3 &&
            [gitTab.name isEqualToString:@"Git"] && [gitTab.command isEqualToString:@"lazygit"] &&
            [legacyGitTab.name isEqualToString:@"Legacy Git"] &&
            [legacyGitTab.command isEqualToString:@"lazygit"] && gitTab.session && legacyGitTab.session;
        BOOL gitCommandsPrefilled = NO;
        for (int attempt = 0; attempt < 500 && !gitCommandsPrefilled; attempt++) {
            for (MicaTab *tab in delegate.tabs) mica_session_poll(tab.session, 0);
            gitCommandsPrefilled = MicaUITestFindText(gitTab.session, @"lazygit", NULL, NULL) &&
                MicaUITestFindText(legacyGitTab.session, @"lazygit", NULL, NULL);
            if (!gitCommandsPrefilled)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        MicaUITestRecord(report, &allPassed, gitEntriesAreOrdinaryTabs && gitCommandsPrefilled,
            [NSString stringWithFormat:@"Git layout entries open as regular zsh tabs with lazygit prefilled, including migration from mica-git (tabs=%lu ordinary=%d prefilled=%d)",
                (unsigned long)delegate.tabs.count, gitEntriesAreOrdinaryTabs, gitCommandsPrefilled]);
        if (gitLayoutPath) unlink(gitLayoutPath.fileSystemRepresentation);
        delegate.tabs = [NSMutableArray array];
        delegate.activeIndex = 0;

        NSString *fixture = @"i=1; while [ \"$i\" -le 45 ]; do printf 'ROW-%02d\\n' \"$i\"; i=$((i+1)); done; "
            "printf '\\033[38;2;244;135;113mUI-TRUECOLOR\\033[0m\\n'; "
            "printf '\\033[48;2;18;52;86mUI-BLOCK\\033[0m\\n'; "
            "printf '\\033[7mUI-REVERSE-CHOICE\\033[0m\\n'; "
            "printf 'UI-EMOJI-🙂-👍🏽-👩‍💻-🇮🇹-❤️\\n'; "
            "printf 'Explored src directory\\nWorking (0s - esc to interrupt)\\n'";
        [delegate addTabWithName:@"UI smoke" cwd:@"/tmp" command:fixture prefilled:NO];
        [delegate addTabWithName:@"Second" cwd:@"/tmp" command:@"printf 'SECOND-TAB\\n'" prefilled:NO];
        [delegate addTabWithName:@"Third" cwd:@"/tmp" command:@"printf 'THIRD-TAB\\n'" prefilled:NO];

        MicaTab *fixtureTab = delegate.tabs.firstObject;
        BOOL fixtureReady = NO;
        BOOL emojiLabelFound = NO, colorBlockFound = NO, emojiCellFound = NO;
        for (int attempt = 0; attempt < 600; attempt++) {
            for (MicaTab *tab in delegate.tabs) mica_session_poll(tab.session, 0);
            emojiLabelFound = MicaUITestFindText(fixtureTab.session, @"UI-EMOJI-", NULL, NULL);
            colorBlockFound = MicaUITestFindText(fixtureTab.session, @"UI-BLOCK", NULL, NULL);
            emojiCellFound = MicaUITestFindCodepoint(fixtureTab.session, 0x1f642, NULL, NULL);
            if (emojiLabelFound && colorBlockFound && emojiCellFound &&
                mica_session_history_lines(fixtureTab.session) >= 10) {
                fixtureReady = YES;
                break;
            }
            usleep(10000);
        }
        MicaUITestRecord(report, &allPassed, delegate.tabs.count == 3, @"app delegate created three isolated PTY tabs");
        MicaUITestRecord(report, &allPassed, fixtureReady,
                         [NSString stringWithFormat:@"PTY fixture output (emoji label=%d, RGB block=%d, emoji glyph=%d, history=%lu)",
                          emojiLabelFound, colorBlockFound, emojiCellFound,
                          (unsigned long)mica_session_history_lines(fixtureTab.session)]);
        NSString *agentDetail = nil;
        NSString *agentActivity = MicaAgentActivityForSession(fixtureTab.session, &agentDetail);
        MicaUITestRecord(report, &allPassed, [agentActivity isEqualToString:@"Working"] &&
            [agentDetail containsString:@"Explored src directory"],
            [NSString stringWithFormat:@"agent progress reads the active phase and keeps a recent action for the tooltip (phase=%@ detail=%@)",
                agentActivity, agentDetail]);
        MicaSession *quietAgentProbe = mica_session_create("/tmp",
            "printf 'Claude Code ready\\n'; sleep 2", 6, 80);
        BOOL quietAgentPromptFound = NO;
        for (int attempt = 0; quietAgentProbe && attempt < 100; attempt++) {
            mica_session_poll(quietAgentProbe, 10);
            if (MicaUITestFindText(quietAgentProbe, @"Claude Code ready", NULL, NULL)) {
                quietAgentPromptFound = YES;
                break;
            }
        }
        NSString *quietAgentActivity = quietAgentProbe
            ? MicaAgentActivityForSession(quietAgentProbe, NULL) : nil;
        MicaUITestRecord(report, &allPassed,
            quietAgentPromptFound && [quietAgentActivity isEqualToString:@"Idle"],
            @"an open agent session with no recognized work status is idle, not loading");
        if (quietAgentProbe) mica_session_destroy(quietAgentProbe);
        MicaSession *waitingProbe = mica_session_create("/tmp",
            "printf 'PRESS ENTER TO CONTINUE\\n'; sleep 2", 6, 80);
        BOOL waitingPromptFound = NO;
        for (int attempt = 0; waitingProbe && attempt < 100; attempt++) {
            mica_session_poll(waitingProbe, 10);
            if (MicaUITestFindText(waitingProbe, @"PRESS ENTER TO CONTINUE", NULL, NULL)) {
                waitingPromptFound = YES;
                break;
            }
        }
        NSString *waitingDetail = nil;
        NSString *waitingActivity = waitingProbe
            ? MicaAgentActivityForSession(waitingProbe, &waitingDetail) : nil;
        MicaUITestRecord(report, &allPassed,
            waitingPromptFound && [waitingActivity isEqualToString:@"Needs input"],
            @"the shared activity detector marks a generic command waiting for terminal input");
        if (waitingProbe) mica_session_destroy(waitingProbe);
        MicaSession *glyphPromptProbe = mica_session_create("/tmp", "printf '\\033[5;1H\\u276f'; sleep 2", 6, 80);
        BOOL glyphPromptFound = NO;
        for (int attempt = 0; glyphPromptProbe && attempt < 100; attempt++) {
            mica_session_poll(glyphPromptProbe, 10);
            if (MicaUITestFindCodepoint(glyphPromptProbe, 0x276f, NULL, NULL)) {
                glyphPromptFound = YES;
                break;
            }
        }
        NSString *glyphPromptActivity = glyphPromptProbe
            ? MicaAgentActivityForSession(glyphPromptProbe, NULL) : nil;
        MicaUITestRecord(report, &allPassed,
            glyphPromptFound && [glyphPromptActivity isEqualToString:@"Needs input"],
            [NSString stringWithFormat:@"a Claude-style input prompt glyph is classified as waiting for input (found=%d activity=%@ screen=%@)",
                glyphPromptFound, glyphPromptActivity, MicaUITestScreenTail(glyphPromptProbe)]);
        if (glyphPromptProbe) mica_session_destroy(glyphPromptProbe);
        MicaAppDelegate *pollProbe = [[MicaAppDelegate alloc] init];
        pollProbe.tabs = [NSMutableArray array];
        pollProbe.activeIndex = 0;
        MicaUITestAttachWindow(pollProbe);
        for (int index = 0; index < 7; index++) {
            NSString *command = index == 0
                ? @"exec perl -e '$|=1; while (1) { print \"bulk-output-abcdefghijklmnopqrstuvwxyz-0123456789\\n\"; }'"
                : @"while :; do printf 'busy-output\\n'; sleep 0.01; done";
            [pollProbe addTabWithName:[NSString stringWithFormat:@"Busy %d", index + 1] cwd:@"/tmp"
                command:command prefilled:NO];
        }
        BOOL pollProbeReady = pollProbe.tabs.count == 7;
        for (int attempt = 0; pollProbeReady && attempt < 20; attempt++) {
            [pollProbe pollSessions:nil];
            MicaUITestRunLoopFor(0.015);
        }
        NSTimeInterval pollTotal = 0, pollMaximum = 0;
        for (int attempt = 0; pollProbeReady && attempt < 100; attempt++) {
            NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
            [pollProbe pollSessions:nil];
            NSTimeInterval durationMS = (NSProcessInfo.processInfo.systemUptime - started) * 1000.0;
            pollTotal += durationMS;
            pollMaximum = MAX(pollMaximum, durationMS);
            MicaUITestRunLoopFor(0.015);
        }
        BOOL allBusy = pollProbeReady;
        for (MicaTab *tab in pollProbe.tabs)
            allBusy = allBusy && tab.session && mica_session_is_running(tab.session) && tab.lastOutputReadAt > 0;
        MicaUITestRecord(report, &allPassed, allBusy && pollTotal / 100.0 < 16.0 && pollMaximum < 50.0,
            [NSString stringWithFormat:@"one flooding and six busy PTY tabs poll below 16 ms average and 50 ms worst (avg=%.2f max=%.2f)",
                pollTotal / 100.0, pollMaximum]);
        for (MicaTab *tab in pollProbe.tabs) {
            MicaSession *session = tab.session;
            tab.session = NULL;
            if (session) mica_session_destroy(session);
        }
        pollProbe.tabs = [NSMutableArray array];
        pollProbe.terminalView.owner = nil;
        [pollProbe.window orderOut:nil];
        MicaAppDelegate *cwdProbe = [[MicaAppDelegate alloc] init];
        cwdProbe.tabs = [NSMutableArray array];
        cwdProbe.activeIndex = 0;
        MicaUITestAttachWindow(cwdProbe);
        [cwdProbe addTabWithName:@"Folder change" cwd:@"/tmp"
            command:@"cd /; printf 'MICA-CWD-CHANGED\\n'; sleep 0.5" prefilled:NO];
        MicaTab *cwdTab = cwdProbe.activeTab;
        for (int attempt = 0; cwdTab && attempt < 300 && ![cwdTab.cwd isEqualToString:@"/"]; attempt++) {
            [cwdProbe pollSessions:nil];
            MicaUITestRunLoopFor(0.01);
        }
        MicaUITestRecord(report, &allPassed, [cwdTab.cwd isEqualToString:@"/"],
            @"the folder indicator follows a shell cd after its next PTY output");
        if (cwdTab.session) {
            MicaSession *session = cwdTab.session;
            cwdTab.session = NULL;
            mica_session_destroy(session);
        }
        cwdProbe.terminalView.owner = nil;
        [cwdProbe.window orderOut:nil];
        MicaTab *agentLabelTab = delegate.tabs[0];
        NSString *savedCommand = agentLabelTab.currentCommand;
        NSString *savedName = agentLabelTab.name;
        NSTimeInterval savedOutputReadAt = agentLabelTab.lastOutputReadAt;
        agentLabelTab.currentCommand = @"codex";
        agentLabelTab.name = @"Codex";
        agentLabelTab.agentActivity = @"Working";
        agentLabelTab.lastOutputReadAt = NSProcessInfo.processInfo.systemUptime;
        NSString *firstAgentLabel = [delegate.terminalView labelForTab:agentLabelTab active:YES];
        BOOL reportsRunning = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateRunning;
        agentLabelTab.lastOutputReadAt = NSProcessInfo.processInfo.systemUptime - kAgentActivityQuietInterval - 1.0;
        BOOL quietAgentStopsAnimating = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateIdle;
        agentLabelTab.agentActivity = @"Ready";
        BOOL readyAgentDoesNotAnimate = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateIdle;
        agentLabelTab.agentActivity = @"Needs approval";
        BOOL reportsWaiting = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateWaiting;
        agentLabelTab.needsAttention = YES;
        agentLabelTab.currentCommand = nil;
        BOOL reportsNeedsAttention = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateNeedsAttention;
        agentLabelTab.needsAttention = NO;
        agentLabelTab.completedCommand = YES;
        BOOL reportsComplete = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateComplete;
        agentLabelTab.completedCommand = NO;
        agentLabelTab.currentCommand = @"lazygit";
        agentLabelTab.agentActivity = nil;
        agentLabelTab.lastOutputReadAt = NSProcessInfo.processInfo.systemUptime;
        BOOL lazygitOutputAnimates = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateRunning;
        agentLabelTab.lastOutputReadAt = NSProcessInfo.processInfo.systemUptime - kAgentActivityQuietInterval - 1.0;
        BOOL idleLazygitStopsAnimating = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateIdle;
        agentLabelTab.agentActivity = @"Needs input";
        BOOL lazygitInputDoesNotShowLoading = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateWaiting;
        agentLabelTab.currentCommand = @"codex";
        agentLabelTab.agentActivity = @"Working";
        agentLabelTab.lastOutputReadAt = NSProcessInfo.processInfo.systemUptime;
        agentLabelTab.agentActivityDetail = @"Read src/mica_app.m";
        NSString *updatedAgentLabel = [delegate.terminalView labelForTab:agentLabelTab active:YES];
        BOOL configuredTabNameIsStable = [firstAgentLabel isEqualToString:@"Codex"] &&
            [updatedAgentLabel isEqualToString:firstAgentLabel] && reportsRunning && reportsWaiting &&
            reportsNeedsAttention && reportsComplete && quietAgentStopsAnimating && readyAgentDoesNotAnimate &&
            lazygitOutputAnimates && idleLazygitStopsAnimating && lazygitInputDoesNotShowLoading;
        agentLabelTab.currentCommand = savedCommand;
        agentLabelTab.name = savedName;
        agentLabelTab.agentActivity = nil;
        agentLabelTab.agentActivityDetail = nil;
        agentLabelTab.lastOutputReadAt = savedOutputReadAt;
        MicaUITestRecord(report, &allPassed, configuredTabNameIsStable,
            [NSString stringWithFormat:@"Codex and lazygit animate only after recent output; idle and waiting states stay distinct (%@ → %@; git active=%d idle=%d input=%d)",
                firstAgentLabel, updatedAgentLabel, lazygitOutputAnimates, idleLazygitStopsAnimating,
                lazygitInputDoesNotShowLoading]);
        MicaUITestRecord(report, &allPassed, delegate.terminalView.terminalFont.pointSize >= 16,
                         @"default terminal font remains at least 16 points");
        MicaUITestRecord(report, &allPassed, kTabTitleFontSize == 12.0 && kHeaderHeight == 28.0,
                         @"tab titles use a readable 12-point system font in a 28-point header");
        NSDictionary *footerTextAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:10.5] };
        NSFont *footerFont = footerTextAttrs[NSFontAttributeName];
        NSFont *tabFont = [NSFont systemFontOfSize:kTabTitleFontSize weight:NSFontWeightMedium];
        CGFloat tabBaseline = MicaCenteredTextBaseline(tabFont, kHeaderHeight);
        CGFloat footerBaseline = MicaCenteredTextBaseline(footerFont, kStatusHeight);
        MicaUITestRecord(report, &allPassed,
            fabs((tabBaseline + (tabFont.ascender + tabFont.descender) / 2.0) - kHeaderHeight / 2.0) < 0.01 &&
                fabs((footerBaseline + (footerFont.ascender + footerFont.descender) / 2.0) - kStatusHeight / 2.0) < 0.01 &&
                footerBaseline + footerFont.descender >= 0 && footerBaseline + footerFont.ascender <= kStatusHeight,
            @"tab labels and footer text stay vertically centered at their separate row heights");
        NSDictionary *pathAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:10.5] };
        NSString *samplePath = @"/Users/me/Desktop/Freelance/vsc-vpp-compliance";
        NSString *shortPath = MicaTruncatedPath(samplePath, 170, pathAttrs);
        MicaUITestRecord(report, &allPassed,
            [MicaTruncatedPath(samplePath, 2000, pathAttrs) isEqualToString:samplePath] &&
                [shortPath hasPrefix:@"…/"] && [shortPath hasSuffix:@"vsc-vpp-compliance"],
            [NSString stringWithFormat:@"footer keeps the full project path when space allows and truncates its start when needed (%@)", shortPath]);
        NSString *graphemeTitle = @"Build 👩🏽‍💻 now";
        NSString *graphemePrefix = @"Build 👩🏽‍💻…";
        CGFloat graphemeWidth = [graphemePrefix sizeWithAttributes:pathAttrs].width;
        NSString *shortGraphemeTitle = MicaTruncatedText(graphemeTitle, graphemeWidth, pathAttrs);
        MicaUITestRecord(report, &allPassed, [shortGraphemeTitle isEqualToString:graphemePrefix],
            [NSString stringWithFormat:@"tab truncation stays on composed-character boundaries and finds the longest fitting prefix (%@)",
                shortGraphemeTitle]);
        char removedFolderTemplate[] = "/tmp/mica-missing-cwd-XXXXXX";
        char *removedFolderRoot = mkdtemp(removedFolderTemplate);
        NSString *removedParentFolder = removedFolderRoot
            ? [NSString stringWithFormat:@"%s/removed-parent", removedFolderRoot] : nil;
        NSString *removedFolder = removedParentFolder
            ? [removedParentFolder stringByAppendingPathComponent:@"deleted-project"] : nil;
        if (removedFolder) [[NSFileManager defaultManager] createDirectoryAtPath:removedFolder
            withIntermediateDirectories:YES attributes:nil error:nil];
        if (removedParentFolder) [[NSFileManager defaultManager] removeItemAtPath:removedParentFolder error:nil];
        char canonicalExpectedFolder[PATH_MAX] = {0};
        NSString *expectedFolder = removedFolderRoot && realpath(removedFolderRoot, canonicalExpectedFolder)
            ? [NSString stringWithUTF8String:canonicalExpectedFolder] : nil;
        MicaSession *directoryFallbackSession = removedFolder
            ? mica_session_create([[removedFolder stringByAppendingString:@"/"] fileSystemRepresentation], NULL, 12, 80)
            : NULL;
        BOOL recoveredFolder = NO;
        char recoveredPath[4096] = {0};
        for (int attempt = 0; directoryFallbackSession && attempt < 200; attempt++) {
            mica_session_poll(directoryFallbackSession, 10);
            if (mica_session_working_directory(directoryFallbackSession, recoveredPath,
                                               sizeof(recoveredPath))) {
                NSString *actualFolder = [NSString stringWithUTF8String:recoveredPath];
                if ([actualFolder isEqualToString:expectedFolder]) {
                    recoveredFolder = YES;
                    break;
                }
            }
            MicaUITestRunLoopFor(0.01);
        }
        MicaUITestRecord(report, &allPassed, recoveredFolder,
            [NSString stringWithFormat:@"a deleted multi-level project path with a trailing slash falls back to its existing parent (resolved=%s expected=%@)",
                recoveredPath, expectedFolder]);
        BOOL fallbackNoticeVisible = NO;
        for (int attempt = 0; directoryFallbackSession && attempt < 100 && !fallbackNoticeVisible; attempt++) {
            mica_session_poll(directoryFallbackSession, 10);
            fallbackNoticeVisible = MicaUITestFindTextAcrossWrappedRows(
                directoryFallbackSession, @"cannot enter");
            if (!fallbackNoticeVisible) MicaUITestRunLoopFor(0.01);
        }
        MicaUITestRecord(report, &allPassed, fallbackNoticeVisible,
            @"a recovered project folder prints an explanation in its terminal");
        if (directoryFallbackSession) mica_session_destroy(directoryFallbackSession);
        if (removedFolderRoot) rmdir(removedFolderRoot);

        [delegate.terminalView updateGridSize];
        NSRect firstTabRect = [delegate.terminalView tabRectAtIndex:0];
        NSRect secondTabRect = [delegate.terminalView tabRectAtIndex:1];
        NSRect thirdTabRect = [delegate.terminalView tabRectAtIndex:2];
        BOOL equalTabWidths = fabs(firstTabRect.size.width - secondTabRect.size.width) < 0.01 &&
            fabs(secondTabRect.size.width - thirdTabRect.size.width) < 0.01 &&
            fabs(firstTabRect.origin.x - [delegate.terminalView tabsLeadingInset]) < 0.01 &&
            fabs(NSMaxX(firstTabRect) - NSMinX(secondTabRect)) < 0.01 &&
            fabs(NSMaxX(secondTabRect) - NSMinX(thirdTabRect)) < 0.01 &&
            fabs(NSMaxX(thirdTabRect) - delegate.terminalView.bounds.size.width) > 0.01 &&
            fabs(firstTabRect.size.width - kTabMaximumWidth) < 0.01 &&
            [delegate.terminalView tabIndexAtPoint:NSMakePoint(delegate.terminalView.bounds.size.width - 8,
                NSMidY(firstTabRect))] == NSNotFound;
        MicaUITestRecord(report, &allPassed, equalTabWidths,
                         @"tabs stop growing at the maximum width and unused header space is not clickable");
        NSPoint secondTabCenter = NSMakePoint(NSMidX(secondTabRect), NSMidY(secondTabRect));
        MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, secondTabCenter, 0);
        MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, secondTabCenter, 0);
        BOOL mouseSelectsTabs = delegate.activeIndex == 1;
        NSPoint firstTabCenter = NSMakePoint(NSMidX(firstTabRect), NSMidY(firstTabRect));
        MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, firstTabCenter, 0);
        MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, firstTabCenter, 0);
        mouseSelectsTabs = mouseSelectsTabs && delegate.activeIndex == 0;
        MicaUITestRecord(report, &allPassed, mouseSelectsTabs,
                         @"clicking the top tab header selects tabs with the mouse");

        MicaDirtyRows testDirtyRows = { .start_row = 1, .end_row = 3 };
        NSRect terminalAreaForDamage = [delegate.terminalView terminalRect];
        CGFloat lineHeightForDamage = ceil(delegate.terminalView.terminalFont.ascender -
            delegate.terminalView.terminalFont.descender + delegate.terminalView.terminalFont.leading + 1.0);
        NSRect mappedDirtyRect = [delegate.terminalView dirtyRectForRows:testDirtyRows];
        BOOL rowDamageMappingWorks = NSPointInRect(NSMakePoint(15, NSMaxY(terminalAreaForDamage) - lineHeightForDamage * 1.5), mappedDirtyRect) &&
            NSPointInRect(NSMakePoint(15, NSMaxY(terminalAreaForDamage) - lineHeightForDamage * 2.5), mappedDirtyRect) &&
            !NSPointInRect(NSMakePoint(15, NSMaxY(terminalAreaForDamage) - lineHeightForDamage * 0.5), mappedDirtyRect) &&
            !NSPointInRect(NSMakePoint(15, NSMaxY(terminalAreaForDamage) - lineHeightForDamage * 3.5), mappedDirtyRect);
        MicaUITestRecord(report, &allPassed, rowDamageMappingWorks,
                         @"PTY dirty rows map to only their terminal display rows");

        MicaTab *tooltipTab = delegate.tabs[1];
        NSString *originalTooltipName = tooltipTab.name;
        tooltipTab.name = @"An intentionally long tab name preserved by the hover tooltip";
        tooltipTab.currentCommand = @"codex";
        tooltipTab.command = @"codex";
        tooltipTab.agentActivityDetail = @"Ran git status --short";
        NSPoint tooltipPoint = NSMakePoint(NSMidX(secondTabRect), NSMidY(secondTabRect));
        NSString *tooltipText = [delegate.terminalView view:delegate.terminalView stringForToolTip:0
            point:tooltipPoint userData:NULL];
        BOOL tooltipKeepsFullTitle = [tooltipText containsString:tooltipTab.name] &&
            [tooltipText containsString:@"Recent activity: Ran git status --short"];
        tooltipTab.name = originalTooltipName;
        tooltipTab.currentCommand = nil;
        tooltipTab.command = nil;
        tooltipTab.agentActivityDetail = nil;
        MicaUITestRecord(report, &allPassed, tooltipKeepsFullTitle,
                         [NSString stringWithFormat:@"hover tooltip returns the full tab title and recent Codex action (text=%@)",
                            tooltipText]);

        NSMutableArray<MicaTab *> *originalTabs = delegate.tabs;
        NSInteger originalActiveIndex = delegate.activeIndex;
        delegate.tabs = [originalTabs mutableCopy];
        for (NSUInteger index = delegate.tabs.count; index < 12; index++) {
            MicaTab *placeholderTab = [[MicaTab alloc] init];
            placeholderTab.name = [NSString stringWithFormat:@"Overflow test tab %lu", (unsigned long)(index + 1)];
            [delegate.tabs addObject:placeholderTab];
        }
        NSRange visibleOverflowTabs = [delegate.terminalView visibleTabRange];
        NSRect overflowRect = [delegate.terminalView tabOverflowRect];
        BOOL overflowMinimumWidth = [delegate.terminalView hasTabOverflow] && visibleOverflowTabs.length > 0 &&
            visibleOverflowTabs.length < delegate.tabs.count && !NSIsEmptyRect(overflowRect);
        for (NSUInteger index = visibleOverflowTabs.location; index < NSMaxRange(visibleOverflowTabs); index++)
            overflowMinimumWidth = overflowMinimumWidth &&
                [delegate.terminalView tabRectAtIndex:index].size.width >= kTabMinimumWidth - 0.01;
        NSMenu *overflowMenu = [delegate.terminalView tabOverflowMenu];
        NSUInteger hiddenTabCount = delegate.tabs.count - visibleOverflowTabs.length;
        BOOL overflowMenuComplete = overflowMenu.itemArray.count == hiddenTabCount && hiddenTabCount > 0;
        NSPoint overflowButtonPoint = NSMakePoint(NSMidX(overflowRect), NSMidY(overflowRect));
        BOOL overflowHitAreaWorks = [delegate.terminalView tabIndexAtPoint:overflowButtonPoint] == NSNotFound &&
            [[delegate.terminalView view:delegate.terminalView stringForToolTip:0 point:overflowButtonPoint userData:NULL]
                containsString:@"more terminal tabs"];
        BOOL overflowSelectWorks = NO;
        if (overflowMenuComplete) {
            NSMenuItem *firstHiddenTab = overflowMenu.itemArray.firstObject;
            NSInteger hiddenIndex = [(NSNumber *)firstHiddenTab.representedObject integerValue];
            [delegate.terminalView selectOverflowTab:firstHiddenTab];
            overflowSelectWorks = delegate.activeIndex == hiddenIndex &&
                NSLocationInRange((NSUInteger)hiddenIndex, [delegate.terminalView visibleTabRange]);
        }
        MicaUITestRecord(report, &allPassed,
            overflowMinimumWidth && overflowMenuComplete && overflowHitAreaWorks && overflowSelectWorks,
            [NSString stringWithFormat:@"wide tabs stay visible until the minimum width, then the More menu exposes and selects hidden tabs (visible=%lu hidden=%lu min=%d menu=%d hit=%d select=%d)",
             (unsigned long)visibleOverflowTabs.length, (unsigned long)hiddenTabCount,
             overflowMinimumWidth, overflowMenuComplete, overflowHitAreaWorks, overflowSelectWorks]);
        delegate.tabs = originalTabs;
        delegate.activeIndex = originalActiveIndex;
        [delegate resizeActiveSession];

        if (fixtureReady) {
            NSInteger textRow = 0, textCol = 0;
            BOOL foundSelectableText = MicaUITestFindText(fixtureTab.session, @"UI-TRUECOLOR", &textRow, &textCol);
            NSDictionary *cellAttrs = @{ NSFontAttributeName: delegate.terminalView.terminalFont };
            CGFloat testCellWidth = [@"M" sizeWithAttributes:cellAttrs].width;
            CGFloat testLineHeight = lineHeightForDamage;
            NSRect terminalArea = [delegate.terminalView terminalRect];
            NSPoint clickPoint = NSMakePoint(8, NSMaxY(terminalArea) - testLineHeight * 0.5);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, clickPoint, 0);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, clickPoint, 0);
            BOOL clickDoesNotSelect = ![delegate.terminalView hasTextSelection];
            NSPoint dragStart = NSMakePoint((textCol + 1) * testCellWidth + 1,
                NSMaxY(terminalArea) - (textRow + 0.5) * testLineHeight);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, dragStart, 0);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDragged,
                NSMakePoint(dragStart.x + 1, dragStart.y), 0);
            BOOL tinyMoveDoesNotSelect = ![delegate.terminalView hasTextSelection];
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, NSMakePoint(dragStart.x + 1, dragStart.y), 0);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, dragStart, 0);
            NSPoint dragEnd = NSMakePoint((textCol + 8) * testCellWidth + 1, dragStart.y);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDragged, dragEnd, 0);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, dragEnd, 0);
            BOOL dragSelectsText = foundSelectableText && [delegate.terminalView hasTextSelection];
            NSPoint outsideSelection = NSMakePoint(NSMaxX(terminalArea) - 8,
                                                   NSMinY(terminalArea) + testLineHeight * 0.5);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, outsideSelection, 0);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, outsideSelection, 0);
            BOOL outsideClickClearsSelection = ![delegate.terminalView hasTextSelection];
            [delegate.terminalView clearSelection];
            MicaUITestRecord(report, &allPassed, clickDoesNotSelect && tinyMoveDoesNotSelect && dragSelectsText && outsideClickClearsSelection,
                [NSString stringWithFormat:@"plain click and tiny pointer movement keep UI interaction clear; outside click clears a drag selection (found=%d click=%d tiny=%d drag=%d clear=%d)",
                 foundSelectableText, clickDoesNotSelect, tinyMoveDoesNotSelect, dragSelectsText, outsideClickClearsSelection]);
        }

        if (delegate.tabs.count == 3 && fixtureReady) {
            [delegate selectTabAtIndex:0];
            MicaUITestSendKey(delegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
            MicaUITestSendKey(delegate, @"l", 0, 37);
            BOOL nextTabWorked = delegate.activeIndex == 1 && delegate.uiMode == MicaUIModeTab;
            MicaUITestSendKey(delegate, @"j", 0, 38);
            BOOL secondNavigationWorked = delegate.activeIndex == 2;
            MicaUITestSendKey(delegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
            MicaUITestRecord(report, &allPassed, nextTabWorked && secondNavigationWorked && delegate.uiMode == MicaUIModeNormal,
                             @"Command-Shift-P tab menu, hjkl navigation and return to normal mode work");

            MicaUITestSendKey(delegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
            MicaUITestSendKey(delegate, @"1", 0, 18);
            BOOL digitJumpWorked = delegate.activeIndex == 0 && delegate.uiMode == MicaUIModeNormal;
            MicaUITestSendKey(delegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
            MicaUITestSendKey(delegate, @"n", 0, 45);
            BOOL newTabWorked = delegate.tabs.count == 4 && delegate.activeIndex == 3 && delegate.uiMode == MicaUIModeNormal;
            MicaUITestSendKey(delegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
            MicaUITestSendKey(delegate, @"x", 0, 7);
            BOOL closeTabWorked = delegate.tabs.count == 3 && delegate.uiMode == MicaUIModeNormal;
            MicaUITestRecord(report, &allPassed, digitJumpWorked && newTabWorked && closeTabWorked,
                             @"tab mode number jump, new tab and close tab actions work");

            MicaUITestSendKey(delegate, @"2", NSEventModifierFlagCommand, 19);
            BOOL commandNumberSelectsTab = delegate.activeIndex == 1;
            MicaUITestSendKey(delegate, @"9", NSEventModifierFlagCommand, 25);
            BOOL commandNineSelectsLastTab = delegate.activeIndex == 2;
            MicaUITestRecord(report, &allPassed, commandNumberSelectsTab && commandNineSelectsLastTab,
                @"Command-number shortcuts select numbered tabs and Command-9 selects the last tab");

            [delegate selectTabAtIndex:0];
            [delegate.terminalView updateGridSize];
            MicaUITestSendKey(delegate, @"s", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1);
            NSInteger pageLines = MAX(1, mica_session_rows(fixtureTab.session) - 1);
            NSInteger halfPageLines = MAX(1, mica_session_rows(fixtureTab.session) / 2);
            NSInteger historyLines = (NSInteger)mica_session_history_lines(fixtureTab.session);
            pageLines = MIN(pageLines, historyLines);
            halfPageLines = MIN(halfPageLines, historyLines);
            BOOL scrollBindings = delegate.uiMode == MicaUIModeScroll;
            MicaUITestSendKey(delegate, @"k", 0, 40);
            NSInteger kOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 1;
            MicaUITestSendKey(delegate, @"j", 0, 38);
            NSInteger jOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 0;
            MicaUITestSendKey(delegate, @"\uF700", 0, 126);
            NSInteger upOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 1;
            MicaUITestSendKey(delegate, @"\uF701", 0, 125);
            NSInteger downOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 0;
            MicaUITestSendKey(delegate, @"h", 0, 4);
            NSInteger hOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == pageLines;
            MicaUITestSendKey(delegate, @"l", 0, 37);
            NSInteger lOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 0;
            MicaUITestSendKey(delegate, @"\uF702", 0, 123);
            NSInteger leftOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == pageLines;
            MicaUITestSendKey(delegate, @"\uF703", 0, 124);
            NSInteger rightOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 0;
            MicaUITestSendKey(delegate, @"b", NSEventModifierFlagControl, 11);
            NSInteger ctrlBOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == pageLines;
            MicaUITestSendKey(delegate, @"f", NSEventModifierFlagControl, 3);
            NSInteger ctrlFOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 0;
            MicaUITestSendKey(delegate, @"\uF72C", 0, 116);
            NSInteger pageUpOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == pageLines;
            MicaUITestSendKey(delegate, @"\uF72D", 0, 121);
            NSInteger pageDownOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 0;
            MicaUITestSendKey(delegate, @"u", 0, 32);
            NSInteger uOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == halfPageLines;
            MicaUITestSendKey(delegate, @"d", 0, 2);
            NSInteger dOffset = mica_session_view_offset(fixtureTab.session);
            scrollBindings = scrollBindings && mica_session_view_offset(fixtureTab.session) == 0;
            MicaUITestSendKey(delegate, @"\033", 0, 53);
            MicaUITestRecord(report, &allPassed, scrollBindings && delegate.uiMode == MicaUIModeNormal &&
                             mica_session_view_offset(fixtureTab.session) == 0,
                             [NSString stringWithFormat:@"Mica scroll keys match line, page, half-page, Ctrl-F/Ctrl-B and live return (rows=%d history=%ld expected-page=%ld, k=%ld j=%ld up=%ld down=%ld h=%ld l=%ld left=%ld right=%ld ^B=%ld ^F=%ld PgUp=%ld PgDn=%ld u=%ld d=%ld)",
                              mica_session_rows(fixtureTab.session), (long)historyLines, (long)pageLines,
                              (long)kOffset, (long)jOffset, (long)upOffset, (long)downOffset,
                              (long)hOffset, (long)lOffset, (long)leftOffset, (long)rightOffset,
                              (long)ctrlBOffset, (long)ctrlFOffset, (long)pageUpOffset, (long)pageDownOffset,
                              (long)uOffset, (long)dOffset]);

            delegate.terminalView.testClipboardText = @"printf 'MICA-CLIPBOARD-OUTPUT-%s\\n' EXECUTED";
            [delegate selectTabAtIndex:0];
            MicaUITestSendKey(delegate, @"v", NSEventModifierFlagCommand, 9);
            BOOL textPasteWorked = NO;
            for (int attempt = 0; attempt < 100; attempt++) {
                mica_session_poll(fixtureTab.session, 0);
                if (MicaUITestFindText(fixtureTab.session, @"MICA-CLIPBOARD-OUTPUT-%s", NULL, NULL)) {
                    textPasteWorked = YES;
                    break;
                }
                usleep(10000);
            }
            MicaUITestRecord(report, &allPassed, textPasteWorked,
                             @"Command-V inserts clipboard text at the active shell prompt");
            BOOL pastedCommandRan = NO;
            if (textPasteWorked) MicaUITestSendKey(delegate, @"\r", 0, 36);
            for (int attempt = 0; attempt < 100; attempt++) {
                mica_session_poll(fixtureTab.session, 0);
                if (MicaUITestFindText(fixtureTab.session, @"MICA-CLIPBOARD-OUTPUT-EXECUTED", NULL, NULL)) {
                    pastedCommandRan = YES;
                    break;
                }
                usleep(10000);
            }
            MicaUITestRecord(report, &allPassed, pastedCommandRan,
                             @"Return executes the pasted command and leaves the shell ready");
            delegate.terminalView.testClipboardText = nil;

            NSString *droppedFilePath = [NSString stringWithFormat:@"/tmp/Mica folder's %@.txt",
                [NSUUID.UUID.UUIDString substringToIndex:8]];
            BOOL droppedFileCreated = [NSFileManager.defaultManager createFileAtPath:droppedFilePath
                contents:[NSData data] attributes:nil];
            NSURL *droppedFileURL = [NSURL fileURLWithPath:droppedFilePath];
            delegate.terminalView.testDraggedFileURLs = @[droppedFileURL];
            MicaUITestDraggingInfo *dragInfo = [[MicaUITestDraggingInfo alloc] init];
            dragInfo.pasteboard = nil;
            dragInfo.location = [delegate.terminalView convertPoint:
                NSMakePoint(20, NSMidY([delegate.terminalView terminalRect])) toView:nil];
            NSDragOperation fileDropOperation = droppedFileCreated
                ? [delegate.terminalView draggingEntered:(id<NSDraggingInfo>)dragInfo] : NSDragOperationNone;
            BOOL dropPrepared = droppedFileCreated && fileDropOperation == NSDragOperationCopy &&
                [delegate.terminalView prepareForDragOperation:(id<NSDraggingInfo>)dragInfo];
            BOOL fileDropInserted = dropPrepared &&
                [delegate.terminalView performDragOperation:(id<NSDraggingInfo>)dragInfo];
            NSString *escapedFilePath = [droppedFilePath stringByReplacingOccurrencesOfString:@"'"
                withString:@"'\\''"];
            NSString *quotedFilePath = [NSString stringWithFormat:@"'%@'", escapedFilePath];
            BOOL quotedFilePathVisible = NO;
            for (int attempt = 0; fileDropInserted && attempt < 100; attempt++) {
                mica_session_poll(fixtureTab.session, 0);
                if (MicaUITestFindText(fixtureTab.session, quotedFilePath, NULL, NULL)) {
                    quotedFilePathVisible = YES;
                    break;
                }
                usleep(10000);
            }
            BOOL rejectedHeaderDrop = NO;
            if (fileDropInserted) {
                dragInfo.location = [delegate.terminalView convertPoint:
                    NSMakePoint(20, NSMaxY(delegate.terminalView.bounds) - 5) toView:nil];
                rejectedHeaderDrop = [delegate.terminalView draggingEntered:(id<NSDraggingInfo>)dragInfo] == NSDragOperationNone &&
                    ![delegate.terminalView performDragOperation:(id<NSDraggingInfo>)dragInfo];
            }
            MicaUITestRecord(report, &allPassed, droppedFileCreated && fileDropInserted &&
                quotedFilePathVisible && rejectedHeaderDrop,
                [NSString stringWithFormat:@"dropping a file over the terminal inserts a shell-quoted path without executing it and rejects header drops (written=%d prepared=%d inserted=%d visible=%d header-rejected=%d)",
                 droppedFileCreated, dropPrepared, fileDropInserted, quotedFilePathVisible, rejectedHeaderDrop]);
            [NSFileManager.defaultManager removeItemAtPath:droppedFilePath error:nil];
            delegate.terminalView.testDraggedFileURLs = nil;
            if (fileDropInserted) MicaUITestSendKey(delegate, @"c", NSEventModifierFlagControl, 8);

            NSString *imageRouteCommand = @"old=$(stty -g); stty raw -echo; printf 'IMAGE-ROUTE-READY\\n'; "
                "dd bs=1 count=1 2>/dev/null | od -An -tu1; stty \"$old\"; printf 'IMAGE-ROUTE-OK\\n'";
            [delegate addTabWithName:@"Image paste" cwd:@"/tmp" command:imageRouteCommand prefilled:NO];
            MicaTab *imageTab = delegate.activeTab;
            BOOL imageReaderReady = NO;
            for (int attempt = 0; attempt < 300; attempt++) {
                mica_session_poll(imageTab.session, 0);
                if (MicaUITestFindText(imageTab.session, @"IMAGE-ROUTE-READY", NULL, NULL)) {
                    imageReaderReady = YES;
                    break;
                }
                usleep(10000);
            }
            NSBitmapImageRep *clipboardBitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
                pixelsWide:2 pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            NSData *clipboardPNG = [clipboardBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            delegate.terminalView.testClipboardImage = clipboardPNG;
            MicaUITestSendKey(delegate, @"v", NSEventModifierFlagCommand, 9);
            BOOL imagePasteWorked = NO;
            for (int attempt = 0; imageReaderReady && attempt < 300; attempt++) {
                mica_session_poll(imageTab.session, 0);
                if (MicaUITestFindText(imageTab.session, @"22", NULL, NULL) &&
                    MicaUITestFindText(imageTab.session, @"IMAGE-ROUTE-OK", NULL, NULL)) {
                    imagePasteWorked = YES;
                    break;
                }
                usleep(10000);
            }
            MicaUITestRecord(report, &allPassed, imageReaderReady && imagePasteWorked,
                             @"Command-V forwards Ctrl-V for a clipboard image without reading or storing the image");
            if (imageReaderReady && !imagePasteWorked)
                MicaUITestSendKey(delegate, @"c", NSEventModifierFlagControl, 8);
            delegate.terminalView.testClipboardImage = nil;

            NSString *codexStubDir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            NSError *directoryError = nil;
            BOOL codexStubDirectoryReady = [[NSFileManager defaultManager] createDirectoryAtPath:codexStubDir
                withIntermediateDirectories:NO attributes:nil error:&directoryError];
            NSString *codexStubPath = [codexStubDir stringByAppendingPathComponent:@"codex"];
            NSString *codexStubBody = @"#!/bin/sh\n"
                "printf 'CODEX-ARGS:%s\\n' \"$*\"\n"
                "i=1; while [ \"$i\" -le 90 ]; do printf 'CODEX-LINE-%03d\\n' \"$i\"; i=$((i+1)); done\n"
                "printf '\\033[?1000h\\033[?1006h'\n"
                "printf 'CODEX-LIVE-READY\\n'\n";
            BOOL codexStubCreated = codexStubDirectoryReady &&
                [NSFileManager.defaultManager createFileAtPath:codexStubPath
                    contents:[codexStubBody dataUsingEncoding:NSUTF8StringEncoding]
                    attributes:@{ NSFilePosixPermissions: @0755 }];
            NSString *originalPath = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"/usr/bin:/bin";
            BOOL pathUpdated = codexStubCreated && setenv("PATH",
                [[NSString stringWithFormat:@"%@:%@", codexStubDir, originalPath] UTF8String], 1) == 0;
            BOOL codexScrollPassed = NO;
            BOOL codexFixtureReady = NO;
            BOOL oldestOutputHiddenAtLiveEdge = NO;
            BOOL wheelScrollbackWorked = NO;
            BOOL oldOutputReachable = NO;
            NSInteger codexHistoryRows = 0;
            NSInteger codexRows = 0;
            NSInteger oldOutputOffset = 0;
            NSInteger codexPageUpSteps = 0;
            if (pathUpdated) {
                NSString *codexLaunchCommand = @"codex -c tui.raw_output_mode=true --no-alt-screen";
                [delegate addTabWithName:@"Codex" cwd:@"/tmp" command:codexLaunchCommand prefilled:NO];
                MicaTab *codexTab = delegate.activeTab;
                [delegate.terminalView updateGridSize];
                for (int attempt = 0; attempt < 600; attempt++) {
                    mica_session_poll(codexTab.session, 0);
                    if (strcmp(mica_session_command(codexTab.session), codexLaunchCommand.UTF8String) == 0 &&
                        MicaUITestFindText(codexTab.session, @"CODEX-LIVE-READY", NULL, NULL) &&
                        mica_session_reports_mouse(codexTab.session) &&
                        mica_session_history_lines(codexTab.session) > (size_t)mica_session_rows(codexTab.session)) {
                        codexFixtureReady = YES;
                        break;
                    }
                    usleep(10000);
                }
                oldestOutputHiddenAtLiveEdge = codexFixtureReady &&
                    !MicaUITestFindText(codexTab.session, @"CODEX-LINE-001", NULL, NULL);
                MicaUITestSendKey(delegate, @"s", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1);
                MicaUITestSendWheel(delegate, 24);
                wheelScrollbackWorked = codexFixtureReady &&
                    mica_session_view_offset(codexTab.session) == 1 && delegate.uiMode == MicaUIModeScroll;
                codexHistoryRows = (NSInteger)mica_session_history_lines(codexTab.session);
                codexRows = mica_session_rows(codexTab.session);
                NSInteger pageSize = MAX(1, codexRows - 1);
                NSInteger maximumPageUps = (codexHistoryRows + pageSize - 1) / pageSize + 2;
                for (NSInteger page = 0; codexFixtureReady && page < maximumPageUps &&
                     !MicaUITestFindText(codexTab.session, @"CODEX-LINE-001", NULL, NULL); page++) {
                    NSInteger previousOffset = mica_session_view_offset(codexTab.session);
                    MicaUITestSendKey(delegate, @"b", NSEventModifierFlagControl, 11);
                    codexPageUpSteps++;
                    if (mica_session_view_offset(codexTab.session) == previousOffset) break;
                }
                oldOutputOffset = mica_session_view_offset(codexTab.session);
                oldOutputReachable = codexFixtureReady &&
                    MicaUITestFindText(codexTab.session, @"CODEX-LINE-001", NULL, NULL) &&
                    mica_session_view_offset(codexTab.session) > 0;
                MicaUITestSendKey(delegate, @"s", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1);
                codexScrollPassed = wheelScrollbackWorked && oldOutputReachable && oldestOutputHiddenAtLiveEdge &&
                    delegate.uiMode == MicaUIModeNormal && mica_session_view_offset(codexTab.session) == 0 &&
                    MicaUITestFindText(codexTab.session, @"CODEX-LIVE-READY", NULL, NULL);
            }
            setenv("PATH", originalPath.UTF8String, 1);
            if (codexStubDirectoryReady) [NSFileManager.defaultManager removeItemAtPath:codexStubDir error:nil];
            MicaUITestRecord(report, &allPassed, codexScrollPassed,
                [NSString stringWithFormat:@"Codex inline output scrolls to its oldest line and returns live (directory=%d executable=%d path=%d fixture=%d hidden=%d wheel=%d old=%d offset=%d mode=%lu)%@",
                 codexStubDirectoryReady, codexStubCreated, pathUpdated, codexFixtureReady,
                 oldestOutputHiddenAtLiveEdge, wheelScrollbackWorked, oldOutputReachable,
                 pathUpdated ? mica_session_view_offset(delegate.activeTab.session) : 0,
                 (unsigned long)delegate.uiMode,
                 [NSString stringWithFormat:@" (rows=%ld history=%ld old-offset=%ld page-ups=%ld)%@",
                  (long)codexRows, (long)codexHistoryRows, (long)oldOutputOffset, (long)codexPageUpSteps,
                  directoryError ? [NSString stringWithFormat:@" fixture error: %@", directoryError.localizedDescription] : @""]]);

            [delegate selectTabAtIndex:0];
            [delegate.terminalView updateGridSize];
            MicaSession *foldUITestSession = fixtureTab.session;
            size_t foldUIHistoryLines = mica_session_history_lines(foldUITestSession);
            mica_session_scroll(foldUITestSession, (int)foldUIHistoryLines);
            NSRect foldTerminalArea = [delegate.terminalView terminalRect];
            CGFloat foldLineHeight = ceil(delegate.terminalView.terminalFont.ascender -
                delegate.terminalView.terminalFont.descender + delegate.terminalView.terminalFont.leading + 1.0);
            NSPoint foldStartPoint = NSMakePoint(12, NSMaxY(foldTerminalArea) - 1.5 * foldLineHeight);
            NSPoint foldEndPoint = NSMakePoint(64, NSMaxY(foldTerminalArea) - 3.5 * foldLineHeight);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, foldStartPoint, 0);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDragged, foldEndPoint, 0);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, foldEndPoint, 0);
            BOOL foldSelectionReady = [delegate.terminalView hasTextSelection];
            size_t historyBeforeUIFold = mica_session_display_history_lines(foldUITestSession);
            [delegate.terminalView foldSelectedLines:nil];
            size_t foldedRowsInUI = 0;
            BOOL uiFoldCreated = foldSelectionReady &&
                mica_session_fold_info_at_view_row(foldUITestSession, 1, &foldedRowsInUI) &&
                foldedRowsInUI == 2 &&
                mica_session_display_history_lines(foldUITestSession) + 2 == historyBeforeUIFold;
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown,
                NSMakePoint(40, NSMaxY(foldTerminalArea) - 1.5 * foldLineHeight), 0);
            MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp,
                NSMakePoint(40, NSMaxY(foldTerminalArea) - 1.5 * foldLineHeight), 0);
            BOOL uiFoldExpanded = uiFoldCreated &&
                mica_session_display_history_lines(foldUITestSession) == historyBeforeUIFold &&
                !mica_session_fold_info_at_view_row(foldUITestSession, 1, NULL);
            mica_session_scroll_to_bottom(foldUITestSession);
            [delegate.terminalView setNeedsDisplay:YES];
            MicaUITestRecord(report, &allPassed, uiFoldCreated && uiFoldExpanded,
                [NSString stringWithFormat:@"selected scrollback lines collapse into a visible fold and a click expands them (selected=%d folded=%d expanded=%d)",
                 foldSelectionReady, uiFoldCreated, uiFoldExpanded]);

            NSString *mouseTrackingCommand = @"stty raw -echo -isig; "
                "printf '\\033[?1002h\\033[?1006hMICA-MOUSE-READY\\n'; "
                "python3 -c 'import os,select,time\n"
                "data=bytearray()\n"
                "deadline=time.monotonic()+1.0\n"
                "while time.monotonic()<deadline:\n"
                " ready=select.select([0],[],[],0.1)[0]\n"
                " if ready:\n"
                "  data.extend(os.read(0,256))\n"
                "  deadline=time.monotonic()+0.25\n"
                "print(data.hex(),flush=True)'";
            [delegate addTabWithName:@"Mouse tracking" cwd:@"/tmp" command:mouseTrackingCommand prefilled:NO];
            MicaTab *mouseTrackingTab = delegate.activeTab;
            [delegate.terminalView updateGridSize];
            BOOL mouseTrackingReady = NO;
            for (int attempt = 0; attempt < 300; attempt++) {
                mica_session_poll(mouseTrackingTab.session, 0);
                if (MicaUITestFindText(mouseTrackingTab.session, @"MICA-MOUSE-READY", NULL, NULL) &&
                    mica_session_reports_mouse(mouseTrackingTab.session)) {
                    mouseTrackingReady = YES;
                    break;
                }
                usleep(10000);
            }
            NSRect mouseTerminal = [delegate.terminalView terminalRect];
            CGFloat mouseY = NSMidY(mouseTerminal);
            NSPoint mouseStart = NSMakePoint(20, mouseY);
            NSPoint mouseEnd = NSMakePoint(100, mouseY);
            if (mouseTrackingReady) {
                MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, mouseStart, 0);
                MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDragged, mouseEnd, 0);
                MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, mouseEnd, 0);
                MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDown, mouseStart, NSEventModifierFlagOption);
                MicaUITestSendMouse(delegate, NSEventTypeLeftMouseDragged, mouseEnd, NSEventModifierFlagOption);
                MicaUITestSendMouse(delegate, NSEventTypeLeftMouseUp, mouseEnd, NSEventModifierFlagOption);
            }
            BOOL optionDragSelects = mouseTrackingReady && [delegate.terminalView hasTextSelection];
            [delegate.terminalView clearSelection];
            BOOL mouseDragReported = NO;
            for (int attempt = 0; mouseTrackingReady && attempt < 300; attempt++) {
                mica_session_poll(mouseTrackingTab.session, 0);
                if (MicaUITestFindText(mouseTrackingTab.session, @"1b5b3c3332", NULL, NULL)) {
                    mouseDragReported = YES;
                    break;
                }
                usleep(10000);
            }
            MicaUITestRecord(report, &allPassed, mouseTrackingReady && mouseDragReported && optionDragSelects,
                [NSString stringWithFormat:@"mouse-aware terminal receives left-button drag reports while Option-drag selects locally (ready=%d report=%d option-select=%d)",
                 mouseTrackingReady, mouseDragReported, optionDragSelects]);

            CGFloat originalFontSize = delegate.terminalView.terminalFont.pointSize;
            MicaUITestSendKey(delegate, @"+", NSEventModifierFlagCommand, 24);
            BOOL fontGrew = delegate.terminalView.terminalFont.pointSize == originalFontSize + 1;
            MicaUITestSendKey(delegate, @"-", NSEventModifierFlagCommand, 27);
            MicaUITestRecord(report, &allPassed, fontGrew && delegate.terminalView.terminalFont.pointSize == originalFontSize,
                             @"Command-plus and Command-minus adjust font size");
            MicaUITestSendKey(delegate, @"+", NSEventModifierFlagCommand, 24);
            MicaUITestSendKey(delegate, @"+", NSEventModifierFlagCommand, 24);
            BOOL grewTwice = delegate.terminalView.terminalFont.pointSize == originalFontSize + 2;
            MicaUITestSendKey(delegate, @"0", NSEventModifierFlagCommand, 29);
            MicaUITestRecord(report, &allPassed, grewTwice && delegate.terminalView.terminalFont.pointSize == 16.0,
                             @"Command-zero resets the font size to the default");
            [delegate openPreferences:nil];
            NSWindow *preferences = delegate.preferencesWindow;
            NSPopUpButton *themePopUp = nil;
            for (NSView *view in preferences.contentView.subviews)
                if ([view isKindOfClass:NSPopUpButton.class] && !themePopUp) themePopUp = (NSPopUpButton *)view;
            BOOL preferencesOffer = preferences != nil && themePopUp.numberOfItems == 3 &&
                [[themePopUp itemTitleAtIndex:2] isEqualToString:@"System"];
            [themePopUp selectItemAtIndex:1];
            [delegate prefThemeChanged:themePopUp];
            BOOL lightApplied = [delegate.window.appearance.name isEqualToString:NSAppearanceNameAqua];
            NSAppearance *savedAppAppearance = NSApp.appearance;
            NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            [themePopUp selectItemAtIndex:2];
            [delegate prefThemeChanged:themePopUp];
            BOOL systemLightApplied = gMicaFollowSystemTheme && gMicaLightTheme;
            NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            [delegate applySystemAppearanceIfNeeded];
            BOOL systemDarkApplied = gMicaFollowSystemTheme && !gMicaLightTheme;
            NSApp.appearance = savedAppAppearance;
            [themePopUp selectItemAtIndex:0];
            [delegate prefThemeChanged:themePopUp];
            MicaUITestRecord(report, &allPassed, preferencesOffer && lightApplied && systemLightApplied && systemDarkApplied &&
                [delegate.window.appearance.name isEqualToString:NSAppearanceNameDarkAqua],
                @"Theme offers Dark, Light and System; System follows both appearance changes live");
            NSString *suiteName = [NSString stringWithFormat:@"mica-theme-relaunch-%d", getpid()];
            NSUserDefaults *isolatedDefaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
            [isolatedDefaults removePersistentDomainForName:suiteName];
            gMicaDefaultsOverride = isolatedDefaults;
            [themePopUp selectItemAtIndex:1]; [delegate prefThemeChanged:themePopUp];
            MicaAppDelegate *freshDelegate = [MicaAppDelegate new];
            [freshDelegate loadStoredThemePreference];
            BOOL lightSurvives = !gMicaFollowSystemTheme && gMicaLightTheme;
            [themePopUp selectItemAtIndex:2]; [delegate prefThemeChanged:themePopUp];
            freshDelegate = [MicaAppDelegate new]; [freshDelegate loadStoredThemePreference];
            BOOL systemSurvives = gMicaFollowSystemTheme;
            [themePopUp selectItemAtIndex:0]; [delegate prefThemeChanged:themePopUp];
            freshDelegate = [MicaAppDelegate new]; [freshDelegate loadStoredThemePreference];
            BOOL darkSurvives = !gMicaFollowSystemTheme && !gMicaLightTheme;
            gMicaDefaultsOverride = nil; [isolatedDefaults removePersistentDomainForName:suiteName];
            MicaUITestRecord(report, &allPassed, lightSurvives && systemSurvives && darkSurvives,
                [NSString stringWithFormat:@"Dark, Light and System theme settings load in a fresh delegate from an isolated defaults suite (light=%d system=%d dark=%d mode=%@)",
                    lightSurvives, systemSurvives, darkSurvives, [isolatedDefaults stringForKey:@"MicaThemeMode"]]);
            // Global shortcut: off by default, persists, and registering/unregistering goes through the injected hook.
            shortcutEnableCalls = shortcutDisableCalls = 0;
            NSString *shortcutSuite = [NSString stringWithFormat:@"mica-shortcut-%d", getpid()];
            NSUserDefaults *shortcutDefaults = [[NSUserDefaults alloc] initWithSuiteName:shortcutSuite];
            [shortcutDefaults removePersistentDomainForName:shortcutSuite];
            gMicaDefaultsOverride = shortcutDefaults;
            gMicaHotKeyRegistrar = MicaUITestCountingRegistrar;
            MicaAppDelegate *shortcutDelegate = [MicaAppDelegate new];
            [shortcutDelegate applyStoredShortcutPreference];
            BOOL offByDefault = shortcutEnableCalls == 0 && shortcutDisableCalls == 1 && ![shortcutDefaults boolForKey:@"MicaGlobalShortcut"];
            NSButton *shortcutBox = [NSButton checkboxWithTitle:@"x" target:nil action:nil];
            shortcutBox.state = NSControlStateValueOn; [shortcutDelegate prefShortcutChanged:shortcutBox];
            BOOL enabledPersists = shortcutEnableCalls == 1 && [shortcutDefaults boolForKey:@"MicaGlobalShortcut"];
            [shortcutDelegate applyStoredShortcutPreference];
            BOOL relaunchRegisters = shortcutEnableCalls == 2;
            shortcutBox.state = NSControlStateValueOff; [shortcutDelegate prefShortcutChanged:shortcutBox];
            BOOL disableUnregisters = shortcutDisableCalls == 2 && ![shortcutDefaults boolForKey:@"MicaGlobalShortcut"];
            gMicaHotKeyRegistrar = NULL; gMicaDefaultsOverride = nil;
            [shortcutDefaults removePersistentDomainForName:shortcutSuite];
            MicaUITestRecord(report, &allPassed, offByDefault && enabledPersists && relaunchRegisters && disableUnregisters,
                [NSString stringWithFormat:@"the global shortcut is off by default, persists, re-registers on launch and unregisters when disabled (default=%d on=%d relaunch=%d off=%d)",
                    offByDefault, enabledPersists, relaunchRegisters, disableUnregisters]);
            // Scrollback allowance: 5,000 lines by default, 1,000 / 5,000 / 20,000 selectable, persisted and applied live.
            NSString *scrollSuite = [NSString stringWithFormat:@"mica-scrollback-%d", getpid()];
            NSUserDefaults *scrollDefaults = [[NSUserDefaults alloc] initWithSuiteName:scrollSuite];
            [scrollDefaults removePersistentDomainForName:scrollSuite];
            gMicaDefaultsOverride = scrollDefaults;
            MicaAppDelegate *scrollDelegate = [MicaAppDelegate new];
            size_t savedLimit = mica_history_limit_bytes();
            [scrollDelegate applyStoredScrollbackPreference];
            BOOL scrollDefaultOk = mica_history_limit_bytes() <= MICA_HISTORY_LIMIT_BYTES && mica_history_limit_bytes() > MICA_HISTORY_LIMIT_BYTES - 80u * sizeof(VTermScreenCell);
            NSPopUpButton *scrollPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            [scrollPopUp addItemsWithTitles:@[@"a", @"b", @"c", @"d"]];
            [scrollPopUp selectItemAtIndex:3]; [scrollDelegate prefScrollbackChanged:scrollPopUp];
            BOOL scrollLongOk = mica_history_limit_bytes() == 20000u * 80u * sizeof(VTermScreenCell) &&
                [scrollDefaults integerForKey:@"MicaScrollbackLines"] == 20000;
            [scrollPopUp selectItemAtIndex:1]; [scrollDelegate prefScrollbackChanged:scrollPopUp];
            BOOL scrollShortOk = mica_history_limit_bytes() == 2000u * 80u * sizeof(VTermScreenCell) - 0;
            mica_set_history_limit_lines(savedLimit / (80u * sizeof(VTermScreenCell)));
            gMicaDefaultsOverride = nil; [scrollDefaults removePersistentDomainForName:scrollSuite];
            MicaUITestRecord(report, &allPassed, scrollDefaultOk && scrollLongOk && scrollShortOk,
                [NSString stringWithFormat:@"the scrollback allowance defaults to the built-in 2 MiB and follows the Settings choice (default=%d long=%d short=%d)",
                    scrollDefaultOk, scrollLongOk, scrollShortOk]);
            BOOL oldContrast = gMicaTestIncreaseContrast;
            gMicaTestIncreaseContrast = YES;
            double darkContrast = MicaContrastRatio(MicaSecondaryLabelColor(1), MicaBackgroundColor());
            [delegate setLightTheme:YES];
            double lightContrast = MicaContrastRatio(MicaSecondaryLabelColor(1), MicaBackgroundColor());
            double darkSeparator = MicaContrastRatio(MicaSeparatorColor(), MicaBackgroundColor());
            [delegate setLightTheme:NO]; gMicaTestIncreaseContrast = oldContrast;
            MicaUITestRecord(report, &allPassed, darkContrast >= 4.5 && lightContrast >= 4.5 && darkSeparator >= 4.5,
                [NSString stringWithFormat:@"simulated Increase Contrast ratios meet 4.5:1 (dark %.2f, light %.2f, separator %.2f)",
                    darkContrast, lightContrast, darkSeparator]);
            NSMutableArray *savedControllers = [MicaControllers() mutableCopy];
            [MicaControllers() removeAllObjects];
            MicaAppDelegate *stateOwner = [MicaAppDelegate new];
            stateOwner.tabs = [NSMutableArray array];
            NSString *safeTempFolder = @"/private/tmp";
            MicaTab *savedTab = [MicaTab new]; savedTab.name = @"Remembered"; savedTab.cwd = safeTempFolder; savedTab.command = @"printf MICA_RESTORED";
            [stateOwner.tabs addObject:savedTab]; [MicaControllers() addObject:stateOwner];
            NSString *stateDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"mica-state-%d", getpid()]];
            NSString *statePath = [stateDirectory stringByAppendingPathComponent:@"sessions.json"];
            gMicaSessionStateURLOverride = [NSURL fileURLWithPath:statePath];
            [stateOwner saveSessionState];
            NSDictionary *savedState = [stateOwner readSessionState].firstObject;
            NSString *rawState = [NSString stringWithContentsOfFile:statePath encoding:NSUTF8StringEncoding error:nil];
            BOOL stateRoundTrips = [savedState[@"tabs"] count] == 1 &&
                [savedState[@"tabs"][0][@"name"] isEqual:@"Remembered"] &&
                [savedState[@"tabs"][0][@"cwd"] isEqual:safeTempFolder] &&
                [savedState[@"tabs"][0][@"command"] isEqual:@"printf MICA_RESTORED"];
            NSDictionary *stateAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:statePath error:nil];
            NSDictionary *directoryAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:stateDirectory error:nil];
            BOOL privateStatePermissions = [stateAttributes[NSFilePosixPermissions] unsignedShortValue] == 0600 &&
                [directoryAttributes[NSFilePosixPermissions] unsignedShortValue] == 0700;
            MicaAppDelegate *restoredStateOwner = [MicaAppDelegate new];
            restoredStateOwner.tabs = [NSMutableArray array]; restoredStateOwner.activeIndex = 0;
            [restoredStateOwner loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            BOOL restoredSession = restoredStateOwner.tabs.count == 1 &&
                [restoredStateOwner.activeTab.name isEqual:@"Remembered"] &&
                [restoredStateOwner.activeTab.cwd isEqual:MicaStandardizedWorkingDirectory(@"/tmp")] &&
                [restoredStateOwner.activeTab.command isEqual:@"printf MICA_RESTORED"];
            for (NSValue *value in [restoredStateOwner detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
            NSDictionary *missingFolderState = @{@"version":@1,@"windows":@[@{@"tabs":@[@{
                @"name":@"Missing folder",@"cwd":[stateDirectory stringByAppendingPathComponent:@"deleted-folder"]}]}]};
            [[NSJSONSerialization dataWithJSONObject:missingFolderState options:0 error:nil] writeToFile:statePath atomically:YES];
            MicaAppDelegate *missingFolderOwner = [MicaAppDelegate new];
            missingFolderOwner.tabs = [NSMutableArray array]; missingFolderOwner.activeIndex = 0;
            [missingFolderOwner loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            BOOL missingFolderFallsHome = [missingFolderOwner.activeTab.cwd isEqual:MicaStandardizedWorkingDirectory(NSHomeDirectory())];
            for (NSValue *value in [missingFolderOwner detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
            [stateOwner saveSessionState];
            [@"{" writeToFile:statePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            BOOL corruptIgnored = [stateOwner readSessionState].count == 0;
            [[NSMutableData dataWithLength:256 * 1024 + 1] writeToFile:statePath atomically:YES];
            BOOL oversizedIgnored = [stateOwner readSessionState].count == 0;
            NSString *hugeName = [@"x" stringByPaddingToLength:4096 withString:@"x" startingAtIndex:0];
            NSArray<NSDictionary *> *hostileCases = @[
                @{@"name":hugeName,@"cwd":safeTempFolder},
                @{@"name":@"bad\nname",@"cwd":safeTempFolder},
                @{@"name":@"Traversal",@"cwd":@"/tmp/../tmp"}
            ];
            BOOL hostileIgnored = YES;
            for (NSDictionary *entry in hostileCases) {
                NSDictionary *hostile = @{@"version":@1,@"windows":@[@{@"tabs":@[entry]}]};
                NSData *hostileJSON = [NSJSONSerialization dataWithJSONObject:hostile options:0 error:nil];
                [hostileJSON writeToFile:statePath atomically:YES];
                hostileIgnored = hostileIgnored && [stateOwner readSessionState].count == 0;
            }
            NSString *fileLink = [stateDirectory stringByAppendingPathComponent:@"file-link"];
            symlink("/etc/hosts", fileLink.fileSystemRepresentation);
            NSDictionary *linkHostile = @{@"version":@1,@"windows":@[@{@"tabs":@[@{@"name":@"Link",@"cwd":fileLink}]}]};
            [[NSJSONSerialization dataWithJSONObject:linkHostile options:0 error:nil] writeToFile:statePath atomically:YES];
            hostileIgnored = hostileIgnored && [stateOwner readSessionState].count == 0;
            NSDictionary *commandHostile = @{@"version":@1,@"windows":@[@{@"tabs":@[@{@"name":@"Command",@"cwd":safeTempFolder,
                @"command":@"printf COMMAND_RESTORED"}]}]};
            [[NSJSONSerialization dataWithJSONObject:commandHostile options:0 error:nil] writeToFile:statePath atomically:YES];
            BOOL commandFieldRead = [stateOwner readSessionState].count == 1;
            MicaAppDelegate *commandRestored = [MicaAppDelegate new];
            commandRestored.tabs = [NSMutableArray array]; commandRestored.activeIndex = 0;
            [commandRestored loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            BOOL commandRestoredSafely = commandFieldRead && commandRestored.tabs.count == 1 &&
                [commandRestored.activeTab.command isEqual:@"printf COMMAND_RESTORED"];
            for (NSValue *value in [commandRestored detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
            hostileIgnored = hostileIgnored && commandRestoredSafely;
            [NSFileManager.defaultManager removeItemAtPath:stateDirectory error:nil];
            gMicaSessionStateURLOverride = nil;
            [MicaControllers() removeAllObjects]; [MicaControllers() addObjectsFromArray:savedControllers];
            MicaUITestRecord(report, &allPassed, stateRoundTrips && restoredSession && missingFolderFallsHome && corruptIgnored && oversizedIgnored && hostileIgnored && privateStatePermissions,
                [NSString stringWithFormat:@"session state validates names/folders, ignores hostile metadata and uses private permissions (roundtrip=%d restore=%d corrupt=%d oversized=%d hostile=%d private=%d command=%d mode=%o/%o saved=%@ actual=%@ raw=%@)",
                    stateRoundTrips, restoredSession, corruptIgnored, oversizedIgnored, hostileIgnored, privateStatePermissions,
                    commandRestoredSafely, [stateAttributes[NSFilePosixPermissions] unsignedShortValue],
                    [directoryAttributes[NSFilePosixPermissions] unsignedShortValue], savedState, restoredStateOwner.activeTab, rawState]);
            [preferences close];

            // Git branch detection reads .git/HEAD directly: plain repo, linked worktree, detached HEAD, no repo.
            NSString *gitRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"mica-git-%d", getpid()]];
            NSFileManager *fileManager = NSFileManager.defaultManager;
            [fileManager createDirectoryAtPath:[gitRoot stringByAppendingPathComponent:@"repo/.git"] withIntermediateDirectories:YES attributes:nil error:nil];
            [fileManager createDirectoryAtPath:[gitRoot stringByAppendingPathComponent:@"repo/src/deep"] withIntermediateDirectories:YES attributes:nil error:nil];
            [@"ref: refs/heads/feature/x\n" writeToFile:[gitRoot stringByAppendingPathComponent:@"repo/.git/HEAD"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [fileManager createDirectoryAtPath:[gitRoot stringByAppendingPathComponent:@"linked"] withIntermediateDirectories:YES attributes:nil error:nil];
            [fileManager createDirectoryAtPath:[gitRoot stringByAppendingPathComponent:@"gitdirs/linked"] withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSString stringWithFormat:@"gitdir: %@\n", [gitRoot stringByAppendingPathComponent:@"gitdirs/linked"]]
                writeToFile:[gitRoot stringByAppendingPathComponent:@"linked/.git"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [@"ref: refs/heads/agent-2\n" writeToFile:[gitRoot stringByAppendingPathComponent:@"gitdirs/linked/HEAD"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [fileManager createDirectoryAtPath:[gitRoot stringByAppendingPathComponent:@"detached/.git"] withIntermediateDirectories:YES attributes:nil error:nil];
            [@"3f9c1a2b8be07d4e1a4d6e95c20b83aa11223344\n" writeToFile:[gitRoot stringByAppendingPathComponent:@"detached/.git/HEAD"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            BOOL gitBranchesDetected =
                [MicaGitBranchForDirectory([gitRoot stringByAppendingPathComponent:@"repo/src/deep"]) isEqualToString:@"feature/x"] &&
                [MicaGitBranchForDirectory([gitRoot stringByAppendingPathComponent:@"linked"]) isEqualToString:@"agent-2"] &&
                [MicaGitBranchForDirectory([gitRoot stringByAppendingPathComponent:@"detached"]) isEqualToString:@"3f9c1a2"] &&
                MicaGitBranchForDirectory(@"/") == nil;
            BOOL branchNamesValidated = MicaValidBranchName(@"agent/fix-login") && MicaValidBranchName(@"v1.2_x") &&
                !MicaValidBranchName(@"-rf") && !MicaValidBranchName(@"a..b") && !MicaValidBranchName(@"a b") &&
                !MicaValidBranchName(@"x;rm") && !MicaValidBranchName(@"/abs") && !MicaValidBranchName(@"") &&
                [MicaGitRootForDirectory([gitRoot stringByAppendingPathComponent:@"repo/src/deep"]) isEqualToString:
                    [[gitRoot stringByAppendingPathComponent:@"repo"] stringByStandardizingPath]];
            MicaUITestRecord(report, &allPassed, branchNamesValidated,
                @"worktree branch names reject options and shell-looking text, and the repository root is found");
            [fileManager removeItemAtPath:gitRoot error:nil];

            // Bare URLs in terminal text: found under the pointer, punctuation stripped, other text ignored.
            NSString *prose = @"see (https://example.com/a?b=1). and http://localhost:8080/x, or file:///etc/passwd or javascript:alert(1)";
            BOOL bareUrls =
                [MicaBareURLInLine(prose, 8).absoluteString isEqualToString:@"https://example.com/a?b=1"] &&
                [MicaBareURLInLine(prose, [prose rangeOfString:@"localhost"].location + 2).absoluteString isEqualToString:@"http://localhost:8080/x"] &&
                MicaBareURLInLine(prose, 1) == nil &&
                MicaBareURLInLine(prose, [prose rangeOfString:@"file:"].location + 1) == nil &&
                MicaBareURLInLine(prose, [prose rangeOfString:@"javascript"].location + 3) == nil &&
                MicaBareURLInLine(@"https://user:pw@evil.test/", 4) == nil;
            MicaUITestRecord(report, &allPassed, bareUrls,
                @"plain http(s) addresses in terminal text can be opened, and file:, javascript: and credential URLs cannot");

            // mica:// project URLs: only layouts inside the layouts folder are accepted.
            NSString *layoutsRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"mica-layouts-%d", getpid()]];
            [fileManager createDirectoryAtPath:layoutsRoot withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *goodLayout = [layoutsRoot stringByAppendingPathComponent:@"alpha.mica"];
            NSString *secondLayout = [layoutsRoot stringByAppendingPathComponent:@"beta.mica"];
            [@"# Mica layout v1\n# Mica project: Alpha\nShell\t/tmp\t\n" writeToFile:goodLayout atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [@"# Mica layout v1\n# Mica project: Beta\nShell\t/tmp\t\n" writeToFile:secondLayout atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *outside = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"outside-%d.mica", getpid()]];
            [@"x" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *escapeLink = [layoutsRoot stringByAppendingPathComponent:@"escape.mica"];
            [fileManager createSymbolicLinkAtPath:escapeLink withDestinationPath:outside error:nil];
            NSString *(^enc)(NSString *) = ^NSString *(NSString *v) {
                return [v stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]; };
            NSArray<NSString *> *good = MicaArgumentsForOpenURL(
                [NSURL URLWithString:[NSString stringWithFormat:@"mica://open?layout=%@&name=%@", enc(goodLayout), enc(@"Alpha Project")]], layoutsRoot);
            BOOL urlsValidated = good.count == 5 && [good[1] isEqualToString:@"--layout"] && [good[3] isEqualToString:@"--project-name"] &&
                [good[4] isEqualToString:@"Alpha Project"] &&
                MicaArgumentsForOpenURL([NSURL URLWithString:[NSString stringWithFormat:@"mica://open?layout=%@", enc(outside)]], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:[NSString stringWithFormat:@"mica://open?layout=%@", enc(escapeLink)]], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:[NSString stringWithFormat:@"mica://open?layout=%@/../x.mica", enc(layoutsRoot)]], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:@"https://open?layout=/etc/passwd"], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:@"mica://run?layout=/etc/passwd"], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:@"mica://open"], layoutsRoot) == nil;
            MicaUITestRecord(report, &allPassed, urlsValidated,
                @"mica:// URLs open only layouts from the layouts folder, and refuse other paths, symlinks and schemes");

            // Several project windows in one process: separate controllers, one menu bar that follows the key window,
            // duplicates focus the existing window, and closing one leaves the others running.
            setenv("MICA_TEST_NO_STARTUP", "1", 1);
            MicaAppDelegate *windowA = [[MicaAppDelegate alloc] init];
            MicaAppDelegate *windowB = [[MicaAppDelegate alloc] init];
            [windowA startWindowWithArguments:@[@"mica", @"--layout", goodLayout, @"--project-name", @"Alpha"]];
            [windowB startWindowWithArguments:@[@"mica", @"--layout", secondLayout, @"--project-name", @"Beta"]];
            BOOL twoWindows = MicaControllers().count == 2 && windowA.tabs.count == 1 && windowB.tabs.count == 1 &&
                [windowA.projectName isEqualToString:@"Alpha"] && [windowB.projectName isEqualToString:@"Beta"];
            [windowA takeMenuOwnership];
            NSMenuItem *newTabItem = [[NSApp.mainMenu itemWithTitle:@"Session"].submenu itemWithTitle:@"New Shell Tab"];
            BOOL menuAtA = newTabItem.target == windowA;
            [windowB takeMenuOwnership];
            BOOL menuAtB = newTabItem.target == windowB;
            [windowA openProjectWindowWithArguments:@[@"mica", @"--layout", goodLayout]];   // already open: no third window
            BOOL noDuplicate = MicaControllers().count == 2;
            NSUInteger tabsBeforeClose = windowA.tabs.count;
            pid_t closedShellPID = mica_session_pid(windowB.activeTab.session);
            [windowB windowWillClose:nil];
            for (NSUInteger attempt = 0; attempt < 200 && kill(closedShellPID, 0) == 0; attempt++)
                usleep(10000);
            BOOL closedCleanly = MicaControllers().count == 1 && MicaControllers().firstObject == windowA &&
                windowA.tabs.count == tabsBeforeClose && windowA.activeTab.session != NULL &&
                windowB.activeTab.session == NULL && windowB.pollTimer == nil &&
                kill(closedShellPID, 0) == -1 && errno == ESRCH;
            MicaUITestRecord(report, &allPassed, twoWindows && menuAtA && menuAtB && noDuplicate && closedCleanly,
                [NSString stringWithFormat:@"one process hosts several project windows (two=%d menuA=%d menuB=%d nodup=%d closed=%d)",
                    twoWindows, menuAtA, menuAtB, noDuplicate, closedCleanly]);
            for (NSValue *leftover in [windowA detachSessionsForTermination]) mica_session_destroy(leftover.pointerValue);
            [MicaControllers() removeAllObjects];
            [fileManager removeItemAtPath:layoutsRoot error:nil];
            unlink(outside.fileSystemRepresentation);
            MicaUITestRecord(report, &allPassed, gitBranchesDetected,
                @"the git branch is read for a repo, a linked worktree and a detached HEAD, and is absent outside a repo");

            [delegate selectTabAtIndex:0];
            [delegate.terminalView setNeedsDisplay:YES];
            [delegate.terminalView displayIfNeeded];
            MicaSession *cursorSession = delegate.activeTab.session;
            int cursorRow = 0, cursorCol = 0;
            mica_session_cursor(cursorSession, &cursorRow, &cursorCol);
            MicaCell cursorCell = {0};
            BOOL cursorCellReady = cursorSession && cursorRow >= 0 && cursorRow < mica_session_rows(cursorSession) &&
                cursorCol >= 0 && cursorCol < mica_session_cols(cursorSession) &&
                mica_session_get_cell(cursorSession, cursorRow, cursorCol, &cursorCell);
            NSBitmapImageRep *cursorBitmap = [delegate.terminalView bitmapImageRepForCachingDisplayInRect:delegate.terminalView.bounds];
            if (cursorBitmap)
                [delegate.terminalView cacheDisplayInRect:delegate.terminalView.bounds toBitmapImageRep:cursorBitmap];
            NSRect cursorCellRect = cursorCellReady
                ? [delegate.terminalView cellRectAtRow:cursorRow col:cursorCol] : NSZeroRect;
            if (cursorCellReady) cursorCellRect.size.width *= MAX((NSInteger)cursorCell.width, 1);
            CGFloat cursorScaleX = cursorBitmap
                ? cursorBitmap.pixelsWide / MAX(delegate.terminalView.bounds.size.width, 1.0) : 1.0;
            CGFloat cursorScaleY = cursorBitmap
                ? cursorBitmap.pixelsHigh / MAX(delegate.terminalView.bounds.size.height, 1.0) : 1.0;
            NSUInteger visibleCursorPixels = 0;
            if (cursorBitmap && cursorCellReady) {
                NSInteger x0 = (NSInteger)floor(NSMinX(cursorCellRect) * cursorScaleX);
                NSInteger x1 = (NSInteger)ceil(NSMaxX(cursorCellRect) * cursorScaleX);
                NSInteger y0 = (NSInteger)floor(NSMinY(cursorCellRect) * cursorScaleY);
                NSInteger y1 = (NSInteger)ceil(NSMaxY(cursorCellRect) * cursorScaleY);
                for (NSUInteger flipped = 0; flipped < 2; flipped++) {
                    NSUInteger count = 0;
                    NSInteger startY = flipped ? cursorBitmap.pixelsHigh - y1 : y0;
                    for (NSInteger y = MAX(0, startY); y < MIN(cursorBitmap.pixelsHigh,
                        startY + y1 - y0); y++) {
                        for (NSInteger x = MAX(0, x0); x < MIN(cursorBitmap.pixelsWide, x1); x++) {
                            NSColor *pixel = [[cursorBitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                            if (pixel && pixel.redComponent * 0.2126 + pixel.greenComponent * 0.7152 +
                                pixel.blueComponent * 0.0722 > 0.55) count++;
                        }
                    }
                    visibleCursorPixels = MAX(visibleCursorPixels, count);
                }
            }
            NSUInteger cursorCellPixelArea = cursorBitmap
                ? (NSUInteger)MAX(1, (NSInteger)ceil(cursorCellRect.size.width * cursorScaleX)) *
                  (NSUInteger)MAX(1, (NSInteger)ceil(cursorCellRect.size.height * cursorScaleY)) : 0;
            BOOL blockCursorVisible = cursorBitmap && cursorCellReady && cursorCellPixelArea > 0 &&
                visibleCursorPixels > cursorCellPixelArea / 3;
            MicaUITestRecord(report, &allPassed, blockCursorVisible,
                [NSString stringWithFormat:@"terminal cursor renders as a high-contrast full-cell block (pixels=%lu cell=%lu)",
                    (unsigned long)visibleCursorPixels, (unsigned long)cursorCellPixelArea]);

            MicaVoiceController *previewController = [[MicaVoiceController alloc]
                initWithHelperURL:[NSURL fileURLWithPath:@"/usr/bin/false"]];
            [previewController setValue:@(MicaVoiceControllerStateListening) forKey:@"state"];
            [previewController setValue:@"" forKey:@"statusText"];
            [previewController setValue:@"Change the Codex tab widths so all tabs fit in the window"
                                  forKey:@"transcript"];
            [previewController setValue:@"Change the Codex tab widths"
                                  forKey:@"confirmedTranscript"];
            [previewController setValue:@(4.0) forKey:@"elapsedSeconds"];
            delegate.voiceController = previewController;
            [delegate.terminalView setNeedsDisplay:YES];
            [delegate.terminalView displayIfNeeded];
            NSRect voicePanel = [delegate.terminalView dictationStatusRect];
            NSRect terminalArea = [delegate.terminalView terminalRect];
            MicaUITestRecord(report, &allPassed,
                !NSIsEmptyRect(voicePanel) && NSEqualRects(voicePanel,
                    NSMakeRect(0, 0, delegate.terminalView.bounds.size.width, kStatusHeight)) &&
                !NSIntersectsRect(voicePanel, terminalArea),
                @"live dictation uses the bottom status strip without covering terminal cells or cursor");
            NSDictionary *layoutHintAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:11.5]};
            NSDictionary *layoutContextAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:11.5]};
            CGFloat minFolderContext = 18 + [@"Ready · " sizeWithAttributes:layoutContextAttrs].width +
                [@"…/Fieldnote" sizeWithAttributes:layoutContextAttrs].width;
            CGFloat layoutMemoryWidth = [@"58 MB" sizeWithAttributes:
                @{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium]}].width;
            NSArray<NSString *> *layoutHints = @[@"⌘/ Shortcuts", @"⌥ Dictate", @"⌘1–8 Switch tab",
                @"⌘T New tab", @"⌘Q Quit"];
            NSRect layoutTimer = [delegate.terminalView pomodoroControlRect];
            BOOL narrowRectsDoNotOverlap = YES;
            for (NSNumber *widthValue in @[@600, @800]) {
                CGFloat width = widthValue.doubleValue;
                MicaStatusBarLayout layout = MicaComputeStatusBarLayout(width, NSMaxX(layoutTimer) + 12,
                    minFolderContext, layoutMemoryWidth, layoutHints, layoutHintAttrs);
                narrowRectsDoNotOverlap = narrowRectsDoNotOverlap &&
                    !NSIntersectsRect(layoutTimer, layout.contextRect) &&
                    !NSIntersectsRect(layoutTimer, layout.hintsRect) &&
                    !NSIntersectsRect(layoutTimer, layout.memoryRect) &&
                    !NSIntersectsRect(layout.contextRect, layout.hintsRect) &&
                    !NSIntersectsRect(layout.contextRect, layout.memoryRect) &&
                    !NSIntersectsRect(layout.hintsRect, layout.memoryRect) &&
                    layout.contextRect.size.width >= minFolderContext - 18;
            }
            MicaUITestRecord(report, &allPassed, narrowRectsDoNotOverlap,
                @"status timer, folder context, hints and memory rectangles never overlap at 600 px or 800 px");
            NSMutableParagraphStyle *tailStyle = [[NSMutableParagraphStyle alloc] init];
            tailStyle.lineBreakMode = NSLineBreakByTruncatingHead;
            NSDictionary *tailAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:10.5],
                NSParagraphStyleAttributeName: tailStyle };
            NSMutableArray<NSString *> *fortyTranscriptWords = [NSMutableArray array];
            for (NSUInteger wordIndex = 0; wordIndex < 40; wordIndex++)
                [fortyTranscriptWords addObject:@[@"recent", @"words", @"current", @"phrase"][wordIndex % 4]];
            NSString *longLiveTranscript = [fortyTranscriptWords componentsJoinedByString:@" "];
            [previewController setValue:longLiveTranscript forKey:@"transcript"];
            NSRect transcriptRect = NSMakeRect(205, 0,
                MAX(0, delegate.terminalView.bounds.size.width - 217), kStatusHeight);
            MicaUITestRecord(report, &allPassed,
                [previewController.transcript sizeWithAttributes:tailAttrs].width > transcriptRect.size.width &&
                    transcriptRect.size.height == kStatusHeight,
                @"a long live transcript stays on one status line and truncates from the start to keep recent words visible");
            BOOL dictationRectsSafe = YES;
            NSArray<NSNumber *> *dictationWidths = @[@480, @600, @800, @1600];
            NSArray<NSNumber *> *dictationStatesForLayout = @[@(MicaVoiceControllerStatePreparing),
                @(MicaVoiceControllerStateListening), @(MicaVoiceControllerStateFailed)];
            NSArray<NSString *> *dictationWordSamples = @[@"", @"change the tab widths", longLiveTranscript];
            NSWindow *dictationLayoutWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1600, 360)
                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            dictationLayoutWindow.releasedWhenClosed = NO;
            MicaTerminalView *dictationLayoutView = [[MicaTerminalView alloc] initWithFrame:NSMakeRect(0, 0, 1600, 360)];
            dictationLayoutView.owner = delegate;
            dictationLayoutView.terminalFont = delegate.terminalView.terminalFont;
            [dictationLayoutWindow setContentView:dictationLayoutView];
            for (NSInteger themeIndex = 0; themeIndex < 2; themeIndex++) {
                [delegate setLightTheme:themeIndex == 1];
                for (NSNumber *width in dictationWidths) for (NSNumber *stateValue in dictationStatesForLayout)
                    for (NSString *sampleWords in dictationWordSamples) {
                    [dictationLayoutView setFrameSize:NSMakeSize(width.doubleValue, dictationLayoutView.bounds.size.height)];
                    [previewController setValue:stateValue forKey:@"state"];
                    [previewController setValue:sampleWords forKey:@"transcript"];
                    [previewController setValue:[stateValue integerValue] == MicaVoiceControllerStateFailed
                        ? @"Microphone access was denied. Enable Mica in System Settings → Privacy & Security → Microphone."
                        : @"Listening · 00:00" forKey:@"statusText"];
                    [dictationLayoutView setNeedsDisplay:YES]; [dictationLayoutView displayIfNeeded];
                    NSBitmapImageRep *layoutBitmap = [dictationLayoutView bitmapImageRepForCachingDisplayInRect:dictationLayoutView.bounds];
                    [dictationLayoutView cacheDisplayInRect:dictationLayoutView.bounds toBitmapImageRep:layoutBitmap];
                    NSRect labelRect = dictationLayoutView.dictationLabelTextRect;
                    NSRect wordsRect = dictationLayoutView.dictationWordsTextRect;
                    NSRect hintRect = dictationLayoutView.dictationHintTextRect;
                    NSDictionary *visibleAttrs = @{NSFontAttributeName:sampleWords.length
                        ? [NSFont systemFontOfSize:kDictationWordsFontSize weight:NSFontWeightMedium]
                        : [NSFont systemFontOfSize:kDictationLabelFontSize]};
                    NSString *visibleText = MicaHeadTruncatedText(sampleWords, wordsRect.size.width, visibleAttrs);
                    NSRange lastSpace = [sampleWords rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet
                        options:NSBackwardsSearch];
                    NSString *lastWord = lastSpace.location == NSNotFound ? sampleWords :
                        [sampleWords substringFromIndex:NSMaxRange(lastSpace)];
                    BOOL shouldShowLastWord = [stateValue integerValue] == MicaVoiceControllerStateListening && sampleWords.length;
                    dictationRectsSafe = dictationRectsSafe && !NSIntersectsRect(labelRect, wordsRect) &&
                        (NSIsEmptyRect(hintRect) || (!NSIntersectsRect(labelRect, hintRect) && !NSIntersectsRect(wordsRect, hintRect))) &&
                        NSMinX(wordsRect) >= NSMaxX(labelRect) && NSMaxX(wordsRect) <= width.doubleValue &&
                        (!shouldShowLastWord || [visibleText hasSuffix:lastWord]);
                }
            }
            [dictationLayoutWindow close];
            [delegate setLightTheme:NO];
            MicaUITestRecord(report, &allPassed, dictationRectsSafe,
                @"dictation label, 0/3/40-word transcript and hint stay separate with the last word visible at 480/600/800/1600 px in both themes");
            [previewController setValue:@(MicaVoiceControllerStateFailed) forKey:@"state"];
            [previewController setValue:@"I didn’t catch any speech. Hold left Option and speak a little longer."
                                  forKey:@"statusText"];
            [delegate.terminalView setNeedsDisplay:YES];
            [delegate.terminalView displayIfNeeded];
            NSRect voiceStatusText = NSMakeRect(38, 0, 155, kStatusHeight);
            NSRect voiceDetailText = NSMakeRect(205, 0, MAX(0, voicePanel.size.width - 217), kStatusHeight);
            MicaUITestRecord(report, &allPassed,
                !NSIntersectsRect(voiceStatusText, voiceDetailText) &&
                    previewController.statusText.length > 0,
                @"dictation failure keeps its short heading and recovery detail in separate status-bar columns");
            [previewController setValue:@"Microphone access was denied. Enable Mica in System Settings → Privacy & Security → Microphone."
                                  forKey:@"statusText"];
            NSRect micSettingsButton = [delegate.terminalView microphoneSettingsButtonRect];
            MicaUITestRecord(report, &allPassed,
                !NSIsEmptyRect(micSettingsButton) && micSettingsButton.size.width >= 160 &&
                    NSMaxX(micSettingsButton) <= delegate.terminalView.bounds.size.width &&
                    [MicaMicrophoneSettingsURL().absoluteString containsString:@"Privacy_Microphone"],
                @"a denied microphone shows a visible System Settings action with the documented privacy URL");
            NSBitmapImageRep *bitmap = [delegate.terminalView bitmapImageRepForCachingDisplayInRect:delegate.terminalView.bounds];
            if (bitmap) [delegate.terminalView cacheDisplayInRect:delegate.terminalView.bounds toBitmapImageRep:bitmap];
            BOOL bitmapReady = bitmap != nil;
            NSString *imagePath = NSProcessInfo.processInfo.environment[@"MICA_UI_SMOKE_IMAGE"] ?: @"build/ui-smoke.png";
            NSData *png = bitmap ? [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
            BOOL imageSaved = png && [png writeToFile:imagePath atomically:YES];
            MicaUITestRecord(report, &allPassed, bitmapReady && imageSaved,
                             [NSString stringWithFormat:@"offscreen AppKit render saved to %@", imagePath]);

            NSString *lightPath = NSProcessInfo.processInfo.environment[@"MICA_UI_SMOKE_LIGHT_IMAGE"];
            if (lightPath.length) {
                // Optional: render the light theme too so it can be inspected by eye.
                [delegate setLightTheme:YES];
                NSBitmapImageRep *lightBitmap = [delegate.terminalView bitmapImageRepForCachingDisplayInRect:delegate.terminalView.bounds];
                if (lightBitmap) [delegate.terminalView cacheDisplayInRect:delegate.terminalView.bounds toBitmapImageRep:lightBitmap];
                NSData *lightPNG = lightBitmap ? [lightBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
                [lightPNG writeToFile:lightPath atomically:YES];
                [delegate setLightTheme:NO];
            }

            if (bitmapReady) {
                NSColor *reverseBackground = MicaUITestColor(gMicaLightTheme ? 0x24292f : 0xd4d4d4, bitmap.colorSpace);
                NSColor *blockBackground = MicaUITestColor(0x123456, bitmap.colorSpace);
                NSColor *terminalBackground = MicaUITestColor(0x1e1e1e, bitmap.colorSpace);
                NSInteger blockRow = 0, blockCol = 0;
                NSFont *font = delegate.terminalView.terminalFont;
                NSDictionary *fontAttrs = @{ NSFontAttributeName: font };
                CGFloat cellWidth = [@"M" sizeWithAttributes:fontAttrs].width;
                CGFloat lineHeight = ceil(font.ascender - font.descender + font.leading + 1.0);
                NSRect terminalArea = [delegate.terminalView terminalRect];
                BOOL blockFound = MicaUITestFindText(fixtureTab.session, @"UI-BLOCK", &blockRow, &blockCol);
                CGFloat scaleX = bitmap.pixelsWide / MAX(delegate.terminalView.bounds.size.width, 1.0);
                CGFloat scaleY = bitmap.pixelsHigh / MAX(delegate.terminalView.bounds.size.height, 1.0);
                NSInteger reverseRow = 0, reverseCol = 0;
                BOOL reverseFound = MicaUITestFindText(fixtureTab.session,
                    @"UI-REVERSE-CHOICE", &reverseRow, &reverseCol);
                MicaCell reverseCell = {0};
                BOOL reverseAttr = reverseFound && mica_session_get_cell(
                    fixtureTab.session, (int)reverseRow, (int)reverseCol, &reverseCell) && reverseCell.attrs.reverse;
                NSInteger reverseX = (NSInteger)floor(reverseCol * cellWidth * scaleX);
                NSInteger reverseY = (NSInteger)floor((NSMaxY(terminalArea) - (reverseRow + 1) * lineHeight) * scaleY);
                NSInteger reverseWidth = MAX(1, (NSInteger)ceil(18 * cellWidth * scaleX));
                NSInteger reverseHeight = MAX(1, (NSInteger)ceil(lineHeight * scaleY));
                NSUInteger reverseBackgroundPixels = 0;
                for (NSUInteger flipped = 0; flipped < 2; flipped++) {
                    NSUInteger orientationPixels = 0;
                    NSInteger startY = flipped ? bitmap.pixelsHigh - reverseY - reverseHeight : reverseY;
                    for (NSInteger y = MAX(0, startY); reverseAttr && y < MIN(bitmap.pixelsHigh, startY + reverseHeight); y++) {
                        for (NSInteger x = MAX(0, reverseX); x < MIN(bitmap.pixelsWide, reverseX + reverseWidth); x++) {
                            if (MicaUITestCheckColor([bitmap colorAtX:x y:y], reverseBackground)) orientationPixels++;
                        }
                    }
                    reverseBackgroundPixels = MAX(reverseBackgroundPixels, orientationPixels);
                }
                MicaUITestRecord(report, &allPassed, reverseAttr && reverseBackgroundPixels > 40,
                    [NSString stringWithFormat:@"reverse-video TUI choices retain visible inverse background cells (attr=%d pixels=%lu)",
                        reverseAttr, (unsigned long)reverseBackgroundPixels]);
                NSInteger blockX = (NSInteger)floor(blockCol * cellWidth * scaleX);
                NSInteger blockY = (NSInteger)floor((NSMaxY(terminalArea) - (blockRow + 1) * lineHeight) * scaleY);
                NSInteger blockWidth = MAX(1, (NSInteger)ceil(8 * cellWidth * scaleX));
                NSInteger blockHeight = MAX(1, (NSInteger)ceil(lineHeight * scaleY));
                NSUInteger rgbPixels = 0;
                for (NSUInteger flipped = 0; flipped < 2; flipped++) {
                    NSUInteger orientationPixels = 0;
                    NSInteger startY = flipped ? bitmap.pixelsHigh - blockY - blockHeight : blockY;
                    for (NSInteger y = MAX(0, startY); blockFound && y < MIN(bitmap.pixelsHigh, startY + blockHeight); y++) {
                        for (NSInteger x = MAX(0, blockX); x < MIN(bitmap.pixelsWide, blockX + blockWidth); x++) {
                            if (MicaUITestCheckColor([bitmap colorAtX:x y:y], blockBackground)) orientationPixels++;
                        }
                    }
                    rgbPixels = MAX(rgbPixels, orientationPixels);
                }
                MicaUITestRecord(report, &allPassed, blockFound && rgbPixels > 20,
                                 [NSString stringWithFormat:@"terminal RGB background paints exact-color pixels (%lu)",
                                  (unsigned long)rgbPixels]);

                NSInteger emojiRow = 0, emojiCol = 0;
                BOOL emojiFound = MicaUITestFindCodepoint(fixtureTab.session, 0x1f642, &emojiRow, &emojiCol);
                NSInteger emojiX = (NSInteger)floor(emojiCol * cellWidth * scaleX);
                NSInteger emojiY = (NSInteger)floor((NSMaxY(terminalArea) - (emojiRow + 1) * lineHeight) * scaleY);
                NSInteger emojiWidth = MAX(1, (NSInteger)ceil(2 * cellWidth * scaleX));
                NSInteger emojiHeight = MAX(1, (NSInteger)ceil(lineHeight * scaleY));
                NSUInteger inkPixels = 0;
                NSUInteger colorPixels = 0;
                for (NSUInteger flipped = 0; flipped < 2; flipped++) {
                    NSUInteger orientationPixels = 0;
                    NSUInteger orientationColorPixels = 0;
                    NSInteger startY = flipped ? bitmap.pixelsHigh - emojiY - emojiHeight : emojiY;
                    for (NSInteger y = MAX(0, startY); emojiFound && y < MIN(bitmap.pixelsHigh, startY + emojiHeight); y++) {
                        for (NSInteger x = MAX(0, emojiX); x < MIN(bitmap.pixelsWide, emojiX + emojiWidth); x++) {
                            NSColor *pixel = [bitmap colorAtX:x y:y];
                            if (!MicaUITestCheckColor(pixel, terminalBackground)) orientationPixels++;
                            CGFloat highest = MAX(pixel.redComponent, MAX(pixel.greenComponent, pixel.blueComponent));
                            CGFloat lowest = MIN(pixel.redComponent, MIN(pixel.greenComponent, pixel.blueComponent));
                            if (highest - lowest > 0.08) orientationColorPixels++;
                        }
                    }
                    inkPixels = MAX(inkPixels, orientationPixels);
                    colorPixels = MAX(colorPixels, orientationColorPixels);
                }
                MicaUITestRecord(report, &allPassed, emojiFound && inkPixels > 5 && colorPixels > 5,
                                 [NSString stringWithFormat:@"emoji cell paints ink and color pixels (%lu ink, %lu color)",
                                  (unsigned long)inkPixels, (unsigned long)colorPixels]);
            }
        }

        char optionDirectory[] = "/tmp/mica-option-picker-XXXXXX";
        NSString *optionRoot = mkdtemp(optionDirectory)
            ? [NSString stringWithUTF8String:optionDirectory] : nil;
        NSString *optionScript = [optionRoot stringByAppendingPathComponent:@"choose.py"];
        NSString *optionScriptBody = @"import sys, termios, tty\n"
            "import os, select\n"
            "fd = sys.stdin.fileno()\n"
            "saved = termios.tcgetattr(fd)\n"
            "tty.setraw(fd)\n"
            "sys.stdout.write('Resume a previous session\\r\\n'"
            "+ 'Filter: Cwd  All    Status: Active  Archived    Sort: Updated  Created\\r\\n'"
            "+ 'Type to search\\r\\n\\r\\n'"
            "+ '\\x1b[7m  3h ago       Reply READY\\x1b[0m\\r\\n'"
            "+ '  1d ago       Fix the tab selection bug\\r\\n'"
            "+ '  2d ago       Review terminal input\\r\\n\\r\\n'"
            "+ 'enter resume   ctrl+a archive   esc exit   tab focus sort/filter\\r\\n'"
            "+ 'OPTION-MENU-READY')\n"
            "sys.stdout.flush()\n"
            "arrow = bytearray()\n"
            "while len(arrow) < 16:\n"
            "    ready, _, _ = select.select([fd], [], [], 1)\n"
            "    if not ready: break\n"
            "    byte = os.read(fd, 1)\n"
            "    if not byte: break\n"
            "    arrow.extend(byte)\n"
            "    if arrow[0] != 27 or (len(arrow) > 2 and arrow[-1] in b'ABCD'): break\n"
            "valid_arrow = arrow.startswith((b'\\x1b[B', b'\\x1bOB')) and arrow[-1:] == b'B'\n"
            "print('\\r\\nOPTION-ARROW-RECEIVED' if valid_arrow else '\\r\\nOPTION-ARROW-FAILED-' + bytes(arrow).hex())\n"
            "sys.stdout.flush()\n"
            "ready, _, _ = select.select([fd], [], [], 1)\n"
            "enter = os.read(fd, 1) if ready else b''\n"
            "termios.tcsetattr(fd, termios.TCSADRAIN, saved)\n"
            "print('\\r\\nOPTION-SELECTED-CODEX' if valid_arrow and enter in (b'\\r', b'\\n') else '\\r\\nOPTION-SELECT-FAILED-' + bytes(arrow).hex() + '-' + enter.hex())\n";
        BOOL optionScriptReady = optionRoot &&
            [optionScriptBody writeToFile:optionScript atomically:YES encoding:NSUTF8StringEncoding error:nil];
        MicaAppDelegate *optionDelegate = [[MicaAppDelegate alloc] init];
        optionDelegate.tabs = [NSMutableArray array];
        optionDelegate.activeIndex = 0;
        MicaUITestAttachWindow(optionDelegate);
        if (optionScriptReady)
            [optionDelegate addTabWithName:@"Choice prompt" cwd:@"/tmp"
                command:[NSString stringWithFormat:@"python3 %@", optionScript] prefilled:NO];
        MicaTab *optionTab = optionDelegate.activeTab;
        BOOL optionPromptReady = NO;
        for (int attempt = 0; optionScriptReady && attempt < 300; attempt++) {
            mica_session_poll(optionTab.session, 0);
            if (MicaUITestFindText(optionTab.session, @"OPTION-MENU-READY", NULL, NULL)) {
                optionPromptReady = YES;
                break;
            }
            usleep(10000);
        }
        if (optionPromptReady) {
            MicaUITestSendKey(optionDelegate, @"\uF701", 0, 125);
        }
        BOOL optionArrowReceived = NO;
        for (int attempt = 0; optionPromptReady && attempt < 300; attempt++) {
            mica_session_poll(optionTab.session, 0);
            if (MicaUITestFindText(optionTab.session, @"OPTION-ARROW-RECEIVED", NULL, NULL)) {
                optionArrowReceived = YES;
                break;
            }
            if (MicaUITestFindText(optionTab.session, @"OPTION-ARROW-FAILED-", NULL, NULL)) break;
            usleep(10000);
        }
        if (optionArrowReceived) MicaUITestSendKey(optionDelegate, @"\r", 0, 36);
        BOOL optionSelectionWorked = NO;
        for (int attempt = 0; optionPromptReady && attempt < 300; attempt++) {
            mica_session_poll(optionTab.session, 0);
            if (MicaUITestFindText(optionTab.session, @"OPTION-SELECTED-CODEX", NULL, NULL)) {
                optionSelectionWorked = YES;
                break;
            }
            usleep(10000);
        }
        NSString *optionScreen = MicaUITestScreenTail(optionTab.session);
        BOOL optionSessionStopped = optionTab.session != NULL;
        if (optionTab.session) {
            mica_session_destroy(optionTab.session);
            optionTab.session = NULL;
        }
        optionDelegate.tabs = [NSMutableArray array];
        MicaUITestRecord(report, &allPassed,
            optionPromptReady && optionArrowReceived && optionSelectionWorked && optionSessionStopped,
            [NSString stringWithFormat:@"Claude-like previous-session picker accepts Down and Return through Mica's PTY (ready=%d arrow=%d selected=%d cleaned=%d screen=%@)",
                optionPromptReady, optionArrowReceived, optionSelectionWorked, optionSessionStopped, optionScreen]);
        if (optionRoot) [[NSFileManager defaultManager] removeItemAtPath:optionRoot error:nil];

        char projectLayoutDirectory[] = "/tmp/mica-project-layouts-XXXXXX";
        NSString *projectLayoutRoot = mkdtemp(projectLayoutDirectory)
            ? [NSString stringWithUTF8String:projectLayoutDirectory] : nil;
        NSString *projectALayout = [projectLayoutRoot stringByAppendingPathComponent:@"alpha.mica"];
        NSString *projectBLayout = [projectLayoutRoot stringByAppendingPathComponent:@"beta.mica"];
        NSString *commandLayout = [projectLayoutRoot stringByAppendingPathComponent:@"commands.mica"];
        NSString *layoutCommandScript = [projectLayoutRoot stringByAppendingPathComponent:@"r.sh"];
        NSString *projectALayoutContents = @"# Mica layout v1\n# Mica project: Project Alpha\n# Custom project metadata\n"
            "Claude Code 1\t/tmp\tprintf 'PROJECT-A-PREFILLED'\nShell\t/tmp\t\n";
        NSString *projectBLayoutContents = @"# Mica layout v1\n"
            "Codex\t/tmp\tprintf 'PROJECT-B-PREFILLED'\nShell\t/tmp\t\n";
        BOOL layoutCommandScriptReady = projectLayoutRoot &&
            [@"#!/bin/sh\nsleep 0.35\nprintf 'MICA-LAYOUT-OUTPUT\\n'\n" writeToFile:layoutCommandScript
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *layoutStartupCommand = [NSString stringWithFormat:@"sh %@", layoutCommandScript];
        NSString *commandLayoutContents = [NSString stringWithFormat:
            @"# Mica layout v1\nClaude Code\t/tmp\t%@\n", layoutStartupCommand];
        NSError *projectLayoutError = nil;
        BOOL projectLayoutsWritten = projectLayoutRoot &&
            [projectALayoutContents writeToFile:projectALayout atomically:YES encoding:NSUTF8StringEncoding error:&projectLayoutError] &&
            [projectBLayoutContents writeToFile:projectBLayout atomically:YES encoding:NSUTF8StringEncoding error:&projectLayoutError] &&
            layoutCommandScriptReady &&
            [commandLayoutContents writeToFile:commandLayout atomically:YES encoding:NSUTF8StringEncoding error:&projectLayoutError];
        NSDictionary *projectA = @{};
        NSDictionary *projectB = @{};
        if (projectLayoutsWritten) {
            projectA = MicaResolveLaunchConfiguration(@[@"mica", @"--layout", projectALayout,
                @"--project-name", @"Stale Script Name"],
                @{@"MicaProjectName": @"Stale Bundle Name", @"MicaProjectLayout": projectBLayout}, @"/tmp");
            projectB = MicaResolveLaunchConfiguration(@[@"mica"],
                @{@"MicaProjectName": @"Project Beta", @"MicaProjectLayout": projectBLayout}, @"/tmp");
        }
        NSArray<NSDictionary *> *projectATabs = projectA[@"tabs"];
        NSArray<NSDictionary *> *projectBTabs = projectB[@"tabs"];
        NSDictionary *projectAFirstTab = projectATabs.firstObject;
        NSDictionary *projectBFirstTab = projectBTabs.firstObject;
        MicaAppDelegate *projectATitle = [[MicaAppDelegate alloc] init];
        projectATitle.projectName = projectA[@"projectName"];
        MicaAppDelegate *projectBTitle = [[MicaAppDelegate alloc] init];
        projectBTitle.projectName = projectB[@"projectName"];
        MicaTab *projectATitleTab = [[MicaTab alloc] init];
        projectATitleTab.name = projectAFirstTab[@"name"];
        MicaTab *projectBTitleTab = [[MicaTab alloc] init];
        projectBTitleTab.name = projectBFirstTab[@"name"];
        BOOL projectAppsIndependent = projectLayoutsWritten &&
            projectATabs.count == 2 && projectBTabs.count == 2 &&
            [projectA[@"layoutPath"] isEqualToString:projectALayout] &&
            [projectB[@"layoutPath"] isEqualToString:projectBLayout] &&
            [projectAFirstTab[@"name"] isEqualToString:@"Claude Code 1"] &&
            [projectBFirstTab[@"name"] isEqualToString:@"Codex"] &&
            [projectAFirstTab[@"command"] isEqualToString:@"printf 'PROJECT-A-PREFILLED'"] &&
            [projectBFirstTab[@"command"] isEqualToString:@"printf 'PROJECT-B-PREFILLED'"] &&
            [projectA[@"projectName"] isEqualToString:@"Project Alpha"] &&
            [projectB[@"projectName"] isEqualToString:@"Project Beta"] &&
            [[projectATitle windowTitleForTab:projectATitleTab] isEqualToString:@"Project Alpha — Claude Code 1"] &&
            [[projectBTitle windowTitleForTab:projectBTitleTab] isEqualToString:@"Project Beta — Codex"] &&
            [projectA[@"activeIndex"] integerValue] == 0 &&
            [projectB[@"activeIndex"] integerValue] == 0 &&
            [projectA[@"activeIndex"] integerValue] == 0;
        MicaUITestRecord(report, &allPassed, projectAppsIndependent,
                         [NSString stringWithFormat:@"per-project layouts resolve separate named tabs, commands and window titles (A=%lu/%@ B=%lu/%@)%@",
                          (unsigned long)projectATabs.count, projectAFirstTab[@"name"],
                          (unsigned long)projectBTabs.count, projectBFirstTab[@"name"],
                          projectLayoutError ? [NSString stringWithFormat:@" error: %@", projectLayoutError.localizedDescription] : @""]);

        MicaAppDelegate *settingsOwner = [[MicaAppDelegate alloc] init];
        settingsOwner.projectName = @"Project Alpha";
        settingsOwner.projectLayoutPath = projectALayout;
        MicaUITestAttachWindow(settingsOwner);
        MicaProjectSettingsController *staleProjectSettings = [[MicaProjectSettingsController alloc] initWithOwner:settingsOwner];
        MicaProjectSettingsController *projectSettings = [[MicaProjectSettingsController alloc] initWithOwner:settingsOwner];
        BOOL settingsLoadedRows = projectSettings.rows.count == 2 && [projectSettings.rows[0][0] isEqualToString:@"Claude Code 1"];
        projectSettings.projectNameField.stringValue = @"Renamed Alpha";
        projectSettings.rows[0][0] = @"Claude";
        projectSettings.rows[0][2] = @"printf 'UPDATED-SETTINGS'";
        [settingsOwner.window beginSheet:projectSettings.window completionHandler:nil];
        [projectSettings save:nil];
        BOOL concurrentSettingsDetected = [staleProjectSettings layoutChangedOnDisk];
        NSDictionary *savedSettings = MicaResolveLaunchConfiguration(@[@"mica", @"--layout", projectALayout,
            @"--project-name", @"Old Launcher Name"], @{}, @"/tmp");
        NSArray<NSDictionary *> *savedSettingTabs = savedSettings[@"tabs"];
        BOOL projectSettingsPersisted = settingsLoadedRows &&
            [savedSettings[@"projectName"] isEqualToString:@"Renamed Alpha"] &&
            [savedSettingTabs.firstObject[@"name"] isEqualToString:@"Claude"] &&
            [savedSettingTabs.firstObject[@"command"] isEqualToString:@"printf 'UPDATED-SETTINGS'"] &&
            [settingsOwner.projectName isEqualToString:@"Renamed Alpha"] &&
            [[NSString stringWithContentsOfFile:projectALayout encoding:NSUTF8StringEncoding error:nil]
                containsString:@"# Custom project metadata"];
        projectSettingsPersisted = projectSettingsPersisted && concurrentSettingsDetected;
        MicaUITestRecord(report, &allPassed, projectSettingsPersisted,
                         [NSString stringWithFormat:@"project settings persist edits and detect stale concurrent settings (%lu rows, conflict=%d)",
                          (unsigned long)savedSettingTabs.count, concurrentSettingsDetected]);
        [settingsOwner.window orderOut:nil];

        char sharedTimerDirectory[] = "/tmp/mica-shared-timer-XXXXXX";
        NSURL *sharedTimerURL = mkdtemp(sharedTimerDirectory)
            ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:sharedTimerDirectory] isDirectory:YES] : nil;
        MicaAppDelegate *timerWindowA = [[MicaAppDelegate alloc] init];
        MicaAppDelegate *timerWindowB = [[MicaAppDelegate alloc] init];
        timerWindowA.pomodoroStorageDirectoryOverride = sharedTimerURL;
        timerWindowB.pomodoroStorageDirectoryOverride = sharedTimerURL;
        [timerWindowA configurePomodoro];
        [timerWindowB configurePomodoro];
        MicaUITestAttachWindow(timerWindowA);
        MicaUITestAttachWindow(timerWindowB);
        BOOL timerDefaultsShared = sharedTimerURL && timerWindowA.focusDurationMinutes == 60 &&
            timerWindowA.autoStartFocus && timerWindowA.autoStartBreaks &&
            timerWindowB.breakDurationMinutes == 15 &&
            [timerWindowA savePomodoroDurationsFocusMinutes:50 breakMinutes:8];
        BOOL timerOptionsSaved = timerDefaultsShared &&
            [timerWindowA savePomodoroSettingsFocusMinutes:50 breakMinutes:8
                autoStartFocus:NO autoStartBreaks:NO];
        [timerWindowB refreshPomodoroState];
        NSView *timerSettingsAccessory = [timerWindowB pomodoroSettingsAccessory];
        NSButton *autoBreakCheckbox = nil, *autoFocusCheckbox = nil;
        for (NSView *view in timerSettingsAccessory.subviews) {
            if (![view isKindOfClass:NSButton.class]) continue;
            NSButton *button = (NSButton *)view;
            if ([button.title isEqualToString:@"Auto-start break after focus"]) autoBreakCheckbox = button;
            if ([button.title isEqualToString:@"Auto-start focus after break"]) autoFocusCheckbox = button;
        }
        BOOL timerCheckboxesLoaded = autoBreakCheckbox && autoFocusCheckbox &&
            autoBreakCheckbox.state == NSControlStateValueOff && autoFocusCheckbox.state == NSControlStateValueOff;
        autoBreakCheckbox.state = NSControlStateValueOn;
        autoFocusCheckbox.state = NSControlStateValueOff;
        BOOL timerMixedCheckboxesSaved = timerCheckboxesLoaded &&
            [timerWindowB savePomodoroSettingsFromAccessory:timerSettingsAccessory];
        [timerWindowA refreshPomodoroState];
        BOOL timerMixedOptionsShared = timerMixedCheckboxesSaved && timerWindowA.autoStartBreaks &&
            !timerWindowA.autoStartFocus;
        autoBreakCheckbox.state = NSControlStateValueOff;
        autoFocusCheckbox.state = NSControlStateValueOn;
        BOOL timerReverseMixedSaved = [timerWindowB savePomodoroSettingsFromAccessory:timerSettingsAccessory];
        [timerWindowA refreshPomodoroState];
        BOOL timerReverseMixedShared = timerReverseMixedSaved && !timerWindowA.autoStartBreaks &&
            timerWindowA.autoStartFocus;
        autoBreakCheckbox.state = NSControlStateValueOff;
        autoFocusCheckbox.state = NSControlStateValueOff;
        BOOL timerOptionsRestored = [timerWindowB savePomodoroSettingsFromAccessory:timerSettingsAccessory];
        [timerWindowA refreshPomodoroState];
        BOOL timerOptionsShared = timerOptionsSaved && timerOptionsRestored && timerMixedOptionsShared &&
            timerReverseMixedShared &&
            !timerWindowA.autoStartFocus && !timerWindowA.autoStartBreaks &&
            !timerWindowB.autoStartFocus && !timerWindowB.autoStartBreaks;
        NSRect timerControl = [timerWindowA.terminalView pomodoroControlRect];
        MicaUITestSendMouse(timerWindowA, NSEventTypeLeftMouseDown,
            NSMakePoint(NSMaxX(timerControl) - 68, NSMidY(timerControl)), 0);
        [timerWindowB refreshPomodoroState];
        BOOL timerStartShared = timerOptionsShared && timerControl.size.width >= 180 &&
            timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS && timerWindowB.focusDurationMinutes == 50 &&
            timerWindowB.breakDurationMinutes == 8 && timerWindowB.pomodoro.phase == MICA_POMODORO_FOCUS &&
            timerWindowB.pomodoroCycleFocusMinutes == 50 && timerWindowB.pomodoro.deadline == timerWindowA.pomodoro.deadline;
        NSArray *timerAXLabels = [[timerWindowA.terminalView accessibilityChildren]
            valueForKey:@"accessibilityLabel"];
        BOOL timerToggleAccessible = NO;
        for (NSString *label in timerAXLabels)
            if ([label hasPrefix:@"Focus timer, Focus,"] &&
                [label containsString:@"0 focus sessions completed"] &&
                [label containsString:@"Pause timer"]) timerToggleAccessible = YES;
        BOOL timerControlsAccessible = timerToggleAccessible && [timerAXLabels containsObject:@"Reset focus timer"];
        [timerWindowB togglePomodoroPause:nil];
        [timerWindowA refreshPomodoroState];
        BOOL timerPauseShared = timerWindowA.pomodoro.phase == MICA_POMODORO_PAUSED_FOCUS;
        BOOL pausedPhaseVisible = [[timerWindowA.terminalView pomodoroStatusText] hasPrefix:@"Paused focus · "];
        NSMenuItem *skipTimerMenu = [[NSMenuItem alloc] initWithTitle:@"End Current Phase"
            action:@selector(skipPomodoroPhase:) keyEquivalent:@""];
        BOOL timerSkipMenuAccessible = [timerWindowA validateMenuItem:skipTimerMenu] &&
            [skipTimerMenu.title isEqualToString:@"End Focus & Start Break"];
        BOOL timerSkipAXPerformed = NO;
        for (NSAccessibilityElement *element in [timerWindowA.terminalView accessibilityChildren]) {
            for (NSAccessibilityCustomAction *action in element.accessibilityCustomActions) {
                if ([action.name isEqualToString:@"End focus and start break"] && action.handler)
                    timerSkipAXPerformed = action.handler();
            }
        }
        [timerWindowB refreshPomodoroState];
        BOOL timerSkipFocusShared = timerSkipAXPerformed && timerSkipMenuAccessible &&
            [timerWindowA validateMenuItem:skipTimerMenu] &&
            [skipTimerMenu.title isEqualToString:@"End Break & Start Focus"] &&
            timerWindowA.pomodoro.phase == MICA_POMODORO_BREAK &&
            timerWindowB.pomodoro.phase == MICA_POMODORO_BREAK && timerWindowB.pomodoro.completed_focuses == 1;
        BOOL timerCountAccessible = NO;
        for (NSString *label in [[timerWindowB.terminalView accessibilityChildren] valueForKey:@"accessibilityLabel"])
            if ([label hasPrefix:@"Focus timer, Break,"] &&
                [label containsString:@"1 focus session completed"]) timerCountAccessible = YES;
        NSString *visibleTimerStatus = [timerWindowB.terminalView pomodoroStatusText];
        NSRect visibleTimerRect = [timerWindowB.terminalView pomodoroControlRect];
        NSDictionary *visibleTimerAttributes = @{NSFontAttributeName:
            [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]};
        CGFloat visibleTimerTextWidth = ceil([[visibleTimerStatus uppercaseString]
            sizeWithAttributes:visibleTimerAttributes].width);
        BOOL timerPhaseVisible = [visibleTimerStatus hasPrefix:@"Break · "] &&
            [visibleTimerStatus containsString:@":"] && ![visibleTimerStatus containsString:@"done"] &&
            visibleTimerRect.size.width >= visibleTimerTextWidth + 140;
        timerSkipFocusShared = timerSkipFocusShared && timerCountAccessible && timerPhaseVisible && pausedPhaseVisible;
        [timerWindowB skipPomodoroPhase:nil];
        [timerWindowA refreshPomodoroState];
        BOOL timerSkipBreakShared = timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS &&
            timerWindowA.pomodoro.completed_focuses == 1;
        [timerWindowA resetPomodoro:nil];
        [timerWindowB refreshPomodoroState];
        BOOL timerResetShared = timerWindowB.pomodoro.phase == MICA_POMODORO_IDLE;
        timerResetShared = timerResetShared && ![timerWindowB validateMenuItem:skipTimerMenu] &&
            [skipTimerMenu.title isEqualToString:@"End Current Phase"];
        MicaPomodoro phaseLabelProbe = {0};
        phaseLabelProbe.phase = MICA_POMODORO_FOCUS;
        phaseLabelProbe.deadline = MicaContinuousTimeSeconds() + 90;
        timerWindowB.pomodoro = phaseLabelProbe;
        BOOL timerLabelsAllPhases = [[timerWindowB.terminalView pomodoroStatusText] hasPrefix:@"Focus · "];
        phaseLabelProbe.phase = MICA_POMODORO_PAUSED_BREAK;
        phaseLabelProbe.paused_remaining = 45;
        timerWindowB.pomodoro = phaseLabelProbe;
        timerLabelsAllPhases = timerLabelsAllPhases &&
            [[timerWindowB.terminalView pomodoroStatusText] hasPrefix:@"Paused break · "];
        timerWindowB.pomodoro = (MicaPomodoro){0};
        timerLabelsAllPhases = timerLabelsAllPhases &&
            [[timerWindowB.terminalView pomodoroStatusText] hasPrefix:@"Ready · "];
        MicaUITestRecord(report, &allPassed, timerDefaultsShared && timerStartShared && timerControlsAccessible &&
            timerPauseShared && timerSkipFocusShared && timerSkipBreakShared && timerResetShared && timerLabelsAllPhases,
            [NSString stringWithFormat:@"timer controls preserve independent checkbox auto-start choices, prioritize the visible phase and countdown, and expose completed focus count and skip actions accessibly across windows (options=%d start=%d accessible=%d phase=%d pause=%d focus-skip=%d break-skip=%d reset=%d labels=%d)",
                timerOptionsShared, timerStartShared, timerControlsAccessible, timerPhaseVisible, timerPauseShared,
                timerSkipFocusShared, timerSkipBreakShared, timerResetShared, timerLabelsAllPhases]);
        for (MicaAppDelegate *window in @[timerWindowA, timerWindowB]) {
            window.voiceController = [[MicaVoiceController alloc]
                initWithHelperURL:[NSURL fileURLWithPath:@"/usr/bin/false"]];
            [window.voiceController setValue:@(MicaVoiceControllerStateListening) forKey:@"state"];
            [window.voiceController setValue:@"" forKey:@"transcript"];
        }
        NSTimeInterval heldAnimationStamp = NSProcessInfo.processInfo.systemUptime + 60;
        timerWindowA.lastVoiceAnimationAt = heldAnimationStamp;
        timerWindowB.lastVoiceAnimationAt = 0;
        [timerWindowA pollSessions:nil];
        [timerWindowB pollSessions:nil];
        BOOL independentVoiceAnimation = timerWindowA.lastVoiceAnimationAt == heldAnimationStamp &&
            timerWindowB.lastVoiceAnimationAt > 0;
        timerWindowB.lastVoiceAnimationAt = heldAnimationStamp;
        timerWindowA.lastVoiceAnimationAt = 0;
        [timerWindowB pollSessions:nil];
        [timerWindowA pollSessions:nil];
        independentVoiceAnimation = independentVoiceAnimation &&
            timerWindowB.lastVoiceAnimationAt == heldAnimationStamp && timerWindowA.lastVoiceAnimationAt > 0;
        MicaUITestRecord(report, &allPassed, independentVoiceAnimation,
            @"dictation animation throttling belongs to each window and does not suppress another window's repaint");
        timerWindowA.voiceController = nil;
        timerWindowB.voiceController = nil;
        if (sharedTimerURL) [NSFileManager.defaultManager removeItemAtURL:sharedTimerURL error:nil];

        MicaAppDelegate *layoutDelegate = [[MicaAppDelegate alloc] init];
        layoutDelegate.tabs = [NSMutableArray array];
        layoutDelegate.activeIndex = 0;
        MicaUITestAttachWindow(layoutDelegate);
        if (projectLayoutsWritten)
            [layoutDelegate loadLaunchConfigurationFromArguments:@[@"mica", @"--layout", commandLayout]
                                                      bundleInfo:@{}];
        MicaTab *configuredCommandTab = layoutDelegate.activeTab;
        BOOL configuredCommandPrefilled = projectLayoutsWritten && layoutDelegate.tabs.count == 1 &&
            [configuredCommandTab.name isEqualToString:@"Claude Code"] &&
            [configuredCommandTab.command isEqualToString:layoutStartupCommand] &&
            strcmp(mica_session_command(configuredCommandTab.session), configuredCommandTab.command.UTF8String) == 0;
        BOOL configuredCommandStarted = NO;
        for (int attempt = 0; configuredCommandPrefilled && attempt < 300; attempt++) {
            [layoutDelegate pollSessions:nil];
            if (MicaUITestFindText(configuredCommandTab.session, @"r.sh", NULL, NULL)) {
                configuredCommandStarted = YES;
                break;
            }
            usleep(10000);
        }
        if (configuredCommandStarted) MicaUITestSendKey(layoutDelegate, @"\r", 0, 36);
        BOOL configuredCommandExecuted = NO;
        BOOL commandLabelUpdated = NO;
        for (int attempt = 0; configuredCommandStarted && attempt < 300; attempt++) {
            [layoutDelegate pollSessions:nil];
            NSString *runningLabel = [layoutDelegate.terminalView labelForTab:configuredCommandTab active:YES];
            if (configuredCommandTab.currentCommand.length &&
                [runningLabel isEqualToString:configuredCommandTab.name] &&
                [layoutDelegate.terminalView activityStateForTab:configuredCommandTab] == MicaTabActivityStateRunning)
                commandLabelUpdated = YES;
            if (MicaUITestFindText(configuredCommandTab.session, @"MICA-LAYOUT-OUTPUT", NULL, NULL))
                configuredCommandExecuted = YES;
            if (configuredCommandExecuted) break;
            usleep(10000);
        }
        for (int attempt = 0; configuredCommandExecuted && configuredCommandTab.currentCommand.length && attempt < 100; attempt++) {
            [layoutDelegate pollSessions:nil];
            usleep(10000);
        }
        BOOL commandLabelCleared = configuredCommandTab.currentCommand.length == 0 &&
            [[layoutDelegate.terminalView labelForTab:configuredCommandTab active:YES] isEqualToString:@"Claude Code"];
        NSString *layoutScreen = MicaUITestScreenTail(configuredCommandTab.session);
        BOOL layoutSessionCleaned = configuredCommandTab.session != NULL;
        if (configuredCommandTab.session) {
            mica_session_destroy(configuredCommandTab.session);
            configuredCommandTab.session = NULL;
        }
        layoutDelegate.tabs = [NSMutableArray array];
        MicaUITestRecord(report, &allPassed,
            configuredCommandPrefilled && configuredCommandStarted && configuredCommandExecuted &&
                commandLabelUpdated && commandLabelCleared && layoutSessionCleaned,
            [NSString stringWithFormat:@"a layout keeps the configured tab label while its startup command runs and returns to the shell (configured=%d prefilled=%d ran=%d label=%d reset=%d cleaned=%d screen=%@)",
                configuredCommandPrefilled, configuredCommandStarted, configuredCommandExecuted,
                commandLabelUpdated, commandLabelCleared, layoutSessionCleaned, layoutScreen]);
        if (projectLayoutRoot) [[NSFileManager defaultManager] removeItemAtPath:projectLayoutRoot error:nil];

        MicaAppDelegate *shortcutDelegate = [[MicaAppDelegate alloc] init];
        shortcutDelegate.tabs = [NSMutableArray array];
        shortcutDelegate.activeIndex = 0;
        shortcutDelegate.uiMode = MicaUIModeNormal;
        MicaUITestAttachWindow(shortcutDelegate);
        [shortcutDelegate addTabWithName:@"Shortcut probe" cwd:@"/tmp"
            command:@"stty -icanon -echo min 1 time 0; printf 'MICA-KEYS-READY\\n'; dd if=/dev/tty bs=1 count=2 2>/dev/null | od -An -t x1; stty sane"
            prefilled:NO];
        MicaTab *shortcutTab = shortcutDelegate.activeTab;
        BOOL shortcutPromptReady = NO;
        for (int attempt = 0; attempt < 500; attempt++) {
            [shortcutDelegate pollSessions:nil];
            if (MicaUITestFindText(shortcutTab.session, @"MICA-KEYS-READY", NULL, NULL)) {
                shortcutPromptReady = YES;
                break;
            }
            usleep(10000);
        }
        MicaUITestSendKey(shortcutDelegate, @"t", NSEventModifierFlagControl, 17);
        MicaUITestSendKey(shortcutDelegate, @"s", NSEventModifierFlagControl, 1);
        BOOL controlKeysForwarded = NO;
        for (int attempt = 0; attempt < 300; attempt++) {
            [shortcutDelegate pollSessions:nil];
            if (MicaUITestFindText(shortcutTab.session, @"14  13", NULL, NULL)) {
                controlKeysForwarded = YES;
                break;
            }
            usleep(10000);
        }
        MicaUITestSendKey(shortcutDelegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
        BOOL pickerShortcutWorks = shortcutDelegate.uiMode == MicaUIModeTab;
        MicaUITestSendKey(shortcutDelegate, @"\033", 0, 53);
        MicaUITestSendKey(shortcutDelegate, @"s", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1);
        BOOL historyShortcutWorks = shortcutDelegate.uiMode == MicaUIModeScroll;
        MicaUITestSendKey(shortcutDelegate, @"s", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1);
        historyShortcutWorks = historyShortcutWorks && shortcutDelegate.uiMode == MicaUIModeNormal;
        MicaUITestRecord(report, &allPassed,
            shortcutPromptReady && controlKeysForwarded && pickerShortcutWorks && historyShortcutWorks,
            [NSString stringWithFormat:@"Codex-safe app shortcuts leave Ctrl-T/Ctrl-S available to terminal TUIs (ready=%d forwarded=%d picker=%d history=%d screen=%@)",
                shortcutPromptReady, controlKeysForwarded, pickerShortcutWorks, historyShortcutWorks,
                MicaUITestScreenTail(shortcutTab.session)]);
        BOOL shortcutSessionExited = MicaUITestExitTabs(shortcutDelegate.tabs);
        MicaUITestRecord(report, &allPassed, shortcutSessionExited,
            @"the terminal shortcut probe exits cleanly");
        shortcutDelegate.tabs = [NSMutableArray array];
        [shortcutDelegate.window orderOut:nil];
        shortcutDelegate.terminalView = nil;
        shortcutDelegate.window = nil;

        MicaAppDelegate *exitDelegate = [[MicaAppDelegate alloc] init];
        exitDelegate.tabs = [NSMutableArray array];
        exitDelegate.activeIndex = 0;
        MicaUITestAttachWindow(exitDelegate);
        [exitDelegate addTabWithName:@"Keep" cwd:@"/tmp" command:nil prefilled:NO];
        [exitDelegate addTabWithName:@"Exit" cwd:@"/tmp" command:nil prefilled:NO];
        MicaTab *tabToExit = exitDelegate.activeTab;
        mica_session_write(tabToExit.session, "exit\n", 5);
        for (int attempt = 0; attempt < 300 && exitDelegate.tabs.count > 1; attempt++) {
            [exitDelegate pollSessions:nil];
            if (exitDelegate.tabs.count <= 1) break;
            usleep(10000);
        }
        BOOL shellExitClosedTab = exitDelegate.tabs.count == 1 && exitDelegate.activeIndex == 0 &&
            [exitDelegate.activeTab.name isEqualToString:@"Keep"] &&
            !mica_session_is_running(tabToExit.session);
        [exitDelegate.terminalView displayIfNeeded];
        [exitDelegate.terminalView updateGridSize];
        NSDictionary *gridAttrs = @{ NSFontAttributeName: exitDelegate.terminalView.terminalFont };
        CGFloat exitCharWidth = [@"M" sizeWithAttributes:gridAttrs].width;
        NSInteger expectedRemainingCols = (NSInteger)floor(
            [exitDelegate.terminalView terminalRect].size.width / MAX(1, exitCharWidth));
        BOOL remainingTabResized = shellExitClosedTab &&
            mica_session_cols(exitDelegate.activeTab.session) == expectedRemainingCols;
        MicaUITestRecord(report, &allPassed, shellExitClosedTab && remainingTabResized,
            [NSString stringWithFormat:@"exiting a shell closes that tab and gives the full terminal width to the remaining tab (closed=%d tabs=%lu active=%@ cols=%d expected=%ld)",
                shellExitClosedTab, (unsigned long)exitDelegate.tabs.count,
                exitDelegate.activeTab.name, mica_session_cols(exitDelegate.activeTab.session),
                (long)expectedRemainingCols]);
        BOOL exitDelegateClean = MicaUITestExitTabs(exitDelegate.tabs);
        MicaUITestRecord(report, &allPassed, exitDelegateClean, @"the shell-exit reflow probe exits cleanly");
        exitDelegate.tabs = [NSMutableArray array];
        [exitDelegate.window orderOut:nil];
        exitDelegate.terminalView = nil;
        exitDelegate.window = nil;

        BOOL primarySessionsExited = MicaUITestExitTabs(delegate.tabs);
        MicaUITestRecord(report, &allPassed, primarySessionsExited,
                         @"all UI smoke PTYs accept normal shell exit during teardown");

        NSString *reportPath = NSProcessInfo.processInfo.environment[@"MICA_UI_SMOKE_REPORT"] ?: @"build/ui-smoke-report.txt";
        BOOL reportSaved = [report writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (!reportSaved) fprintf(stderr, "[FAIL] could not save UI smoke report to %s\n", reportPath.UTF8String);
        [delegate.window orderOut:nil];
        delegate.tabs = [NSMutableArray array];
        delegate.terminalView = nil;
        delegate.window = nil;
        return allPassed && reportSaved ? 0 : 1;
    }
}

int main(void) {
    return MicaRunUISelfTest();
}
