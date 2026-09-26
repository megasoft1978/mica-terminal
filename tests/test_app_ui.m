#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"
#import <ApplicationServices/ApplicationServices.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

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

static void MicaUITestSendWheel(MicaAppDelegate *delegate, int deltaY) {
    CGEventRef cgEvent = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, deltaY);
    if (!cgEvent) return;
    NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
    CFRelease(cgEvent);
    if (event) [delegate.terminalView scrollWheel:event];
}

static int MicaRunUISelfTest(void) {
    @autoreleasepool {
        NSMutableString *report = [NSMutableString string];
        BOOL allPassed = YES;
        setenv("MICA_TEST_NO_STARTUP", "1", 1);
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;

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
        NSMenuItem *claudeMenuItem = [sessionMenu itemWithTitle:@"New Claude Code Tab"];
        NSMenuItem *codexMenuItem = [sessionMenu itemWithTitle:@"New Codex Tab"];
        NSEventModifierFlags agentModifiers = NSEventModifierFlagCommand | NSEventModifierFlagOption;
        MicaUITestRecord(report, &allPassed,
                         claudeMenuItem.target == delegate && [claudeMenuItem.keyEquivalent isEqualToString:@"c"] &&
                         (claudeMenuItem.keyEquivalentModifierMask & agentModifiers) == agentModifiers &&
                         codexMenuItem.target == delegate && [codexMenuItem.keyEquivalent isEqualToString:@"x"] &&
                         (codexMenuItem.keyEquivalentModifierMask & agentModifiers) == agentModifiers,
                         @"Claude Code and Codex menu shortcuts target the app delegate");

        [delegate loadLaunchConfiguration];
        MicaTab *defaultTab = delegate.activeTab;
        MicaUITestRecord(report, &allPassed, delegate.tabs.count == 1 && defaultTab.session != NULL &&
                         [defaultTab.name isEqualToString:@"Shell"] &&
                         [defaultTab.cwd isEqualToString:NSFileManager.defaultManager.currentDirectoryPath],
                         @"default launch configuration creates a shell tab in the working directory");
        delegate.tabs = [NSMutableArray array];
        delegate.activeIndex = 0;

        NSString *fixture = @"i=1; while [ \"$i\" -le 45 ]; do printf 'ROW-%02d\\n' \"$i\"; i=$((i+1)); done; "
            "printf '\\033[38;2;244;135;113mUI-TRUECOLOR\\033[0m\\n'; "
            "printf '\\033[48;2;18;52;86mUI-BLOCK\\033[0m\\n'; "
            "printf 'UI-EMOJI-🙂-👍🏽-👩‍💻-🇮🇹-❤️\\n'";
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
        MicaUITestRecord(report, &allPassed, delegate.terminalView.terminalFont.pointSize >= 16,
                         @"default terminal font remains at least 16 points");

        if (delegate.tabs.count == 3 && fixtureReady) {
            [delegate selectTabAtIndex:0];
            MicaUITestSendKey(delegate, @"t", NSEventModifierFlagControl, 17);
            MicaUITestSendKey(delegate, @"l", 0, 37);
            BOOL nextTabWorked = delegate.activeIndex == 1 && delegate.uiMode == MicaUIModeTab;
            MicaUITestSendKey(delegate, @"j", 0, 38);
            BOOL secondNavigationWorked = delegate.activeIndex == 2;
            MicaUITestSendKey(delegate, @"t", NSEventModifierFlagControl, 17);
            MicaUITestRecord(report, &allPassed, nextTabWorked && secondNavigationWorked && delegate.uiMode == MicaUIModeNormal,
                             @"Ctrl-T tab mode, hjkl navigation and return to normal mode work");

            MicaUITestSendKey(delegate, @"t", NSEventModifierFlagControl, 17);
            MicaUITestSendKey(delegate, @"1", 0, 18);
            BOOL digitJumpWorked = delegate.activeIndex == 0 && delegate.uiMode == MicaUIModeNormal;
            MicaUITestSendKey(delegate, @"t", NSEventModifierFlagControl, 17);
            MicaUITestSendKey(delegate, @"n", 0, 45);
            BOOL newTabWorked = delegate.tabs.count == 4 && delegate.activeIndex == 3 && delegate.uiMode == MicaUIModeNormal;
            MicaUITestSendKey(delegate, @"t", NSEventModifierFlagControl, 17);
            MicaUITestSendKey(delegate, @"x", 0, 7);
            BOOL closeTabWorked = delegate.tabs.count == 3 && delegate.uiMode == MicaUIModeNormal;
            MicaUITestRecord(report, &allPassed, digitJumpWorked && newTabWorked && closeTabWorked,
                             @"tab mode number jump, new tab and close tab actions work");

            [delegate selectTabAtIndex:0];
            [delegate.terminalView updateGridSize];
            MicaUITestSendKey(delegate, @"s", NSEventModifierFlagControl, 1);
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

            NSPasteboard *testPasteboard = [NSPasteboard pasteboardWithName:@"MicaUITestClipboard"];
            setenv("MICA_TEST_PASTEBOARD_NAME", "MicaUITestClipboard", 1);
            [testPasteboard clearContents];
            [testPasteboard setString:@"printf 'MICA-CLIPBOARD-OUTPUT-%s\\n' EXECUTED"
                               forType:NSPasteboardTypeString];
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
            [testPasteboard clearContents];
            [testPasteboard setData:clipboardPNG forType:NSPasteboardTypePNG];
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
            unsetenv("MICA_TEST_PASTEBOARD_NAME");
            [testPasteboard releaseGlobally];

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
                delegate.agentCommands = @{@"codex.start": codexLaunchCommand};
                [delegate newCodex:nil];
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
                MicaUITestSendKey(delegate, @"s", NSEventModifierFlagControl, 1);
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
                MicaUITestSendKey(delegate, @"s", NSEventModifierFlagControl, 1);
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

            CGFloat originalFontSize = delegate.terminalView.terminalFont.pointSize;
            MicaUITestSendKey(delegate, @"+", NSEventModifierFlagCommand, 24);
            BOOL fontGrew = delegate.terminalView.terminalFont.pointSize == originalFontSize + 1;
            MicaUITestSendKey(delegate, @"-", NSEventModifierFlagCommand, 27);
            MicaUITestRecord(report, &allPassed, fontGrew && delegate.terminalView.terminalFont.pointSize == originalFontSize,
                             @"Command-plus and Command-minus adjust font size");

            [delegate selectTabAtIndex:0];
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

            if (bitmapReady) {
                NSInteger blockRow = 0, blockCol = 0;
                NSFont *font = delegate.terminalView.terminalFont;
                NSDictionary *fontAttrs = @{ NSFontAttributeName: font };
                CGFloat cellWidth = ceil([@"M" sizeWithAttributes:fontAttrs].width);
                CGFloat lineHeight = ceil(font.ascender - font.descender + font.leading + 1.0);
                NSRect terminalArea = [delegate.terminalView terminalRect];
                BOOL blockFound = MicaUITestFindText(fixtureTab.session, @"UI-BLOCK", &blockRow, &blockCol);
                CGFloat scaleX = bitmap.pixelsWide / MAX(delegate.terminalView.bounds.size.width, 1.0);
                CGFloat scaleY = bitmap.pixelsHigh / MAX(delegate.terminalView.bounds.size.height, 1.0);
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

        char projectLayoutDirectory[] = "/tmp/mica-project-layouts-XXXXXX";
        NSString *projectLayoutRoot = mkdtemp(projectLayoutDirectory)
            ? [NSString stringWithUTF8String:projectLayoutDirectory] : nil;
        NSString *projectALayout = [projectLayoutRoot stringByAppendingPathComponent:@"alpha.mica"];
        NSString *projectBLayout = [projectLayoutRoot stringByAppendingPathComponent:@"beta.mica"];
        NSString *agentLayout = [projectLayoutRoot stringByAppendingPathComponent:@"agent.mica"];
        NSString *projectALayoutContents = @"# Mica layout v1\n"
            "agent.claude.start\tprintf 'PROJECT-A-CLAUDE-START'\n"
            "agent.claude.resume\tprintf 'PROJECT-A-CLAUDE-RESUME'\n"
            "agent.codex.start\tprintf 'PROJECT-A-CODEX-START'\n"
            "agent.codex.resume\tprintf 'PROJECT-A-CODEX-RESUME'\n"
            "Claude Code 1\t/tmp\tprintf 'PROJECT-A-PREFILLED'\nShell\t/tmp\t\n";
        NSString *projectBLayoutContents = @"# Mica layout v1\n"
            "agent.claude.start\tprintf 'PROJECT-B-CLAUDE-START'\n"
            "agent.codex.start\tprintf 'PROJECT-B-CODEX-START'\n"
            "Codex\t/tmp\tprintf 'PROJECT-B-PREFILLED'\nShell\t/tmp\t\n";
        NSString *agentLayoutContents = @"# Mica layout v1\n"
            "agent.claude.start\tprintf 'PROJECT-A-CLAUDE-START'\n"
            "agent.claude.resume\tprintf 'PROJECT-A-CLAUDE-RESUME'\n";
        NSError *projectLayoutError = nil;
        BOOL projectLayoutsWritten = projectLayoutRoot &&
            [projectALayoutContents writeToFile:projectALayout atomically:YES encoding:NSUTF8StringEncoding error:&projectLayoutError] &&
            [projectBLayoutContents writeToFile:projectBLayout atomically:YES encoding:NSUTF8StringEncoding error:&projectLayoutError] &&
            [agentLayoutContents writeToFile:agentLayout atomically:YES encoding:NSUTF8StringEncoding error:&projectLayoutError];
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
        NSDictionary<NSString *, NSString *> *projectAAgentCommands = projectA[@"agentCommands"];
        NSDictionary<NSString *, NSString *> *projectBAgentCommands = projectB[@"agentCommands"];
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
            [projectAAgentCommands[@"claude.start"] isEqualToString:@"printf 'PROJECT-A-CLAUDE-START'"] &&
            [projectAAgentCommands[@"claude.resume"] isEqualToString:@"printf 'PROJECT-A-CLAUDE-RESUME'"] &&
            [projectAAgentCommands[@"codex.start"] isEqualToString:@"printf 'PROJECT-A-CODEX-START'"] &&
            [projectAAgentCommands[@"codex.resume"] isEqualToString:@"printf 'PROJECT-A-CODEX-RESUME'"] &&
            [projectBAgentCommands[@"claude.start"] isEqualToString:@"printf 'PROJECT-B-CLAUDE-START'"] &&
            [projectBAgentCommands[@"codex.start"] isEqualToString:@"printf 'PROJECT-B-CODEX-START'"] &&
            [projectA[@"projectName"] isEqualToString:@"Project Alpha"] &&
            [projectB[@"projectName"] isEqualToString:@"Project Beta"] &&
            [[projectATitle windowTitleForTab:projectATitleTab] containsString:@"Project Alpha"] &&
            [[projectBTitle windowTitleForTab:projectBTitleTab] containsString:@"Project Beta"] &&
            [projectA[@"activeIndex"] integerValue] == 0 &&
            [projectB[@"activeIndex"] integerValue] == 0;
        MicaUITestRecord(report, &allPassed, projectAppsIndependent,
                         [NSString stringWithFormat:@"per-project layouts resolve separate tabs, agent commands and window titles (A=%lu/%@ B=%lu/%@)%@",
                          (unsigned long)projectATabs.count, projectAFirstTab[@"name"],
                          (unsigned long)projectBTabs.count, projectBFirstTab[@"name"],
                          projectLayoutError ? [NSString stringWithFormat:@" error: %@", projectLayoutError.localizedDescription] : @""]);

        MicaAppDelegate *layoutDelegate = [[MicaAppDelegate alloc] init];
        layoutDelegate.tabs = [NSMutableArray array];
        layoutDelegate.activeIndex = 0;
        if (projectLayoutsWritten)
            [layoutDelegate loadLaunchConfigurationFromArguments:@[@"mica", @"--layout", agentLayout]
                                                      bundleInfo:@{}];
        [layoutDelegate newClaude:nil];
        MicaTab *configuredAgentTab = layoutDelegate.activeTab;
        [layoutDelegate selectTabAtIndex:0];
        BOOL configuredAgentStarted = NO;
        for (int attempt = 0; projectLayoutsWritten && attempt < 300; attempt++) {
            [layoutDelegate pollSessions:nil];
            if (configuredAgentTab.completedCommand) {
                configuredAgentStarted = MicaUITestFindText(configuredAgentTab.session,
                    @"PROJECT-A-CLAUDE-START", NULL, NULL) &&
                    configuredAgentTab.completionStatus == 0 && configuredAgentTab.needsAttention;
                break;
            }
            usleep(10000);
        }
        [layoutDelegate resumeClaude:nil];
        MicaTab *configuredResumeTab = layoutDelegate.activeTab;
        BOOL resumeCommandConfigured =
            [configuredResumeTab.command isEqualToString:@"printf 'PROJECT-A-CLAUDE-RESUME'"];
        if (layoutDelegate.attentionRequest != 0)
            [NSApp cancelUserAttentionRequest:layoutDelegate.attentionRequest];
        BOOL layoutSessionsExited = MicaUITestExitTabs(layoutDelegate.tabs);
        layoutDelegate.tabs = [NSMutableArray array];
        MicaUITestRecord(report, &allPassed, configuredAgentStarted && resumeCommandConfigured && layoutSessionsExited,
                         @"layout agent command starts in a real PTY, reports completion, has a separate resume command, and closes cleanly");

        MicaAppDelegate *unconfiguredDelegate = [[MicaAppDelegate alloc] init];
        unconfiguredDelegate.tabs = [NSMutableArray array];
        unconfiguredDelegate.activeIndex = 0;
        [unconfiguredDelegate addTabWithName:@"Shell" cwd:@"/tmp" command:nil prefilled:NO];
        [unconfiguredDelegate newClaude:nil];
        BOOL unconfiguredAgentUsesShell =
            [unconfiguredDelegate.activeTab.name isEqualToString:@"Shell"] &&
            [[NSString stringWithUTF8String:mica_session_command(unconfiguredDelegate.activeTab.session)]
                isEqualToString:@"/bin/zsh -l -i"];
        BOOL unconfiguredSessionExited = MicaUITestExitTabs(unconfiguredDelegate.tabs);
        unconfiguredDelegate.tabs = [NSMutableArray array];
        MicaUITestRecord(report, &allPassed, unconfiguredAgentUsesShell && unconfiguredSessionExited,
                         @"agent shortcuts open a plain zsh tab when no local command is configured and close cleanly");
        if (projectLayoutRoot) [[NSFileManager defaultManager] removeItemAtPath:projectLayoutRoot error:nil];

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
