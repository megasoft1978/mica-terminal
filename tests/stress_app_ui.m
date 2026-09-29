// App-level stress test: drives the real AppKit view with thousands of random user actions (tabs, keys,
// mouse, resize, find, clear, theme, settings, paste, dictation state) and expects no crash or sanitizer
// report. Build and run with `make stress` (AddressSanitizer + UBSan).
#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"

static unsigned int rngState = 1;
static unsigned int Next(void) { rngState = rngState * 1664525u + 1013904223u; return rngState >> 8; }
static int Between(int low, int high) { return low + (int)(Next() % (unsigned)(high - low + 1)); }

static void RunLoopFor(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void Key(MicaAppDelegate *delegate, NSString *characters, NSEventModifierFlags modifiers, unsigned short keyCode) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
        timestamp:0 windowNumber:delegate.window.windowNumber context:nil characters:characters
        charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
    if (event) [delegate.terminalView keyDown:event];
}

static void Mouse(MicaAppDelegate *delegate, NSEventType type, NSPoint point, NSEventModifierFlags modifiers, NSInteger clicks) {
    NSPoint windowPoint = [delegate.terminalView convertPoint:point toView:nil];
    NSEvent *event = [NSEvent mouseEventWithType:type location:windowPoint modifierFlags:modifiers timestamp:0
        windowNumber:delegate.window.windowNumber context:nil eventNumber:0 clickCount:clicks pressure:1.0];
    if (!event) return;
    if (type == NSEventTypeLeftMouseDown) [delegate.terminalView mouseDown:event];
    else if (type == NSEventTypeLeftMouseDragged) [delegate.terminalView mouseDragged:event];
    else if (type == NSEventTypeLeftMouseUp) [delegate.terminalView mouseUp:event];
}

static void Act(MicaAppDelegate *delegate) {
    MicaTerminalView *view = delegate.terminalView;
    NSSize size = view.bounds.size;
    int chosen = Between(0, 24);
    const char *only = getenv("STRESS_ONLY");
    if (only && chosen != atoi(only)) return;
    switch (chosen) {
    case 0: if (delegate.tabs.count < 9) [delegate newTabWithName:@"Shell" command:nil]; break;
    case 1: if (delegate.tabs.count > 1) [delegate closeActiveTab]; break;
    case 2: [delegate selectTabAtIndex:Between(0, (int)delegate.tabs.count - 1)]; break;
    case 3: [delegate selectRelativeTab:Between(0, 1) ? 1 : -1]; break;
    case 4: {
        CGFloat width = Between(600, 1600), height = Between(300, 1000);
        [delegate.window setContentSize:NSMakeSize(width, height)];
        [view scheduleGridResize];
        break;
    }
    case 5: [view updateGridSize]; [delegate resizeActiveSession]; break;
    case 6: Key(delegate, @"f", NSEventModifierFlagCommand, 3); break;   // find prompt is modal; skipped in test env
    case 7: Key(delegate, @"k", NSEventModifierFlagCommand, 40); break;  // clear scrollback
    case 8: [delegate setLightTheme:Between(0, 1)]; break;
    case 9: [delegate applyCursorStyle:Between(0, 2)]; break;
    case 10: [delegate toggleTabPicker]; break;
    case 11: [delegate toggleScrollback]; break;
    case 12: {
        static const char *letters = "abcdefghijklmnopqrstuvwxyz0123456789 ;:'\"[]{}\\/|<>?,.-_=+!@#$%^&*()";
        char letter[2] = { letters[Between(0, (int)strlen(letters) - 1)], 0 };
        Key(delegate, @(letter), Between(0, 1) ? NSEventModifierFlagShift : 0, (unsigned short)Between(0, 60));
        break;
    }
    case 13: Key(delegate, @"\r", 0, 36); break;
    case 14: Key(delegate, @"\x1b", 0, 53); break;
    case 15: Key(delegate, @"c", NSEventModifierFlagControl, 8); break;
    case 16: Key(delegate, @"\uF700", 0, 126); break;
    case 17: {
        NSPoint a = NSMakePoint(Between(0, (int)size.width), Between(0, (int)size.height));
        NSPoint b = NSMakePoint(Between(0, (int)size.width), Between(0, (int)size.height));
        Mouse(delegate, NSEventTypeLeftMouseDown, a, 0, 1);
        Mouse(delegate, NSEventTypeLeftMouseDragged, b, 0, 1);
        Mouse(delegate, NSEventTypeLeftMouseUp, b, 0, 1);
        break;
    }
    case 18: Mouse(delegate, NSEventTypeLeftMouseDown, NSMakePoint(Between(0, (int)size.width), size.height - 10), 0, Between(1, 2));
             Mouse(delegate, NSEventTypeLeftMouseUp, NSMakePoint(Between(0, (int)size.width), size.height - 10), 0, 1); break;
    case 19: if (view.hasTextSelection) [view copySelection:nil]; break;
    case 20: [view clearSelection]; [view setNeedsDisplay:YES]; break;
    case 21: {
        NSPasteboard *board = NSPasteboard.generalPasteboard;
        [board clearContents];
        [board setString:@"echo stress-paste\n" forType:NSPasteboardTypeString];
        [view paste:nil];
        break;
    }
    case 22: [delegate openPreferences:nil]; [delegate.preferencesWindow close]; break;
    case 23: [delegate updateWindowTitle]; break;
    case 24: [delegate pollSessions:nil]; break;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int seed = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : (unsigned)time(NULL);
        int steps = argc > 2 ? atoi(argv[2]) : 1500;
        rngState = seed;
        printf("stress seed %u, %d steps\n", seed, steps);
        setenv("MICA_TEST_NO_STARTUP", "1", 1);
        [NSApplication sharedApplication];
        MicaAppDelegate *delegate = [[MicaAppDelegate alloc] init];
        delegate.tabs = [NSMutableArray array];
        delegate.activeIndex = 0;
        delegate.uiMode = MicaUIModeNormal;
        delegate.projectName = @"Stress";
        delegate.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        delegate.window.releasedWhenClosed = NO;
        delegate.terminalView = [[MicaTerminalView alloc] initWithFrame:delegate.window.contentView.bounds];
        delegate.terminalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        delegate.terminalView.owner = delegate;
        delegate.terminalView.terminalFont = MicaTerminalFont(15);
        [delegate.window setContentView:delegate.terminalView];
        delegate.window.delegate = delegate;
        [delegate installMenus];
        [delegate newTabWithName:@"Shell" command:@"perl -e 'for(1..4000){print \"stress line $_ \\e[3\".($_%8).\"mcolor\\e[0m\\n\"}'; sleep 5"];
        [delegate newTabWithName:@"Shell" command:nil];
        for (int step = 0; step < steps; step++) {
            Act(delegate);
            if (step % 5 == 0) { [delegate pollSessions:nil]; [delegate.terminalView displayIfNeeded]; }
            if (step % 50 == 0) RunLoopFor(0.02);
        }
        for (MicaTab *tab in delegate.tabs) if (tab.session) { mica_session_destroy(tab.session); tab.session = NULL; }
        printf("stress ok (seed %u)\n", seed);
    }
    return 0;
}
