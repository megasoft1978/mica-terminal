#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"
#import <ApplicationServices/ApplicationServices.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

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

static BOOL MicaUITestCheckColor(NSColor *color, uint32_t expectedRGB) {
    return fabs(color.redComponent - ((expectedRGB >> 16) & 0xff) / 255.0) < 0.01 &&
        fabs(color.greenComponent - ((expectedRGB >> 8) & 0xff) / 255.0) < 0.01 &&
        fabs(color.blueComponent - (expectedRGB & 0xff) / 255.0) < 0.01;
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
        NSMenuItem *newShellMenuItem = [sessionMenu itemWithTitle:@"New Shell Tab"];
        NSMenuItem *tabPickerMenuItem = [sessionMenu itemWithTitle:@"Choose Tab…"];
        NSMenuItem *scrollbackMenuItem = [sessionMenu itemWithTitle:@"Browse Scrollback"];
        NSMenu *helpMenu = [NSApp.mainMenu itemWithTitle:@"Help"].submenu;
        NSMenuItem *diagnosticLogsMenuItem = [helpMenu itemWithTitle:@"Open Diagnostic Logs"];
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
                         [sessionMenu itemWithTitle:@"New Claude Code Tab"] == nil &&
                         [sessionMenu itemWithTitle:@"New Codex Tab"] == nil,
                         @"Session shortcuts omit toggle dictation; Dictation uses left Option press and release");

        MicaAppDelegate *voiceDelegate = [[MicaAppDelegate alloc] init];
        voiceDelegate.tabs = [NSMutableArray array];
        voiceDelegate.activeIndex = 0;
        voiceDelegate.uiMode = MicaUIModeNormal;
        MicaUITestAttachWindow(voiceDelegate);
        MicaUITestVoiceController *pushToTalkProbe = [[MicaUITestVoiceController alloc]
            initWithHelperURL:[NSURL fileURLWithPath:@"/bin/false"]];
        voiceDelegate.voiceController = pushToTalkProbe;
        [voiceDelegate addTabWithName:@"PTT target" cwd:@"/tmp"
            command:@"printf 'PTT-TARGET-READY\\n'" prefilled:NO];
        [voiceDelegate addTabWithName:@"Other tab" cwd:@"/tmp"
            command:@"printf 'PTT-OTHER-READY\\n'" prefilled:NO];
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
        MicaUITestRunLoopFor(0.22);
        BOOL heldOptionStartedOnce = pushToTalkProbe.pushToTalkStarts == 1 &&
            voiceDelegate.voiceTargetTab == voiceTargetTab;
        MicaUITestSendFlags(voiceDelegate, 0, 58);
        BOOL optionReleaseFinishedOnce = pushToTalkProbe.pushToTalkFinishes == 1;
        MicaUITestRecord(report, &allPassed, voiceTabsReady && quickOptionTapIgnored &&
            optionChordIgnored && heldOptionStartedOnce && optionReleaseFinishedOnce,
            [NSString stringWithFormat:@"left Option hold starts dictation once, release finishes, and taps/chords are ignored (ready=%d quick=%d chord=%d starts=%lu finishes=%lu)",
                voiceTabsReady, quickOptionTapIgnored, optionChordIgnored,
                (unsigned long)pushToTalkProbe.pushToTalkStarts,
                (unsigned long)pushToTalkProbe.pushToTalkFinishes]);

        MicaUITestSendFlags(voiceDelegate, NSEventModifierFlagOption, 58);
        MicaUITestRunLoopFor(0.22);
        [voiceDelegate.terminalView cancelLeftOptionTracking];
        BOOL focusLossFinishesHold = pushToTalkProbe.pushToTalkStarts == 2 &&
            pushToTalkProbe.pushToTalkFinishes == 2;
        MicaUITestRecord(report, &allPassed, focusLossFinishesHold,
            @"losing app focus finalizes an active hold-to-talk capture exactly once");

        char rawHelperTemplate[] = "/tmp/mica-voice-raw-XXXXXX";
        char rawCallsTemplate[] = "/tmp/mica-voice-raw-calls-XXXXXX";
        int rawHelperFD = mkstemp(rawHelperTemplate);
        int rawCallsFD = mkstemp(rawCallsTemplate);
        NSString *rawCallsPath = [NSString stringWithUTF8String:rawCallsTemplate];
        NSString *rawHelperSource = [NSString stringWithFormat:
            @"#!/bin/sh\nprintf '%%s\\n' \"$1\" >> '%@'\n"
             "if [ \"$1\" = stream ]; then\n"
             "  printf '%%s\\n' '{\"type\":\"result\",\"text\":\"MICA-RAW-TRANSCRIPT\"}'\n"
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
            [rawVoiceController launchHelperWithArguments:@[@"stream"] inputData:nil keepsInputOpen:NO];
        for (int attempt = 0; rawHelperReady && rawVoiceController.state != MicaVoiceControllerStateIdle &&
             rawVoiceController.state != MicaVoiceControllerStateFailed && attempt < 300; attempt++)
            MicaUITestRunLoopFor(0.01);
        for (int attempt = 0; rawHelperReady && !MicaUITestFindText(voiceTargetTab.session,
             @"MICA-RAW-TRANSCRIPT", NULL, NULL) && attempt < 100; attempt++) {
            mica_session_poll(voiceTargetTab.session, 0);
            MicaUITestRunLoopFor(0.01);
        }
        NSString *rawHelperCalls = [NSString stringWithContentsOfFile:rawCallsPath
            encoding:NSUTF8StringEncoding error:nil];
        BOOL rawTranscriptInsertedWithoutCleanup = rawHelperReady &&
            rawVoiceController.state == MicaVoiceControllerStateIdle &&
            [rawHelperCalls isEqualToString:@"stream\n"] &&
            MicaUITestFindText(voiceTargetTab.session, @"MICA-RAW-TRANSCRIPT", NULL, NULL) &&
            !MicaUITestFindText(((MicaTab *)voiceDelegate.tabs[1]).session,
                @"MICA-RAW-TRANSCRIPT", NULL, NULL);
        MicaUITestRecord(report, &allPassed, rawTranscriptInsertedWithoutCleanup,
            [NSString stringWithFormat:@"raw speech result is inserted into the tab targeted when capture began without invoking cleanup or submitting it (calls=%@ status=%@)",
                rawHelperCalls, rawVoiceController.statusText]);
        mica_session_write(voiceTargetTab.session, "\x15", 1);
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
        [resizeDelegate addTabWithName:@"Resize" cwd:@"/tmp"
            command:@"python3 -c 'import fcntl,termios,struct,time\n"
                     "get=lambda:struct.unpack(\"HHHH\",fcntl.ioctl(0,termios.TIOCGWINSZ,b\"\\0\"*8))\n"
                     "old=get()[2]\n"
                     "print(\"MICA-RESIZE-READY\",flush=True)\n"
                     "end=time.time()+5\n"
                     "while time.time()<end:\n"
                     " new=get()[2]\n"
                     " if new!=old:\n"
                     "  print(\"MICA-RESIZE-PIXELS-UPDATED\",flush=True)\n"
                     "  old=new\n"
                     " time.sleep(.01)'"
            prefilled:NO];
        MicaTab *resizeTab = resizeDelegate.activeTab;
        [resizeView updateGridSize];
        BOOL resizeFixtureReady = NO;
        for (int attempt = 0; attempt < 200; attempt++) {
            mica_session_poll(resizeTab.session, 0);
            if (MicaUITestFindText(resizeTab.session, @"MICA-RESIZE-READY", NULL, NULL)) {
                resizeFixtureReady = YES;
                break;
            }
            usleep(10000);
        }
        NSInteger originalRows = mica_session_rows(resizeTab.session);
        NSInteger originalCols = mica_session_cols(resizeTab.session);
        CGFloat cellWidth = [@"M" sizeWithAttributes:@{
            NSFontAttributeName: resizeView.terminalFont
        }].width;
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
            MicaUITestCountText(resizeTab.session, @"MICA-RESIZE-PIXELS-UPDATED") == 0;
        resizeView.testInLiveResize = NO;
        [resizeView updateGridSize];
        for (int attempt = 0; attempt < 100 &&
             MicaUITestCountText(resizeTab.session, @"MICA-RESIZE-PIXELS-UPDATED") == 0; attempt++) {
            mica_session_poll(resizeTab.session, 10);
        }
        for (int repeat = 0; repeat < 3; repeat++) [resizeView updateGridSize];
        MicaUITestRunLoopFor(0.1);
        mica_session_poll(resizeTab.session, 0);
        NSUInteger pixelUpdatesAfterEnd = MicaUITestCountText(resizeTab.session,
            @"MICA-RESIZE-PIXELS-UPDATED");
        MicaUITestRecord(report, &allPassed, pixelResizeDeferred && pixelUpdatesAfterEnd == 1,
            [NSString stringWithFormat:@"pixel-only terminal dimensions stay stable during live resize and update once when it ends (deferred=%d final-updates=%lu rows=%ld/%ld cols=%ld/%ld)",
                pixelResizeDeferred, (unsigned long)pixelUpdatesAfterEnd,
                (long)mica_session_rows(resizeTab.session), (long)originalRows,
                (long)mica_session_cols(resizeTab.session), (long)originalCols]);
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
        MicaTab *agentLabelTab = delegate.tabs[0];
        NSString *savedCommand = agentLabelTab.currentCommand;
        NSString *savedName = agentLabelTab.name;
        agentLabelTab.currentCommand = @"codex";
        agentLabelTab.name = @"Codex";
        agentLabelTab.agentActivity = @"Working";
        agentLabelTab.agentActivityDetail = @"Ran make test";
        NSString *firstAgentLabel = [delegate displayNameForTab:agentLabelTab];
        agentLabelTab.agentActivityDetail = @"Read src/mica_app.m";
        NSString *updatedAgentLabel = [delegate displayNameForTab:agentLabelTab];
        BOOL agentTitleShowsAction = [firstAgentLabel isEqualToString:@"Codex · Ran make test"] &&
            [updatedAgentLabel isEqualToString:@"Codex · Read src/mica_app.m"];
        agentLabelTab.currentCommand = savedCommand;
        agentLabelTab.name = savedName;
        agentLabelTab.agentActivity = nil;
        agentLabelTab.agentActivityDetail = nil;
        MicaUITestRecord(report, &allPassed, agentTitleShowsAction,
            [NSString stringWithFormat:@"agent tab title follows action changes without elapsed-time noise (%@ → %@)",
                firstAgentLabel, updatedAgentLabel]);
        MicaUITestRecord(report, &allPassed, delegate.terminalView.terminalFont.pointSize >= 16,
                         @"default terminal font remains at least 16 points");
        MicaUITestRecord(report, &allPassed, kTabTitleFontSize <= 11.0 && kHeaderHeight <= 32.0,
                         @"tab titles use a compact 10.5-point system font and a 32-point header");
        NSDictionary *footerTextAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:10.5] };
        NSFont *footerFont = footerTextAttrs[NSFontAttributeName];
        MicaUITestRecord(report, &allPassed,
            fabs(MicaCenteredTextBaseline([NSFont systemFontOfSize:kTabTitleFontSize weight:NSFontWeightMedium], kHeaderHeight) -
                 MicaCenteredTextBaseline(footerFont, kStatusHeight)) < 0.01,
            @"tab labels and footer text share a vertically centered baseline");
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
        NSString *removedFolder = removedFolderRoot
            ? [NSString stringWithFormat:@"%s/deleted-project", removedFolderRoot] : nil;
        if (removedFolder) [[NSFileManager defaultManager] createDirectoryAtPath:removedFolder
            withIntermediateDirectories:NO attributes:nil error:nil];
        if (removedFolder) [[NSFileManager defaultManager] removeItemAtPath:removedFolder error:nil];
        NSString *recoveredFolder = removedFolder ? MicaUsableWorkingDirectory(removedFolder) : nil;
        NSString *expectedFolder = removedFolderRoot
            ? [NSString stringWithUTF8String:removedFolderRoot] : nil;
        MicaUITestRecord(report, &allPassed, [recoveredFolder isEqualToString:expectedFolder],
            [NSString stringWithFormat:@"a deleted project folder falls back to its nearest readable parent (resolved=%@ expected=%@)",
                recoveredFolder, expectedFolder]);
        if (removedFolderRoot) rmdir(removedFolderRoot);

        [delegate.terminalView updateGridSize];
        NSRect firstTabRect = [delegate.terminalView tabRectAtIndex:0];
        NSRect secondTabRect = [delegate.terminalView tabRectAtIndex:1];
        NSRect thirdTabRect = [delegate.terminalView tabRectAtIndex:2];
        BOOL equalTabWidths = fabs(firstTabRect.size.width - secondTabRect.size.width) < 0.01 &&
            fabs(secondTabRect.size.width - thirdTabRect.size.width) < 0.01 &&
            fabs(firstTabRect.origin.x) < 0.01 &&
            fabs(NSMaxX(firstTabRect) - NSMinX(secondTabRect)) < 0.01 &&
            fabs(NSMaxX(secondTabRect) - NSMinX(thirdTabRect)) < 0.01 &&
            fabs(NSMaxX(thirdTabRect) - delegate.terminalView.bounds.size.width) < 0.01;
        MicaUITestRecord(report, &allPassed, equalTabWidths,
                         @"tab hit areas split the complete window width into equal sections");
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
        BOOL rowDamageMappingWorks = NSPointInRect(NSMakePoint(5, NSMaxY(terminalAreaForDamage) - lineHeightForDamage * 1.5), mappedDirtyRect) &&
            NSPointInRect(NSMakePoint(5, NSMaxY(terminalAreaForDamage) - lineHeightForDamage * 2.5), mappedDirtyRect) &&
            !NSPointInRect(NSMakePoint(5, NSMaxY(terminalAreaForDamage) - lineHeightForDamage * 0.5), mappedDirtyRect) &&
            !NSPointInRect(NSMakePoint(5, NSMaxY(terminalAreaForDamage) - lineHeightForDamage * 3.5), mappedDirtyRect);
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
            [delegate.terminalView clearSelection];
            MicaUITestRecord(report, &allPassed, clickDoesNotSelect && tinyMoveDoesNotSelect && dragSelectsText,
                [NSString stringWithFormat:@"plain click and tiny pointer movement keep UI interaction clear while a real drag selects text (found=%d click=%d tiny=%d drag=%d)",
                 foundSelectableText, clickDoesNotSelect, tinyMoveDoesNotSelect, dragSelectsText]);
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
            NSRect voicePanel = [delegate.terminalView voiceOverlayRect];
            NSRect voiceAction = [delegate.terminalView voiceOverlayActionRect];
            MicaUITestRecord(report, &allPassed,
                !NSIsEmptyRect(voicePanel) && voicePanel.size.height >= 140 && NSIsEmptyRect(voiceAction),
                @"live dictation overlay reserves wrapped transcript space and has no Stop or Done button");
            NSMutableParagraphStyle *wrapStyle = [[NSMutableParagraphStyle alloc] init];
            wrapStyle.lineBreakMode = NSLineBreakByWordWrapping;
            NSAttributedString *wrapProbe = [[NSAttributedString alloc] initWithString:
                @"Change the Codex tab widths so all tabs fit in the window and show complete activity"
                attributes:@{ NSFontAttributeName: MicaTerminalFont(13), NSParagraphStyleAttributeName: wrapStyle }];
            CGRect wrapBounds = [wrapProbe boundingRectWithSize:NSMakeSize(260, 100)
                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
            MicaUITestRecord(report, &allPassed, wrapBounds.size.height >= 30,
                [NSString stringWithFormat:@"live transcript text wraps to multiple readable lines (height=%.1f)", wrapBounds.size.height]);
            NSBitmapImageRep *bitmap = [delegate.terminalView bitmapImageRepForCachingDisplayInRect:delegate.terminalView.bounds];
            if (bitmap) [delegate.terminalView cacheDisplayInRect:delegate.terminalView.bounds toBitmapImageRep:bitmap];
            BOOL bitmapReady = bitmap != nil;
            NSString *imagePath = NSProcessInfo.processInfo.environment[@"MICA_UI_SMOKE_IMAGE"] ?: @"build/ui-smoke.png";
            NSData *png = bitmap ? [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
            BOOL imageSaved = png && [png writeToFile:imagePath atomically:YES];
            MicaUITestRecord(report, &allPassed, bitmapReady && imageSaved,
                             [NSString stringWithFormat:@"offscreen AppKit render saved to %@", imagePath]);

            if (bitmapReady) {
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
                            if (MicaUITestCheckColor([bitmap colorAtX:x y:y], 0xd4d4d4)) orientationPixels++;
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
                            if (MicaUITestCheckColor([bitmap colorAtX:x y:y], 0x123456)) orientationPixels++;
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
                            if (!MicaUITestCheckColor(pixel, 0x1e1e1e)) orientationPixels++;
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
            "ready, _, _ = select.select([fd], [], [], 1)\n"
            "enter = os.read(fd, 1) if ready else b''\n"
            "termios.tcsetattr(fd, termios.TCSADRAIN, saved)\n"
            "valid_arrow = arrow.startswith((b'\\x1b[B', b'\\x1bOB')) and arrow[-1:] == b'B'\n"
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
            usleep(50000);
            MicaUITestSendKey(optionDelegate, @"\r", 0, 36);
        }
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
            optionPromptReady && optionSelectionWorked && optionSessionStopped,
            [NSString stringWithFormat:@"Claude-like previous-session picker accepts Down and Return through Mica's PTY (ready=%d selected=%d cleaned=%d screen=%@)",
                optionPromptReady, optionSelectionWorked, optionSessionStopped, optionScreen]);
        if (optionRoot) [[NSFileManager defaultManager] removeItemAtPath:optionRoot error:nil];

        char projectLayoutDirectory[] = "/tmp/mica-project-layouts-XXXXXX";
        NSString *projectLayoutRoot = mkdtemp(projectLayoutDirectory)
            ? [NSString stringWithUTF8String:projectLayoutDirectory] : nil;
        NSString *projectALayout = [projectLayoutRoot stringByAppendingPathComponent:@"alpha.mica"];
        NSString *projectBLayout = [projectLayoutRoot stringByAppendingPathComponent:@"beta.mica"];
        NSString *commandLayout = [projectLayoutRoot stringByAppendingPathComponent:@"commands.mica"];
        NSString *layoutCommandScript = [projectLayoutRoot stringByAppendingPathComponent:@"r.sh"];
        NSString *projectALayoutContents = @"# Mica layout v1\n"
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
            projectA = MicaResolveLaunchConfiguration(@[@"mica", @"--layout", projectALayout],
                @{@"MicaProjectName": @"Project Alpha", @"MicaProjectLayout": projectBLayout}, @"/tmp");
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
            [[projectATitle windowTitleForTab:projectATitleTab] containsString:@"Project Alpha"] &&
            [[projectBTitle windowTitleForTab:projectBTitleTab] containsString:@"Project Beta"] &&
            [projectA[@"activeIndex"] integerValue] == 0 &&
            [projectB[@"activeIndex"] integerValue] == 0;
        MicaUITestRecord(report, &allPassed, projectAppsIndependent,
                         [NSString stringWithFormat:@"per-project layouts resolve separate named tabs, commands and window titles (A=%lu/%@ B=%lu/%@)%@",
                          (unsigned long)projectATabs.count, projectAFirstTab[@"name"],
                          (unsigned long)projectBTabs.count, projectBFirstTab[@"name"],
                          projectLayoutError ? [NSString stringWithFormat:@" error: %@", projectLayoutError.localizedDescription] : @""]);

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
            NSString *runningLabel = [layoutDelegate displayNameForTab:configuredCommandTab];
            if (configuredCommandTab.currentCommand.length &&
                ![runningLabel isEqualToString:configuredCommandTab.name] &&
                [runningLabel containsString:@" · "])
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
            [[layoutDelegate displayNameForTab:configuredCommandTab] isEqualToString:@"Claude Code"];
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
            [NSString stringWithFormat:@"a layout opens a regular zsh tab, shows its running command and then restores the tab name (configured=%d prefilled=%d ran=%d label=%d reset=%d cleaned=%d screen=%@)",
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
            exitDelegate.terminalView.bounds.size.width / MAX(1, exitCharWidth));
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
