// Renders every Mica surface offscreen into PNGs (build/ui-audit/) so the whole interface can be reviewed
// side by side: states of the main window, the two themes, narrow and crowded tab strips, dictation states,
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
    delegate.terminalView = [[MicaTerminalView alloc] initWithFrame:delegate.window.contentView.bounds];
    delegate.terminalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    delegate.terminalView.owner = delegate;
    delegate.terminalView.terminalFont = MicaTerminalFont(15);
    [delegate.window setContentView:delegate.terminalView];
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *out = argc > 1 ? @(argv[1]) : @"build/ui-audit";
        [NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("MICA_TEST_NO_STARTUP", "1", 1);
        [NSApplication sharedApplication];
        NSArray *tabs = @[@"Shell", @"Preview", @"Codex", @"Claude Code", @"lazygit"];

        MicaAppDelegate *main = MakeWindow(1100, 440, tabs, @"Fieldnote");
        Scene(main);
        SaveViewImage(main.terminalView, out, @"01-dark-default");

        main.uiMode = MicaUIModeTab;
        [main.terminalView setNeedsDisplay:YES];
        SaveViewImage(main.terminalView, out, @"02-tab-picker-mode");
        main.uiMode = MicaUIModeScroll;
        SaveViewImage(main.terminalView, out, @"03-scrollback-mode");
        main.uiMode = MicaUIModeNormal;

        MicaVoiceController *voice = [[MicaVoiceController alloc] initWithHelperURL:[NSURL fileURLWithPath:@"/nonexistent"]];
        main.voiceController = voice;
        [voice setValue:@(MicaVoiceControllerStatePreparing) forKey:@"state"];
        [voice setValue:@"Downloading speech model files…" forKey:@"statusText"];
        [voice setValue:@YES forKey:@"hasProgress"];
        [voice setValue:@(0.42) forKey:@"progress"];
        SaveViewImage(main.terminalView, out, @"04-dictation-preparing");
        [voice setValue:@(MicaVoiceControllerStateListening) forKey:@"state"];
        [voice setValue:@"Change the tab widths so all five tabs fit in the window and then run the tests again" forKey:@"transcript"];
        [voice setValue:@(6.0) forKey:@"elapsedSeconds"];
        SaveViewImage(main.terminalView, out, @"05-dictation-listening");
        [voice setValue:@(MicaVoiceControllerStateFailed) forKey:@"state"];
        [voice setValue:@"Microphone access is off. Enable Mica in System Settings → Privacy & Security → Microphone." forKey:@"statusText"];
        SaveViewImage(main.terminalView, out, @"06-dictation-failed");
        [voice setValue:@(MicaVoiceControllerStateIdle) forKey:@"state"];

        MicaAppDelegate *narrow = MakeWindow(620, 380, tabs, @"Fieldnote");
        Scene(narrow);
        SaveViewImage(narrow.terminalView, out, @"07-dark-narrow");

        NSMutableArray *many = [NSMutableArray array];
        for (int i = 1; i <= 12; i++) [many addObject:[NSString stringWithFormat:@"Agent %d", i]];
        MicaAppDelegate *crowded = MakeWindow(1000, 380, many, @"A very long project name here");
        Scene(crowded);
        crowded.activeIndex = 7;
        SaveViewImage(crowded.terminalView, out, @"08-dark-many-tabs");

        gMicaLightTheme = YES;
        MicaAppDelegate *light = MakeWindow(1100, 440, tabs, @"Fieldnote");
        [light setLightTheme:YES];
        Scene(light);
        SaveViewImage(light.terminalView, out, @"09-light-default");
        [light openPreferences:nil];
        SaveViewImage(light.preferencesWindow.contentView, out, @"10-settings-light");
        gMicaLightTheme = NO;
        [main openPreferences:nil];
        SaveViewImage(main.preferencesWindow.contentView, out, @"11-settings-dark");
    }
    return 0;
}
