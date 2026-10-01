// Captures the current native terminal view offscreen. Only local PTY commands run.
#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"

static void PollDemo(MicaAppDelegate *owner) {
    for (MicaTab *tab in owner.tabs) mica_session_poll(tab.session, 0);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *directory = @(argv[1]);
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) return 1;
        setenv("MICA_TEST_NO_STARTUP", "1", 1);
        unsetenv("MICA_TEST_ZLE_DIR");
        [NSApplication sharedApplication];
        MicaAppDelegate *owner = [MicaAppDelegate new];
        owner.tabs = [NSMutableArray new];
        owner.activeIndex = 0;
        owner.projectName = @"Mica Demo";
        owner.focusDurationMinutes = 25;
        owner.breakDurationMinutes = 5;
        owner.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 440)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        owner.window.releasedWhenClosed = NO;
        owner.terminalView = [[MicaTerminalView alloc] initWithFrame:owner.window.contentView.bounds];
        owner.terminalView.owner = owner;
        owner.terminalView.terminalFont = MicaTerminalFont(16);
        [owner.window setContentView:owner.terminalView];
        for (NSString *name in @[@"Shell", @"Preview", @"Agent"] ) {
            MicaTab *tab = [MicaTab new];
            tab.name = name;
            tab.cwd = @"/tmp";
            tab.session = mica_session_create("/tmp", nil, 24, 100);
            if (!tab.session) return 1;
            [owner.tabs addObject:tab];
        }
        [owner setLightTheme:NO];
        [owner.terminalView updateGridSize];
        MicaSession *session = owner.activeTab.session;
        const char *setup = "PROMPT='demo> '; RPROMPT=''; clear\n";
        mica_session_write(session, setup, strlen(setup));
        for (int attempt = 0; attempt < 100; attempt++) PollDemo(owner);
        NSArray<NSString *> *commands = @[@"printf 'Hello, Mica! 界🙂 café\\n'", @"seq 1 60"];
        NSMutableArray<NSArray<NSString *> *> *typedCommands = [NSMutableArray new];
        for (NSString *command in commands) {
            NSMutableArray<NSString *> *characters = [NSMutableArray new];
            [command enumerateSubstringsInRange:NSMakeRange(0, command.length) options:NSStringEnumerationByComposedCharacterSequences
                usingBlock:^(NSString *piece, NSRange range, NSRange enclosing, BOOL *stop) {
                    (void)range; (void)enclosing; (void)stop;
                    [characters addObject:piece];
                }];
            [typedCommands addObject:characters];
        }
        for (int frame = 0; frame < 160; frame++) {
            @autoreleasepool {
                if (frame >= 10 && frame < 50) {
                    NSArray<NSString *> *command = typedCommands[0];
                    NSUInteger index = (NSUInteger)(frame - 10);
                    if (index < command.count) {
                        NSData *bytes = [command[index] dataUsingEncoding:NSUTF8StringEncoding];
                        mica_session_write(session, bytes.bytes, bytes.length);
                    }
                    if (frame == 49) mica_session_key(session, VTERM_KEY_ENTER, VTERM_MOD_NONE);
                }
                if (frame >= 65 && frame < 74) {
                    NSArray<NSString *> *command = typedCommands[1];
                    NSUInteger index = (NSUInteger)(frame - 65);
                    if (index < command.count) {
                        NSData *bytes = [command[index] dataUsingEncoding:NSUTF8StringEncoding];
                        mica_session_write(session, bytes.bytes, bytes.length);
                    }
                    if (frame == 73) mica_session_key(session, VTERM_KEY_ENTER, VTERM_MOD_NONE);
                }
                if (frame == 85) {
                    MicaPomodoro timer = owner.pomodoro;
                    mica_pomodoro_start(&timer, MicaContinuousTimeSeconds(), 25 * 60);
                    owner.pomodoro = timer;
                }
                if (frame == 95) mica_session_scroll(session, 12);
                if (frame == 100) {
                    long cursor = -1;
                    if (!mica_session_find(session, "Hello, Mica!", true, &cursor)) return 1;
                }
                if (frame == 110) {
                    MicaPomodoro timer = owner.pomodoro;
                    timer.phase = MICA_POMODORO_BREAK;
                    timer.deadline = MicaContinuousTimeSeconds() + 5 * 60;
                    timer.completed_focuses = 1;
                    owner.pomodoro = timer;
                }
                if (frame == 135) {
                    MicaPomodoro timer = owner.pomodoro;
                    mica_pomodoro_toggle_pause(&timer, MicaContinuousTimeSeconds());
                    owner.pomodoro = timer;
                }
                if (frame == 145) [owner setLightTheme:YES];
                if (frame == 155) { [owner setLightTheme:NO]; mica_session_scroll_to_bottom(session); }
                PollDemo(owner);
                [owner.terminalView setNeedsDisplay:YES];
                NSView *view = owner.terminalView;
                NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
                NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%04d.png", frame]];
                if (!png || ![png writeToFile:path atomically:YES]) return 1;
            }
        }
        for (MicaTab *tab in owner.tabs) { mica_session_destroy(tab.session); tab.session = NULL; }
        printf("Captured 160 current-UI frames with local PTY output.\n");
    }
    return 0;
}
