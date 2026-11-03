#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"
#import <ApplicationServices/ApplicationServices.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

@interface MicaTestNotificationContent : NSObject
@property(nonatomic, copy) NSDictionary *userInfo;
@end
@implementation MicaTestNotificationContent @end
@interface MicaTestNotificationRequest : NSObject
@property(nonatomic, strong) MicaTestNotificationContent *content;
@end
@implementation MicaTestNotificationRequest @end
@interface MicaTestNotification : NSObject
@property(nonatomic, strong) MicaTestNotificationRequest *request;
@end
@implementation MicaTestNotification @end
@interface MicaTestNotificationResponse : NSObject
@property(nonatomic, strong) MicaTestNotification *notification;
@end
@implementation MicaTestNotificationResponse @end

@interface MicaRedrawSpySidebar : MicaAgentSidebarView
@property(nonatomic) NSUInteger redrawRequests;
@end
@implementation MicaRedrawSpySidebar
- (void)setNeedsDisplay:(BOOL)flag { if (flag) self.redrawRequests++; [super setNeedsDisplay:flag]; }
@end

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

static NSString *MicaUITestZLEFile(NSString *directory, MicaSession *session, NSString *suffix) {
    return [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%d.%@", (int)mica_session_pid(session), suffix]];
}

static NSString *MicaUITestCaptureZLEBuffer(NSString *directory, MicaSession *session) {
    NSString *path = MicaUITestZLEFile(directory, session, @"buffer");
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

static BOOL MicaUITestExitTabs(NSArray<MicaTab *> *tabs) {
    // Let finite fixture commands release stdin before typing `exit`; otherwise
    // their output can appear ready while the shell still owns the PTY.
    NSDate *commandDeadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
    while ([commandDeadline timeIntervalSinceNow] > 0) {
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
    NSDate *exitDeadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
    while ([exitDeadline timeIntervalSinceNow] > 0) {
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

static int shortcutEnableCalls, shortcutDisableCalls;
static BOOL MicaUITestCountingRegistrar(BOOL enable) { if (enable) shortcutEnableCalls++; else shortcutDisableCalls++; return YES; }

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
        char projectLabelTemplate[] = "/tmp/mica-project-label-XXXXXX";
        char *projectLabelPath = mkdtemp(projectLabelTemplate);
        NSString *projectLabelRoot = projectLabelPath ? [NSString stringWithUTF8String:projectLabelPath] : nil;
        NSString *projectRepo = [projectLabelRoot stringByAppendingPathComponent:@"Mica Repo"];
        NSString *projectNested = [projectRepo stringByAppendingPathComponent:@"src/deep"];
        NSString *plainWorkspace = [projectLabelRoot stringByAppendingPathComponent:@"Loose Workspace"];
        BOOL projectLabelFixtures = projectLabelRoot.length &&
            [NSFileManager.defaultManager createDirectoryAtPath:[projectRepo stringByAppendingPathComponent:@".git"]
                withIntermediateDirectories:YES attributes:nil error:nil] &&
            [NSFileManager.defaultManager createDirectoryAtPath:projectNested
                withIntermediateDirectories:YES attributes:nil error:nil] &&
            [NSFileManager.defaultManager createDirectoryAtPath:plainWorkspace
                withIntermediateDirectories:YES attributes:nil error:nil];
        MicaAppDelegate *projectLabelOwner = [MicaAppDelegate new];
        MicaTab *projectLabelTab = [MicaTab new];
        projectLabelTab.name = @"Codex";
        projectLabelTab.cwd = projectNested;
        projectLabelTab.projectRoot = projectRepo;
        projectLabelOwner.projectName = nil;
        BOOL gitRootLabel = projectLabelFixtures &&
            [[projectLabelOwner projectDisplayNameForTab:projectLabelTab] isEqualToString:projectRepo.lastPathComponent] &&
            [MicaGitRootForDirectory(projectNested) isEqualToString:projectRepo] &&
            [[projectLabelOwner windowTitleForTab:projectLabelTab]
                isEqualToString:[NSString stringWithFormat:@"%@ — %@", projectRepo.lastPathComponent, MicaTabDisplayName(projectLabelTab)]];
        projectLabelOwner.projectName = @"Configured Project";
        BOOL configuredLabelWins = [[projectLabelOwner projectDisplayNameForTab:projectLabelTab]
            isEqualToString:@"Configured Project"];
        projectLabelOwner.projectName = nil;
        projectLabelTab.remoteProfile = @{ @"name": @"M1 Mac Mini" };
        BOOL sshLabel = [[projectLabelOwner projectDisplayNameForTab:projectLabelTab] isEqualToString:@"M1 Mac Mini"];
        projectLabelTab.remoteProfile = nil;
        projectLabelTab.projectRoot = nil;
        projectLabelTab.cwd = plainWorkspace;
        BOOL folderLabel = [[projectLabelOwner projectDisplayNameForTab:projectLabelTab]
            isEqualToString:plainWorkspace.lastPathComponent];
        projectLabelTab.cwd = NSHomeDirectory();
        BOOL homeStaysGeneric = [projectLabelOwner projectDisplayNameForTab:projectLabelTab] == nil;
        projectLabelTab.cwd = projectNested;
        projectLabelTab.projectRoot = projectRepo;
        projectLabelOwner.tabs = [NSMutableArray arrayWithObject:projectLabelTab];
        projectLabelOwner.activeIndex = 0;
        MicaTerminalView *projectLabelView = [[MicaTerminalView alloc] initWithFrame:NSMakeRect(0, 0, 900, 320)];
        projectLabelView.owner = projectLabelOwner;
        NSRect projectBadgeRect = [projectLabelView projectBadgeRect];
        NSString *projectBadgeTip = [projectLabelView view:projectLabelView stringForToolTip:0
            point:NSMakePoint(NSMidX(projectBadgeRect), NSMidY(projectBadgeRect)) userData:NULL];
        BOOL badgeIsVisibleAndReadable = projectBadgeRect.size.width >= 100 &&
            [projectBadgeTip isEqualToString:projectRepo.lastPathComponent];
        MicaUITestRecord(report, &allPassed,
            projectLabelFixtures && gitRootLabel && configuredLabelWins && sshLabel && folderLabel &&
            homeStaysGeneric && badgeIsVisibleAndReadable,
            [NSString stringWithFormat:@"project identity labels prefer settings, then Git root or folder, show an SSH name, and expose the full badge tooltip (git=%d configured=%d ssh=%d folder=%d home=%d badge=%@)",
                gitRootLabel, configuredLabelWins, sshLabel, folderLabel, homeStaysGeneric, projectBadgeTip ?: @"(missing)"]);
        if (projectLabelRoot) [NSFileManager.defaultManager removeItemAtPath:projectLabelRoot error:nil];
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
        MicaDiagnosticsSetEnabled(NO);
        MicaDiagnosticsLog(@"test", @"disabled diagnostic record");
        NSArray<NSURL *> *disabledDiagnosticFiles = diagnosticDirectoryCreated
            ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:
                [NSURL fileURLWithPath:[NSString stringWithUTF8String:diagnosticDirectoryPath] isDirectory:YES]
                includingPropertiesForKeys:nil options:0 error:nil] : @[];
        BOOL diagnosticsAreOffByDefault = disabledDiagnosticFiles.count == 0;
        MicaDiagnosticsSetEnabled(YES);
        MicaDiagnosticsInitialize();
        MicaDiagnosticsLog(@"test", @"startup diagnostic record");
        NSURL *diagnosticDirectory = MicaDiagnosticsLogDirectory();
        NSArray<NSURL *> *diagnosticFiles = diagnosticDirectory
            ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:diagnosticDirectory
                includingPropertiesForKeys:nil options:0 error:nil] : @[];
        NSString *diagnosticContents = diagnosticFiles.count
            ? [NSString stringWithContentsOfURL:diagnosticFiles.firstObject
                encoding:NSUTF8StringEncoding error:nil] : nil;
        MicaUITestRecord(report, &allPassed, diagnosticsAreOffByDefault && diagnosticDirectoryCreated && diagnosticFiles.count == 1 &&
            [diagnosticContents containsString:@"[test] startup diagnostic record"],
            @"diagnostics stay off until enabled, then write timestamped plain-text logs in an easy-to-open folder");

        char imeDirectoryTemplate[] = "/tmp/mica-ime-input-XXXXXX";
        char *imeDirectoryPath = mkdtemp(imeDirectoryTemplate);
        NSString *imeDirectory = imeDirectoryPath ? [NSString stringWithUTF8String:imeDirectoryPath] : nil;
        MicaAppDelegate *imeDelegate = [[MicaAppDelegate alloc] init];
        imeDelegate.tabs = [NSMutableArray array];
        imeDelegate.activeIndex = 0;
        imeDelegate.uiMode = MicaUIModeNormal;
        MicaUITestAttachWindow(imeDelegate);
        BOOL imePromptReady = imeDirectory.length > 0 &&
            setenv("MICA_TEST_ZLE_DIR", imeDirectory.fileSystemRepresentation, 1) == 0;
        if (imePromptReady)
            [imeDelegate addTabWithName:@"Composed input" cwd:@"/tmp" command:nil prefilled:NO];
        unsetenv("MICA_TEST_ZLE_DIR");
        MicaTab *imeTab = imeDelegate.activeTab;
        NSString *imeReadyPath = imeTab.session ? MicaUITestZLEFile(imeDirectory, imeTab.session, @"ready") : nil;
        for (int attempt = 0; imePromptReady && ![NSFileManager.defaultManager fileExistsAtPath:imeReadyPath] && attempt < 300; attempt++) {
            mica_session_poll(imeTab.session, 0);
            MicaUITestRunLoopFor(0.01);
        }
        imePromptReady = imePromptReady && [NSFileManager.defaultManager fileExistsAtPath:imeReadyPath];
        for (NSString *character in @[@"@", @"#", @"@", @"@"])
            if (imePromptReady) MicaUITestSendKey(imeDelegate, character, NSEventModifierFlagOption, 0);
        NSString *optionComposedBuffer = imePromptReady ? MicaUITestCaptureZLEBuffer(imeDirectory, imeTab.session) : nil;
        BOOL optionCompositionReachesShell = [optionComposedBuffer isEqualToString:@"@#@@"];
        MicaUITestRecord(report, &allPassed, imePromptReady && optionCompositionReachesShell,
            [NSString stringWithFormat:@"Option-composed punctuation reaches the shell as typed text (ready=%d buffer=%@)",
                imePromptReady, optionComposedBuffer ?: @"<missing>"]);
        // Ctrl-U clears the line without SIGINT, which could flush the queued `exit`.
        if (imeTab.session) mica_session_write(imeTab.session, "\x15", 1);
        BOOL imeSessionStopped = MicaUITestExitTabs(imeDelegate.tabs);
        MicaUITestRecord(report, &allPassed, imeSessionStopped, @"composed-input test shell exits cleanly");
        imeDelegate.tabs = [NSMutableArray array];
        [imeDelegate.window orderOut:nil];
        imeDelegate.terminalView = nil;
        imeDelegate.window = nil;
        if (imeDirectoryPath) [[NSFileManager defaultManager] removeItemAtPath:imeDirectory error:nil];

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
        delegate.windowContentView = [[MicaWindowContentView alloc] initWithFrame:delegate.window.contentView.bounds];
        delegate.windowContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        delegate.windowContentView.owner = delegate;
        delegate.windowContentView.terminalView = delegate.terminalView;
        [delegate.windowContentView addSubview:delegate.terminalView];
        [delegate.window setContentView:delegate.windowContentView];
        [delegate installMenus];

        NSMenu *sessionMenu = [NSApp.mainMenu itemWithTitle:@"Session"].submenu;
        NSMenuItem *quitMenuItem = [[NSApp.mainMenu itemWithTitle:@"Mica"].submenu
            itemWithTitle:@"Quit Mica"];
        NSMenuItem *newShellMenuItem = [sessionMenu itemWithTitle:@"New Shell Tab"];
        NSMenuItem *sshProfilesMenuItem = [sessionMenu itemWithTitle:@"SSH Connections…"];
        NSMenuItem *tabPickerMenuItem = [sessionMenu itemWithTitle:@"Choose Tab…"];
        NSMenuItem *scrollbackMenuItem = [sessionMenu itemWithTitle:@"Browse Scrollback"];
        NSMenuItem *selectOutputMenuItem = [[NSApp.mainMenu itemWithTitle:@"Edit"].submenu
            itemWithTitle:@"Select Last Command Output"];
        NSMenuItem *copyOutputMenuItem = [[NSApp.mainMenu itemWithTitle:@"Edit"].submenu
            itemWithTitle:@"Copy Last Command Output"];
        NSMenu *helpMenu = [NSApp.mainMenu itemWithTitle:@"Help"].submenu;
        NSMenuItem *diagnosticLogsMenuItem = [helpMenu itemWithTitle:@"Open Diagnostic Logs"];
        NSMenuItem *shortcutsMenuItem = [helpMenu itemWithTitle:@"Keyboard Shortcuts…"];
        NSMenuItem *paletteMenuItem = [helpMenu itemWithTitle:@"Command Palette…"];
        NSMenu *editMenu = [NSApp.mainMenu itemWithTitle:@"Edit"].submenu;
        NSMenuItem *quickSelectMenuItem = [editMenu itemWithTitle:@"Quick Select…"];
        [delegate openPreferences:nil];
        MicaUITestRecord(report, &allPassed,
                         newShellMenuItem.target == delegate &&
                         sshProfilesMenuItem.target == delegate &&
                         [newShellMenuItem.keyEquivalent isEqualToString:@"t"] &&
                         (newShellMenuItem.keyEquivalentModifierMask & NSEventModifierFlagCommand) != 0 &&
                         tabPickerMenuItem.keyEquivalent.length == 0 &&
                         [scrollbackMenuItem.keyEquivalent isEqualToString:@"s"] &&
                         selectOutputMenuItem.target == delegate.terminalView &&
                         copyOutputMenuItem.target == delegate.terminalView &&
                         (scrollbackMenuItem.keyEquivalentModifierMask &
                          (NSEventModifierFlagCommand | NSEventModifierFlagShift)) ==
                            (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
                         diagnosticLogsMenuItem.target == delegate &&
                         quickSelectMenuItem.target == delegate.terminalView && quickSelectMenuItem.isEnabled &&
                         paletteMenuItem.target == delegate &&
                         [paletteMenuItem.keyEquivalent isEqualToString:@"p"] &&
                         (paletteMenuItem.keyEquivalentModifierMask &
                          (NSEventModifierFlagCommand | NSEventModifierFlagShift)) ==
                            (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
                         shortcutsMenuItem.target == delegate &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Start Focus"].target == delegate &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Pause/Resume Focus"].target == delegate &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Skip Phase"].target == delegate &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Take Break"].target == delegate &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Start Focus"].isEnabled &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Pause/Resume Focus"].isEnabled &&
                         ![delegate validateMenuItem:[[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Skip Phase"]] &&
                         [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Timer Settings…"].target == delegate &&
                         [shortcutsMenuItem.keyEquivalent isEqualToString:@"/"] &&
                         (shortcutsMenuItem.keyEquivalentModifierMask & NSEventModifierFlagCommand) != 0 &&
                         [quitMenuItem.keyEquivalent isEqualToString:@"q"] &&
                         (quitMenuItem.keyEquivalentModifierMask & NSEventModifierFlagCommand) != 0 &&
                         [sessionMenu itemWithTitle:@"New Claude Code Tab"] == nil &&
                         [sessionMenu itemWithTitle:@"New Codex Tab"] == nil,
                         @"smoke: shipped menu actions exist and are enabled when applicable");

        NSString *recentMenuDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"mica-recent-menu-%@", NSUUID.UUID.UUIDString]];
        const char *oldRecentLayoutsValue = getenv("MICA_TEST_LAYOUTS_DIRECTORY");
        NSString *oldRecentLayoutsDirectory = oldRecentLayoutsValue ? @(oldRecentLayoutsValue) : nil;
        [NSFileManager.defaultManager createDirectoryAtPath:recentMenuDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("MICA_TEST_LAYOUTS_DIRECTORY", recentMenuDirectory.fileSystemRepresentation, 1);
        NSString *validRecentLayout = [recentMenuDirectory stringByAppendingPathComponent:@"Ready.mica"];
        [@"# Mica layout v1\n# Mica project: Ready\nReady tab\t/private/tmp\t\n"
            writeToFile:validRecentLayout atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *missingRecentLayout = [recentMenuDirectory stringByAppendingPathComponent:@"Missing.mica"];
        NSString *recentMenuSuite = [NSString stringWithFormat:@"MicaRecentMenuTests.%@", NSUUID.UUID.UUIDString];
        NSUserDefaults *oldRecentMenuDefaults = gMicaDefaultsOverride;
        NSUserDefaults *recentMenuDefaults = [[NSUserDefaults alloc] initWithSuiteName:recentMenuSuite];
        NSArray<MicaAppDelegate *> *oldRecentMenuControllers = [MicaControllers() copy];
        [MicaControllers() removeAllObjects];
        [MicaControllers() addObject:delegate];
        [delegate takeMenuOwnership];
        gMicaDefaultsOverride = recentMenuDefaults;
        MicaProjectHistory *recentMenuHistory = MicaRecentProjectHistory();
        [recentMenuHistory clear];
        [recentMenuHistory recordLayoutPath:missingRecentLayout name:@"Missing Project"];
        [recentMenuHistory recordLayoutPath:validRecentLayout name:@"Ready Project"];
        [delegate menuNeedsUpdate:gRecentProjectsMenu];
        NSMenu *recentMenu = [[NSApp.mainMenu itemWithTitle:@"Mica"].submenu itemWithTitle:@"Recent Projects"].submenu;
        [recentMenu update];
        NSMenuItem *readyProjectItem = recentMenu.itemArray.count > 0 ? recentMenu.itemArray[0] : nil;
        NSMenuItem *missingProjectItem = recentMenu.itemArray.count > 1 ? recentMenu.itemArray[1] : nil;
        NSMenuItem *clearRecentMenuItem = [recentMenu itemWithTitle:@"Clear Recent Projects"];
        BOOL recentMenuRowsValid = [readyProjectItem.title isEqualToString:@"Ready Project"] &&
            [missingProjectItem.title isEqualToString:@"Missing Project"] && readyProjectItem.isEnabled &&
            !missingProjectItem.isEnabled && clearRecentMenuItem.isEnabled;
        [recentMenuHistory clear];
        [delegate menuNeedsUpdate:gRecentProjectsMenu];
        [recentMenu update];
        NSMenuItem *emptyRecentMenuItem = recentMenu.itemArray.count > 0 ? recentMenu.itemArray[0] : nil;
        clearRecentMenuItem = [recentMenu itemWithTitle:@"Clear Recent Projects"];
        BOOL recentMenuEmptyStateValid = [emptyRecentMenuItem.title isEqualToString:@"No Recent Projects"] &&
            !emptyRecentMenuItem.isEnabled && !clearRecentMenuItem.isEnabled;
        [recentMenuHistory recordLayoutPath:missingRecentLayout name:@"Missing Project"];
        [recentMenuHistory recordLayoutPath:validRecentLayout name:@"Ready Project"];
        [delegate menuNeedsUpdate:gRecentProjectsMenu];
        [recentMenu update];
        clearRecentMenuItem = [recentMenu itemWithTitle:@"Clear Recent Projects"];
        [delegate clearRecentProjects:clearRecentMenuItem];
        [recentMenu update];
        BOOL clearRecentProjectsWorks = recentMenuHistory.projects.count == 0 &&
            [recentMenu.itemArray.firstObject.title isEqualToString:@"No Recent Projects"] &&
            ![recentMenu itemWithTitle:@"Clear Recent Projects"].isEnabled;
        gMicaDefaultsOverride = oldRecentMenuDefaults;
        [MicaControllers() removeAllObjects];
        [MicaControllers() addObjectsFromArray:oldRecentMenuControllers];
        [MicaControllers().firstObject takeMenuOwnership];
        [recentMenuDefaults removePersistentDomainForName:recentMenuSuite];
        if (oldRecentLayoutsDirectory) setenv("MICA_TEST_LAYOUTS_DIRECTORY", oldRecentLayoutsDirectory.fileSystemRepresentation, 1);
        else unsetenv("MICA_TEST_LAYOUTS_DIRECTORY");
        [NSFileManager.defaultManager removeItemAtPath:recentMenuDirectory error:nil];
        MicaUITestRecord(report, &allPassed,
            recentMenuRowsValid && recentMenuEmptyStateValid && clearRecentProjectsWorks,
            [NSString stringWithFormat:@"Recent Projects menu orders history, validates missing layouts, shows an empty state and clears history (rows=%d empty=%d clear=%d)",
                recentMenuRowsValid, recentMenuEmptyStateValid, clearRecentProjectsWorks]);

        NSString *sshProfileSuite = [NSString stringWithFormat:@"mica-ssh-profiles-%d", getpid()];
        NSUserDefaults *sshProfileDefaults = [[NSUserDefaults alloc] initWithSuiteName:sshProfileSuite];
        [sshProfileDefaults removePersistentDomainForName:sshProfileSuite];
        NSUserDefaults *priorDefaultsOverride = gMicaDefaultsOverride;
        gMicaDefaultsOverride = sshProfileDefaults;
        [delegate openSSHProfiles:nil];
        MicaSSHProfilesController *sshManager = delegate.sshProfilesController;
        NSTableColumn *sshNameColumn = [sshManager.tableView tableColumnWithIdentifier:@"name"];
        NSTableColumn *sshDestinationColumn = [sshManager.tableView tableColumnWithIdentifier:@"destination"];
        NSTableColumn *sshDirectoryColumn = [sshManager.tableView tableColumnWithIdentifier:@"remoteDirectory"];
        [sshManager addProfile:nil];
        [sshManager.tableView.window makeFirstResponder:sshManager.tableView];
        [sshManager tableView:sshManager.tableView setObjectValue:@"M1 Mac Mini"
            forTableColumn:sshNameColumn row:0];
        [sshManager tableView:sshManager.tableView setObjectValue:@"mini"
            forTableColumn:sshDestinationColumn row:0];
        [sshManager tableView:sshManager.tableView setObjectValue:@"~/Projects/Mica"
            forTableColumn:sshDirectoryColumn row:0];
        [sshManager save:nil];
        NSDictionary *sshStored = [sshProfileDefaults dictionaryForKey:@"MicaSSHProfiles"];
        NSDictionary *sshSavedProfile = [sshStored[@"profiles"] firstObject];
        BOOL sshProfileSaved = [sshStored[@"version"] integerValue] == 1 &&
            [sshSavedProfile[@"name"] isEqualToString:@"M1 Mac Mini"] &&
            [sshSavedProfile[@"destination"] isEqualToString:@"mini"] &&
            [sshSavedProfile[@"remoteDirectory"] isEqualToString:@"~/Projects/Mica"] &&
            [sshSavedProfile[@"id"] isKindOfClass:NSString.class];
        [delegate openSSHProfiles:nil];
        MicaSSHProfilesController *reopenedSSHManager = delegate.sshProfilesController;
        BOOL sshProfileReopened = reopenedSSHManager.rows.count == 1 &&
            [reopenedSSHManager.rows[0][@"destination"] isEqualToString:@"mini"] &&
            reopenedSSHManager.tableView.numberOfColumns == 3;
        [reopenedSSHManager cancel:nil];
        gMicaDefaultsOverride = priorDefaultsOverride;
        [sshProfileDefaults removePersistentDomainForName:sshProfileSuite];
        MicaUITestRecord(report, &allPassed, sshProfileSaved && sshProfileReopened,
            [NSString stringWithFormat:@"SSH profile manager saves and restores bounded, versioned profile records (saved=%d reopened=%d)",
                sshProfileSaved, sshProfileReopened]);

        MicaAppDelegate *landmarkUIDelegate = [[MicaAppDelegate alloc] init];
        landmarkUIDelegate.tabs = [NSMutableArray array];
        landmarkUIDelegate.activeIndex = 0;
        landmarkUIDelegate.uiMode = MicaUIModeNormal;
        MicaUITestAttachWindow(landmarkUIDelegate);
        MicaTab *landmarkUITab = [MicaTab new];
        landmarkUITab.name = @"Landmarks";
        landmarkUITab.cwd = @"/tmp";
        landmarkUITab.session = mica_session_create("/tmp",
            "printf '\\033]133;A\\033\\\\'; printf '\\033]133;C\\033\\\\'; "
            "printf 'MICA-OUTPUT-FIXTURE\\n'; printf '\\033]133;D;0\\033\\\\'; "
            "printf '\\033]133;A\\033\\\\'; sleep 1", 8, 80);
        [landmarkUIDelegate.tabs addObject:landmarkUITab];
        [landmarkUIDelegate.terminalView updateGridSize];
        BOOL commandOutputFinished = NO;
        NSDate *landmarkDeadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
        while (!commandOutputFinished && [landmarkDeadline timeIntervalSinceNow] > 0) {
            mica_session_poll(landmarkUITab.session, 10);
            BOOL hasFinishedMark = NO;
            for (int row = 0; row < mica_session_rows(landmarkUITab.session); row++) {
                if (mica_session_row_landmark(landmarkUITab.session, row, NULL) & MICA_LANDMARK_FINISHED) {
                    hasFinishedMark = YES;
                    break;
                }
            }
            commandOutputFinished = hasFinishedMark &&
                mica_session_osc133_state(landmarkUITab.session) == 'A' &&
                MicaUITestFindText(landmarkUITab.session, @"MICA-OUTPUT-FIXTURE", NULL, NULL);
            usleep(10000);
        }
        [landmarkUIDelegate.terminalView selectLastCommandOutput:nil];
        BOOL outputSelected = landmarkUIDelegate.terminalView.hasTextSelection;
        __block NSString *copiedOutput = @"";
        landmarkUIDelegate.terminalView.testCopyHandler = ^(NSString *text) { copiedOutput = text; };
        [landmarkUIDelegate.terminalView copyLastCommandOutput:nil];
        uint64_t revisionBeforeJump = mica_session_revision(landmarkUITab.session);
        MicaUITestSendKey(landmarkUIDelegate, @"↑", NSEventModifierFlagCommand, 126);
        BOOL previousPromptJumped = mica_session_revision(landmarkUITab.session) > revisionBeforeJump;
        MicaUITestRecord(report, &allPassed, outputSelected && [copiedOutput containsString:@"MICA-OUTPUT-FIXTURE"] && previousPromptJumped,
            [NSString stringWithFormat:@"last command output selects and copies, and Command-Up moves to a prior shell prompt (selected=%d copied=%d jumped=%d)",
                outputSelected, [copiedOutput containsString:@"MICA-OUTPUT-FIXTURE"], previousPromptJumped]);
        MicaUITestExitTabs(landmarkUIDelegate.tabs);

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
        for (int attempt = 0; attempt < 20 &&
             MicaUITestCountText(resizeTab.session, @"MICA-RESIZE-PIXELS-UPDATED") == updatesBeforeAXResize; attempt++) {
            MicaUITestRunLoopFor(0.05);
            mica_session_poll(resizeTab.session, 10);
        }
        NSUInteger updatesAfterAXResize = MicaUITestCountText(resizeTab.session,
            @"MICA-RESIZE-PIXELS-UPDATED");
        BOOL programmaticResizeCoalesced = programmaticResizeDeferred &&
            updatesAfterAXResize == updatesBeforeAXResize + 1;
        MicaUITestRecord(report, &allPassed, programmaticResizeCoalesced,
            [NSString stringWithFormat:@"programmatic window resizes defer and coalesce terminal PTY size changes (deferred=%d updates=%lu→%lu frame=%@ cell=%.2f grid=%ldx%ld)",
                programmaticResizeDeferred, (unsigned long)updatesBeforeAXResize,
                (unsigned long)updatesAfterAXResize, NSStringFromRect(resizeView.frame), cellWidth,
                (long)mica_session_cols(resizeTab.session), (long)mica_session_rows(resizeTab.session)]);
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
        NSRect sidebarOriginalWindowFrame = delegate.window.frame;
        NSInteger columnsBeforeSidebarResize = mica_session_cols(delegate.activeTab.session);
        NSRect widerSidebarFrame = sidebarOriginalWindowFrame; widerSidebarFrame.size.width = 1200;
        [delegate.window setFrame:widerSidebarFrame display:YES];
        [delegate.windowContentView setNeedsLayout:YES]; [delegate.windowContentView layoutSubtreeIfNeeded];
        [delegate resizeActiveSession];
        for (int attempt = 0; attempt < 40 && mica_session_cols(delegate.activeTab.session) <= columnsBeforeSidebarResize; attempt++)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        NSInteger sidebarOriginalIndex = delegate.activeIndex;
        MicaTab *sidebarResizeTab = delegate.activeTab;
        NSString *savedFixtureCommand = fixtureTab.currentCommand;
        NSString *savedFixtureActivity = fixtureTab.agentActivity;
        BOOL savedFixtureAttention = fixtureTab.needsAttention;
        NSString *savedAgentState = fixtureTab.agentState;
        NSString *savedAgentMessage = fixtureTab.agentLastMessage;
        BOOL savedReceivedAgentHook = fixtureTab.receivedAgentHook;
        NSMenuItem *sidebarMenuItem = [[NSApp.mainMenu itemWithTitle:@"View"].submenu itemWithTitle:@"Show Sidebar"];
        BOOL sidebarDefaultOff = !delegate.sidebarVisible && delegate.windowContentView.sidebarView == nil &&
            sidebarMenuItem != nil && sidebarMenuItem.state == NSControlStateValueOff;
        NSInteger sidebarOriginalCols = mica_session_cols(sidebarResizeTab.session);
        [delegate toggleSidebar:nil];
        BOOL sidebarVisible = delegate.sidebarVisible && delegate.windowContentView.sidebarView != nil &&
            delegate.terminalView.frame.origin.x == 220 && delegate.terminalView.bounds.size.width < delegate.windowContentView.bounds.size.width &&
            [sidebarMenuItem.title isEqualToString:@"Hide Sidebar"] && sidebarMenuItem.state == NSControlStateValueOn;
        NSString *savedFixtureAgentKind = fixtureTab.agentKind;
        uint64_t savedFixtureRSS = fixtureTab.agentRSSBytes;
        NSUInteger rssOwnerOriginalIndex = [MicaControllers() indexOfObject:delegate];
        if (rssOwnerOriginalIndex == NSNotFound) {
            [MicaControllers() insertObject:delegate atIndex:0];
        } else if (rssOwnerOriginalIndex > 0) {
            [MicaControllers() removeObjectAtIndex:rssOwnerOriginalIndex];
            [MicaControllers() insertObject:delegate atIndex:0];
        }
        MicaAppDelegate *rssOwner = delegate;
        [rssOwner updateAgentRSSTimer];
        BOOL sidebarArmsRSSSampling = rssOwner.agentRSSTimer != nil;
        id savedRSSPreference = [[rssOwner micaDefaults] objectForKey:@"MicaAgentRSSWarningGB"];
        [[rssOwner micaDefaults] setInteger:2 forKey:@"MicaAgentRSSWarningGB"];
        fixtureTab.agentKind = @"codex";
        rssOwner.agentRSSMonitor = [MicaAgentRSSMonitor new];
        rssOwner.agentRSSMonitor.sampler = ^uint64_t(pid_t pid) { (void)pid; return 3ULL * 1024 * 1024 * 1024; };
        NSDictionary *directRSSSamples = [rssOwner.agentRSSMonitor sampleTabs:@[fixtureTab]];
        [rssOwner agentRSSTimerFired:nil];
        NSUInteger fixtureIndexForRSS = [delegate.tabs indexOfObject:fixtureTab];
        NSArray *rssAccessibilityRows = [delegate.windowContentView.sidebarView accessibilityChildren];
        NSString *rssAccessibility = fixtureIndexForRSS < rssAccessibilityRows.count ?
            [rssAccessibilityRows[fixtureIndexForRSS] accessibilityLabel] : @"";
        BOOL rssSidebarAndWarning = fixtureTab.agentRSSBytes == 3ULL * 1024 * 1024 * 1024 &&
            [rssAccessibility containsString:@"3.0 GB memory"] &&
            [MicaAttention().events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) {
                (void)bindings; return [event[@"tabID"] unsignedLongLongValue] == fixtureTab.identifier &&
                    [event[@"kind"] integerValue] == MicaAttentionHighMemory;
            }]].count == 1;
        uint64_t rssObservedBytes = fixtureTab.agentRSSBytes;
        NSUInteger rssObservedAlerts = [MicaAttention().events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) {
            (void)bindings; return [event[@"tabID"] unsignedLongLongValue] == fixtureTab.identifier &&
                [event[@"kind"] integerValue] == MicaAttentionHighMemory;
        }]].count;
        fixtureTab.agentKind = savedFixtureAgentKind;
        fixtureTab.agentRSSBytes = savedFixtureRSS;
        if (savedRSSPreference) [[rssOwner micaDefaults] setObject:savedRSSPreference forKey:@"MicaAgentRSSWarningGB"];
        else [[rssOwner micaDefaults] removeObjectForKey:@"MicaAgentRSSWarningGB"];
        if (rssOwnerOriginalIndex == NSNotFound) {
            [MicaControllers() removeObject:delegate];
        } else if (rssOwnerOriginalIndex > 0) {
            [MicaControllers() removeObject:delegate];
            [MicaControllers() insertObject:delegate atIndex:MIN(rssOwnerOriginalIndex, MicaControllers().count)];
        }
        [MicaAttention() clearTabID:fixtureTab.identifier];
        [rssOwner updateAgentRSSTimer];
        fixtureTab.currentCommand = @"codex"; fixtureTab.agentActivity = @"Needs input"; fixtureTab.needsAttention = YES;
        [delegate.windowContentView.sidebarView refreshRows];
        MicaRedrawSpySidebar *sidebarRedrawProbe = [MicaRedrawSpySidebar new];
        sidebarRedrawProbe.owner = delegate;
        [sidebarRedrawProbe refreshRows];
        [sidebarRedrawProbe refreshRows];
        BOOL unchangedSidebarSkipsRedraw = sidebarRedrawProbe.redrawRequests == 1;
        fixtureTab.receivedAgentHook = YES;
        NSArray<NSString *> *agentStates = @[@"idle", @"working", @"waitingPermission", @"waitingInput", @"done", @"error"];
        NSArray<NSString *> *agentStateLabels = @[@"Idle", @"Working", @"Needs permission", @"Needs input", @"Done", @"Error"];
        BOOL allAgentStatesAccessible = YES;
        for (NSUInteger stateIndex = 0; stateIndex < agentStates.count; stateIndex++) {
            fixtureTab.agentState = agentStates[stateIndex];
            NSString *stateLabel = [[[delegate.windowContentView.sidebarView accessibilityChildren] firstObject] accessibilityLabel];
            if (![stateLabel containsString:agentStateLabels[stateIndex]]) allAgentStatesAccessible = NO;
        }
        fixtureTab.agentState = @"working";
        NSString *longAgentMessage = [@"preview " stringByPaddingToLength:100 withString:@"x" startingAtIndex:0];
        fixtureTab.agentLastMessage = longAgentMessage;
        NSString *previewLabel = [[[delegate.windowContentView.sidebarView accessibilityChildren] firstObject] accessibilityLabel];
        NSString *expectedPreview = [[longAgentMessage substringToIndex:79] stringByAppendingString:@"…"];
        BOOL previewTruncates = [previewLabel containsString:expectedPreview] && ![previewLabel containsString:longAgentMessage];
        MicaRedrawSpySidebar *modelChangeProbe = [MicaRedrawSpySidebar new];
        modelChangeProbe.owner = delegate;
        [modelChangeProbe refreshRows]; [modelChangeProbe refreshRows];
        fixtureTab.agentState = @"done"; [modelChangeProbe refreshRows];
        BOOL changedAgentStateRedrawsOnce = modelChangeProbe.redrawRequests == 2;
        fixtureTab.agentLastMessage = @"updated preview"; [modelChangeProbe refreshRows];
        BOOL changedAgentMessageRedrawsOnce = modelChangeProbe.redrawRequests == 3;
        fixtureTab.agentState = @"waitingInput";
        NSArray *sidebarElements = [delegate.windowContentView.sidebarView accessibilityChildren];
        BOOL sidebarStateAccessible = sidebarElements.count == delegate.tabs.count &&
            [sidebarElements[0] accessibilityLabel].length && [[sidebarElements[0] accessibilityLabel] containsString:@"Needs input"] &&
            [[sidebarElements[0] accessibilityLabel] containsString:@"unread attention"];
        ((MicaTabAccessibilityElement *)sidebarElements[1]).pressHandler();
        NSArray *selectedSidebarElements = [delegate.windowContentView.sidebarView accessibilityChildren];
        BOOL sidebarActivationSelects = delegate.activeIndex == 1 &&
            [[selectedSidebarElements[1] accessibilityLabel] containsString:@"selected"] &&
            ![[selectedSidebarElements[0] accessibilityLabel] containsString:@"selected"];
        [delegate selectTabAtIndex:sidebarOriginalIndex];
        MicaAppDelegate *otherSidebarWindow = [MicaAppDelegate new];
        otherSidebarWindow.tabs = [NSMutableArray array]; otherSidebarWindow.activeIndex = 0;
        otherSidebarWindow.windowContentView = [[MicaWindowContentView alloc] initWithFrame:NSMakeRect(0, 0, 700, 400)];
        otherSidebarWindow.windowContentView.owner = otherSidebarWindow;
        otherSidebarWindow.terminalView = [MicaTerminalView new]; otherSidebarWindow.terminalView.owner = otherSidebarWindow;
        otherSidebarWindow.windowContentView.terminalView = otherSidebarWindow.terminalView;
        [otherSidebarWindow.windowContentView addSubview:otherSidebarWindow.terminalView];
        [otherSidebarWindow toggleSidebar:nil];
        BOOL sidebarWindowIsolation = otherSidebarWindow.sidebarVisible && delegate.sidebarVisible;
        NSInteger resizedSidebarCols = mica_session_cols(sidebarResizeTab.session);
        for (int attempt = 0; attempt < 40 && resizedSidebarCols >= sidebarOriginalCols; attempt++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            resizedSidebarCols = mica_session_cols(sidebarResizeTab.session);
        }
        BOOL sidebarResizePreservesPTY = sidebarOriginalCols > resizedSidebarCols && fixtureReady &&
            MicaUITestFindText(fixtureTab.session, @"UI-TRUECOLOR", NULL, NULL);
        [delegate toggleSidebar:nil];
        [rssOwner updateAgentRSSTimer];
        BOOL hiddenSidebarDisarmsRSSSampling = rssOwner.agentRSSTimer == nil;
        for (int attempt = 0; attempt < 40 && mica_session_cols(sidebarResizeTab.session) < sidebarOriginalCols; attempt++)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        BOOL sidebarHiddenReleasesView = !delegate.sidebarVisible && delegate.windowContentView.sidebarView == nil &&
            delegate.terminalView.frame.origin.x == 0 && mica_session_cols(sidebarResizeTab.session) >= sidebarOriginalCols &&
            [sidebarMenuItem.title isEqualToString:@"Show Sidebar"] && sidebarMenuItem.state == NSControlStateValueOff;
        [delegate.window setFrame:sidebarOriginalWindowFrame display:YES];
        [delegate.windowContentView setNeedsLayout:YES]; [delegate.windowContentView layoutSubtreeIfNeeded];
        [delegate resizeActiveSession];
        [otherSidebarWindow toggleSidebar:nil];
        fixtureTab.currentCommand = savedFixtureCommand;
        fixtureTab.agentActivity = savedFixtureActivity;
        fixtureTab.needsAttention = savedFixtureAttention;
        fixtureTab.agentState = savedAgentState;
        fixtureTab.agentLastMessage = savedAgentMessage;
        fixtureTab.receivedAgentHook = savedReceivedAgentHook;
        [delegate selectTabAtIndex:sidebarOriginalIndex];
        MicaUITestRecord(report, &allPassed, sidebarDefaultOff && sidebarVisible && rssSidebarAndWarning && sidebarStateAccessible && sidebarActivationSelects &&
            sidebarWindowIsolation && sidebarResizePreservesPTY && sidebarHiddenReleasesView,
            [NSString stringWithFormat:@"optional sidebar is per-window, exposes fake agent attention state, selects tabs, resizes the PTY without losing fixture output, and releases hidden views (visible=%d accessible=%d select=%d isolated=%d resize=%ld→%ld hidden=%d)",
                sidebarDefaultOff && sidebarVisible, sidebarStateAccessible, sidebarActivationSelects, sidebarWindowIsolation,
                (long)sidebarOriginalCols, (long)resizedSidebarCols, sidebarHiddenReleasesView]);
        MicaUITestRecord(report, &allPassed, unchangedSidebarSkipsRedraw,
            @"sidebar refresh skips redraw requests when row state is unchanged");
        MicaUITestRecord(report, &allPassed, rssSidebarAndWarning,
            [NSString stringWithFormat:@"visible sidebar samples Claude/Codex RSS, exposes the reading to VoiceOver, and posts a threshold alert (bytes=%llu direct=%@ index=%lu label=%@ alerts=%lu controller=%lu root=%d)",
                (unsigned long long)rssObservedBytes, directRSSSamples, (unsigned long)fixtureIndexForRSS, rssAccessibility, (unsigned long)rssObservedAlerts,
                (unsigned long)MicaControllers().count, MicaControllers().firstObject == delegate]);
        MicaUITestRecord(report, &allPassed, sidebarArmsRSSSampling && hiddenSidebarDisarmsRSSSampling,
            [NSString stringWithFormat:@"RSS sampling timer follows sidebar visibility (sidebar=%d hidden=%d)",
                sidebarArmsRSSSampling, hiddenSidebarDisarmsRSSSampling]);
        MicaUITestRecord(report, &allPassed, allAgentStatesAccessible && previewTruncates && changedAgentMessageRedrawsOnce,
            [NSString stringWithFormat:@"sidebar exposes each agent state and truncated message, and redraws once for state/message changes (states=%d preview=%d state-redraw=%d message-redraw=%d)",
                allAgentStatesAccessible, previewTruncates, changedAgentStateRedrawsOnce, changedAgentMessageRedrawsOnce]);
        NSString *agentDetail = nil;
        NSString *agentActivity = MicaAgentActivityForSession(fixtureTab.session, &agentDetail);
        MicaUITestRecord(report, &allPassed, [agentActivity isEqualToString:@"Working"] &&
            [agentDetail containsString:@"Explored src directory"],
            [NSString stringWithFormat:@"agent progress reads the active phase and keeps a recent action for the tooltip (phase=%@ detail=%@)",
                agentActivity, agentDetail]);
        NSString *savedAgentTitleFixtureKind = fixtureTab.agentKind;
        NSString *savedAgentTitleFixtureState = fixtureTab.agentState;
        BOOL savedAgentTitleReceivedHook = fixtureTab.receivedAgentHook;
        fixtureTab.agentKind = @"claude";
        fixtureTab.receivedAgentHook = YES;
        fixtureTab.agentState = @"working";
        NSString *workingTabTitle = [delegate.terminalView displayLabelForTab:fixtureTab];
        fixtureTab.agentState = @"waitingInput";
        NSString *waitingTabTitle = [delegate.terminalView displayLabelForTab:fixtureTab];
        NSRect agentTabRect = [delegate.terminalView tabRectAtIndex:(NSUInteger)[delegate.tabs indexOfObjectIdenticalTo:fixtureTab]];
        NSString *agentTabTip = [delegate.terminalView view:delegate.terminalView
            stringForToolTip:0 point:NSMakePoint(NSMidX(agentTabRect), NSMidY(agentTabRect)) userData:NULL];
        BOOL agentTabTitlesShowState = [workingTabTitle isEqualToString:@"Claude · Work"] &&
            [waitingTabTitle isEqualToString:@"Claude · Input"] &&
            [agentTabTip containsString:@"Claude Code status: Needs input"];
        fixtureTab.agentKind = savedAgentTitleFixtureKind;
        fixtureTab.agentState = savedAgentTitleFixtureState;
        fixtureTab.receivedAgentHook = savedAgentTitleReceivedHook;
        MicaUITestRecord(report, &allPassed, agentTabTitlesShowState,
            [NSString stringWithFormat:@"agent tab titles show compact Claude state and the tooltip gives the full state (work=%@ input=%@ tip=%@)",
                workingTabTitle, waitingTabTitle, agentTabTip]);
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
            waitingPromptFound && [waitingActivity isEqualToString:@"Idle"],
            @"generic shell prose does not become agent input state without an agent prompt glyph and UI marker");
        if (waitingProbe) mica_session_destroy(waitingProbe);
        MicaSession *codexIdleProbe = mica_session_create("/tmp",
            "printf 'Ask Codex to do anything\\n'; sleep 2", 6, 80);
        BOOL codexIdleTextFound = NO;
        for (int attempt = 0; codexIdleProbe && attempt < 100; attempt++) {
            mica_session_poll(codexIdleProbe, 10);
            if (MicaUITestFindText(codexIdleProbe, @"Ask Codex to do anything", NULL, NULL)) {
                codexIdleTextFound = YES; break;
            }
        }
        NSString *codexIdleActivity = codexIdleProbe ? MicaAgentActivityForSession(codexIdleProbe, NULL) : nil;
        MicaUITestRecord(report, &allPassed, codexIdleTextFound &&
            ![codexIdleActivity isEqualToString:@"Needs input"] && ![codexIdleActivity isEqualToString:@"Needs approval"],
            [NSString stringWithFormat:@"Codex idle prompt remains idle (activity=%@)", codexIdleActivity]);
        if (codexIdleProbe) mica_session_destroy(codexIdleProbe);
        MicaTab *plainShellTab = [MicaTab new]; plainShellTab.currentCommand = @"sh";
        plainShellTab.agentActivity = @"Running tests";
        MicaUITestRecord(report, &allPassed, MicaAgentNameForTab(plainShellTab) == nil,
            @"plain shell prose such as running tests does not identify an agent");
        MicaSession *codexPermissionProbe = mica_session_create("/tmp",
            "printf '\\033[5;1H\\342\\235\\257 ALLOW THIS COMMAND?\\n'; sleep 2", 6, 80);
        BOOL codexPermissionTextFound = NO;
        for (int attempt = 0; codexPermissionProbe && attempt < 100; attempt++) {
            mica_session_poll(codexPermissionProbe, 10);
            if (MicaUITestFindText(codexPermissionProbe, @"ALLOW THIS COMMAND?", NULL, NULL)) {
                codexPermissionTextFound = YES; break;
            }
        }
        NSString *codexPermissionActivity = codexPermissionProbe
            ? MicaAgentActivityForSession(codexPermissionProbe, NULL) : nil;
        MicaTab *codexPermissionTab = [MicaTab new];
        codexPermissionTab.session = codexPermissionProbe;
        codexPermissionTab.currentCommand = @"codex";
        codexPermissionTab.processAgentKind = @"codex";
        codexPermissionTab.agentActivity = codexPermissionActivity;
        BOOL codexPermissionWaiting = [delegate.terminalView activityStateForTab:codexPermissionTab] == MicaTabActivityStateWaiting;
        MicaUITestRecord(report, &allPassed, codexPermissionTextFound &&
            [codexPermissionActivity isEqualToString:@"Needs approval"] && codexPermissionWaiting,
            [NSString stringWithFormat:@"process-identified Codex permission fixture requests approval (activity=%@)", codexPermissionActivity]);
        if (codexPermissionProbe) mica_session_destroy(codexPermissionProbe);
        codexPermissionTab.session = NULL;
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
            glyphPromptFound && [glyphPromptActivity isEqualToString:@"Idle"],
            [NSString stringWithFormat:@"a prompt glyph alone does not imply that an agent needs input (found=%d activity=%@ screen=%@)",
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
        agentLabelTab.needsAttention = NO;   // attention is cleared by output events now, not timer ticks
        agentLabelTab.currentCommand = @"codex";
        agentLabelTab.name = @"Codex";
        agentLabelTab.agentActivity = @"Working";
        agentLabelTab.lastOutputReadAt = NSProcessInfo.processInfo.systemUptime;
        NSString *firstAgentLabel = [delegate.terminalView labelForTab:agentLabelTab];
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
        NSString *updatedAgentLabel = [delegate.terminalView labelForTab:agentLabelTab];
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
        NSMutableArray<NSString *> *agentNotificationTitles = [NSMutableArray array];
        delegate.testAgentNotificationHandler = ^(NSString *title, NSString *body, MicaTab *tab) {
            (void)body; (void)tab;
            [agentNotificationTitles addObject:title ?: @""];
        };
        [MicaAttention() clearTabID:agentLabelTab.identifier];
        void (^savedAttentionDelivery)(NSDictionary *) = MicaAttention().delivery;
        MicaAttention().delivery = ^(NSDictionary *event) {
            for (MicaTab *candidate in delegate.tabs) if (candidate.identifier == [event[@"tabID"] unsignedLongLongValue])
                delegate.testAgentNotificationHandler(event[@"title"] ?: @"Mica", event[@"body"] ?: @"", candidate);
        };
        agentLabelTab.completionLabel = @"codex";
        BOOL waitingTitle = [[delegate agentNotificationTitleForTab:agentLabelTab waiting:YES] isEqual:@"Codex needs input"];
        BOOL finishedTitle = [[delegate agentNotificationTitleForTab:agentLabelTab waiting:NO] isEqual:@"Codex finished"];
        NSMenu *muteMenu = [delegate notificationMenuForTab:agentLabelTab];
        NSMenuItem *muteItem = muteMenu.itemArray.firstObject;
        BOOL muteMenuStartsOff = muteItem.state == NSControlStateValueOff;
        [delegate toggleMuteNotificationsForTab:muteItem];
        agentLabelTab.needsAttention = YES;
        [MicaAttention() setMuted:agentLabelTab.muteNotifications tabID:agentLabelTab.identifier];
        [MicaAttention() postTabID:agentLabelTab.identifier kind:MicaAttentionWaitingInput
            title:[delegate agentNotificationTitleForTab:agentLabelTab waiting:YES] body:@"please continue" muted:NO];
        BOOL muteSuppressesNotice = agentNotificationTitles.count == 0;
        BOOL mutedBadgeRemains = [delegate.terminalView activityStateForTab:agentLabelTab] == MicaTabActivityStateNeedsAttention;
        NSMenu *mutedMenu = [delegate notificationMenuForTab:agentLabelTab];
        BOOL muteMenuShowsOn = [mutedMenu.itemArray.firstObject state] == NSControlStateValueOn;
        [delegate toggleMuteNotificationsForTab:mutedMenu.itemArray.firstObject];
        [MicaAttention() setMuted:agentLabelTab.muteNotifications tabID:agentLabelTab.identifier];
        [MicaAttention() postTabID:agentLabelTab.identifier kind:MicaAttentionWaitingInput
            title:[delegate agentNotificationTitleForTab:agentLabelTab waiting:YES] body:@"please continue" muted:NO];
        [MicaAttention() postTabID:agentLabelTab.identifier kind:MicaAttentionDone
            title:[delegate agentNotificationTitleForTab:agentLabelTab waiting:NO] body:@"work complete" muted:NO];
        NSArray *mutePaletteRows = [delegate paletteRows];
        NSUInteger mutePaletteIndex = [mutePaletteRows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger idx, BOOL *stop) {
            (void)idx; (void)stop;
            return [row[@"kind"] isEqual:@"mute"] && [row[@"title"] hasPrefix:@"Mute notifications for"] &&
                [row[@"tabID"] unsignedLongLongValue] == agentLabelTab.identifier;
        }];
        BOOL paletteCanMute = mutePaletteIndex != NSNotFound;
        if (paletteCanMute) {
            delegate.commandPaletteRows = mutePaletteRows;
            delegate.commandPaletteTable = [NSTableView new];
            [delegate.commandPaletteTable addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"name"]];
            delegate.commandPaletteTable.dataSource = (id)delegate;
            delegate.commandPaletteTable.delegate = (id)delegate;
            [delegate.commandPaletteTable reloadData];
            [delegate.commandPaletteTable selectRowIndexes:[NSIndexSet indexSetWithIndex:mutePaletteIndex] byExtendingSelection:NO];
            [delegate runCommandPaletteSelection:nil];
            paletteCanMute = agentLabelTab.muteNotifications;
            agentLabelTab.muteNotifications = NO;
        }
        MicaUITestRecord(report, &allPassed, waitingTitle && finishedTitle && muteMenuStartsOff && muteMenuShowsOn &&
            muteSuppressesNotice && mutedBadgeRemains && paletteCanMute && [agentNotificationTitles isEqual:@[@"Codex needs input", @"Codex finished"]],
            [NSString stringWithFormat:@"agent notices label waiting and finished states; per-tab mute suppresses notices while preserving the badge (titles=%@ mute=%d/%d badge=%d palette=%d)",
                agentNotificationTitles, muteMenuStartsOff, muteMenuShowsOn, mutedBadgeRemains, paletteCanMute]);
        delegate.testAgentNotificationHandler = nil;
        MicaAttention().delivery = savedAttentionDelivery;
        NSDictionary *attentionProbe = @{@"tabID": @(agentLabelTab.identifier), @"kind": @(MicaAttentionDone),
            @"title": @"Done", @"body": @"Finished"};
        UNMutableNotificationContent *attentionContent = MicaNotificationContentForAttention(attentionProbe);
        BOOL notificationDeliveryPolicy = MicaShouldDeliverAttention(NO, YES) &&
            MicaShouldDeliverAttention(YES, NO) && !MicaShouldDeliverAttention(YES, YES);
        BOOL notificationHasNoSound = attentionContent.sound == nil &&
            [attentionContent.userInfo[@"tabID"] unsignedLongLongValue] == agentLabelTab.identifier &&
            [attentionContent.userInfo[@"kind"] integerValue] == MicaAttentionDone;
        MicaUITestRecord(report, &allPassed, notificationDeliveryPolicy && notificationHasNoSound,
            @"attention notifications deliver only when inactive or away from the key window tab, carry stable IDs and kind, and have no sound");
        agentLabelTab.needsAttention = NO;
        agentLabelTab.completionLabel = nil;
        MicaUITestRecord(report, &allPassed, delegate.terminalView.terminalFont.pointSize >= 16,
                         @"default terminal font remains at least 16 points");
        MicaUITestRecord(report, &allPassed, kTabTitleFontSize == 12.0 && kHeaderHeight == 36.0,
                         @"tab titles use a readable 12-point system font in a 36-point two-line header");
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
            MicaAppDelegate *quickDelegate = [MicaAppDelegate new];
            quickDelegate.tabs = [NSMutableArray array]; quickDelegate.activeIndex = 0;
            MicaTab *quickTab = [MicaTab new]; quickTab.name=@"Quick Select"; quickTab.cwd=@"/tmp";
            quickTab.session = mica_session_create("/tmp", NULL, 12, 38);
            [quickDelegate.tabs addObject:quickTab];
            char quickPath[]="/tmp/mica quick select fixture"; int quickFD=open(quickPath,O_CREAT|O_WRONLY|O_TRUNC,0600); if(quickFD>=0) close(quickFD);
            NSMutableString *quickOutput=[NSMutableString stringWithString:@"padding-xxxxxxxxxxxxxxxx https://quick.select.test/wrapped-url\n\"/tmp/mica quick select fixture\" /tmp/mica-no-such-quick-path "];
            for (unsigned i=0;i<30;i++) [quickOutput appendFormat:@"%08x ",0xabc00000u+i];
            mica_session_test_feed_output(quickTab.session, quickOutput.UTF8String, quickOutput.length);
            quickDelegate.terminalView=[MicaTerminalView new]; quickDelegate.terminalView.owner=quickDelegate;
            [quickDelegate.terminalView toggleQuickSelect:nil];
            NSDate *quickDeadline=[NSDate dateWithTimeIntervalSinceNow:0.75];
            while (!quickDelegate.terminalView.quickSelectActive && [quickDeadline timeIntervalSinceNow] > 0)
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            NSArray *quickMatches=quickDelegate.terminalView.quickSelectMatches ?: @[];
            NSDictionary *wrappedURL=[quickMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == %@",@"url"]].firstObject;
            BOOL quickHasWrappedURL=wrappedURL && [wrappedURL[@"value"] isEqualToString:@"https://quick.select.test/wrapped-url"];
            BOOL quickQuotedPath=[quickMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == %@ AND value == %@",@"path",[NSString stringWithUTF8String:quickPath]]].count==1;
            BOOL quickRejectsUnquoted=[quickMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"value CONTAINS %@",@"mica-no-such-quick-path"]].count==0;
            BOOL quickHasHash= [quickMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == %@",@"hash"]].count==30;
            BOOL quickUniqueLabels=[NSSet setWithArray:[quickMatches valueForKey:@"label"]].count==quickMatches.count &&
                [[quickMatches.lastObject objectForKey:@"label"] isEqualToString:@"AF"];
            NSDictionary *firstQuick=[quickDelegate.terminalView.quickSelectMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == %@",@"url"]].firstObject;
            [quickDelegate.terminalView finishQuickSelectWithLabel:firstQuick[@"label"] option:NO];
            BOOL quickCopies=quickDelegate.terminalView.testClipboardText.length>0;
            __block NSURL *quickRevealed=nil; quickDelegate.terminalView.testRevealURLHandler=^(NSURL *url){quickRevealed=url;};
            [quickDelegate.terminalView toggleQuickSelect:nil];
            quickDeadline=[NSDate dateWithTimeIntervalSinceNow:0.75];
            while (!quickDelegate.terminalView.quickSelectActive && [quickDeadline timeIntervalSinceNow] > 0)
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            wrappedURL=[quickDelegate.terminalView.quickSelectMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == %@",@"url"]].firstObject;
            [quickDelegate.terminalView finishQuickSelectWithLabel:wrappedURL[@"label"] option:YES];
            BOOL quickOptionOpens=[quickRevealed.absoluteString isEqualToString:@"https://quick.select.test/wrapped-url"];
            MicaUITestRecord(report,&allPassed,quickHasWrappedURL && quickQuotedPath && quickRejectsUnquoted && quickHasHash && quickUniqueLabels && quickCopies && quickOptionOpens,
                [NSString stringWithFormat:@"Quick Select detects wrapped URLs, quoted existing paths and hashes, rejects unquoted missing paths, assigns unique labels past Z, copies by default and opens with Option (url=%d path=%d reject=%d hashes=%lu labels=%d copy=%d option=%d)",quickHasWrappedURL,quickQuotedPath,quickRejectsUnquoted,(unsigned long)[quickMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == %@",@"hash"]].count,quickUniqueLabels,quickCopies,quickOptionOpens]);
            [quickTab destroySession]; unlink(quickPath);

            MicaUITestSendKey(delegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
            BOOL paletteOpens = delegate.commandPalettePanel != nil && delegate.uiMode == MicaUIModeNormal;
            BOOL paletteAccessibility = [delegate.commandPaletteSearch.accessibilityLabel isEqualToString:@"Search actions and tabs"] &&
                [delegate.commandPaletteTable.accessibilityLabel isEqualToString:@"Command palette results"];
            NSArray *initialTabRows = [delegate.commandPaletteRows filteredArrayUsingPredicate:
                [NSPredicate predicateWithFormat:@"kind == %@", @"tab"]];
            BOOL activeTabFirst = initialTabRows.count == 3 && [initialTabRows.firstObject[@"tabID"] unsignedLongLongValue] == [delegate.tabs[0] identifier];
            [delegate selectTabAtIndex:1];
            NSArray *recentTabRows = [[delegate paletteRows] filteredArrayUsingPredicate:
                [NSPredicate predicateWithFormat:@"kind == %@", @"tab"]];
            BOOL recentTabFirst = recentTabRows.count == 3 && [recentTabRows.firstObject[@"tabID"] unsignedLongLongValue] == [delegate.tabs[1] identifier];
            [delegate selectTabAtIndex:0];
            [delegate filterCommandPalette:nil];
            NSInteger indexBeforePaletteAction = delegate.activeIndex;
            delegate.commandPaletteSearch.stringValue = @"Next Tab";
            [delegate filterCommandPalette:nil];
            BOOL filterFindsAction = delegate.commandPaletteRows.count >= 1 &&
                [delegate.commandPaletteRows.firstObject[@"title"] isEqualToString:@"Next Tab"];
            [delegate runCommandPaletteSelection:nil];
            BOOL paletteRunsAction = delegate.activeIndex == (indexBeforePaletteAction + 1) % (NSInteger)delegate.tabs.count;
            [delegate selectTabAtIndex:indexBeforePaletteAction];
            delegate.commandPaletteSearch = nil;
            MicaUITestSendKey(delegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
            delegate.commandPaletteSearch.stringValue = @"Second tmp";
            [delegate filterCommandPalette:nil];
            BOOL filterFindsTab = delegate.commandPaletteRows.count == 1 &&
                [delegate.commandPaletteRows.firstObject[@"kind"] isEqualToString:@"tab"];
            MicaPaletteRowView *accessibleTabRow = (MicaPaletteRowView *)[delegate tableView:delegate.commandPaletteTable rowViewForRow:0];
            BOOL tabRowAccessible = [accessibleTabRow.accessibilityLabel containsString:@"Go to tab tmp"];
            [delegate runCommandPaletteSelection:nil];
            BOOL paletteSwitchesTab = delegate.activeIndex == 1;
            MicaPaletteSearchField *paletteSearch = (MicaPaletteSearchField *)delegate.commandPaletteSearch;
            NSEvent *escapeEvent = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                timestamp:0 windowNumber:delegate.commandPalettePanel.windowNumber context:nil characters:@"\033"
                charactersIgnoringModifiers:@"\033" isARepeat:NO keyCode:53];
            [paletteSearch keyDown:escapeEvent];
            BOOL escapeCloses = delegate.commandPalettePanel == nil;
            MicaUITestRecord(report, &allPassed, paletteOpens && paletteAccessibility && activeTabFirst && recentTabFirst && filterFindsAction &&
                paletteRunsAction && filterFindsTab && tabRowAccessible && paletteSwitchesTab && escapeCloses,
                [NSString stringWithFormat:@"Command-Shift-P opens an accessible per-window action/tab palette; filtering, action dispatch, tab switching and Escape work (open=%d a11y=%d mru=%d/%d action-filter=%d action=%d tab-filter=%d row-label=%d switch=%d escape=%d)",
                 paletteOpens, paletteAccessibility, activeTabFirst, recentTabFirst, filterFindsAction, paletteRunsAction, filterFindsTab, tabRowAccessible, paletteSwitchesTab, escapeCloses]);

            MicaAppDelegate *isolatedPalette = [[MicaAppDelegate alloc] init];
            [isolatedPalette toggleCommandPalette:nil];
            BOOL twoWindowIsolation = isolatedPalette.commandPalettePanel != nil && delegate.commandPalettePanel == nil;
            [isolatedPalette toggleCommandPalette:nil];
            MicaUITestRecord(report, &allPassed, twoWindowIsolation,
                @"palette window state is isolated");

            [delegate selectTabAtIndex:0];
            [delegate toggleTabPicker];
            MicaUITestSendKey(delegate, @"l", 0, 37);
            BOOL nextTabWorked = delegate.activeIndex == 1 && delegate.uiMode == MicaUIModeTab;
            MicaUITestSendKey(delegate, @"j", 0, 38);
            BOOL secondNavigationWorked = delegate.activeIndex == 2;
            [delegate toggleTabPicker];
            MicaUITestRecord(report, &allPassed, nextTabWorked && secondNavigationWorked && delegate.uiMode == MicaUIModeNormal,
                             @"Choose Tab menu, hjkl navigation and return to normal mode work");

            [delegate toggleTabPicker];
            MicaUITestSendKey(delegate, @"1", 0, 18);
            BOOL digitJumpWorked = delegate.activeIndex == 0 && delegate.uiMode == MicaUIModeNormal;
            [delegate toggleTabPicker];
            MicaUITestSendKey(delegate, @"n", 0, 45);
            BOOL newTabWorked = delegate.tabs.count == 4 && delegate.activeIndex == 3 && delegate.uiMode == MicaUIModeNormal;
            [delegate toggleTabPicker];
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
            for (int attempt = 0; attempt < 500; attempt++) {
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
            MicaUITestRunLoopFor(0.05);
            [delegate.terminalView paste:nil];
            BOOL imagePasteWorked = NO;
            for (int attempt = 0; imageReaderReady && attempt < 500; attempt++) {
                mica_session_poll(imageTab.session, 0);
                if (MicaUITestFindText(imageTab.session, @"22", NULL, NULL) &&
                    MicaUITestFindTextAcrossWrappedRows(imageTab.session, @"IMAGE-ROUTE-OK")) {
                    imagePasteWorked = YES;
                    break;
                }
                usleep(10000);
            }
            MicaUITestRecord(report, &allPassed, imageReaderReady && imagePasteWorked,
                [NSString stringWithFormat:@"image paste forwards Ctrl-V without reading or storing clipboard image data (ready=%d bitmap=%d bytes=%lu focus=%d running=%d screen=%@)",
                    imageReaderReady, clipboardPNG != nil, (unsigned long)clipboardPNG.length,
                    delegate.window.firstResponder == delegate.terminalView, mica_session_is_running(imageTab.session),
                    MicaUITestScreenTail(imageTab.session)]);
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
            NSPopUpButton *themePopUp = (NSPopUpButton *)[preferences.contentView viewWithTag:102];
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
                [NSString stringWithFormat:@"Theme offers Dark, Light and System; follows appearance changes (offers=%d light=%d system-light=%d system-dark=%d window-dark=%d app=%@ effective=%@)",
                    preferencesOffer, lightApplied, systemLightApplied, systemDarkApplied,
                    [delegate.window.appearance.name isEqualToString:NSAppearanceNameDarkAqua],
                    NSApp.appearance.name, NSApp.effectiveAppearance.name]);
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
            MicaTab *savedTab = [MicaTab new]; savedTab.name = @"Remembered"; savedTab.cwd = safeTempFolder;
            savedTab.command = @"printf MICA_RESTORED"; savedTab.muteNotifications = YES;
            savedTab.agentKind = @"claude"; savedTab.agentSessionID = @"session-1234";
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
                [savedState[@"tabs"][0][@"command"] isEqual:@"printf MICA_RESTORED"] &&
                [savedState[@"tabs"][0][@"agentKind"] isEqual:@"claude"] &&
                [savedState[@"tabs"][0][@"agentSessionID"] isEqual:@"session-1234"] &&
                [savedState[@"tabs"][0][@"muteNotifications"] boolValue];
            NSDictionary *stateAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:statePath error:nil];
            NSDictionary *directoryAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:stateDirectory error:nil];
            BOOL privateStatePermissions = [stateAttributes[NSFilePosixPermissions] unsignedShortValue] == 0600 &&
                [directoryAttributes[NSFilePosixPermissions] unsignedShortValue] == 0700;
            NSString *explicitLayoutPath = [stateDirectory stringByAppendingPathComponent:@"Explicit.mica"];
            [@"# Mica layout v1\n# Mica project: Explicit\nExplicit tab\t/private/tmp\t\n"
                writeToFile:explicitLayoutPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            MicaAppDelegate *explicitProjectOwner = [MicaAppDelegate new];
            explicitProjectOwner.tabs = [NSMutableArray array]; explicitProjectOwner.activeIndex = 0;
            [explicitProjectOwner loadLaunchConfigurationFromArguments:@[@"mica", @"--layout", explicitLayoutPath]
                                                              bundleInfo:@{}];
            BOOL explicitProjectSkipsSavedWindows = explicitProjectOwner.tabs.count == 1 &&
                [explicitProjectOwner.projectName isEqualToString:@"Explicit"] &&
                [explicitProjectOwner.activeTab.name isEqualToString:@"Explicit tab"] &&
                ![explicitProjectOwner.activeTab.name isEqualToString:@"Remembered"];
            for (NSValue *value in [explicitProjectOwner detachSessionsForTermination]) mica_session_destroy(value.pointerValue);

            NSString *layoutsDirectory = [stateDirectory stringByAppendingPathComponent:@"layouts"];
            [NSFileManager.defaultManager createDirectoryAtPath:layoutsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *(^writeProjectLayout)(NSString *, NSString *) = ^NSString *(NSString *fileName, NSString *projectName) {
                NSString *path = [layoutsDirectory stringByAppendingPathComponent:fileName];
                NSString *contents = [NSString stringWithFormat:@"# Mica layout v1\n# Mica project: %@\n%@ tab\t%@\t\n",
                    projectName, projectName, stateDirectory];
                [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                return path;
            };
            NSString *layoutA = writeProjectLayout(@"A.mica", @"Project A");
            NSString *layoutB = writeProjectLayout(@"B.mica", @"Project B");
            NSString *layoutC = writeProjectLayout(@"C.mica", @"Project C");
            NSString *layoutD = writeProjectLayout(@"D.mica", @"Project D");
            const char *oldLayoutsEnvironment = getenv("MICA_TEST_LAYOUTS_DIRECTORY");
            NSString *oldLayoutsDirectory = oldLayoutsEnvironment ? @(oldLayoutsEnvironment) : nil;
            setenv("MICA_TEST_LAYOUTS_DIRECTORY", layoutsDirectory.fileSystemRepresentation, 1);
            NSUserDefaults *oldDefaultsOverride = gMicaDefaultsOverride;
            NSString *launchDefaultsSuite = [NSString stringWithFormat:@"MicaLaunchTests.%@", NSUUID.UUID.UUIDString];
            NSUserDefaults *launchDefaults = [[NSUserDefaults alloc] initWithSuiteName:launchDefaultsSuite];
            gMicaDefaultsOverride = launchDefaults;
            id standardRecentProjectsBeforeLaunch = [NSUserDefaults.standardUserDefaults objectForKey:@"MicaRecentProjects"];

            NSDictionary *(^savedWindow)(NSString *, NSString *) = ^NSDictionary *(NSString *layout, NSString *projectName) {
                return @{@"layout":layout, @"projectName":projectName,
                         @"tabs":@[@{@"name":projectName, @"cwd":stateDirectory}]};
            };
            NSDictionary *launchState = @{@"version":@1, @"windows":@[savedWindow(layoutB, @"Project B"),
                                                                            savedWindow(layoutD, @"Project D")]};
            [[NSJSONSerialization dataWithJSONObject:launchState options:0 error:nil] writeToFile:statePath atomically:YES];
            NSMutableArray<NSURL *> *pendingLayouts = MicaPendingOpenURLs();
            NSArray<NSURL *> *oldPendingLayouts = [pendingLayouts copy];
            [pendingLayouts removeAllObjects];
            [pendingLayouts addObjectsFromArray:@[[NSURL fileURLWithPath:layoutA], [NSURL fileURLWithPath:layoutC]]];
            [MicaControllers() removeAllObjects];
            MicaAppDelegate *explicitLaunchDelegate = [MicaAppDelegate new];
            [explicitLaunchDelegate applicationDidFinishLaunching:nil];
            NSMutableSet<NSString *> *explicitLaunchProjects = [NSMutableSet set];
            for (MicaAppDelegate *controller in MicaControllers())
                if (controller.projectName.length) [explicitLaunchProjects addObject:controller.projectName];
            BOOL explicitLaunchOnlyOpensRequestedProjects = MicaControllers().count == 2 &&
                [explicitLaunchProjects isEqualToSet:[NSSet setWithArray:@[@"Project A", @"Project C"]]];
            NSArray<NSDictionary<NSString *, NSString *> *> *explicitLaunchHistory = MicaRecentProjectHistory().projects;
            BOOL explicitLaunchRecordsHistoryNewestFirst = explicitLaunchHistory.count == 2 &&
                [explicitLaunchHistory[0][@"name"] isEqualToString:@"Project C"] &&
                [explicitLaunchHistory[0][@"path"] isEqualToString:layoutC] &&
                [explicitLaunchHistory[1][@"name"] isEqualToString:@"Project A"] &&
                [explicitLaunchHistory[1][@"path"] isEqualToString:layoutA];
            for (MicaAppDelegate *controller in [MicaControllers() copy]) {
                for (NSValue *value in [controller detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
                controller.window.delegate = nil; [controller.window orderOut:nil]; [controller.window close];
            }
            [MicaControllers() removeAllObjects]; [pendingLayouts removeAllObjects];

            [[NSJSONSerialization dataWithJSONObject:launchState options:0 error:nil] writeToFile:statePath atomically:YES];
            MicaAppDelegate *plainLaunchDelegate = [MicaAppDelegate new];
            [plainLaunchDelegate applicationDidFinishLaunching:nil];
            NSMutableSet<NSString *> *restoredLaunchProjects = [NSMutableSet set];
            for (MicaAppDelegate *controller in MicaControllers())
                if (controller.projectName.length) [restoredLaunchProjects addObject:controller.projectName];
            BOOL plainLaunchRestoresSavedProjects = MicaControllers().count == 2 &&
                [restoredLaunchProjects isEqualToSet:[NSSet setWithArray:@[@"Project B", @"Project D"]]];
            id standardRecentProjectsAfterLaunch = [NSUserDefaults.standardUserDefaults objectForKey:@"MicaRecentProjects"];
            BOOL standardRecentProjectsUnchanged = standardRecentProjectsBeforeLaunch == nil
                ? standardRecentProjectsAfterLaunch == nil
                : [standardRecentProjectsBeforeLaunch isEqual:standardRecentProjectsAfterLaunch];
            BOOL plainRestoreDoesNotRecordRecentProjects = [MicaRecentProjectHistory().projects isEqualToArray:explicitLaunchHistory] &&
                standardRecentProjectsUnchanged;
            for (MicaAppDelegate *controller in [MicaControllers() copy]) {
                for (NSValue *value in [controller detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
                controller.window.delegate = nil; [controller.window orderOut:nil]; [controller.window close];
            }
            [MicaControllers() removeAllObjects];
            {
                // Reopening a layout with a saved window restores that window's tabs, once.
                NSDictionary *reopenState = @{@"version":@1, @"windows":@[
                    @{@"layout":layoutA, @"projectName":@"Project A", @"tabs":@[@{@"name":@"Saved A1", @"cwd":stateDirectory},
                                                                                  @{@"name":@"Saved A2", @"cwd":stateDirectory}]},
                    savedWindow(layoutB, @"Project B")]};
                [[NSJSONSerialization dataWithJSONObject:reopenState options:0 error:nil] writeToFile:statePath atomically:YES];
                MicaAppDelegate *reopened = [MicaAppDelegate new];
                reopened.tabs = [NSMutableArray array]; reopened.activeIndex = 0;
                [reopened loadLaunchConfigurationFromArguments:@[@"mica", @"--layout", layoutA] bundleInfo:@{}];
                BOOL restoresSavedTabs = reopened.tabs.count == 2 && [reopened.tabs[0].name isEqualToString:@"Saved A1"] &&
                    [reopened.projectName isEqualToString:@"Project A"];
                [MicaControllers() addObject:reopened];
                MicaAppDelegate *second = [MicaAppDelegate new];
                second.tabs = [NSMutableArray array]; second.activeIndex = 0;
                [second loadLaunchConfigurationFromArguments:@[@"mica", @"--layout", layoutA] bundleInfo:@{}];
                BOOL secondOpenIsFresh = second.tabs.count == 1 && [second.tabs[0].name isEqualToString:@"Project A tab"];
                [MicaControllers() removeAllObjects];
                for (MicaAppDelegate *owner in @[reopened, second])
                    for (NSValue *value in [owner detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
                [pendingLayouts removeAllObjects]; [pendingLayouts addObject:[NSURL fileURLWithPath:layoutA]];
                MicaAppDelegate *launchWithFile = [MicaAppDelegate new];
                [launchWithFile applicationDidFinishLaunching:nil];
                BOOL launchHasNoDuplicate = MicaControllers().count == 1 && launchWithFile.tabs.count == 2 &&
                    [launchWithFile.tabs[1].name isEqualToString:@"Saved A2"];
                for (MicaAppDelegate *controller in [MicaControllers() copy]) {
                    for (NSValue *value in [controller detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
                    controller.window.delegate = nil; [controller.window orderOut:nil]; [controller.window close];
                }
                [MicaControllers() removeAllObjects];
                MicaUITestRecord(report, &allPassed, restoresSavedTabs && secondOpenIsFresh && launchHasNoDuplicate,
                    [NSString stringWithFormat:@"opening a layout restores its saved window's tabs once, without a duplicate window (restored=%d secondFresh=%d launch=%d)",
                        restoresSavedTabs, secondOpenIsFresh, launchHasNoDuplicate]);
            }
            [MicaControllers() addObjectsFromArray:savedControllers];
            [pendingLayouts removeAllObjects]; [pendingLayouts addObjectsFromArray:oldPendingLayouts];
            gMicaDefaultsOverride = oldDefaultsOverride;
            [launchDefaults removePersistentDomainForName:launchDefaultsSuite];
            if (oldLayoutsDirectory) setenv("MICA_TEST_LAYOUTS_DIRECTORY", oldLayoutsDirectory.fileSystemRepresentation, 1);
            else unsetenv("MICA_TEST_LAYOUTS_DIRECTORY");
            [rawState writeToFile:statePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSMutableDictionary *legacyWindow = [savedState mutableCopy];
            NSMutableDictionary *legacyTab = [[legacyWindow[@"tabs"] firstObject] mutableCopy];
            [legacyTab removeObjectForKey:@"agentKind"]; [legacyTab removeObjectForKey:@"agentSessionID"];
            legacyWindow[@"tabs"] = @[legacyTab];
            NSDictionary *legacyState = @{@"version":@1, @"windows":@[legacyWindow]};
            [[NSJSONSerialization dataWithJSONObject:legacyState options:0 error:nil] writeToFile:statePath atomically:YES];
            MicaAppDelegate *restoredStateOwner = [MicaAppDelegate new];
            restoredStateOwner.tabs = [NSMutableArray array]; restoredStateOwner.activeIndex = 0;
            [restoredStateOwner loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            BOOL restoredSession = restoredStateOwner.tabs.count == 1 &&
                [restoredStateOwner.activeTab.name isEqual:@"Remembered"] &&
                [restoredStateOwner.activeTab.cwd isEqual:MicaStandardizedWorkingDirectory(@"/tmp")] &&
                [restoredStateOwner.activeTab.command isEqual:@"printf MICA_RESTORED"] &&
                restoredStateOwner.activeTab.muteNotifications;
            for (int attempt = 0; restoredSession && attempt < 300; attempt++) {
                [restoredStateOwner pollSessions:nil];
                if (MicaUITestFindTextAcrossWrappedRows(restoredStateOwner.activeTab.session, @"printf MICA_RESTORED")) break;
                usleep(10000);
            }
            BOOL restorePrefillsWithoutRunning = restoredSession &&
                MicaUITestFindTextAcrossWrappedRows(restoredStateOwner.activeTab.session, @"printf MICA_RESTORED") &&
                mica_session_command_completion_count(restoredStateOwner.activeTab.session) == 0;
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
            NSDictionary *numericMuteState = @{@"version":@1,@"windows":@[@{@"tabs":@[@{
                @"name":@"Bad mute type",@"cwd":safeTempFolder,@"muteNotifications":@1}]}]};
            [[NSJSONSerialization dataWithJSONObject:numericMuteState options:0 error:nil] writeToFile:statePath atomically:YES];
            hostileIgnored = hostileIgnored && [stateOwner readSessionState].count == 0;
            NSDictionary *mixedState = @{ @"version":@1, @"windows":@[@{ @"tabs":@[
                @{ @"name":@"Invalid", @"cwd":safeTempFolder, @"muteNotifications":@1 },
                @{ @"name":@"Survivor", @"cwd":safeTempFolder }
            ]}]};
            [[NSJSONSerialization dataWithJSONObject:mixedState options:0 error:nil] writeToFile:statePath atomically:YES];
            NSDictionary *mixedRead = [stateOwner readSessionState].firstObject;
            NSArray *mixedTabs = mixedRead[@"tabs"];
            BOOL badEntryDropped = mixedTabs.count == 1 && [mixedTabs[0][@"name"] isEqual:@"Survivor"];
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
            NSString *stubDirectory = [stateDirectory stringByAppendingPathComponent:@"bin"];
            [NSFileManager.defaultManager createDirectoryAtPath:stubDirectory withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *stub = [stubDirectory stringByAppendingPathComponent:@"claude"];
            NSString *capture = [stateDirectory stringByAppendingPathComponent:@"capture"];
            NSString *stubScript = @"#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$MICA_RESUME_CAPTURE\"\nprintf 'RESUME_STUB_RAN\\n'\n";
            [stubScript writeToFile:stub atomically:YES encoding:NSUTF8StringEncoding error:nil];
            chmod(stub.fileSystemRepresentation, 0755);
            NSString *oldPath = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"/usr/bin:/bin";
            NSString *testPath = [NSString stringWithFormat:@"%@:%@", stubDirectory, oldPath];
            setenv("PATH", testPath.UTF8String, 1); setenv("MICA_RESUME_CAPTURE", capture.UTF8String, 1);
            NSDictionary *agentRestoreFixture = @{ @"version":@1, @"windows":@[@{@"tabs":@[@{
                @"name":@"Agent", @"cwd":safeTempFolder, @"agentKind":@"claude", @"agentSessionID":@"session-1234"}]}]};
            [[NSJSONSerialization dataWithJSONObject:agentRestoreFixture options:0 error:nil] writeToFile:statePath atomically:YES];
            NSString *resumeSuite = [NSString stringWithFormat:@"mica-resume-%d", getpid()];
            NSUserDefaults *resumeDefaults = [[NSUserDefaults alloc] initWithSuiteName:resumeSuite];
            [resumeDefaults removePersistentDomainForName:resumeSuite]; gMicaDefaultsOverride = resumeDefaults;
            MicaAppDelegate *resumeOff = [MicaAppDelegate new]; resumeOff.tabs = [NSMutableArray array]; resumeOff.activeIndex = 0;
            [resumeOff loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            for (int attempt = 0; attempt < 100; attempt++) {
                [resumeOff pollSessions:nil];
                if (MicaUITestFindTextAcrossWrappedRows(resumeOff.activeTab.session, @"claude --resume session-1234")) break;
                usleep(10000);
            }
            BOOL resumeOffPrefilled = MicaUITestFindTextAcrossWrappedRows(resumeOff.activeTab.session, @"claude --resume session-1234") &&
                ![NSFileManager.defaultManager fileExistsAtPath:capture];
            for (NSValue *value in [resumeOff detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
            [resumeDefaults setBool:YES forKey:@"MicaResumeAgentsOnRestore"];
            MicaAppDelegate *resumeOn = [MicaAppDelegate new]; resumeOn.tabs = [NSMutableArray array]; resumeOn.activeIndex = 0;
            [resumeOn loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            for (int attempt = 0; attempt < 1500 && ![NSFileManager.defaultManager fileExistsAtPath:capture]; attempt++) {
                [resumeOn pollSessions:nil]; usleep(10000);
            }
            NSString *capturedArgs = [NSString stringWithContentsOfFile:capture encoding:NSUTF8StringEncoding error:nil];
            BOOL resumeOnRan = [capturedArgs isEqualToString:@"--resume session-1234\n"];
            for (NSValue *value in [resumeOn detachSessionsForTermination]) mica_session_destroy(value.pointerValue);

            {
                // Resume reproduces the launch: config dir + allowlisted flags; hostile values are dropped on read.
                NSString *configDir = [stateDirectory stringByAppendingPathComponent:@"claude-work"];
                [NSFileManager.defaultManager createDirectoryAtPath:configDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *safeDir = MicaSanitizedConfigDir(configDir, NSHomeDirectory());
                NSDictionary *launchFixture = @{@"version":@1, @"windows":@[@{@"tabs":@[
                    @{@"name":@"C", @"cwd":safeTempFolder, @"agentKind":@"claude", @"agentSessionID":@"session-1234",
                      @"agentConfigDir":configDir, @"agentFlags":@[@"--dangerously-skip-permissions", @"--evil"]},
                    @{@"name":@"X", @"cwd":safeTempFolder, @"agentKind":@"codex", @"agentSessionID":@"codex-1234",
                      @"agentConfigDir":@"/definitely/missing", @"agentFlags":@[@"--sandbox", @"danger-full-access", @"--ask-for-approval", @"never", @"; rm"]}]}]};
                [[NSJSONSerialization dataWithJSONObject:launchFixture options:0 error:nil] writeToFile:statePath atomically:YES];
                MicaAppDelegate *launchOwner = [MicaAppDelegate new]; launchOwner.tabs = [NSMutableArray array]; launchOwner.activeIndex = 0;
                NSArray *readBack = [launchOwner readSessionState].firstObject[@"tabs"];
                BOOL readValidated = readBack.count == 2 && [readBack[0][@"agentConfigDir"] isEqual:safeDir] &&
                    [readBack[0][@"agentFlags"] isEqual:@[@"--dangerously-skip-permissions"]] && !readBack[1][@"agentConfigDir"] &&
                    [readBack[1][@"agentFlags"] isEqual:@[@"--sandbox", @"danger-full-access", @"--ask-for-approval", @"never"]];
                [resumeDefaults setBool:NO forKey:@"MicaResumeAgentsOnRestore"];
                [launchOwner loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
                NSString *claudeLine = [NSString stringWithFormat:@"CLAUDE_CONFIG_DIR='%@' claude --dangerously-skip-permissions --resume session-1234", safeDir];
                NSString *codexLine = @"codex resume codex-1234 --sandbox danger-full-access --ask-for-approval never";
                BOOL claudeShown = NO, codexShown = NO;
                for (int attempt = 0; attempt < 200 && !(claudeShown && codexShown); attempt++) {
                    [launchOwner pollSessions:nil];
                    claudeShown = launchOwner.tabs.count > 0 && MicaUITestFindTextAcrossWrappedRows(launchOwner.tabs[0].session, claudeLine);
                    codexShown = launchOwner.tabs.count > 1 && MicaUITestFindTextAcrossWrappedRows(launchOwner.tabs[1].session, codexLine);
                    usleep(10000);
                }
                // saving round-trips the launch info and never replaces a hook-supplied id
                MicaTab *hooked = launchOwner.tabs.firstObject;
                hooked.agentKind = @"claude"; hooked.agentSessionID = @"hook-id-1234"; hooked.agentSessionFromHook = YES;
                hooked.agentConfigDir = configDir; hooked.agentFlags = @[@"--dangerously-skip-permissions"];
                hooked.agentLaunchResolvedID = @"hook-id-1234";
                [MicaControllers() removeAllObjects]; [MicaControllers() addObject:launchOwner];
                [launchOwner saveSessionState];
                NSDictionary *savedLaunch = [launchOwner readSessionState].firstObject[@"tabs"][0];
                BOOL saveKeepsLaunch = [savedLaunch[@"agentSessionID"] isEqual:@"hook-id-1234"] &&
                    [savedLaunch[@"agentConfigDir"] isEqual:safeDir] && [savedLaunch[@"agentFlags"] isEqual:@[@"--dangerously-skip-permissions"]];
                hooked.agentLaunchResolvedID = nil; hooked.agentDiscoverAt = 0;
                [launchOwner saveSessionState];
                BOOL hookIDKept = [hooked.agentSessionID isEqual:@"hook-id-1234"];
                // a discovered (non-hook) id whose agent processes are gone is cleared, not kept stale
                MicaTab *stale = launchOwner.tabs.count > 1 ? launchOwner.tabs[1] : nil;
                stale.agentKind = @"claude"; stale.agentSessionID = @"stale-id-1234"; stale.agentSessionFromHook = NO;
                stale.agentLaunchResolvedID = @"stale-id-1234"; stale.agentDiscoverAt = 0;
                [MicaControllers() removeAllObjects]; [MicaControllers() addObject:launchOwner];
                [launchOwner resolveAgentResumeForTab:stale];
                BOOL staleKept = stale.agentSessionID.length > 0;   // shell child may still exist; only assert no wrong replacement
                if (!staleKept) hookIDKept = hookIDKept && !stale.agentKind && !stale.agentLaunchResolvedID;
                [MicaControllers() removeAllObjects];
                for (NSValue *value in [launchOwner detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
                [resumeDefaults setBool:YES forKey:@"MicaResumeAgentsOnRestore"];
                MicaUITestRecord(report, &allPassed, readValidated && claudeShown && codexShown && saveKeepsLaunch && hookIDKept,
                    [NSString stringWithFormat:@"resume reproduces the config dir and allowlisted flags, validates them on read, and keeps hook ids (read=%d claude=%d codex=%d save=%d hook=%d)",
                        readValidated, claudeShown, codexShown, saveKeepsLaunch, hookIDKept]);
            }
            NSString *sshProfileID = @"A514442E-F80A-4B4E-A83B-98A335BD1942";
            NSDictionary *sshProfile = @{@"id":sshProfileID, @"name":@"Test Mac", @"destination":@"test-mac",
                @"remoteDirectory":@"~/Projects/Mica"};
            [resumeDefaults setObject:@{@"version":@1, @"profiles":@[sshProfile]} forKey:@"MicaSSHProfiles"];
            NSString *sshStub = [stubDirectory stringByAppendingPathComponent:@"ssh"];
            symlink(stub.fileSystemRepresentation, sshStub.fileSystemRepresentation);
            NSDictionary *sshRestoreFixture = @{ @"version":@1, @"windows":@[@{ @"tabs":@[@{
                @"name":@"Test Mac", @"cwd":safeTempFolder, @"sshProfileID":sshProfileID,
                @"command":@"this must never be replayed"}]}]};
            [[NSJSONSerialization dataWithJSONObject:sshRestoreFixture options:0 error:nil] writeToFile:statePath atomically:YES];
            [NSFileManager.defaultManager removeItemAtPath:capture error:nil];
            MicaAppDelegate *sshRestored = [MicaAppDelegate new];
            sshRestored.tabs = [NSMutableArray array]; sshRestored.activeIndex = 0;
            [sshRestored loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            for (int attempt = 0; attempt < 500 && ![NSFileManager.defaultManager fileExistsAtPath:capture]; attempt++) {
                [sshRestored pollSessions:nil]; usleep(10000);
            }
            NSString *sshCapturedArgs = [NSString stringWithContentsOfFile:capture encoding:NSUTF8StringEncoding error:nil];
            BOOL sshRestoredSafely = sshRestored.tabs.count == 1 &&
                [sshRestored.activeTab.remoteProfile[@"id"] isEqualToString:sshProfileID] &&
                [sshCapturedArgs containsString:@"-tt test-mac cd -- \"$HOME\"/'Projects/Mica'" ] &&
                ![sshCapturedArgs containsString:@"this must never be replayed"];
            for (NSValue *value in [sshRestored detachSessionsForTermination]) mica_session_destroy(value.pointerValue);

            NSString *sshLayoutPath = [stateDirectory stringByAppendingPathComponent:@"remote.mica"];
            NSString *sshLayoutContents = [NSString stringWithFormat:@"# Mica layout v2\n# Mica project: Remote workspace\nRemote Mac\t@ssh-profile:%@\n", sshProfileID];
            [sshLayoutContents writeToFile:sshLayoutPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            MicaAppDelegate *sshLayoutOwner = [MicaAppDelegate new];
            sshLayoutOwner.tabs = [NSMutableArray array]; sshLayoutOwner.activeIndex = 0;
            [sshLayoutOwner loadLaunchConfigurationFromArguments:@[@"mica", @"--layout", sshLayoutPath] bundleInfo:@{}];
            [NSFileManager.defaultManager removeItemAtPath:capture error:nil];
            for (int attempt = 0; attempt < 200 && ![NSFileManager.defaultManager fileExistsAtPath:capture]; attempt++) {
                [sshLayoutOwner pollSessions:nil]; usleep(10000);
            }
            NSString *sshLayoutArgs = [NSString stringWithContentsOfFile:capture encoding:NSUTF8StringEncoding error:nil];
            BOOL sshLayoutRestoresProfile = sshLayoutOwner.tabs.count == 1 &&
                [sshLayoutOwner.activeTab.remoteProfile[@"id"] isEqualToString:sshProfileID] &&
                [sshLayoutArgs containsString:@"-tt test-mac"] &&
                [sshLayoutOwner.projectName isEqualToString:@"Remote workspace"];
            for (NSValue *value in [sshLayoutOwner detachSessionsForTermination]) mica_session_destroy(value.pointerValue);

            NSString *codexStub = [stubDirectory stringByAppendingPathComponent:@"codex"];
            symlink(stub.fileSystemRepresentation, codexStub.fileSystemRepresentation);
            NSDictionary *codexRestoreFixture = @{ @"version":@1, @"windows":@[@{@"tabs":@[@{
                @"name":@"Codex", @"cwd":safeTempFolder, @"agentKind":@"codex", @"agentSessionID":@"codex-1234"}]}]};
            [[NSJSONSerialization dataWithJSONObject:codexRestoreFixture options:0 error:nil] writeToFile:statePath atomically:YES];
            [NSFileManager.defaultManager removeItemAtPath:capture error:nil];
            MicaAppDelegate *codexResume = [MicaAppDelegate new]; codexResume.tabs = [NSMutableArray array]; codexResume.activeIndex = 0;
            [codexResume loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            for (int attempt = 0; attempt < 200 && ![NSFileManager.defaultManager fileExistsAtPath:capture]; attempt++) {
                [codexResume pollSessions:nil]; usleep(10000);
            }
            NSString *codexArgs = [NSString stringWithContentsOfFile:capture encoding:NSUTF8StringEncoding error:nil];
            BOOL codexResumeRan = [codexArgs isEqualToString:@"resume codex-1234\n"];
            for (NSValue *value in [codexResume detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
            {
                setenv("MICA_TEST_LAZYGIT_COMMAND", "printf LAZYGIT_STUB; exec sleep 30", 1);
                MicaAppDelegate *lg = [MicaAppDelegate new]; lg.tabs = [NSMutableArray array]; lg.activeIndex = 0;
                [lg addTabWithName:@"Main" cwd:safeTempFolder command:nil prefilled:NO];
                MicaTab *mainTab = lg.tabs.firstObject;
                BOOL disabledOutsideRepo = ![lg canToggleLazygitForTab:mainTab];
                [lg toggleLazygitForTab:mainTab];
                disabledOutsideRepo = disabledOutsideRepo && !mainTab.companion && !mainTab.showingCompanion;
                mainTab.projectRoot = safeTempFolder;
                [lg toggleLazygitForTab:mainTab];
                MicaTab *firstCompanion = mainTab.companion;
                BOOL swapped = mainTab.showingCompanion && lg.activeTab == firstCompanion && lg.selectedTab == mainTab && lg.tabs.count == 1;
                BOOL stubShown = NO;
                for (int attempt = 0; attempt < 300 && !stubShown; attempt++) {
                    [lg pollSessions:nil];
                    stubShown = MicaUITestFindText(firstCompanion.session, @"LAZYGIT_STUB", NULL, NULL);
                    usleep(10000);
                }
                [lg toggleLazygitForTab:mainTab];
                BOOL swappedBack = !mainTab.showingCompanion && lg.activeTab == mainTab && mainTab.companion == firstCompanion &&
                    mica_session_is_running(firstCompanion.session);
                [lg toggleLazygitForTab:mainTab];
                BOOL reused = mainTab.showingCompanion && mainTab.companion == firstCompanion;
                [lg toggleLazygitForTab:mainTab];
                // a repo-root change respawns on the next toggle
                mainTab.projectRoot = @"/private/var";
                [lg toggleLazygitForTab:mainTab];
                MicaTab *respawned = mainTab.companion;
                BOOL respawnedOnRootChange = respawned && respawned != firstCompanion && [mainTab.companionRoot isEqualToString:@"/private/var"];
                [lg toggleLazygitForTab:mainTab];
                // hidden companions die after ten idle minutes
                mainTab.companionHiddenAt = NSProcessInfo.processInfo.systemUptime - 601;
                [lg pollSessions:nil];
                BOOL idleKilled = mainTab.companion == nil && !mainTab.showingCompanion;
                // lazygit exiting swaps back automatically
                setenv("MICA_TEST_LAZYGIT_COMMAND", "printf BYE; exit 0", 1);
                [lg toggleLazygitForTab:mainTab];
                BOOL exitedSwapsBack = NO;
                for (int attempt = 0; attempt < 300 && !exitedSwapsBack; attempt++) {
                    [lg pollSessions:nil];
                    exitedSwapsBack = mainTab.companion == nil && !mainTab.showingCompanion && lg.activeTab == mainTab;
                    usleep(10000);
                }
                // the companion never reaches saved state, and the tab list stays one entry
                [MicaControllers() removeAllObjects]; [MicaControllers() addObject:lg];
                setenv("MICA_TEST_LAZYGIT_COMMAND", "printf LAZYGIT_STUB; exec sleep 30", 1);
                [lg toggleLazygitForTab:mainTab];
                [lg saveSessionState];
                NSString *rawLazygitState = [NSString stringWithContentsOfFile:statePath encoding:NSUTF8StringEncoding error:nil];
                BOOL companionNotSaved = lg.tabs.count == 1 && [[lg readSessionState].firstObject[@"tabs"] count] == 1 &&
                    ![rawLazygitState containsString:@"LAZYGIT"] && ![rawLazygitState containsString:@"lazygit"];
                MicaAgentSidebarView *sidebar = [MicaAgentSidebarView new]; sidebar.owner = lg;
                sidebar.frame = NSMakeRect(0, 0, 220, 300);
                NSRect glyphRect = [sidebar gitGlyphRectForRowTop:42];
                [sidebar refreshRows];
                NSString *activeSignature = sidebar.lastRowsSignature;
                [lg toggleLazygitForTab:mainTab]; [sidebar refreshRows];
                BOOL sidebarIndicator = glyphRect.size.width > 0 && ![activeSignature isEqualToString:sidebar.lastRowsSignature];
                [MicaControllers() removeAllObjects];
                for (NSValue *value in [lg detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
                unsetenv("MICA_TEST_LAZYGIT_COMMAND");
                MicaUITestRecord(report, &allPassed, disabledOutsideRepo && swapped && stubShown && swappedBack && reused &&
                    respawnedOnRootChange && idleKilled && exitedSwapsBack && companionNotSaved && sidebarIndicator,
                    [NSString stringWithFormat:@"lazygit view swaps per tab with a stub: disabled=%d swap=%d stub=%d back=%d reuse=%d respawn=%d idle=%d exit=%d unsaved=%d indicator=%d",
                        disabledOutsideRepo, swapped, stubShown, swappedBack, reused, respawnedOnRootChange, idleKilled,
                        exitedSwapsBack, companionNotSaved, sidebarIndicator]);
            }
            NSString *pwned = [stateDirectory stringByAppendingPathComponent:@"pwned"];
            NSDictionary *tampered = @{ @"version":@1, @"windows":@[@{@"tabs":@[@{
                @"name":@"Tampered", @"cwd":safeTempFolder, @"agentKind":@"claude",
                @"agentSessionID":[NSString stringWithFormat:@"x; touch %@", pwned]}]}]};
            [[NSJSONSerialization dataWithJSONObject:tampered options:0 error:nil] writeToFile:statePath atomically:YES];
            [NSFileManager.defaultManager removeItemAtPath:capture error:nil];
            MicaAppDelegate *resumeTampered = [MicaAppDelegate new]; resumeTampered.tabs = [NSMutableArray array]; resumeTampered.activeIndex = 0;
            [resumeTampered loadLaunchConfigurationFromArguments:@[@"mica"] bundleInfo:@{}];
            for (int attempt = 0; attempt < 30; attempt++) { [resumeTampered pollSessions:nil]; usleep(10000); }
            BOOL tamperedDropped = ![NSFileManager.defaultManager fileExistsAtPath:pwned] &&
                !MicaUITestFindText(resumeTampered.activeTab.session, @"touch", NULL, NULL);
            for (NSValue *value in [resumeTampered detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
            setenv("PATH", oldPath.UTF8String, 1); unsetenv("MICA_RESUME_CAPTURE");
            gMicaDefaultsOverride = nil; [resumeDefaults removePersistentDomainForName:resumeSuite];
            hostileIgnored = hostileIgnored && commandRestoredSafely;
            [NSFileManager.defaultManager removeItemAtPath:stateDirectory error:nil];
            gMicaSessionStateURLOverride = nil;
            [MicaControllers() removeAllObjects]; [MicaControllers() addObjectsFromArray:savedControllers];
            MicaUITestRecord(report, &allPassed, stateRoundTrips && explicitProjectSkipsSavedWindows && explicitLaunchOnlyOpensRequestedProjects && explicitLaunchRecordsHistoryNewestFirst && plainLaunchRestoresSavedProjects && plainRestoreDoesNotRecordRecentProjects && restoredSession && restorePrefillsWithoutRunning && missingFolderFallsHome && corruptIgnored && oversizedIgnored && hostileIgnored && badEntryDropped && privateStatePermissions && resumeOffPrefilled && resumeOnRan && sshRestoredSafely && sshLayoutRestoresProfile && codexResumeRan && tamperedDropped,
                [NSString stringWithFormat:@"session state validates names/folders, explicit launches open requested projects only and record recent history, plain launch restores saved windows without recording them, ignores hostile metadata and uses private permissions (roundtrip=%d explicitConfig=%d explicitLaunch=%d explicitHistory=%d plainLaunch=%d plainHistory=%d restore=%d prefill=%d missing=%d corrupt=%d oversized=%d hostile=%d badEntry=%d private=%d command=%d resumeOff=%d resumeOn=%d ssh=%d sshLayout=%d codex=%d tampered=%d mode=%o/%o saved=%@ actual=%@ raw=%@)",
                    stateRoundTrips, explicitProjectSkipsSavedWindows, explicitLaunchOnlyOpensRequestedProjects,
                    explicitLaunchRecordsHistoryNewestFirst, plainLaunchRestoresSavedProjects, plainRestoreDoesNotRecordRecentProjects,
                    restoredSession, restorePrefillsWithoutRunning, missingFolderFallsHome,
                    corruptIgnored, oversizedIgnored, hostileIgnored, badEntryDropped, privateStatePermissions,
                    commandRestoredSafely, resumeOffPrefilled, resumeOnRan, sshRestoredSafely, sshLayoutRestoresProfile,
                    codexResumeRan, tamperedDropped,
                    [stateAttributes[NSFilePosixPermissions] unsignedShortValue],
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
            NSString *desktopLink = [layoutsRoot stringByAppendingPathComponent:@"Desktop Project.mica"];
            [fileManager createSymbolicLinkAtPath:desktopLink withDestinationPath:goodLayout error:nil];
            NSString *(^enc)(NSString *) = ^NSString *(NSString *v) {
                return [v stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]; };
            NSArray<NSString *> *good = MicaArgumentsForOpenURL(
                [NSURL URLWithString:[NSString stringWithFormat:@"mica://open?layout=%@&name=%@", enc(goodLayout), enc(@"Alpha Project")]], layoutsRoot);
            BOOL urlsValidated = good.count == 5 && [good[1] isEqualToString:@"--layout"] && [good[3] isEqualToString:@"--project-name"] &&
                [good[4] isEqualToString:@"Alpha Project"] &&
                [MicaArgumentsForLayoutFileURL([NSURL fileURLWithPath:desktopLink], layoutsRoot)[2] isEqualToString:goodLayout] &&
                MicaArgumentsForLayoutFileURL([NSURL fileURLWithPath:outside], layoutsRoot) == nil &&
                MicaArgumentsForLayoutFileURL([NSURL URLWithString:@"https://example.test/a.mica"], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:[NSString stringWithFormat:@"mica://open?layout=%@", enc(outside)]], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:[NSString stringWithFormat:@"mica://open?layout=%@", enc(escapeLink)]], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:[NSString stringWithFormat:@"mica://open?layout=%@/../x.mica", enc(layoutsRoot)]], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:@"https://open?layout=/etc/passwd"], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:@"mica://run?layout=/etc/passwd"], layoutsRoot) == nil &&
                MicaArgumentsForOpenURL([NSURL URLWithString:@"mica://open"], layoutsRoot) == nil;
            MicaUITestRecord(report, &allPassed, urlsValidated,
                @"Mica file opens and mica:// URLs accept trusted layouts, including Desktop symlinks, and reject outside paths");

            // Several project windows in one process: separate controllers, one menu bar that follows the key window,
            // duplicates focus the existing window, and closing one leaves the others running.
            setenv("MICA_TEST_NO_STARTUP", "1", 1);
            MicaAppDelegate *windowA = [[MicaAppDelegate alloc] init];
            MicaAppDelegate *windowB = [[MicaAppDelegate alloc] init];
            [windowA startWindowWithArguments:@[@"mica", @"--layout", goodLayout, @"--project-name", @"Alpha"]];
            [windowB startWindowWithArguments:@[@"mica", @"--layout", secondLayout, @"--project-name", @"Beta"]];
            MicaPomodoro savedOwnerTimer = windowA.pomodoro;
            NSMutableArray<MicaTab *> *savedOwnerTabs = windowA.tabs;
            MicaPomodoro elapsedOwnerTimer = {0};
            mica_pomodoro_start(&elapsedOwnerTimer, MicaContinuousTimeSeconds() - 5, 1);
            windowA.tabs = [NSMutableArray array];
            windowA.pomodoro = elapsedOwnerTimer;
            [MicaAttention() clearTabID:0];
            [windowA pomodoroTimerFired:nil];
            BOOL emptyTimerOwnerHandled = [MicaAttention().events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) {
                (void)bindings; return [event[@"tabID"] unsignedLongLongValue] == 0 &&
                    [event[@"kind"] integerValue] == MicaAttentionTimerEnd;
            }]].count == 1;
            [MicaAttention() clearTabID:0];
            windowA.tabs = savedOwnerTabs;
            windowA.pomodoro = savedOwnerTimer;
            [windowA savePomodoroState]; [windowA refreshPomodoroState];
            MicaUITestRecord(report, &allPassed, emptyTimerOwnerHandled,
                @"timer completion posts a process-level event safely when its owner window has no tabs");
            BOOL twoWindows = MicaControllers().count == 2 && windowA.tabs.count == 1 && windowB.tabs.count == 1 &&
                [windowA.projectName isEqualToString:@"Alpha"] && [windowB.projectName isEqualToString:@"Beta"];
            [windowA takeMenuOwnership];
            NSMenuItem *newTabItem = [[NSApp.mainMenu itemWithTitle:@"Session"].submenu itemWithTitle:@"New Shell Tab"];
            BOOL menuAtA = newTabItem.target == windowA;
            [windowB takeMenuOwnership];
            BOOL menuAtB = newTabItem.target == windowB;
            NSMenu *projectDockMenu = [windowA applicationDockMenu:NSApp];
            BOOL dockMenuListsBothProjects = projectDockMenu.itemArray.count == 2;
            BOOL dockMenuTargetsCorrectWindows = NO, dockMenuTitlesIdentifyProjects = NO;
            for (NSMenuItem *item in projectDockMenu.itemArray) {
                if (item.target == windowA && item.action == @selector(showDockWindowFromMenu:))
                    dockMenuTargetsCorrectWindows = [item.title isEqualToString:[windowA windowTitleForTab:windowA.activeTab]];
                if (item.target == windowB && item.action == @selector(showDockWindowFromMenu:))
                    dockMenuTitlesIdentifyProjects = [item.title isEqualToString:[windowB windowTitleForTab:windowB.activeTab]];
            }
            MicaUITestRecord(report, &allPassed,
                dockMenuListsBothProjects && dockMenuTargetsCorrectWindows && dockMenuTitlesIdentifyProjects,
                [NSString stringWithFormat:@"the Dock menu lists each project window with its project and tab title (count=%lu A=%d B=%d)",
                    (unsigned long)projectDockMenu.itemArray.count, dockMenuTargetsCorrectWindows, dockMenuTitlesIdentifyProjects]);
            [windowA openProjectWindowWithArguments:@[@"mica", @"--layout", goodLayout]];   // already open: no third window
            BOOL noDuplicate = MicaControllers().count == 2;
            [windowB addTabWithName:@"Click Target" cwd:NSTemporaryDirectory() command:nil prefilled:NO];
            MicaTab *secondWindowTab = windowB.activeTab;
            for (NSDictionary *event in MicaAttention().events)
                [MicaAttention() clearTabID:[event[@"tabID"] unsignedLongLongValue]];
            [MicaAttention() clearTabID:windowA.activeTab.identifier];
            [MicaAttention() clearTabID:windowB.tabs.firstObject.identifier];
            [MicaAttention() postTabID:windowA.activeTab.identifier kind:MicaAttentionWaitingInput title:@"A" body:@"wait" muted:NO];
            [MicaAttention() postTabID:windowB.tabs.firstObject.identifier kind:MicaAttentionWaitingInput title:@"B" body:@"wait" muted:NO];
            [windowB jumpToNextWaitingTab:nil];
            BOOL jumpStartsAtLowestID =
                windowA.activeTab.identifier == MIN(windowA.activeTab.identifier, windowB.tabs.firstObject.identifier);
            [MicaAttention() postTabID:windowA.activeTab.identifier kind:MicaAttentionWaitingInput title:@"A" body:@"wait" muted:NO];
            [windowA jumpToNextWaitingTab:nil];
            BOOL jumpCyclesAcrossWindows = windowB.activeTab == windowB.tabs.firstObject;
            [MicaAttention() postTabID:windowB.tabs.firstObject.identifier kind:MicaAttentionWaitingInput title:@"B" body:@"wait" muted:NO];
            [windowB jumpToNextWaitingTab:nil];
            BOOL jumpWrapsToLowestID = windowA.activeTab.identifier == MIN(windowA.activeTab.identifier, windowB.tabs.firstObject.identifier);
            MicaUITestRecord(report, &allPassed, jumpStartsAtLowestID && jumpCyclesAcrossWindows && jumpWrapsToLowestID,
                [NSString stringWithFormat:@"Cmd-Shift-J follows sorted tab IDs across windows and wraps (start=%d cycle=%d wrap=%d keyA=%d selected=%llu expectedA=%llu expectedB=%llu)",
                    jumpStartsAtLowestID, jumpCyclesAcrossWindows, jumpWrapsToLowestID, NSApp.keyWindow == windowA.window,
                    windowA.activeTab.identifier, (unsigned long long)MIN(windowA.activeTab.identifier, windowB.tabs.firstObject.identifier),
                    (unsigned long long)windowB.tabs.firstObject.identifier]);
            void (^savedDelivery)(NSDictionary *) = MicaAttention().delivery;
            MicaAttention().delivery = nil;
            [MicaAttention() clearTabID:secondWindowTab.identifier];
            [MicaAttention() postTabID:secondWindowTab.identifier kind:MicaAttentionDone title:@"Done" body:@"Finished" muted:NO];
            MicaTestNotificationContent *clickContent = [MicaTestNotificationContent new];
            clickContent.userInfo = @{@"tabID": @(secondWindowTab.identifier), @"kind": @(MicaAttentionDone)};
            MicaTestNotificationRequest *clickRequest = [MicaTestNotificationRequest new]; clickRequest.content = clickContent;
            MicaTestNotification *clickNotification = [MicaTestNotification new]; clickNotification.request = clickRequest;
            MicaTestNotificationResponse *clickResponse = [MicaTestNotificationResponse new]; clickResponse.notification = clickNotification;
            [windowA userNotificationCenter:nil didReceiveNotificationResponse:(id)clickResponse withCompletionHandler:^{}];
            BOOL clickRoutesAcrossWindows = windowB.activeIndex == 1 &&
                ![MicaAttention().waitingTabIDs containsObject:@(secondWindowTab.identifier)] &&
                ![MicaAttention().events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) {
                    (void)bindings; return [event[@"tabID"] unsignedLongLongValue] == secondWindowTab.identifier;
                }]].count;
            MicaAttention().delivery = savedDelivery;
            for (NSDictionary *event in MicaAttention().events)
                [MicaAttention() clearTabID:[event[@"tabID"] unsignedLongLongValue]];
            [MicaAttention() postTabID:windowA.activeTab.identifier kind:MicaAttentionWaitingInput title:@"Keep" body:@"badge" muted:NO];
            MicaTab *closeProbe = windowB.activeTab;
            [MicaAttention() postTabID:closeProbe.identifier kind:MicaAttentionDone title:@"Close" body:@"clear" muted:NO];
            NSString *badgeBeforeClose = MicaAttention().dockBadge;
            [windowB closeActiveTab];
            BOOL closingTabClearsInbox = ![MicaAttention().events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) {
                (void)bindings; return [event[@"tabID"] unsignedLongLongValue] == closeProbe.identifier;
            }]].count && MicaAttention().dockBadge != nil &&
                MicaAttention().dockBadge.integerValue == badgeBeforeClose.integerValue - 1;
            MicaUITestRecord(report, &allPassed, closingTabClearsInbox,
                [NSString stringWithFormat:@"closing a tab clears its inbox events and updates the Dock badge (before=%@ after=%@ events=%lu)",
                    badgeBeforeClose, MicaAttention().dockBadge, (unsigned long)MicaAttention().events.count]);
            MicaUITestRecord(report, &allPassed, clickRoutesAcrossWindows,
                @"notification click finds a tab in a second window, selects it and clears its inbox events");
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

            // Tabs are not renameable; identity is folder + branch. Git status feeds the change pill.
            {
                MicaTab *labelTab = [[MicaTab alloc] init];
                labelTab.name = @"Custom"; labelTab.cwd = @"/tmp/alpha-folder"; labelTab.gitBranch = @"feat/x";
                labelTab.gitChangeCount = 3; labelTab.gitAhead = 2; labelTab.gitBehind = 1;
                NSInteger parsedChanges = -1, parsedAhead = -1, parsedBehind = -1;
                MicaParseGitStatus(@"## main...origin/main [ahead 2, behind 1]\n M a.txt\n?? b.txt\n", &parsedChanges, &parsedAhead, &parsedBehind);
                NSString *tempRepo = [gitRoot stringByAppendingPathComponent:@"status-repo"];
                [fileManager createDirectoryAtPath:tempRepo withIntermediateDirectories:YES attributes:nil error:nil];
                NSTask *gitInit = [NSTask new];
                gitInit.executableURL = MicaGitExecutableURL();
                gitInit.arguments = @[@"-C", tempRepo, @"init", @"-q"];
                gitInit.standardOutput = gitInit.standardError = [NSFileHandle fileHandleWithNullDevice];
                [gitInit launchAndReturnError:nil]; [gitInit waitUntilExit];
                [@"x" writeToFile:[tempRepo stringByAppendingPathComponent:@"dirty.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                NSInteger repoChanges = -1, repoAhead = -1, repoBehind = -1;
                BOOL statusRan = MicaGitStatusForRoot(tempRepo, 4.0, &repoChanges, &repoAhead, &repoBehind);
                MicaUITestRecord(report, &allPassed,
                    ![delegate respondsToSelector:NSSelectorFromString(@"renameTab:")] &&
                    [MicaTabDisplayName(labelTab) isEqualToString:@"alpha-folder · feat/x"] &&
                    [MicaTabFolderName(labelTab) isEqualToString:@"alpha-folder"] &&
                    [MicaGitChangePillText(3) isEqualToString:@"●3"] && [MicaGitChangePillText(150) isEqualToString:@"●99+"] &&
                    MicaGitChangePillText(0) == nil && [MicaGitSyncText(2, 1) isEqualToString:@"↑2 ↓1"] &&
                    [MicaGitStatusAccessibilityText(labelTab) containsString:@"3 changed files"] &&
                    parsedChanges == 2 && parsedAhead == 2 && parsedBehind == 1 &&
                    statusRan && repoChanges == 1 && repoAhead == 0 && repoBehind == 0,
                    @"tabs show folder and branch only (no rename) and git status counts changed files, ahead and behind");
            }

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

            NSDictionary *layoutHintAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:11.5]};
            NSDictionary *layoutContextAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:11.5]};
            CGFloat minFolderContext = 18 + [@"Ready · " sizeWithAttributes:layoutContextAttrs].width +
                [@"…/Fieldnote" sizeWithAttributes:layoutContextAttrs].width;
            CGFloat layoutMemoryWidth = [@"58 MB" sizeWithAttributes:
                @{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium]}].width;
            NSArray<NSString *> *layoutHints = @[@"⌘/ Shortcuts", @"⌘1–8 Switch tab",
                @"⌘T New tab", @"⌘Q Quit"];
            BOOL narrowRectsDoNotOverlap = YES;
            for (NSNumber *widthValue in @[@600, @800]) {
                CGFloat width = widthValue.doubleValue;
                MicaStatusBarLayout layout = MicaComputeStatusBarLayout(width, 12,
                    minFolderContext, layoutMemoryWidth, layoutHints, layoutHintAttrs);
                narrowRectsDoNotOverlap = narrowRectsDoNotOverlap &&
                    !NSIntersectsRect(layout.contextRect, layout.hintsRect) &&
                    !NSIntersectsRect(layout.contextRect, layout.memoryRect) &&
                    !NSIntersectsRect(layout.hintsRect, layout.memoryRect) &&
                    layout.contextRect.size.width >= minFolderContext - 18;
            }
            MicaUITestRecord(report, &allPassed, narrowRectsDoNotOverlap,
                @"terminal status strip keeps folder context, hints and memory clear at 600 px or 800 px without a timer");

            NSString *smokeProjectName = delegate.projectName;
            delegate.projectName = @"Mica Demo";
            [delegate.terminalView setNeedsDisplay:YES];
            [delegate.terminalView displayIfNeeded];
            NSBitmapImageRep *bitmap = [delegate.terminalView bitmapImageRepForCachingDisplayInRect:delegate.terminalView.bounds];
            if (bitmap) [delegate.terminalView cacheDisplayInRect:delegate.terminalView.bounds toBitmapImageRep:bitmap];
            BOOL bitmapReady = bitmap != nil;
            NSString *imagePath = NSProcessInfo.processInfo.environment[@"MICA_UI_SMOKE_IMAGE"] ?: @"build/ui-smoke.png";
            NSData *png = bitmap ? [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
            BOOL imageSaved = png && [png writeToFile:imagePath atomically:YES];
            MicaUITestRecord(report, &allPassed, bitmapReady && imageSaved,
                             [NSString stringWithFormat:@"offscreen AppKit render saved to %@", imagePath]);
            delegate.projectName = smokeProjectName;
            [delegate updateWindowTitle];
            [delegate.terminalView setNeedsDisplay:YES];
            [delegate.terminalView displayIfNeeded];

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

        NSString *sshProjectSuite = [NSString stringWithFormat:@"mica-ssh-layout-%d", getpid()];
        NSUserDefaults *sshProjectDefaults = [[NSUserDefaults alloc] initWithSuiteName:sshProjectSuite];
        [sshProjectDefaults removePersistentDomainForName:sshProjectSuite];
        NSUserDefaults *savedDefaultsOverride = gMicaDefaultsOverride;
        gMicaDefaultsOverride = sshProjectDefaults;
        NSString *sshProjectID = @"5442F3CA-7DB8-48F5-8FC2-5275E499A66A";
        NSDictionary *sshProjectProfile = @{@"id":sshProjectID, @"name":@"Remote Mac", @"destination":@"remote-mac",
            @"remoteDirectory":@"~/Projects/Mica"};
        [sshProjectDefaults setObject:@{@"version":@1, @"profiles":@[sshProjectProfile]} forKey:@"MicaSSHProfiles"];
        NSString *sshProjectLayout = [projectLayoutRoot stringByAppendingPathComponent:@"ssh-profile.mica"];
        [@"# Mica layout v1\n# Mica project: SSH project\nShell\t/tmp\t\n"
            writeToFile:sshProjectLayout atomically:YES encoding:NSUTF8StringEncoding error:nil];
        MicaAppDelegate *sshProjectSettingsOwner = [MicaAppDelegate new];
        sshProjectSettingsOwner.projectName = @"SSH project";
        sshProjectSettingsOwner.projectLayoutPath = sshProjectLayout;
        MicaUITestAttachWindow(sshProjectSettingsOwner);
        MicaProjectSettingsController *sshProjectSettings = [[MicaProjectSettingsController alloc] initWithOwner:sshProjectSettingsOwner];
        NSMenuItem *remoteMacItem = nil;
        for (NSMenuItem *item in sshProjectSettings.addSSHProfileButton.itemArray)
            if ([item.representedObject[@"id"] isEqualToString:sshProjectID]) { remoteMacItem = item; break; }
        if (remoteMacItem) {
            [sshProjectSettings.addSSHProfileButton selectItem:remoteMacItem];
            [sshProjectSettings addSSHProfile:nil];
        }
        [sshProjectSettings.tableView.window makeFirstResponder:sshProjectSettings.tableView];
        [sshProjectSettingsOwner.window beginSheet:sshProjectSettings.window completionHandler:nil];
        [sshProjectSettings save:nil];
        NSString *sshProjectLayoutText = [NSString stringWithContentsOfFile:sshProjectLayout encoding:NSUTF8StringEncoding error:nil];
        NSDictionary *sshProjectConfig = MicaResolveLaunchConfiguration(@[@"mica", @"--layout", sshProjectLayout], @{}, @"/tmp");
        NSDictionary *sshProjectTab = [sshProjectConfig[@"tabs"] lastObject];
        BOOL sshProjectLayoutSaved = remoteMacItem != nil && sshProjectSettings.rows.count == 2 &&
            [sshProjectLayoutText containsString:@"# Mica layout v2"] &&
            [sshProjectLayoutText containsString:[NSString stringWithFormat:@"@ssh-profile:%@", sshProjectID]] &&
            [sshProjectTab[@"sshProfileID"] isEqualToString:sshProjectID];
        [sshProjectSettingsOwner.window orderOut:nil];
        gMicaDefaultsOverride = savedDefaultsOverride;
        [sshProjectDefaults removePersistentDomainForName:sshProjectSuite];
        MicaUITestRecord(report, &allPassed, sshProjectLayoutSaved,
            [NSString stringWithFormat:@"Project Settings writes a versioned profile reference and the layout resolves it by stable ID (ok=%d)", sshProjectLayoutSaved]);

        NSMutableArray *savedTimerControllers = [MicaControllers() mutableCopy];
        [MicaControllers() removeAllObjects];
        NSString *menuTimerSuite = [NSString stringWithFormat:@"MicaMenuTimer-%@", NSUUID.UUID.UUIDString];
        NSUserDefaults *menuTimerDefaults = [[NSUserDefaults alloc] initWithSuiteName:menuTimerSuite];
        [menuTimerDefaults removePersistentDomainForName:menuTimerSuite];
        gMicaDefaultsOverride = menuTimerDefaults;
        MicaAppDelegate *timerWindowA = [[MicaAppDelegate alloc] init];
        MicaAppDelegate *timerWindowB = [[MicaAppDelegate alloc] init];
        [MicaControllers() addObject:timerWindowA];
        [MicaControllers() addObject:timerWindowB];
        [timerWindowA configurePomodoro];
        [timerWindowB configurePomodoro];
        MicaUITestAttachWindow(timerWindowA);
        MicaUITestAttachWindow(timerWindowB);
        BOOL timerDefaultsShared = timerWindowA.focusDurationMinutes == 60 &&
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
        [timerWindowA startPomodoro:nil];
        [timerWindowB refreshPomodoroState];
        BOOL timerStartShared = timerOptionsShared &&
            timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS && timerWindowB.focusDurationMinutes == 50 &&
            timerWindowB.breakDurationMinutes == 8 && timerWindowB.pomodoro.phase == MICA_POMODORO_FOCUS &&
            timerWindowB.pomodoroCycleFocusMinutes == 50 && timerWindowB.pomodoro.deadline == timerWindowA.pomodoro.deadline;
        BOOL timerLabelValid = MicaPomodoroLabelIsValid(@"Cycle 9") &&
            !MicaPomodoroLabelIsValid([@"x" stringByPaddingToLength:81 withString:@"x" startingAtIndex:0]) &&
            !MicaPomodoroLabelIsValid(@"bad\nlabel");
        timerWindowA.pomodoroLabel = @"Cycle 9";
        [timerWindowA savePomodoroState];
        BOOL timerLabelStored = YES;
        [timerWindowB refreshPomodoroState];
        timerLabelStored = timerLabelStored && [timerWindowB.pomodoroLabel isEqualToString:@"Cycle 9"];
        [timerWindowA buildMenus];
        NSMenuItem *focusRootForLabel = [NSApp.mainMenu itemWithTitle:@"Focus"];
        BOOL timerLabelInFocusMenu = NO;
        for (NSMenuItem *item in focusRootForLabel.submenu.itemArray)
            if (item.tag == 9137 && [item.title isEqualToString:@"Session: Cycle 9"]) timerLabelInFocusMenu = YES;
        NSArray *timerAXLabels = [[timerWindowA.terminalView accessibilityChildren]
            valueForKey:@"accessibilityLabel"];
        BOOL timerControlsAccessible = ![timerAXLabels.description containsString:@"Focus timer,"] &&
            [NSApp.mainMenu itemWithTitle:@"Focus"] != nil;
        [timerWindowB togglePomodoroPause:nil];
        [timerWindowA refreshPomodoroState];
        BOOL timerPauseShared = timerWindowA.pomodoro.phase == MICA_POMODORO_PAUSED_FOCUS &&
            [timerWindowA.pomodoroLabel isEqualToString:@"Cycle 9"];
        NSMenuItem *skipTimerMenu = [[NSMenuItem alloc] initWithTitle:@"End Current Phase"
            action:@selector(skipPomodoroPhase:) keyEquivalent:@""];
        BOOL timerSkipMenuAccessible = [timerWindowA validateMenuItem:skipTimerMenu] &&
            [skipTimerMenu.title isEqualToString:@"End Focus & Start Break"];
        BOOL timerSkipAXPerformed = [timerWindowA validateMenuItem:skipTimerMenu];
        if (timerSkipAXPerformed) [timerWindowA skipPomodoroPhase:nil];
        [timerWindowB refreshPomodoroState];
        BOOL timerSkipFocusShared = timerSkipAXPerformed && timerSkipMenuAccessible &&
            [timerWindowA validateMenuItem:skipTimerMenu] &&
            [skipTimerMenu.title isEqualToString:@"End Break & Start Focus"] &&
            timerWindowA.pomodoro.phase == MICA_POMODORO_BREAK &&
            timerWindowB.pomodoro.phase == MICA_POMODORO_BREAK && timerWindowB.pomodoro.completed_focuses == 1;
        BOOL timerLabelSurvivesPauseAndFocusEnd = [timerWindowB.pomodoroLabel isEqualToString:@"Cycle 9"];
        [timerWindowB skipPomodoroPhase:nil];
        [timerWindowA refreshPomodoroState];
        BOOL timerSkipBreakShared = timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS &&
            timerWindowA.pomodoro.completed_focuses == 1 && timerWindowA.pomodoroLabel.length == 0;
        [timerWindowA resetPomodoro:nil];
        [timerWindowB refreshPomodoroState];
        BOOL timerResetShared = timerWindowB.pomodoro.phase == MICA_POMODORO_IDLE;
        timerResetShared = timerResetShared && timerWindowB.pomodoroLabel.length == 0;
        timerResetShared = timerResetShared && ![timerWindowB validateMenuItem:skipTimerMenu] &&
            [skipTimerMenu.title isEqualToString:@"End Current Phase"];
        MicaUITestRecord(report, &allPassed, timerLabelValid && timerLabelStored && timerLabelInFocusMenu && timerLabelSurvivesPauseAndFocusEnd &&
            timerSkipBreakShared && timerResetShared,
            [NSString stringWithFormat:@"focus labels validate at 80 plain-text characters, show in the Focus menu, persist across windows and pause, then clear at the next focus and reset (valid=%d stored=%d menu=%d preserved=%d)",
                timerLabelValid, timerLabelStored, timerLabelInFocusMenu,
                timerLabelSurvivesPauseAndFocusEnd]);
        [menuTimerDefaults removePersistentDomainForName:menuTimerSuite];
        MicaUITestRecord(report, &allPassed, timerDefaultsShared && timerStartShared && timerControlsAccessible &&
            timerPauseShared && timerSkipFocusShared && timerSkipBreakShared && timerResetShared,
            [NSString stringWithFormat:@"timer controls preserve independent checkbox auto-start choices, expose skip actions accessibly across windows (options=%d start=%d accessible=%d pause=%d focus-skip=%d break-skip=%d reset=%d)",
                timerOptionsShared, timerStartShared, timerControlsAccessible, timerPauseShared,
                timerSkipFocusShared, timerSkipBreakShared, timerResetShared]);
        // Focus band: one band per window under the tab bar, driven by the shared timer.
        {
            NSString *focusLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"mica-focus-log-%@.json", NSUUID.UUID.UUIDString]];
            setenv("MICA_TEST_FOCUS_LOG_PATH", focusLogPath.fileSystemRepresentation, 1);
            gMicaFocusRecorder = nil;
            gMicaFocusHold = nil;
            BOOL focusLogPathFromEnv = [[MicaFocusRecorder defaultLogPath] isEqualToString:focusLogPath];
            [timerWindowA savePomodoroSettingsFocusMinutes:25 breakMinutes:5 autoStartFocus:NO autoStartBreaks:NO];
            [timerWindowA resetPomodoro:nil];
            timerWindowA.tabs = [NSMutableArray array];
            timerWindowA.activeIndex = 0;
            timerWindowA.uiMode = MicaUIModeNormal;
            [timerWindowA addTabWithName:@"Focus probe" cwd:@"/tmp" command:@"sleep 60" prefilled:NO];
            MicaTab *focusTab = timerWindowA.activeTab;
            focusTab.projectRoot = @"/tmp/focus-proj";
            focusTab.gitBranch = @"feature/x";
            [timerWindowA refreshPomodoroState];
            MicaFocusBandView *bandA = timerWindowA.terminalView.focusBand;
            MicaFocusBandView *bandB = timerWindowB.terminalView.focusBand;
            CGFloat idleHeight = [MicaFocusBandView heightForPhase:MICA_POMODORO_IDLE];
            CGFloat activeHeight = [MicaFocusBandView heightForPhase:MICA_POMODORO_FOCUS];
            NSRect idleTerminal = [timerWindowA.terminalView terminalRect];
            int idleRows = mica_session_rows(focusTab.session);
            BOOL bandInEveryWindow = bandA && bandB && bandA.superview == timerWindowA.terminalView &&
                bandB.superview == timerWindowB.terminalView && !bandA.hidden && !bandB.hidden;
            NSRect terminalBounds = timerWindowA.terminalView.bounds;
            BOOL bandUnderTabBar = fabs(NSMaxY(bandA.frame) - (NSMaxY(terminalBounds) - kHeaderHeight)) < 0.5 &&
                fabs(bandA.frame.size.width - terminalBounds.size.width) < 0.5 && NSMinX(bandA.frame) == 0;
            BOOL bandIdleHeight = bandA.frame.size.height == idleHeight && timerWindowA.terminalView.focusBandHeight == idleHeight &&
                bandB.frame.size.height == idleHeight;
            BOOL idleHintShown = [bandA.hintField.stringValue isEqualToString:@"⌥⌘P"] && !bandA.hintField.hidden;

            [bandA.startButton performClick:nil];
            NSString *expectedFocusLabel = @"focus-proj · feature/x";
            BOOL startedFromBand = timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS &&
                timerWindowB.pomodoro.phase == MICA_POMODORO_FOCUS;
            BOOL labelPrefilled = [timerWindowA.pomodoroLabel isEqualToString:expectedFocusLabel] &&
                [timerWindowB.pomodoroLabel isEqualToString:expectedFocusLabel] &&
                [bandA.labelField.stringValue isEqualToString:expectedFocusLabel] &&
                [bandB.labelField.stringValue isEqualToString:expectedFocusLabel];
            NSRect activeTerminal = [timerWindowA.terminalView terminalRect];
            int activeRows = mica_session_rows(focusTab.session);
            BOOL activeHeightApplied = bandA.frame.size.height == activeHeight && bandB.frame.size.height == activeHeight &&
                activeHeight > idleHeight &&
                fabs((idleTerminal.size.height - activeTerminal.size.height) - (activeHeight - idleHeight)) < 0.5 &&
                activeRows < idleRows;
            BOOL bandsConsistentAfterStart =
                [bandA.phaseField.attributedStringValue.string isEqualToString:bandB.phaseField.attributedStringValue.string] &&
                [bandA.phaseField.attributedStringValue.string containsString:@"FOCUS"] &&
                ([bandA.countdownField.stringValue hasPrefix:@"24:5"] || [bandA.countdownField.stringValue isEqualToString:@"25:00"]);
            MicaUITestRecord(report, &allPassed,
                focusLogPathFromEnv && bandInEveryWindow && bandUnderTabBar && bandIdleHeight && idleHintShown &&
                    startedFromBand && labelPrefilled && activeHeightApplied && bandsConsistentAfterStart,
                [NSString stringWithFormat:@"focus band sits under the tab bar in every window, idle/active heights resize the terminal grid, start prefills the label from the tab project and branch (env=%d windows=%d placed=%d idle=%d hint=%d started=%d label=%d active=%d rows=%d->%d consistent=%d)",
                    focusLogPathFromEnv, bandInEveryWindow, bandUnderTabBar, bandIdleHeight, idleHintShown,
                    startedFromBand, labelPrefilled, activeHeightApplied, idleRows, activeRows, bandsConsistentAfterStart]);

            [bandB.pauseButton performClick:nil];
            BOOL pausedShared = timerWindowA.pomodoro.phase == MICA_POMODORO_PAUSED_FOCUS &&
                timerWindowB.pomodoro.phase == MICA_POMODORO_PAUSED_FOCUS &&
                [bandA.phaseField.attributedStringValue.string containsString:@"PAUSED"] &&
                [bandB.phaseField.attributedStringValue.string containsString:@"PAUSED"] &&
                [bandA.countdownField.stringValue isEqualToString:bandB.countdownField.stringValue];
            BOOL bandAccessible = [bandA.accessibilityLabel containsString:@"Focus timer"] &&
                [bandA.accessibilityLabel containsString:@"remaining"] &&
                [bandA.accessibilityLabel containsString:expectedFocusLabel];
            NSString *tooLongLabel = [@"" stringByPaddingToLength:81 withString:@"x" startingAtIndex:0];
            [timerWindowB focusBand:bandB didEditLabel:@"Deep work"];
            BOOL labelEditPersists = [timerWindowA.pomodoroLabel isEqualToString:@"Deep work"] &&
                [timerWindowB.pomodoroLabel isEqualToString:@"Deep work"] &&
                [[[timerWindowA micaDefaults] stringForKey:@"MicaPomodoroLabel"] isEqualToString:@"Deep work"] &&
                [bandA.labelField.stringValue isEqualToString:@"Deep work"] &&
                [bandA.accessibilityLabel containsString:@"Deep work"];
            [timerWindowA focusBand:bandA didEditLabel:tooLongLabel];
            BOOL invalidLabelRejected = [timerWindowA.pomodoroLabel isEqualToString:@"Deep work"];
            MicaUITestRecord(report, &allPassed, pausedShared && bandAccessible && labelEditPersists && invalidLabelRejected,
                [NSString stringWithFormat:@"focus band pause is shared, its accessibility label carries the phase, time and label, and label edits validate and persist (paused=%d ax=%d edit=%d invalid=%d)",
                    pausedShared, bandAccessible, labelEditPersists, invalidLabelRejected]);

            // Resume, pretend 125 seconds of the 25-minute session passed, then skip from the other window.
            [bandA.pauseButton performClick:nil];
            MicaPomodoro aged = timerWindowA.pomodoro;
            aged.deadline = MicaContinuousTimeSeconds() + 25 * 60.0 - 125.0;
            timerWindowA.pomodoro = aged;
            [timerWindowA savePomodoroState];
            [timerWindowA refreshPomodoroState];
            [bandB.skipButton performClick:nil];
            BOOL skippedToBreak = timerWindowA.pomodoro.phase == MICA_POMODORO_BREAK &&
                timerWindowB.pomodoro.phase == MICA_POMODORO_BREAK &&
                [bandA.phaseField.attributedStringValue.string containsString:@"BREAK"] &&
                [bandB.phaseField.attributedStringValue.string containsString:@"BREAK"];
            NSString *focusDay = [MicaFocusRecorder dayKeyForDate:NSDate.date];
            NSArray<NSDictionary *> *focusRows = [MicaFocusRecorderShared() rowsForDayKey:focusDay];
            NSDictionary *focusRow = focusRows.firstObject;
            BOOL skipRecorded = focusRows.count == 1 && [focusRow[@"project"] isEqual:@"focus-proj"] &&
                [focusRow[@"branch"] isEqual:@"feature/x"] && [focusRow[@"seconds"] doubleValue] > 120 &&
                [focusRow[@"seconds"] doubleValue] < 135 && [focusRow[@"sessions"] integerValue] == 1;
            BOOL popoverShowsProject = [[bandA popoverRowsForTesting].description containsString:@"focus-proj"] &&
                [[bandB popoverRowsForTesting].description containsString:@"focus-proj"];
            BOOL goalShown = [bandA.todayButton.attributedTitle.string hasPrefix:@"●○○○"];
            [MicaFocusRecorderShared() flush];
            NSString *savedLog = [NSString stringWithContentsOfFile:focusLogPath encoding:NSUTF8StringEncoding error:nil];
            BOOL logPersisted = [savedLog containsString:@"focus-proj"] && [savedLog containsString:focusDay];
            [[timerWindowA micaDefaults] setInteger:99 forKey:@"MicaFocusDailyGoal"];
            BOOL invalidGoalFallsBack = [timerWindowA focusDailyGoal] == 4;
            [[timerWindowA micaDefaults] setInteger:6 forKey:@"MicaFocusDailyGoal"];
            BOOL goalConfigurable = [timerWindowA focusDailyGoal] == 6;
            [[timerWindowA micaDefaults] removeObjectForKey:@"MicaFocusDailyGoal"];
            MicaUITestRecord(report, &allPassed,
                skippedToBreak && skipRecorded && popoverShowsProject && goalShown && logPersisted && invalidGoalFallsBack && goalConfigurable,
                [NSString stringWithFormat:@"skipping mid-focus records elapsed time per project and branch into the focus log, the band shows it and the goal (break=%d recorded=%d popover=%d goal=%d saved=%d badgoal=%d goal6=%d rows=%@)",
                    skippedToBreak, skipRecorded, popoverShowsProject, goalShown, logPersisted, invalidGoalFallsBack,
                    goalConfigurable, focusRows]);

            // Theme switch re-palettes the band.
            [timerWindowA skipPomodoroPhase:nil];
            BOOL focusRunning = timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS && MicaFocusHoldShared().holding;
            BOOL darkBefore = [bandA.countdownField.textColor isEqual:[MicaFocusBandPalette darkPalette].foreground];
            [timerWindowA setLightTheme:YES];
            BOOL lightApplied = [bandA.countdownField.textColor isEqual:[MicaFocusBandPalette lightPalette].foreground] &&
                [bandB.countdownField.textColor isEqual:[MicaFocusBandPalette lightPalette].foreground];
            [timerWindowA setLightTheme:NO];
            BOOL darkRestored = [bandB.countdownField.textColor isEqual:[MicaFocusBandPalette darkPalette].foreground];
            MicaUITestRecord(report, &allPassed, focusRunning && darkBefore && lightApplied && darkRestored,
                [NSString stringWithFormat:@"focus band follows the terminal theme in every window (running=%d dark=%d light=%d restored=%d)",
                    focusRunning, darkBefore, lightApplied, darkRestored]);

            // Agent holding: during focus only permission requests get through.
            MicaTab *permissionTab = [MicaTab new];
            permissionTab.identifier = 900001;
            permissionTab.name = @"Permission probe";
            [MicaAttention() clearTabID:focusTab.identifier];
            [MicaAttention() clearTabID:permissionTab.identifier];
            NSUInteger (^eventsForTab)(MicaTab *, NSInteger) = ^NSUInteger(MicaTab *tab, NSInteger kind) {
                NSUInteger count = 0;
                for (NSDictionary *event in [MicaAttention() events])
                    if ([event[@"tabID"] unsignedLongLongValue] == tab.identifier && (kind < 0 || [event[@"kind"] integerValue] == kind)) count++;
                return count;
            };
            void (^sendHook)(MicaTab *, const char *, const char *) = ^(MicaTab *tab, const char *event, const char *type) {
                MicaHookEvent hook;
                memset(&hook, 0, sizeof hook);
                strlcpy(hook.event, event, sizeof hook.event);
                strlcpy(hook.notification_type, type, sizeof hook.notification_type);
                strlcpy(hook.agent, "claude", sizeof hook.agent);
                strlcpy(hook.session_id, "focus-session", sizeof hook.session_id);
                [timerWindowA handleHookEvent:hook forTab:tab];
            };
            __block NSUInteger bannerCount = 0;
            timerWindowA.testAgentNotificationHandler = ^(NSString *title, NSString *body, MicaTab *tab) { (void)title; (void)body; (void)tab; bannerCount++; };
            sendHook(focusTab, "Stop", "");
            BOOL doneHeld = eventsForTab(focusTab, -1) == 0 && bannerCount == 0;
            sendHook(permissionTab, "PermissionRequest", "");
            BOOL permissionPasses = eventsForTab(permissionTab, MicaAttentionWaitingPermission) == 1;
            NSUInteger bannersBeforeRelease = bannerCount;
            [bandB.skipButton performClick:nil];
            BOOL releasedOnBreak = timerWindowA.pomodoro.phase == MICA_POMODORO_BREAK && !MicaFocusHoldShared().holding;
            BOOL markerAppears = eventsForTab(focusTab, MicaAttentionDone) == 1;
            BOOL releaseQuiet = bannerCount == bannersBeforeRelease;
            BOOL noticeShown = [timerWindowA.terminalView.focusNotice containsString:@"1 finished"] &&
                [timerWindowB.terminalView.focusNotice containsString:@"1 finished"];
            MicaUITestRecord(report, &allPassed, doneHeld && permissionPasses && releasedOnBreak && markerAppears && releaseQuiet && noticeShown,
                [NSString stringWithFormat:@"focus holds non-permission agent events, lets permission requests through, and re-applies held markers with a summary notice when the break starts (held=%d permission=%d break=%d marker=%d quiet=%d notice=%d)",
                    doneHeld, permissionPasses, releasedOnBreak, markerAppears, releaseQuiet, noticeShown]);

            // Reset releases too; a tab that resumed work is forgotten.
            timerWindowA.terminalView.focusNotice = nil;
            timerWindowB.terminalView.focusNotice = nil;
            [MicaAttention() clearTabID:focusTab.identifier];
            [timerWindowA skipPomodoroPhase:nil];  // break -> focus
            BOOL holdingAgain = timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS && MicaFocusHoldShared().holding;
            sendHook(focusTab, "Notification", "idle_prompt");
            BOOL inputHeld = eventsForTab(focusTab, -1) == 0;
            [bandA.resetButton performClick:nil];
            BOOL resetIdle = timerWindowA.pomodoro.phase == MICA_POMODORO_IDLE && !MicaFocusHoldShared().holding &&
                bandA.frame.size.height == idleHeight;
            BOOL resetReleased = eventsForTab(focusTab, MicaAttentionWaitingInput) == 1 &&
                [timerWindowB.terminalView.focusNotice containsString:@"1 waiting"];
            timerWindowA.terminalView.focusNotice = nil;
            timerWindowB.terminalView.focusNotice = nil;
            [MicaAttention() clearTabID:focusTab.identifier];
            [bandA.startButton performClick:nil];
            sendHook(focusTab, "Stop", "");
            sendHook(focusTab, "UserPromptSubmit", "");
            [bandA.resetButton performClick:nil];
            BOOL forgottenNotReleased = eventsForTab(focusTab, -1) == 0 && timerWindowA.terminalView.focusNotice.length == 0;
            MicaUITestRecord(report, &allPassed, holdingAgain && inputHeld && resetIdle && resetReleased && forgottenNotReleased,
                [NSString stringWithFormat:@"reset releases held events, and a tab that went back to work is forgotten (holding=%d held=%d idle=%d released=%d forgotten=%d)",
                    holdingAgain, inputHeld, resetIdle, resetReleased, forgottenNotReleased]);
            timerWindowA.testAgentNotificationHandler = nil;
            [MicaAttention() clearTabID:permissionTab.identifier];
            [MicaAttention() clearTabID:focusTab.identifier];

            // Reset below 60 seconds is ignored; a long enough one is recorded.
            double secondsBeforeReset = [MicaFocusRecorderShared() totalSecondsForDayKey:focusDay];
            BOOL shortResetIgnored = [MicaFocusRecorderShared() rowsForDayKey:focusDay].count == 1 && secondsBeforeReset < 140;
            [bandA.startButton performClick:nil];
            aged = timerWindowA.pomodoro;
            aged.deadline = MicaContinuousTimeSeconds() + 25 * 60.0 - 300.0;
            timerWindowA.pomodoro = aged;
            [timerWindowA savePomodoroState];
            [timerWindowA resetPomodoro:nil];
            double secondsAfterReset = [MicaFocusRecorderShared() totalSecondsForDayKey:focusDay];
            BOOL longResetRecorded = secondsAfterReset - secondsBeforeReset > 295 && secondsAfterReset - secondsBeforeReset < 310;
            MicaUITestRecord(report, &allPassed, shortResetIgnored && longResetRecorded,
                [NSString stringWithFormat:@"reset ignores focus under a minute but records longer sessions (short=%d long=%d delta=%.1f)",
                    shortResetIgnored, longResetRecorded, secondsAfterReset - secondsBeforeReset]);

            // Band controls clicked in the NON-root window change the shared state once and record once.
            BOOL bandBIsNonRoot = MicaControllers().firstObject == timerWindowA && timerWindowB != timerWindowA;
            [bandB.startButton performClick:nil];
            BOOL nonRootStarted = timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS &&
                timerWindowB.pomodoro.phase == MICA_POMODORO_FOCUS;
            [bandB.pauseButton performClick:nil];
            BOOL nonRootPaused = timerWindowA.pomodoro.phase == MICA_POMODORO_PAUSED_FOCUS &&
                !MicaFocusHoldShared().holding;
            [bandB.pauseButton performClick:nil];
            BOOL nonRootResumed = timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS && MicaFocusHoldShared().holding;
            aged = timerWindowA.pomodoro;
            aged.deadline = MicaContinuousTimeSeconds() + 25 * 60.0 - 125.0;
            timerWindowA.pomodoro = aged;
            [timerWindowA savePomodoroState];
            [timerWindowA refreshPomodoroState];
            double secondsBeforeNonRootSkip = [MicaFocusRecorderShared() totalSecondsForDayKey:focusDay];
            [bandB.skipButton performClick:nil];
            double nonRootSkipDelta = [MicaFocusRecorderShared() totalSecondsForDayKey:focusDay] - secondsBeforeNonRootSkip;
            BOOL nonRootSkipOnce = timerWindowA.pomodoro.phase == MICA_POMODORO_BREAK &&
                timerWindowB.pomodoro.phase == MICA_POMODORO_BREAK && nonRootSkipDelta > 120 && nonRootSkipDelta < 135;
            MicaUITestRecord(report, &allPassed, bandBIsNonRoot && nonRootStarted && nonRootPaused && nonRootResumed && nonRootSkipOnce,
                [NSString stringWithFormat:@"band controls clicked in a non-root window change the shared timer once and skip records elapsed focus exactly once (nonroot=%d start=%d pause=%d resume=%d skip=%d delta=%.1f)",
                    bandBIsNonRoot, nonRootStarted, nonRootPaused, nonRootResumed, nonRootSkipOnce, nonRootSkipDelta]);

            // Break -> focus auto-start captures the active tab's project for the recorder.
            timerWindowA.autoStartFocus = YES; timerWindowA.autoStartBreaks = YES;
            MicaFocusRecorderShared().activeProject = nil; MicaFocusRecorderShared().activeBranch = nil;
            aged = timerWindowA.pomodoro;
            aged.deadline = MicaContinuousTimeSeconds() - 1.0;
            timerWindowA.pomodoro = aged;
            [timerWindowA pomodoroTimerFired:nil];
            BOOL autoStartCaptured = timerWindowA.pomodoro.phase == MICA_POMODORO_FOCUS &&
                [MicaFocusRecorderShared().activeProject isEqual:@"focus-proj"] &&
                [MicaFocusRecorderShared().activeBranch isEqual:@"feature/x"];
            MicaUITestRecord(report, &allPassed, autoStartCaptured,
                [NSString stringWithFormat:@"auto-starting focus after a break captures the active tab project and branch (captured=%d project=%@)",
                    autoStartCaptured, MicaFocusRecorderShared().activeProject]);
            [timerWindowA resetPomodoro:nil];

            // A focus phase that expired while Mica was closed is recorded once on relaunch.
            NSUserDefaults *relaunchDefaults = [timerWindowA micaDefaults];
            [relaunchDefaults setDouble:NSDate.date.timeIntervalSince1970 - 10.0 forKey:@"MicaPomodoroEndsAt"];
            [relaunchDefaults setInteger:MICA_POMODORO_FOCUS forKey:@"MicaPomodoroPhase"];
            double secondsBeforeRelaunch = [MicaFocusRecorderShared() totalSecondsForDayKey:focusDay];
            [timerWindowA configurePomodoro];
            double relaunchDelta = [MicaFocusRecorderShared() totalSecondsForDayKey:focusDay] - secondsBeforeRelaunch;
            BOOL relaunchRecorded = timerWindowA.pomodoro.phase == MICA_POMODORO_PAUSED_BREAK &&
                fabs(relaunchDelta - timerWindowA.pomodoroCycleFocusMinutes * 60.0) < 0.5;
            MicaUITestRecord(report, &allPassed, relaunchRecorded,
                [NSString stringWithFormat:@"a focus phase that expired while closed is recorded once on relaunch (recorded=%d delta=%.1f)",
                    relaunchRecorded, relaunchDelta]);
            [timerWindowA resetPomodoro:nil];

            // View menu toggle hides the band and its height in every window, and persists.
            NSMenuItem *bandToggleItem = [[NSApp.mainMenu itemWithTitle:@"View"].submenu itemWithTitle:@"Show Focus Band"];
            BOOL toggleChecked = bandToggleItem && bandToggleItem.action == @selector(toggleFocusBand:) &&
                [timerWindowA validateMenuItem:bandToggleItem] && bandToggleItem.state == NSControlStateValueOn;
            NSRect shownTerminal = [timerWindowA.terminalView terminalRect];
            [timerWindowA toggleFocusBand:nil];
            BOOL hiddenEverywhere = bandA.hidden && bandB.hidden && timerWindowA.terminalView.focusBandHeight == 0 &&
                timerWindowB.terminalView.focusBandHeight == 0 &&
                ![[timerWindowA micaDefaults] boolForKey:@"MicaFocusBandVisible"] &&
                fabs([timerWindowA.terminalView terminalRect].size.height - shownTerminal.size.height - idleHeight) < 0.5;
            [timerWindowA validateMenuItem:bandToggleItem];
            BOOL toggleUnchecked = bandToggleItem.state == NSControlStateValueOff;
            [timerWindowB startPomodoro:nil];
            BOOL stillHiddenWhileRunning = bandA.hidden && timerWindowA.terminalView.focusBandHeight == 0;
            [timerWindowB resetPomodoro:nil];
            [timerWindowB toggleFocusBand:nil];
            BOOL shownAgain = !bandA.hidden && !bandB.hidden && timerWindowA.terminalView.focusBandHeight == idleHeight &&
                [[timerWindowA micaDefaults] boolForKey:@"MicaFocusBandVisible"];
            MicaUITestRecord(report, &allPassed, toggleChecked && hiddenEverywhere && toggleUnchecked && stillHiddenWhileRunning && shownAgain,
                [NSString stringWithFormat:@"Show Focus Band toggles every window, frees its height and persists (menu=%d hidden=%d unchecked=%d running=%d shown=%d)",
                    toggleChecked, hiddenEverywhere, toggleUnchecked, stillHiddenWhileRunning, shownAgain]);

            // Shortcut: unique key on the existing start/toggle item, injected into the band as the hint.
            NSMenuItem *focusToggleItem = [[NSApp.mainMenu itemWithTitle:@"Focus"].submenu itemWithTitle:@"Pause/Resume Focus"];
            NSEventModifierFlags shortcutMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
            NSUInteger shortcutUsers = 0;
            NSMutableArray<NSMenu *> *menusToScan = [NSMutableArray arrayWithObject:NSApp.mainMenu];
            while (menusToScan.count) {
                NSMenu *menu = menusToScan.lastObject;
                [menusToScan removeLastObject];
                for (NSMenuItem *candidate in menu.itemArray) {
                    if (candidate.submenu) [menusToScan addObject:candidate.submenu];
                    if ([candidate.keyEquivalent isEqualToString:@"p"] &&
                        (candidate.keyEquivalentModifierMask & NSEventModifierFlagDeviceIndependentFlagsMask) == shortcutMask) shortcutUsers++;
                }
            }
            BOOL shortcutAssigned = focusToggleItem.action == @selector(togglePomodoroPause:) && shortcutUsers == 1 &&
                [focusToggleItem.keyEquivalent isEqualToString:@"p"] &&
                (focusToggleItem.keyEquivalentModifierMask & NSEventModifierFlagDeviceIndependentFlagsMask) == shortcutMask;
            MicaUITestRecord(report, &allPassed, shortcutAssigned && idleHintShown,
                [NSString stringWithFormat:@"Option-Command-P starts, pauses and resumes focus, is used by one menu item, and shows as the band hint (assigned=%d users=%lu hint=%d)",
                    shortcutAssigned, (unsigned long)shortcutUsers, idleHintShown]);

            if (focusTab.session) { mica_session_destroy(focusTab.session); focusTab.session = NULL; }
            timerWindowA.tabs = [NSMutableArray array];
            [MicaFocusRecorderShared() flush];
            [[NSFileManager defaultManager] removeItemAtPath:focusLogPath error:nil];
            unsetenv("MICA_TEST_FOCUS_LOG_PATH");
            gMicaFocusRecorder = nil;
            gMicaFocusHold = nil;
        }
        gMicaDefaultsOverride = nil;
        [MicaControllers() removeAllObjects];
        [MicaControllers() addObjectsFromArray:savedTimerControllers];
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
            NSString *runningLabel = [layoutDelegate.terminalView labelForTab:configuredCommandTab];
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
            [[layoutDelegate.terminalView labelForTab:configuredCommandTab] isEqualToString:@"Claude Code"];
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
            command:@"stty -icanon -echo min 1 time 0; printf '\\033[?1049hMICA-KEYS-READY\\n'; keys=$(dd if=/dev/tty bs=1 count=5 2>/dev/null | od -An -t x1); printf '\\033[?1049lMICA-KEYS-RESULT:%s\\n' \"$keys\"; stty sane"
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
        MicaUITestSendKey(shortcutDelegate, @"↓", NSEventModifierFlagCommand, 125);
        BOOL controlKeysForwarded = NO;
        for (int attempt = 0; attempt < 300; attempt++) {
            [shortcutDelegate pollSessions:nil];
            if (MicaUITestFindText(shortcutTab.session, @"14  13", NULL, NULL) &&
                MicaUITestFindText(shortcutTab.session, @"1b  5b  42", NULL, NULL)) {
                controlKeysForwarded = YES;
                break;
            }
            usleep(10000);
        }
        MicaUITestSendKey(shortcutDelegate, @"p", NSEventModifierFlagCommand | NSEventModifierFlagShift, 35);
        BOOL pickerShortcutWorks = shortcutDelegate.commandPalettePanel != nil;
        [shortcutDelegate toggleCommandPalette:nil];
        MicaUITestSendKey(shortcutDelegate, @"s", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1);
        BOOL historyShortcutWorks = shortcutDelegate.uiMode == MicaUIModeScroll;
        MicaUITestSendKey(shortcutDelegate, @"s", NSEventModifierFlagCommand | NSEventModifierFlagShift, 1);
        historyShortcutWorks = historyShortcutWorks && shortcutDelegate.uiMode == MicaUIModeNormal;
        MicaUITestRecord(report, &allPassed,
            shortcutPromptReady && controlKeysForwarded && pickerShortcutWorks && historyShortcutWorks,
            [NSString stringWithFormat:@"Codex-safe app shortcuts leave Ctrl-T/Ctrl-S available and Command-Down reaches alternate-screen TUIs (ready=%d forwarded=%d picker=%d history=%d screen=%@)",
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
