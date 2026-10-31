// Renders every Mica surface offscreen into PNGs (build/ui-audit/) so the whole interface can be reviewed
// side by side: states of the main window, the two themes, narrow and crowded tab strips,
// the timer, and the settings windows. Fictional project, printed sample output, nothing real is run.
#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"

static void RunLoopFor(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void SaveViewImage(NSView *view, NSString *directory, NSString *name) {
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    NSString *path = [directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    printf("wrote %s\n", path.UTF8String);
}

static MicaAppDelegate *MakeWindow(CGFloat width, CGFloat height, NSArray<NSString *> *tabNames, NSString *project) {
    MicaAppDelegate *delegate = [[MicaAppDelegate alloc] init];
    delegate.tabs = [NSMutableArray array];
    delegate.activeIndex = 0;
    delegate.uiMode = MicaUIModeNormal;
    delegate.projectName = project;
    delegate.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    delegate.window.releasedWhenClosed = NO;
    delegate.window.appearance = [NSAppearance appearanceNamed:gMicaLightTheme ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    delegate.windowContentView = [[MicaWindowContentView alloc] initWithFrame:delegate.window.contentView.bounds];
    delegate.windowContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    delegate.windowContentView.owner = delegate;
    delegate.terminalView = [[MicaTerminalView alloc] initWithFrame:delegate.windowContentView.bounds];
    delegate.terminalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    delegate.terminalView.owner = delegate;
    delegate.terminalView.terminalFont = MicaTerminalFont(15);
    delegate.windowContentView.terminalView = delegate.terminalView;
    [delegate.windowContentView addSubview:delegate.terminalView];
    [delegate.window setContentView:delegate.windowContentView];
    [delegate installMenus];
    for (NSString *name in tabNames)
        [delegate addTabWithName:name cwd:NSHomeDirectory() command:nil prefilled:NO];
    delegate.activeIndex = 0;
    [delegate.terminalView updateGridSize];
    for (int i = 0; i < 10; i++) { [delegate pollSessions:nil]; RunLoopFor(0.15); }
    return delegate;
}

static void Type(MicaAppDelegate *delegate, NSString *line) {
    MicaSession *session = delegate.activeTab.session;
    NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
    mica_session_paste(session, bytes.bytes, bytes.length);
    mica_session_key(session, VTERM_KEY_ENTER, VTERM_MOD_NONE);
    for (int i = 0; i < 8; i++) { [delegate pollSessions:nil]; RunLoopFor(0.12); }
}

static void Scene(MicaAppDelegate *delegate) {
    Type(delegate, @"PROMPT=$'%F{cyan}❯%f '; RPROMPT=; git() { printf '\\033[33m3f9c1a2\\033[0m Sync filter buttons with aria-pressed\\n\\033[33m8be07d4\\033[0m Add project board drag handles\\n'; }; make() { printf '\\033[32m✓\\033[0m filters keep aria-pressed in sync\\n\\033[32m✓\\033[0m cards keep their order after reload\\n\\033[1m2 passed\\033[0m in 0.42s\\n'; }; clear");
    Type(delegate, @"git log --oneline -2");
    Type(delegate, @"make test");
    delegate.activeTab.cwd = @"/Users/me/code/fieldnote";
    delegate.memoryLabel = @"58 MB";
}

static void RenderTimerStates(MicaAppDelegate *delegate, NSString *directory, NSString *theme) {
    NSTimeInterval now = MicaContinuousTimeSeconds();
    struct {
        MicaPomodoroPhase phase;
        NSString *name;
        NSTimeInterval remaining;
    } states[] = {
        { MICA_POMODORO_FOCUS, @"focus", 24 * 60 + 18 },
        { MICA_POMODORO_BREAK, @"break", 4 * 60 + 18 },
        { MICA_POMODORO_PAUSED_FOCUS, @"paused-focus", 24 * 60 + 18 },
        { MICA_POMODORO_PAUSED_BREAK, @"paused-break", 4 * 60 + 18 },
    };
    for (NSUInteger i = 0; i < sizeof(states) / sizeof(states[0]); i++) {
        MicaPomodoro timer = {0};
        timer.phase = states[i].phase;
        timer.deadline = now + states[i].remaining;
        timer.paused_remaining = states[i].remaining;
        timer.completed_focuses = 3;
        delegate.pomodoro = timer;
        delegate.pomodoroLabel = @"fieldnote · main";
        delegate.pomodoroCycleFocusMinutes = 50; delegate.pomodoroCycleBreakMinutes = 10;
        [delegate updateFocusBand];
        [delegate.terminalView setNeedsDisplay:YES];
        NSString *name = [NSString stringWithFormat:@"timer-%@-%@", theme, states[i].name];
        SaveViewImage(delegate.terminalView, directory, name);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *out = argc > 1 ? @(argv[1]) : @"build/ui-audit";
        [NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("MICA_TEST_NO_STARTUP", "1", 1);
        [NSApplication sharedApplication];
        NSArray *tabs = @[@"Shell", @"Preview", @"Codex", @"Claude Code", @"lazygit"];

        MicaAppDelegate *main = MakeWindow(1100, 440, tabs, @"Fieldnote");
        Scene(main);
        [main updateFocusBand];
        SaveViewImage(main.terminalView, out, @"01-dark-default");
        [main.terminalView toggleQuickSelect:nil];
        SaveViewImage(main.terminalView, out, @"quick-select-dark");
        [main.terminalView toggleQuickSelect:nil];
        RenderTimerStates(main, out, @"dark");
        main.sidebarVisible = YES;
        main.windowContentView.sidebarVisible = YES;
        [main.windowContentView.sidebarView refreshRows];
        for (NSNumber *width in @[@600, @800, @1200]) {
            NSRect frame = main.window.frame; frame.size.width = width.doubleValue; [main.window setFrame:frame display:YES];
            SaveViewImage(main.windowContentView, out, [NSString stringWithFormat:@"sidebar-dark-%@", width]);
        }
        main.sidebarVisible = NO; main.windowContentView.sidebarVisible = NO;
        NSRect mainFrame = main.window.frame; mainFrame.size.width = 1100; [main.window setFrame:mainFrame display:YES];

        main.uiMode = MicaUIModeTab;
        [main.terminalView setNeedsDisplay:YES];
        SaveViewImage(main.terminalView, out, @"02-tab-picker-mode");
        main.uiMode = MicaUIModeScroll;
        SaveViewImage(main.terminalView, out, @"03-scrollback-mode");
        main.uiMode = MicaUIModeNormal;
        [main toggleCommandPalette:nil];
        SaveViewImage(main.commandPalettePanel.contentView, out, @"command-palette-dark");
        [main toggleCommandPalette:nil];

        MicaAppDelegate *narrow = MakeWindow(620, 380, tabs, @"Fieldnote");
        Scene(narrow);
        SaveViewImage(narrow.terminalView, out, @"07-dark-narrow");
        MicaAppDelegate *narrow800 = MakeWindow(800, 380, tabs, @"Fieldnote");
        Scene(narrow800);
        SaveViewImage(narrow800.terminalView, out, @"12-dark-800-wide");
        MicaAppDelegate *narrow600 = MakeWindow(600, 380, tabs, @"Fieldnote");
        Scene(narrow600);
        SaveViewImage(narrow600.terminalView, out, @"13-dark-600-wide");

        NSMutableArray *many = [NSMutableArray array];
        for (int i = 1; i <= 12; i++) [many addObject:[NSString stringWithFormat:@"Agent %d", i]];
        MicaAppDelegate *crowded = MakeWindow(1000, 380, many, @"A very long project name here");
        Scene(crowded);
        crowded.activeIndex = 7;
        SaveViewImage(crowded.terminalView, out, @"08-dark-many-tabs");

        gMicaLightTheme = YES;
        MicaAppDelegate *light = MakeWindow(1100, 440, tabs, @"Fieldnote");
        [light setLightTheme:YES];
        [light toggleCommandPalette:nil];
        SaveViewImage(light.commandPalettePanel.contentView, out, @"command-palette-light");
        [light toggleCommandPalette:nil];
        Scene(light);
        SaveViewImage(light.terminalView, out, @"09-light-default");
        [light.terminalView toggleQuickSelect:nil];
        SaveViewImage(light.terminalView, out, @"quick-select-light");
        [light.terminalView toggleQuickSelect:nil];
        RenderTimerStates(light, out, @"light");
        light.sidebarVisible = YES; light.windowContentView.sidebarVisible = YES;
        [light.windowContentView.sidebarView refreshRows];
        for (NSNumber *width in @[@600, @800, @1200]) {
            NSRect frame = light.window.frame; frame.size.width = width.doubleValue; [light.window setFrame:frame display:YES];
            SaveViewImage(light.windowContentView, out, [NSString stringWithFormat:@"sidebar-light-%@", width]);
        }
        light.sidebarVisible = NO; light.windowContentView.sidebarVisible = NO;
        NSRect lightFrame = light.window.frame; lightFrame.size.width = 1100; [light.window setFrame:lightFrame display:YES];
        light.uiMode = MicaUIModeTab;
        SaveViewImage(light.terminalView, out, @"14-light-tab-picker");
        light.uiMode = MicaUIModeScroll;
        SaveViewImage(light.terminalView, out, @"15-light-scrollback");
        light.uiMode = MicaUIModeNormal;
        MicaAppDelegate *light600 = MakeWindow(600, 380, tabs, @"Fieldnote");
        [light600 setLightTheme:YES];
        Scene(light600);
        SaveViewImage(light600.terminalView, out, @"17-light-600-wide");
        MicaAppDelegate *light800 = MakeWindow(800, 380, tabs, @"Fieldnote");
        [light800 setLightTheme:YES];
        Scene(light800);
        SaveViewImage(light800.terminalView, out, @"18-light-800-wide");
        [light openPreferences:nil];
        SaveViewImage(light.preferencesWindow.contentView, out, @"10-settings-light");
        gMicaFollowSystemTheme = NO;
        [main setLightTheme:NO];
        [main openPreferences:nil];
        SaveViewImage(main.preferencesWindow.contentView, out, @"11-settings-dark");
    }
    return 0;
}
