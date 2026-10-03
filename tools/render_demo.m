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
        // Companion stills make the cycle's discovery controls legible beside the animated terminal demo.
        const char *samples = "clear; printf 'https://example.test/guide  /Users/megasoft78/Desktop/Freelance/mica-terminal/README.md  3f9c1a2\\n'\n";
        mica_session_write(session, samples, strlen(samples));
        for (int attempt = 0; attempt < 40; attempt++) PollDemo(owner);
        [owner.terminalView toggleQuickSelect:nil];
        NSBitmapImageRep *quickBitmap = [owner.terminalView bitmapImageRepForCachingDisplayInRect:owner.terminalView.bounds];
        [owner.terminalView cacheDisplayInRect:owner.terminalView.bounds toBitmapImageRep:quickBitmap];
        NSData *quickPNG = [quickBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!quickPNG || ![quickPNG writeToFile:[directory stringByAppendingPathComponent:@"quick-select-demo.png"] atomically:YES]) return 1;
        [owner.terminalView toggleQuickSelect:nil];
        [owner toggleCommandPalette:nil];
        NSView *palette = owner.commandPalettePanel.contentView;
        NSBitmapImageRep *paletteBitmap = [palette bitmapImageRepForCachingDisplayInRect:palette.bounds];
        [palette cacheDisplayInRect:palette.bounds toBitmapImageRep:paletteBitmap];
        NSData *palettePNG = [paletteBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!palettePNG || ![palettePNG writeToFile:[directory stringByAppendingPathComponent:@"command-palette-demo.png"] atomically:YES]) return 1;
        [owner toggleCommandPalette:nil];
        const char *landmarks = "clear; printf '\\033]133;A\\007'; printf 'demo> '; printf '\\033]133;B\\007'; printf 'git status --short\\n'; printf '\\033]133;C\\007'; printf ' M src/mica_app.m\\n'; printf '\\033]133;D;1\\007'; printf '\\033]133;A\\007'; printf 'demo> '; printf '\\033]133;B\\007'; printf 'make test\\n'; printf '\\033]133;C\\007'; printf '✓ tests passed\\n'; printf '\\033]133;D;0\\007'; printf '\\033]133;A\\007'; printf 'demo> ';\n";
        mica_session_write(session, landmarks, strlen(landmarks));
        for (int attempt = 0; attempt < 60; attempt++) PollDemo(owner);
        if (!mica_session_jump_prompt(session, -1)) return 1;
        [owner.terminalView setNeedsDisplay:YES];
        NSBitmapImageRep *promptBitmap = [owner.terminalView bitmapImageRepForCachingDisplayInRect:owner.terminalView.bounds];
        [owner.terminalView cacheDisplayInRect:owner.terminalView.bounds toBitmapImageRep:promptBitmap];
        NSData *promptPNG = [promptBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!promptPNG || ![promptPNG writeToFile:[directory stringByAppendingPathComponent:@"prompt-navigation-demo.png"] atomically:YES]) return 1;
        mica_session_destroy(session);
        session = mica_session_create("/tmp", nil, 24, 100);
        if (!session) return 1;
        owner.activeTab.session = session;
        for (int attempt = 0; attempt < 30; attempt++) PollDemo(owner);
        NSString *rawTranscript = @"Open Mica Terminal";
        NSString *correctedTranscript = MicaCorrectTranscript(rawTranscript, @[@"MicaTerminal"]);
        NSString *correction = [NSString stringWithFormat:@"clear; printf 'Fake transcript (no microphone)\\nraw: %@\\ncorrected: %@\\nEdit Vocabulary… · Undo restores raw\\n'\n", rawTranscript, correctedTranscript];
        mica_session_write(session, correction.UTF8String, strlen(correction.UTF8String));
        for (int attempt = 0; attempt < 50; attempt++) PollDemo(owner);
        NSBitmapImageRep *vocabBitmap = [owner.terminalView bitmapImageRepForCachingDisplayInRect:owner.terminalView.bounds];
        [owner.terminalView cacheDisplayInRect:owner.terminalView.bounds toBitmapImageRep:vocabBitmap];
        NSData *vocabPNG = [vocabBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!vocabPNG || ![vocabPNG writeToFile:[directory stringByAppendingPathComponent:@"vocabulary-correction-demo.png"] atomically:YES]) return 1;

        // Capture the shipped SSH profile manager with fictional destinations. No SSH connection is started.
        NSString *suiteName = [NSString stringWithFormat:@"mica-demo-ssh-%d", getpid()];
        NSUserDefaults *demoDefaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        gMicaDefaultsOverride = demoDefaults;
        [demoDefaults setObject:@{ @"version": @1, @"profiles": @[
            @{ @"id": @"86C213DD-CE1A-4F58-A6A0-25033E4C48AF", @"name": @"Mac Studio", @"destination": @"studio.local", @"remoteDirectory": @"~/Projects" },
            @{ @"id": @"A09E195A-D7C9-4DF1-9019-E11633198ED2", @"name": @"Linux · VPN", @"destination": @"devbox", @"remoteDirectory": @"/home/mica/work" }
        ] } forKey:@"MicaSSHProfiles"];
        MicaSSHProfilesController *profilesController = [[MicaSSHProfilesController alloc] initWithOwner:owner];
        [profilesController.window makeKeyAndOrderFront:nil];
        [profilesController.window.contentView layoutSubtreeIfNeeded];
        for (int attempt = 0; attempt < 5; attempt++) PollDemo(owner);
        [profilesController.window displayIfNeeded];
        NSView *profilesView = profilesController.window.contentView;
        NSRect profileDetailsRect = NSMakeRect(0, NSMaxY(profilesView.bounds) - 140,
            NSWidth(profilesView.bounds), 140);
        NSBitmapImageRep *profilesBitmap = [profilesView bitmapImageRepForCachingDisplayInRect:profileDetailsRect];
        [profilesView cacheDisplayInRect:profileDetailsRect toBitmapImageRep:profilesBitmap];
        NSData *profilesPNG = [profilesBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!profilesPNG || ![profilesPNG writeToFile:[directory stringByAppendingPathComponent:@"ssh-profiles-demo.png"] atomically:YES]) return 1;
        [profilesController.window orderOut:nil];
        [demoDefaults removePersistentDomainForName:suiteName];
        gMicaDefaultsOverride = nil;
        for (MicaTab *tab in owner.tabs) { mica_session_destroy(tab.session); tab.session = NULL; }
        printf("Captured current-UI frames with local PTY output and fictional SSH profiles.\n");
    }
    return 0;
}
