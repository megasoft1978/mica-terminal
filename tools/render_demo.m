// Captures the current native terminal view offscreen. Only local PTY commands run.
#define MICA_APP_NO_MAIN 1
#import "../src/mica_app.m"

static void PollDemo(MicaAppDelegate *owner) {
    for (MicaTab *tab in owner.tabs) mica_session_poll(tab.session, 0);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

@interface MicaTimerMenuPreview : NSView
@property(nonatomic, copy) NSString *indicatorTitle;
@property(nonatomic, copy) NSArray<NSString *> *rows;
@end

@implementation MicaTimerMenuPreview
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithCalibratedWhite:0.11 alpha:1] setFill]; NSRectFill(self.bounds);
    NSDictionary *small = @{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.66 alpha:1]};
    [@"MACOS MENU BAR" drawAtPoint:NSMakePoint(28, 23) withAttributes:small];
    NSRect bar = NSMakeRect(20, 52, self.bounds.size.width - 40, 42);
    [[NSColor colorWithCalibratedWhite:0.20 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:9 yRadius:9] fill];
    [@"Mica" drawAtPoint:NSMakePoint(38, 64) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:NSColor.whiteColor}];
    [self.indicatorTitle drawAtPoint:NSMakePoint(NSMaxX(bar) - 104, 64)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName:NSColor.whiteColor}];
    NSRect popup = NSMakeRect(NSMaxX(bar) - 284, 100, 270, 190);
    [[NSColor colorWithCalibratedWhite:0.18 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:popup xRadius:10 yRadius:10] fill];
    [[NSColor colorWithCalibratedWhite:0.32 alpha:1] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:popup xRadius:10 yRadius:10]; border.lineWidth = 1; [border stroke];
    CGFloat y = NSMinY(popup) + 12;
    for (NSUInteger i = 0; i < self.rows.count; i++) {
        NSString *row = self.rows[i];
        BOOL active = [row isEqualToString:@"Pause Timer"];
        NSRect rowRect = NSMakeRect(NSMinX(popup) + 7, y, popup.size.width - 14, i == 0 ? 27 : 29);
        if (active) { [[NSColor colorWithCalibratedRed:0.02 green:0.43 blue:0.96 alpha:1] setFill]; [[NSBezierPath bezierPathWithRoundedRect:rowRect xRadius:5 yRadius:5] fill]; }
        NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:i == 0 ? 11 : 12],
            NSForegroundColorAttributeName:i == 0 ? [NSColor colorWithCalibratedWhite:0.72 alpha:1] : NSColor.whiteColor};
        [row drawAtPoint:NSMakePoint(NSMinX(rowRect) + 10, NSMinY(rowRect) + 6) withAttributes:attrs];
        y += rowRect.size.height + (i == 0 ? 4 : 1);
    }
}
@end

@interface MicaProjectStoryCard : NSView
@property(nonatomic, strong) NSImage *windowImage;
@property(nonatomic, copy) NSString *headline;
@property(nonatomic, copy) NSString *caption;
@property(nonatomic, copy) NSArray<NSMenuItem *> *projectItems;
@property(nonatomic) BOOL showsProjectMenu;
@property(nonatomic) NSUInteger highlightedProject;
@end

@implementation MicaProjectStoryCard
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSGradient *background = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.075 green:0.095 blue:0.125 alpha:1]
        endingColor:[NSColor colorWithCalibratedRed:0.035 green:0.045 blue:0.065 alpha:1]];
    [background drawInRect:self.bounds angle:90];
    NSDictionary *headlineAttributes = @{ NSFontAttributeName:[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.96 alpha:1] };
    NSDictionary *captionAttributes = @{ NSFontAttributeName:[NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.72 alpha:1] };
    [self.headline drawAtPoint:NSMakePoint(56, 22) withAttributes:headlineAttributes];
    [self.caption drawAtPoint:NSMakePoint(56, 57) withAttributes:captionAttributes];

    if (!self.showsProjectMenu) {
        NSRect windowRect = NSMakeRect(140, 105, 1000, 440);
        NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:windowRect xRadius:12 yRadius:12];
        [[NSColor colorWithCalibratedWhite:0.22 alpha:1] setFill]; [frame fill];
        [self.windowImage drawInRect:NSInsetRect(windowRect, 1, 1) fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
        return;
    }

    NSRect windowRect = NSMakeRect(54, 168, 720, 317);
    NSBezierPath *windowFrame = [NSBezierPath bezierPathWithRoundedRect:windowRect xRadius:10 yRadius:10];
    [[NSColor colorWithCalibratedWhite:0.22 alpha:1] setFill]; [windowFrame fill];
    [self.windowImage drawInRect:NSInsetRect(windowRect, 1, 1) fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];

    NSRect menuRect = NSMakeRect(630, 153, 590, 340);
    NSBezierPath *menuPanel = [NSBezierPath bezierPathWithRoundedRect:menuRect xRadius:14 yRadius:14];
    [[NSColor colorWithCalibratedRed:0.13 green:0.15 blue:0.19 alpha:0.98] setFill]; [menuPanel fill];
    [[NSColor colorWithCalibratedWhite:0.38 alpha:0.75] setStroke]; menuPanel.lineWidth = 1; [menuPanel stroke];
    NSDictionary *menuTitleAttributes = @{ NSFontAttributeName:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.92 alpha:1] };
    [@"Open Projects" drawAtPoint:NSMakePoint(menuRect.origin.x + 20, menuRect.origin.y + 18) withAttributes:menuTitleAttributes];
    [[NSColor colorWithCalibratedWhite:1 alpha:0.12] setStroke];
    NSBezierPath *separator = [NSBezierPath bezierPath]; separator.lineWidth = 1;
    [separator moveToPoint:NSMakePoint(menuRect.origin.x + 12, menuRect.origin.y + 54)];
    [separator lineToPoint:NSMakePoint(NSMaxX(menuRect) - 12, menuRect.origin.y + 54)]; [separator stroke];
    for (NSUInteger index = 0; index < self.projectItems.count; index++) {
        NSMenuItem *item = self.projectItems[index];
        NSRect row = NSMakeRect(menuRect.origin.x + 8, menuRect.origin.y + 66 + index * 64, menuRect.size.width - 16, 54);
        if (index == self.highlightedProject) {
            [[NSColor colorWithCalibratedRed:0.10 green:0.36 blue:0.77 alpha:1] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:row xRadius:8 yRadius:8] fill];
        }
        NSDictionary *rowAttributes = @{ NSFontAttributeName:[NSFont systemFontOfSize:15 weight:index == self.highlightedProject ? NSFontWeightSemibold : NSFontWeightRegular],
            NSForegroundColorAttributeName:NSColor.whiteColor };
        [item.title drawAtPoint:NSMakePoint(row.origin.x + 18, row.origin.y + 17) withAttributes:rowAttributes];
        if (item.state == NSControlStateValueOn) {
            NSDictionary *checkAttributes = @{ NSFontAttributeName:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.85 alpha:1] };
            [@"✓" drawAtPoint:NSMakePoint(row.origin.x + row.size.width - 32, row.origin.y + 17) withAttributes:checkAttributes];
        }
    }
}
@end

@interface MicaFeatureStoryCard : NSView
@property(nonatomic, strong) NSImage *featureImage;
@property(nonatomic, copy) NSString *headline;
@property(nonatomic, copy) NSString *caption;
@end

@implementation MicaFeatureStoryCard
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSGradient *background = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.075 green:0.095 blue:0.125 alpha:1]
        endingColor:[NSColor colorWithCalibratedRed:0.035 green:0.045 blue:0.065 alpha:1]];
    [background drawInRect:self.bounds angle:90];
    NSDictionary *headlineAttributes = @{ NSFontAttributeName:[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.96 alpha:1] };
    NSDictionary *captionAttributes = @{ NSFontAttributeName:[NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.72 alpha:1] };
    [self.headline drawAtPoint:NSMakePoint(56, 22) withAttributes:headlineAttributes];
    [self.caption drawAtPoint:NSMakePoint(56, 57) withAttributes:captionAttributes];

    NSRect frame = NSMakeRect(139, 105, 1002, 442);
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:12 yRadius:12];
    [[NSColor colorWithCalibratedWhite:0.26 alpha:1] setFill]; [border fill];
    NSRect imageBounds = NSInsetRect(frame, 1, 1);
    NSSize imageSize = self.featureImage.size;
    if (imageSize.width <= 0 || imageSize.height <= 0) return;
    CGFloat scale = MIN(imageBounds.size.width / imageSize.width, imageBounds.size.height / imageSize.height);
    NSSize fitted = NSMakeSize(imageSize.width * scale, imageSize.height * scale);
    NSRect destination = NSMakeRect(NSMidX(imageBounds) - fitted.width / 2, NSMidY(imageBounds) - fitted.height / 2,
        fitted.width, fitted.height);
    [self.featureImage drawInRect:destination fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
        fraction:1.0 respectFlipped:YES hints:nil];
}
@end

static NSImage *ImageForView(NSView *view) {
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    NSImage *image = [[NSImage alloc] initWithSize:bitmap.size];
    [image addRepresentation:bitmap];
    return image;
}

static BOOL SaveProjectStoryCard(NSImage *windowImage, NSString *headline, NSString *caption,
                                 NSArray<NSMenuItem *> *items, NSUInteger highlighted, BOOL showsMenu, NSString *path) {
    MicaProjectStoryCard *card = [[MicaProjectStoryCard alloc] initWithFrame:NSMakeRect(0, 0, 1280, 564)];
    card.windowImage = windowImage; card.headline = headline; card.caption = caption;
    card.projectItems = items; card.highlightedProject = highlighted; card.showsProjectMenu = showsMenu;
    NSBitmapImageRep *bitmap = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
    [card cacheDisplayInRect:card.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

static BOOL SaveFeatureStoryCard(NSImage *featureImage, NSString *headline, NSString *caption, NSString *path) {
    MicaFeatureStoryCard *card = [[MicaFeatureStoryCard alloc] initWithFrame:NSMakeRect(0, 0, 1280, 564)];
    card.featureImage = featureImage; card.headline = headline; card.caption = caption;
    NSBitmapImageRep *bitmap = [card bitmapImageRepForCachingDisplayInRect:card.bounds];
    [card cacheDisplayInRect:card.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

static BOOL SaveTimerMenuPreview(MicaAppDelegate *owner, NSString *directory) {
    NSString *suite = [NSString stringWithFormat:@"MicaTimerPreview-%@", NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults setBool:YES forKey:@"MicaMenuBarTimer"];
    gMicaDefaultsOverride = defaults;
    MicaPomodoro timer = {0}; timer.phase = MICA_POMODORO_FOCUS; timer.deadline = MicaContinuousTimeSeconds() + 24 * 60 + 18;
    owner.pomodoro = timer; owner.pomodoroLabel = @"Mica Demo";
    [owner applyMenuBarTimerPreference]; [owner updateMenuBarTimer];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    [owner updateMenuBarTimer];
    NSStatusItem *statusItem = [gMicaStatusItem valueForKey:@"statusItem"];
    NSStatusBarButton *button = statusItem.button;
    NSString *indicatorTitle = button.title.length ? button.title : @"◷ 24:18";
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    for (NSMenuItem *item in [owner menuBarTimerMenu].itemArray)
        if (!item.isSeparatorItem && item.title.length) [rows addObject:item.title];
    if (rows.count && indicatorTitle.length) {
        NSRange timeRange = [indicatorTitle rangeOfString:@"[0-9]" options:NSRegularExpressionSearch];
        if (timeRange.location != NSNotFound) {
            NSString *visibleTime = [indicatorTitle substringFromIndex:timeRange.location];
            if ([rows[0] hasPrefix:@"Focus "]) rows[0] = [@"Focus " stringByAppendingString:visibleTime];
            else if ([rows[0] hasPrefix:@"Break "]) rows[0] = [@"Break " stringByAppendingString:visibleTime];
        }
    }
    MicaTimerMenuPreview *preview = [[MicaTimerMenuPreview alloc] initWithFrame:NSMakeRect(0, 0, 720, 320)];
    preview.indicatorTitle = indicatorTitle; preview.rows = rows;
    NSBitmapImageRep *image = [preview bitmapImageRepForCachingDisplayInRect:preview.bounds];
    [preview cacheDisplayInRect:preview.bounds toBitmapImageRep:image];
    NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    BOOL saved = [png writeToFile:[directory stringByAppendingPathComponent:@"timer-menu-bar-demo.png"] atomically:YES];
    [gMicaStatusItem disable]; gMicaStatusItem = nil;
    [defaults removePersistentDomainForName:suite]; gMicaDefaultsOverride = nil;
    return saved;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *directory = @(argv[1]);
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) return 1;
        setenv("MICA_TEST_NO_STARTUP", "1", 1);
        setenv("PS1", "demo> ", 1);
        unsetenv("MICA_TEST_ZLE_DIR");
        [NSApplication sharedApplication];
        MicaAppDelegate *owner = [MicaAppDelegate new];
        owner.tabs = [NSMutableArray new];
        owner.activeIndex = 0;
        owner.projectName = @"Fieldnote";
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
        owner.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        MicaSession *session = owner.activeTab.session;
        const char *setup = "PROMPT='demo> '; RPROMPT=''; clear\n";
        mica_session_write(session, setup, strlen(setup));
        for (int attempt = 0; attempt < 100; attempt++) PollDemo(owner);
        if (!SaveTimerMenuPreview(owner, directory)) return 1;
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
            }
        }
        // A short project-first story uses two fictional windows and the same Dock-menu titles
        // returned by the running app. The terminal output is local sample text; no agent runs.
        NSImage *fieldnoteWindow = ImageForView(owner.terminalView);
        MicaAppDelegate *northstarOwner = [MicaAppDelegate new];
        northstarOwner.tabs = [NSMutableArray new]; northstarOwner.activeIndex = 0;
        northstarOwner.projectName = @"Northstar";
        northstarOwner.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 440)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        northstarOwner.window.releasedWhenClosed = NO;
        northstarOwner.terminalView = [[MicaTerminalView alloc] initWithFrame:northstarOwner.window.contentView.bounds];
        northstarOwner.terminalView.owner = northstarOwner;
        northstarOwner.terminalView.terminalFont = MicaTerminalFont(16);
        [northstarOwner.window setContentView:northstarOwner.terminalView];
        MicaTab *northstarTab = [MicaTab new]; northstarTab.name = @"Shell";
        northstarTab.cwd = @"/Users/me/code/northstar";
        northstarTab.session = mica_session_create("/tmp", nil, 24, 100);
        if (!northstarTab.session) return 1;
        [northstarOwner.tabs addObject:northstarTab];
        [northstarOwner setLightTheme:NO]; [northstarOwner.terminalView updateGridSize];
        const char *northstarSetup = "PROMPT='northstar> '; RPROMPT=''; clear\n";
        mica_session_write(northstarTab.session, northstarSetup, strlen(northstarSetup));
        for (int attempt = 0; attempt < 80; attempt++) PollDemo(northstarOwner);
        const char *northstarOutput = "clear; printf 'git status --short\\n M Sources/App.swift\\n\\nmake test\\n✓ 42 tests passed\\n'\n";
        mica_session_write(northstarTab.session, northstarOutput, strlen(northstarOutput));
        for (int attempt = 0; attempt < 80; attempt++) PollDemo(northstarOwner);
        NSImage *northstarWindow = ImageForView(northstarOwner.terminalView);
        [MicaControllers() removeAllObjects];
        [MicaControllers() addObject:owner]; [MicaControllers() addObject:northstarOwner];
        NSMenu *projectMenu = [owner applicationDockMenu:NSApp];
        if (projectMenu.itemArray.count != 2 ||
            ![projectMenu.itemArray[0].title isEqualToString:[owner windowTitleForTab:owner.activeTab]] ||
            ![projectMenu.itemArray[1].title isEqualToString:[northstarOwner windowTitleForTab:northstarTab]]) return 1;
        projectMenu.itemArray[0].state = NSControlStateValueOn;
        BOOL savedStory =
            SaveProjectStoryCard(fieldnoteWindow, @"Every project gets its own window.",
                @"The project name stays visible in the window.", @[], 0, NO,
                [directory stringByAppendingPathComponent:@"project-switch-fieldnote.png"]) &&
            SaveProjectStoryCard(fieldnoteWindow, @"Choose an open project by name.",
                @"Right-click the one Mica Dock icon to see your project windows.", projectMenu.itemArray, 0, YES,
                [directory stringByAppendingPathComponent:@"project-switch-menu.png"]) &&
            SaveProjectStoryCard(fieldnoteWindow, @"Choose an open project by name.",
                @"Right-click the one Mica Dock icon to see your project windows.", projectMenu.itemArray, 1, YES,
                [directory stringByAppendingPathComponent:@"project-switch-menu-select.png"]) &&
            SaveProjectStoryCard(northstarWindow, @"Switch straight to Northstar.",
                @"Each window keeps its own project name and working folder.", @[], 0, NO,
                [directory stringByAppendingPathComponent:@"project-switch-northstar.png"]);
        if (!savedStory) return 1;
        [MicaControllers() removeAllObjects];
        mica_session_destroy(northstarTab.session); northstarTab.session = NULL;
        // Companion stills make the cycle's discovery controls legible beside the animated terminal demo.
        char fixtureTemplate[] = "/tmp/mica-demo.XXXXXX";
        char *fixturePath = mkdtemp(fixtureTemplate);
        if (!fixturePath) return 1;
        NSString *fixtureDirectory = [NSString stringWithUTF8String:fixturePath];
        NSString *fixtureFile = [fixtureDirectory stringByAppendingPathComponent:@"README.md"];
        if (![NSFileManager.defaultManager createFileAtPath:fixtureFile contents:[@"Mica demo fixture\\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil]) return 1;
        NSString *sampleCommand = [NSString stringWithFormat:@"clear; printf 'https://example.test/guide  %@  3f9c1a2\\n'\n", fixtureFile];
        mica_session_write(session, sampleCommand.UTF8String, strlen(sampleCommand.UTF8String));
        for (int attempt = 0; attempt < 40; attempt++) PollDemo(owner);
        [owner.terminalView toggleQuickSelect:nil];
        for (int attempt = 0; attempt < 60 && !owner.terminalView.quickSelectActive; attempt++) PollDemo(owner);
        if (!owner.terminalView.quickSelectActive || owner.terminalView.quickSelectMatches.count < 3) return 1;
        NSBitmapImageRep *quickBitmap = [owner.terminalView bitmapImageRepForCachingDisplayInRect:owner.terminalView.bounds];
        [owner.terminalView cacheDisplayInRect:owner.terminalView.bounds toBitmapImageRep:quickBitmap];
        NSData *quickPNG = [quickBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!quickPNG || ![quickPNG writeToFile:[directory stringByAppendingPathComponent:@"quick-select-demo.png"] atomically:YES]) return 1;
        [owner.terminalView toggleQuickSelect:nil];
        [owner toggleCommandPalette:nil];
        owner.commandPaletteSearch.stringValue = @"Shell";
        [owner filterCommandPalette:nil];
        [owner.commandPalettePanel displayIfNeeded];
        [owner.commandPalettePanel.contentView displayIfNeeded];
        for (int attempt = 0; attempt < 5; attempt++) PollDemo(owner);
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
        for (int attempt = 0; attempt < 100; attempt++) PollDemo(owner);
        NSString *rawTranscript = @"Open Mica Terminal";
        NSString *correctedTranscript = MicaCorrectTranscript(rawTranscript, @[@"MicaTerminal"]);
        const char *vocabSetup = "PROMPT='demo> '; RPROMPT=''; clear\n";
        mica_session_write(session, vocabSetup, strlen(vocabSetup));
        for (int attempt = 0; attempt < 80; attempt++) PollDemo(owner);
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
        NSString *darkWindowPath = [[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"docs/assets/mica-dark.png"] stringByStandardizingPath];
        NSImage *darkWindowImage = [[NSImage alloc] initWithContentsOfFile:darkWindowPath];
        NSImage *paletteImage = ImageForView(palette);
        NSImage *quickImage = [[NSImage alloc] initWithContentsOfFile:[directory stringByAppendingPathComponent:@"quick-select-demo.png"]];
        NSImage *dictationImage = [[NSImage alloc] initWithContentsOfFile:[directory stringByAppendingPathComponent:@"vocabulary-correction-demo.png"]];
        NSImage *timerImage = [[NSImage alloc] initWithContentsOfFile:[directory stringByAppendingPathComponent:@"timer-menu-bar-demo.png"]];
        NSImage *sshImage = [[NSImage alloc] initWithContentsOfFile:[directory stringByAppendingPathComponent:@"ssh-profiles-demo.png"]];
        BOOL savedFeatureCards = darkWindowImage && paletteImage && quickImage && dictationImage && timerImage && sshImage &&
            SaveFeatureStoryCard(darkWindowImage, @"Keep terminal work in named tabs.",
                @"Shell, Claude Code, Codex and other tools share a project window.",
                [directory stringByAppendingPathComponent:@"feature-tabs.png"]) &&
            SaveFeatureStoryCard(paletteImage, @"Find actions and tabs by name.",
                @"Search the Command Palette, then jump to a matching tab.",
                [directory stringByAppendingPathComponent:@"feature-palette.png"]) &&
            SaveFeatureStoryCard(quickImage, @"Pick a link, existing file or Git hash.",
                @"Quick Select labels items you can reach in the terminal.",
                [directory stringByAppendingPathComponent:@"feature-quick-select.png"]) &&
            SaveFeatureStoryCard(dictationImage, @"Dictate, review and correct locally.",
                @"Illustrative text only. The demo records no speech.",
                [directory stringByAppendingPathComponent:@"feature-dictation.png"]) &&
            SaveFeatureStoryCard(timerImage, @"Keep a focus timer in the menu bar.",
                @"See the active phase and countdown across Mica windows.",
                [directory stringByAppendingPathComponent:@"feature-focus-timer.png"]) &&
            SaveFeatureStoryCard(sshImage, @"Reconnect with saved SSH profiles.",
                @"Open a fresh terminal session through macOS OpenSSH.",
                [directory stringByAppendingPathComponent:@"feature-ssh.png"]);
        if (!savedFeatureCards) return 1;
        [NSFileManager.defaultManager removeItemAtPath:fixtureDirectory error:nil];
        for (MicaTab *tab in owner.tabs) { mica_session_destroy(tab.session); tab.session = NULL; }
        printf("Captured project switching, feature-tour cards, local PTY output and fictional SSH profiles.\n");
    }
    return 0;
}
