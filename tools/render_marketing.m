// Renders the real Mica terminal view offscreen into PNGs for the website and README.
// Uses a fictional project and printed sample output; no agent CLI is started and nothing touches the network.
#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"

static void RunLoopFor(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void SaveView(MicaAppDelegate *delegate, NSString *path) {
    NSView *view = delegate.terminalView;
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    printf("wrote %s\n", path.UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *outputDirectory = argc > 1 ? @(argv[1]) : @"docs/assets";
        setenv("MICA_TEST_NO_STARTUP", "1", 1);
        setenv("PS1", "", 1);
        [NSApplication sharedApplication];
        MicaAppDelegate *delegate = [[MicaAppDelegate alloc] init];
        delegate.tabs = [NSMutableArray array];
        delegate.activeIndex = 0;
        delegate.uiMode = MicaUIModeNormal;
        delegate.projectName = @"Fieldnote";
        delegate.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 440)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        delegate.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        delegate.terminalView = [[MicaTerminalView alloc] initWithFrame:delegate.window.contentView.bounds];
        delegate.terminalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        delegate.terminalView.owner = delegate;
        delegate.terminalView.terminalFont = MicaTerminalFont(15);
        [delegate.window setContentView:delegate.terminalView];
        [delegate installMenus];

        // Fictional project. git and make are shell functions that print sample output, so the tab shows
        // a normal prompt and typed commands; nothing real runs.
        NSString *setup =
            @"PROMPT=$'%F{cyan}❯%f '; RPROMPT=; "
            @"git() { printf '\\033[33m3f9c1a2\\033[0m Sync filter buttons with aria-pressed\\n\\033[33m8be07d4\\033[0m Add project board drag handles\\n\\033[33m1a4d6e9\\033[0m Keep card order after reload\\n\\033[33m5c20b83\\033[0m Set up the Fieldnote board\\n'; }; "
            @"make() { printf '\\033[32m✓\\033[0m filters keep aria-pressed in sync\\n\\033[32m✓\\033[0m cards keep their order after reload\\n\\033[32m✓\\033[0m drag handles are keyboard reachable\\n\\033[1m3 passed\\033[0m in 0.42s\\n'; }; clear";
        for (NSString *name in @[@"Shell", @"Preview", @"Codex", @"Claude Code", @"lazygit"])
            [delegate addTabWithName:name cwd:NSHomeDirectory() command:nil prefilled:NO];
        delegate.activeIndex = 0;
        [delegate.terminalView updateGridSize];
        MicaSession *session = delegate.activeTab.session;
        void (^type)(NSString *) = ^(NSString *line) {
            NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
            mica_session_paste(session, bytes.bytes, bytes.length);
            mica_session_key(session, VTERM_KEY_ENTER, VTERM_MOD_NONE);
            for (int i = 0; i < 8; i++) { [delegate pollSessions:nil]; RunLoopFor(0.12); }
        };
        for (int i = 0; i < 10; i++) { [delegate pollSessions:nil]; RunLoopFor(0.2); }
        type(setup);
        type(@"git log --oneline -4");
        type(@"make test");
        for (int i = 0; i < 8; i++) { [delegate pollSessions:nil]; RunLoopFor(0.15); }
        delegate.activeTab.cwd = @"/Users/me/code/fieldnote";

        // The readout would show this render tool's own footprint; show the measured idle figure for the sample instead.
        delegate.memoryLabel = @"58 MB";
        SaveView(delegate, [outputDirectory stringByAppendingPathComponent:@"mica-dark.png"]);
        // Capture real shipped discovery controls over fictional/local terminal output.
        type(@"clear; printf 'https://example.test/guide  /Users/megasoft78/Desktop/Freelance/mica-terminal/README.md  3f9c1a2\\n'");
        [delegate.terminalView toggleQuickSelect:nil];
        SaveView(delegate, [outputDirectory stringByAppendingPathComponent:@"quick-select-dark.png"]);
        [delegate.terminalView toggleQuickSelect:nil];
        [delegate toggleCommandPalette:nil];
        delegate.commandPaletteSearch.stringValue = @"Shell";
        [delegate filterCommandPalette:nil];
        NSView *palette = delegate.commandPalettePanel.contentView;
        NSBitmapImageRep *paletteBitmap = [palette bitmapImageRepForCachingDisplayInRect:palette.bounds];
        [palette cacheDisplayInRect:palette.bounds toBitmapImageRep:paletteBitmap];
        [[paletteBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[outputDirectory stringByAppendingPathComponent:@"command-palette-tabs-dark.png"] atomically:YES];
        delegate.commandPaletteSearch.stringValue = @"notifications";
        [delegate filterCommandPalette:nil];
        paletteBitmap = [palette bitmapImageRepForCachingDisplayInRect:palette.bounds];
        [palette cacheDisplayInRect:palette.bounds toBitmapImageRep:paletteBitmap];
        [[paletteBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[outputDirectory stringByAppendingPathComponent:@"command-palette-dark.png"] atomically:YES];
        [delegate toggleCommandPalette:nil];
        // Capture cycle 7's command landmarks and vocabulary correction with local sample text only.
        const char *landmarks = "clear; printf '\\033]133;A\\007'; printf '❯ '; printf '\\033]133;B\\007'; printf 'git status --short\\n'; printf '\\033]133;C\\007'; printf ' M src/mica_app.m\\n'; printf '\\033]133;D;1\\007'; printf '\\033]133;A\\007'; printf '❯ '; printf '\\033]133;B\\007'; printf 'make test\\n'; printf '\\033]133;C\\007'; printf '✓ tests passed\\n'; printf '\\033]133;D;0\\007'; printf '\\033]133;A\\007'; printf '❯ ';\n";
        mica_session_write(session, landmarks, strlen(landmarks));
        for (int i = 0; i < 50; i++) { [delegate pollSessions:nil]; RunLoopFor(0.03); }
        if (mica_session_jump_prompt(session, -1)) SaveView(delegate, [outputDirectory stringByAppendingPathComponent:@"prompt-navigation-demo.png"]);
        mica_session_destroy(session);
        session = mica_session_create("/tmp", nil, 24, 100);
        if (!session) return 1;
        delegate.activeTab.session = session;
        for (int i = 0; i < 20; i++) { [delegate pollSessions:nil]; RunLoopFor(0.03); }
        NSString *rawTranscript = @"Open Mica Terminal";
        NSString *correctedTranscript = MicaCorrectTranscript(rawTranscript, @[@"MicaTerminal"]);
        NSString *fakeTranscript = [NSString stringWithFormat:@"clear; printf 'Fake transcript (no microphone)\\nraw: %@\\ncorrected: %@\\nEdit Vocabulary… · Undo restores raw\\n'\n", rawTranscript, correctedTranscript];
        mica_session_write(session, fakeTranscript.UTF8String, strlen(fakeTranscript.UTF8String));
        for (int i = 0; i < 40; i++) { [delegate pollSessions:nil]; RunLoopFor(0.03); }
        SaveView(delegate, [outputDirectory stringByAppendingPathComponent:@"vocabulary-correction-demo.png"]);
        [delegate setLightTheme:YES];
        RunLoopFor(0.3);
        delegate.activeTab.cwd = @"/Users/me/code/fieldnote";
        SaveView(delegate, [outputDirectory stringByAppendingPathComponent:@"mica-light.png"]);
        type(@"clear; printf 'https://example.test/guide  /Users/megasoft78/Desktop/Freelance/mica-terminal/README.md  3f9c1a2\\n'");
        [delegate.terminalView toggleQuickSelect:nil];
        SaveView(delegate, [outputDirectory stringByAppendingPathComponent:@"quick-select-light.png"]);
        [delegate.terminalView toggleQuickSelect:nil];
        [delegate toggleCommandPalette:nil];
        delegate.commandPaletteSearch.stringValue = @"Shell";
        [delegate filterCommandPalette:nil];
        palette = delegate.commandPalettePanel.contentView;
        paletteBitmap = [palette bitmapImageRepForCachingDisplayInRect:palette.bounds];
        [palette cacheDisplayInRect:palette.bounds toBitmapImageRep:paletteBitmap];
        [[paletteBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[outputDirectory stringByAppendingPathComponent:@"command-palette-tabs-light.png"] atomically:YES];
        delegate.commandPaletteSearch.stringValue = @"notifications";
        [delegate filterCommandPalette:nil];
        paletteBitmap = [palette bitmapImageRepForCachingDisplayInRect:palette.bounds];
        [palette cacheDisplayInRect:palette.bounds toBitmapImageRep:paletteBitmap];
        [[paletteBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[outputDirectory stringByAppendingPathComponent:@"command-palette-light.png"] atomically:YES];
        [delegate toggleCommandPalette:nil];
        for (MicaTab *tab in delegate.tabs) if (tab.session) mica_session_destroy(tab.session), tab.session = NULL;
    }
    return 0;
}
