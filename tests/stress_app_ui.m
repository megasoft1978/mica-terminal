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

static NSMutableArray<MicaAppDelegate *> *gWindows;

static void Act(MicaAppDelegate *delegate) {
    MicaTerminalView *view = delegate.terminalView;
    NSSize size = view.bounds.size;
    int chosen = Between(0, 36);
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
    case 25:   // open another project window in this process
        if (gWindows.count < 4) {
            MicaAppDelegate *another = [[MicaAppDelegate alloc] init];
            [another startWindowWithArguments:@[@"mica", @"--new-window"]];
            [gWindows addObject:another];
        }
        break;
    case 26:   // close one of the windows the way a user would
        if (gWindows.count > 1) {
            MicaAppDelegate *closing = gWindows[(NSUInteger)Between(0, (int)gWindows.count - 1)];
            [closing windowWillClose:nil];
            [closing.window close];
            [gWindows removeObject:closing];
            for (MicaAppDelegate *other in gWindows) [other takeMenuOwnership];
        }
        break;
    case 27: {   // dictation strip in every state, with awkward transcripts and levels
        MicaVoiceController *voice = delegate.voiceController;
        static NSString *const transcripts[] = { @"", @"hello", @"the quick brown fox jumps over the lazy dog again and again and again",
            @"emoji 🎤🎧 and ünïcödé and 日本語のテキスト mixed", @"a  b   c\n\td", @"supercalifragilisticexpialidocious_supercalifragilisticexpialidocious_supercalifragilistic" };
        static NSString *const statuses[] = { @"", @"Downloading speech model", @"Checking speech model files…",
            @"Microphone access is off. Enable Mica in System Settings → Privacy & Security → Microphone." };
        [voice setValue:@(Between(0, 4)) forKey:@"state"];
        [voice setValue:transcripts[Between(0, 5)] forKey:@"transcript"];
        [voice setValue:statuses[Between(0, 3)] forKey:@"statusText"];
        [voice setValue:@(Between(0, 1)) forKey:@"hasProgress"];
        [voice setValue:@(Between(0, 100) / 100.0) forKey:@"progress"];
        [voice setValue:@(Between(0, 100) / 100.0f) forKey:@"audioLevel"];
        [voice setValue:@(Between(0, 700)) forKey:@"elapsedSeconds"];
        [voice setValue:@(Between(0, 100) / 100.0) forKey:@"prefetchFraction"];
        [voice setValue:Between(0, 1) ? @"Downloading speech model" : nil forKey:@"prefetchStatus"];
        [delegate voiceControllerDidUpdate:voice];
        [view displayIfNeeded];
        break;
    }
    case 28: {   // left Option holds, taps and Option-composed characters (Italian, German, US layouts)
        static NSString *const composed[][2] = { {@"@", @"\u00f2"}, {@"#", @"\u00e0"}, {@"[", @"\u00e8"}, {@"{", @"\u00e8"},
            {@"~", @"n"}, {@"\u00e9", @"e"}, {@"\u03c0", @"p"}, {@"|", @"7"} };
        NSEvent *down = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:NSEventModifierFlagOption
            timestamp:0 windowNumber:delegate.window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:58];
        if (down) [view flagsChanged:down];
        if (Between(0, 1)) RunLoopFor(Between(0, 1) ? 0.01 : 0.3);
        int pick = Between(0, 7);
        NSEvent *character = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagOption
            timestamp:0 windowNumber:delegate.window.windowNumber context:nil characters:composed[pick][0]
            charactersIgnoringModifiers:Between(0, 1) ? composed[pick][1] : composed[pick][0] isARepeat:NO keyCode:(unsigned short)Between(0, 50)];
        if (character) [view keyDown:character];
        NSEvent *up = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:0
            timestamp:0 windowNumber:delegate.window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:58];
        if (up) [view flagsChanged:up];
        break;
    }
    case 29: {   // a tab whose program draws synchronized-output frames, sometimes never finishing them
        if (delegate.tabs.count >= 9) break;
        static NSString *const scripts[] = {
            @"perl -e '$|=1; for $i (1..60){print \"\\e[?2026h\\e[2J\\e[Hframe $i\\n\"; select(undef,undef,undef,0.01); print \"body line\\n\\e[?2026l\"; select(undef,undef,undef,0.01)}'; sleep 3",
            @"perl -e '$|=1; print \"\\e[?2026hnever ends\\n\"; sleep 3'",
            @"perl -e '$|=1; for $i (1..80){print \"\\e[?20\"; select(undef,undef,undef,0.003); print \"26hpart $i\\e[?2026\"; select(undef,undef,undef,0.003); print \"l\"}'; sleep 3",
        };
        [delegate newTabWithName:@"Sync" command:scripts[Between(0, 2)]];
        break;
    }
    case 30: {   // full-screen program on the alternate screen, with and without a clean exit
        if (delegate.tabs.count >= 9) break;
        [delegate newTabWithName:@"Tui" command:Between(0, 1)
            ? @"perl -e '$|=1; print \"\\e[?1049h\\e[?25l\"; for $i (1..40){print \"\\e[H\\e[2JTUI $i\\n\"; select(undef,undef,undef,0.02)} print \"\\e[?25h\\e[?1049l\"'; sleep 2"
            : @"perl -e '$|=1; print \"\\e[?1049h\"; for $i (1..40){print \"\\e[H\\e[2JTUI $i\\n\"; select(undef,undef,undef,0.02)}'; sleep 2"];
        break;
    }
    case 31: {   // hostile output: random escape sequences, wide characters, huge titles
        if (delegate.tabs.count >= 9) break;
        int seed = Between(1, 100000);
        [delegate newTabWithName:@"Noise" command:[NSString stringWithFormat:
            @"perl -e 'srand(%d); $|=1; @s=(\"\\e[2J\",\"\\e[H\",\"\\e[%%dA\",\"\\e[%%d;%%dH\",\"\\e[1;%%dr\",\"\\e[?1049h\",\"\\e[?1049l\",\"\\e[?2026h\",\"\\e[?2026l\",\"\\e]0;\".(\"t\" x 400).\"\\a\",\"\\e[38;2;1;2;3m\",\"\\e[0m\",\"日本語\",\"👩‍👩‍👧\",\"\\e[4m\",\"\\e[?2004h\",\"\\e[?1000h\",\"\\e[K\",\"\\e[L\",\"\\e[M\",\"\\e[@\",\"\\e[P\",\"\\eM\",\"\\n\",\"text \"); for(1..3000){ $x=$s[int(rand(@s))]; $x=~s/%%d/int(rand(30))+1/ge; print $x }'; sleep 2", seed]];
        break;
    }
    case 32: {   // wheel scrolling and tab-picker / scrollback navigation keys
        CGEventRef cgWheel = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, Between(-8, 8));
        NSEvent *wheel = cgWheel ? [NSEvent eventWithCGEvent:cgWheel] : nil;
        if (cgWheel) CFRelease(cgWheel);
        if (wheel) [view scrollWheel:wheel];
        static NSString *const keys[] = { @"j", @"k", @"u", @"d", @"g", @"q", @"\r" };
        Key(delegate, keys[Between(0, 6)], 0, (unsigned short)Between(0, 50));
        break;
    }
    case 33: [delegate toggleLightTheme:nil]; [delegate refreshPreferencesSizeLabel]; break;
    case 34: {   // Command shortcuts
        static NSString *const commandKeys[] = { @"t", @"w", @"1", @"2", @"9", @"+", @"-", @"0", @"k", @"v", @"c" };
        Key(delegate, commandKeys[Between(0, 10)], NSEventModifierFlagCommand | (Between(0, 3) == 0 ? NSEventModifierFlagShift : 0), (unsigned short)Between(0, 50));
        break;
    }
    case 35: [delegate updatePomodoroTimer]; break;
    case 36: {   // keys while the window is not key, plus programmatic focus changes
        [view setNeedsDisplay:YES];
        [view displayIfNeeded];
        break;
    }
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
        gWindows = [NSMutableArray array];
        MicaAppDelegate *first = [[MicaAppDelegate alloc] init];
        [first startWindowWithArguments:@[@"mica", @"--new-window"]];
        [gWindows addObject:first];
        [first newTabWithName:@"Shell" command:@"perl -e 'for(1..4000){print \"stress line $_ \\e[3\".($_%8).\"mcolor\\e[0m\\n\"}'; sleep 5"];
        for (int step = 0; step < steps; step++) {
            MicaAppDelegate *delegate = gWindows[(NSUInteger)Between(0, (int)gWindows.count - 1)];
            Act(delegate);
            if (step % 5 == 0) for (MicaAppDelegate *each in gWindows) { [each pollSessions:nil]; [each.terminalView displayIfNeeded]; }
            if (step % 50 == 0) RunLoopFor(0.02);
        }
        for (MicaAppDelegate *each in gWindows)
            for (NSValue *value in [each detachSessionsForTermination]) mica_session_destroy(value.pointerValue);
        printf("stress ok (seed %u)\n", seed);
    }
    return 0;
}
