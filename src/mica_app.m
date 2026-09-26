#import <Cocoa/Cocoa.h>
#import "mica.h"

static const CGFloat kHeaderHeight = 30.0;
static const CGFloat kFontSizeDefault = 13.0;

@interface MicaTab : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *cwd;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSString *terminalTitle;
@property(nonatomic, assign) MicaSession *session;
@property(nonatomic, assign) uint64_t revision;
@property(nonatomic, assign) uint64_t attentionCount;
@property(nonatomic, assign) BOOL needsAttention;
@end
@implementation MicaTab
- (void)dealloc { if (_session) mica_session_destroy(_session); }
@end

@class MicaAppDelegate;
@interface MicaTerminalView : NSView
@property(nonatomic, weak) MicaAppDelegate *owner;
@property(nonatomic, strong) NSFont *terminalFont;
- (void)copySelection:(id)sender;
- (void)paste:(id)sender;
- (void)copy:(id)sender;
@end

@interface MicaAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) MicaTerminalView *terminalView;
@property(nonatomic, strong) NSMutableArray<MicaTab *> *tabs;
@property(nonatomic, assign) NSInteger activeIndex;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, assign) NSInteger attentionRequest;
- (MicaTab *)activeTab;
- (NSString *)displayNameForTab:(MicaTab *)tab;
- (void)newTabWithName:(NSString *)name command:(NSString *)command;
- (void)closeActiveTab;
- (void)selectRelativeTab:(NSInteger)delta;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)resizeActiveSession;
@end

static NSMenuItem *AddMenuItem(NSMenu *menu, NSString *title, SEL selector, NSString *key, NSEventModifierFlags modifiers) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:key ?: @""];
    item.keyEquivalentModifierMask = modifiers;
    [menu addItem:item];
    return item;
}

static BOOL CellIsContinuation(MicaCell cell) {
    return cell.width == 0 || cell.chars[0] > 0x10ffff;
}

@implementation MicaTerminalView {
    BOOL _selecting;
    NSPoint _selectionStart;
    NSPoint _selectionEnd;
    CGFloat _charWidth;
    CGFloat _lineHeight;
    NSInteger _rows;
    NSInteger _cols;
    CGFloat _scrollRemainder;
    MicaSession *_sizedSession;
    BOOL _mousePressed;
    NSInteger _mouseRow;
    NSInteger _mouseCol;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return NO; }

- (NSColor *)colorForVTermColor:(VTermColor)color isForeground:(BOOL)isForeground {
    if (isForeground && VTERM_COLOR_IS_DEFAULT_FG(&color)) return [NSColor colorWithRed:0.85 green:0.88 blue:0.92 alpha:1.0];
    if (!isForeground && VTERM_COLOR_IS_DEFAULT_BG(&color)) return [NSColor colorWithRed:0.055 green:0.065 blue:0.082 alpha:1.0];
    if (VTERM_COLOR_IS_RGB(&color))
        return [NSColor colorWithRed:color.rgb.red / 255.0 green:color.rgb.green / 255.0 blue:color.rgb.blue / 255.0 alpha:1.0];
    return isForeground ? NSColor.whiteColor : NSColor.blackColor;
}

- (NSString *)stringForCell:(MicaCell)cell {
    unichar units[VTERM_MAX_CHARS_PER_CELL * 2];
    NSUInteger length = 0;
    for (NSUInteger i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++) {
        uint32_t value = cell.chars[i];
        if (value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) continue;
        if (value <= 0xffff) units[length++] = (unichar)value;
        else {
            value -= 0x10000;
            units[length++] = (unichar)(0xd800 + (value >> 10));
            units[length++] = (unichar)(0xdc00 + (value & 0x3ff));
        }
    }
    return length ? [NSString stringWithCharacters:units length:length] : @" ";
}

- (NSRect)terminalRect {
    return NSMakeRect(0, 0, self.bounds.size.width, MAX(0, self.bounds.size.height - kHeaderHeight));
}

- (void)updateGridSize {
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;
    NSDictionary *attrs = @{ NSFontAttributeName: self.terminalFont };
    NSSize cell = [@"M" sizeWithAttributes:attrs];
    _charWidth = MAX(1.0, ceil(cell.width));
    _lineHeight = MAX(1.0, ceil(self.terminalFont.ascender - self.terminalFont.descender + self.terminalFont.leading + 1.0));
    NSRect area = [self terminalRect];
    NSInteger cols = MAX(2, floor(area.size.width / _charWidth));
    NSInteger rows = MAX(2, floor(area.size.height / _lineHeight));
    if (cols != _cols || rows != _rows || _sizedSession != tab.session) {
        _cols = cols;
        _rows = rows;
        _sizedSession = tab.session;
        mica_session_resize(tab.session, (int)rows, (int)cols);
    }
}

- (NSRect)cellRectAtRow:(NSInteger)row col:(NSInteger)col {
    NSRect area = [self terminalRect];
    CGFloat top = NSMaxY(area);
    return NSMakeRect(col * _charWidth, top - (row + 1) * _lineHeight, _charWidth, _lineHeight);
}

- (NSString *)labelForTab:(MicaTab *)tab active:(BOOL)active {
    NSString *marker = tab.needsAttention ? @"! " : (active ? @"● " : @"");
    return [NSString stringWithFormat:@"%@%@", marker, [self.owner displayNameForTab:tab]];
}

- (NSPoint)cellForPoint:(NSPoint)point {
    CGFloat top = NSMaxY([self terminalRect]);
    NSInteger row = (NSInteger)floor((top - point.y) / MAX(_lineHeight, 1));
    NSInteger col = (NSInteger)floor(point.x / MAX(_charWidth, 1));
    return NSMakePoint(MIN(MAX(0, col), MAX(0, _cols - 1)), MIN(MAX(0, row), MAX(0, _rows - 1)));
}

- (BOOL)point:(NSPoint)point isWithinSelectionAtRow:(NSInteger)row col:(NSInteger)col {
    if (!_selecting) return NO;
    NSPoint a = [self cellForPoint:_selectionStart];
    NSPoint b = [self cellForPoint:_selectionEnd];
    NSInteger ar = (NSInteger)a.y, ac = (NSInteger)a.x, br = (NSInteger)b.y, bc = (NSInteger)b.x;
    if (ar > br || (ar == br && ac > bc)) { NSInteger tr = ar, tc = ac; ar = br; ac = bc; br = tr; bc = tc; }
    return (row > ar || (row == ar && col >= ac)) && (row < br || (row == br && col <= bc));
}

- (void)drawRect:(NSRect)dirtyRect {
    [self updateGridSize];
    [[NSColor colorWithRed:0.055 green:0.065 blue:0.082 alpha:1.0] setFill];
    NSRectFill(self.bounds);
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;

    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight, self.bounds.size.width, kHeaderHeight);
    [[NSColor colorWithRed:0.085 green:0.098 blue:0.12 alpha:1.0] setFill];
    NSRectFill(header);
    CGFloat tabX = 12;
    NSDictionary *tabAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.7 alpha:1] };
    for (NSUInteger i = 0; i < self.owner.tabs.count; i++) {
        MicaTab *candidate = self.owner.tabs[i];
        BOOL active = i == (NSUInteger)self.owner.activeIndex;
        NSString *label = [self labelForTab:candidate active:active];
        NSSize labelSize = [label sizeWithAttributes:tabAttrs];
        NSRect labelRect = NSMakeRect(tabX, NSMinY(header) + 8, labelSize.width + 16, 15);
        if (active) {
            [[NSColor colorWithRed:0.20 green:0.48 blue:0.78 alpha:0.35] setFill];
            NSRectFill(NSInsetRect(labelRect, -4, -3));
            NSDictionary *activeAttrs = @{ NSFontAttributeName: tabAttrs[NSFontAttributeName], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.97 alpha:1] };
            [label drawAtPoint:NSMakePoint(tabX, NSMinY(header) + 8) withAttributes:activeAttrs];
        } else {
            [label drawAtPoint:NSMakePoint(tabX, NSMinY(header) + 8) withAttributes:tabAttrs];
        }
        tabX += labelRect.size.width + 8;
    }
    NSColor *hintColor = [NSColor colorWithWhite:0.49 alpha:1];
    NSDictionary *hintAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:10], NSForegroundColorAttributeName: hintColor };
    NSString *hint = mica_session_view_offset(tab.session) > 0
        ? [NSString stringWithFormat:@"SCROLLBACK  %d lines  ·  Esc to return", mica_session_view_offset(tab.session)]
        : @"⌘T shell   ⌥⌘C Claude   ⌥⌘X Codex   ⇧PgUp scrollback";
    NSSize hintSize = [hint sizeWithAttributes:hintAttrs];
    [hint drawAtPoint:NSMakePoint(self.bounds.size.width - hintSize.width - 12, NSMinY(header) + 9) withAttributes:hintAttrs];

    for (NSInteger row = 0; row < _rows; row++) {
        for (NSInteger col = 0; col < _cols; col++) {
            MicaCell cell;
            if (!mica_session_get_cell(tab.session, (int)row, (int)col, &cell)) continue;
            BOOL selected = [self point:NSZeroPoint isWithinSelectionAtRow:row col:col];
            NSColor *fg = [self colorForVTermColor:cell.fg isForeground:YES];
            NSColor *bg = [self colorForVTermColor:cell.bg isForeground:NO];
            if (cell.attrs.reverse) { NSColor *swap = fg; fg = bg; bg = swap; }
            if (selected) bg = [NSColor colorWithRed:0.18 green:0.37 blue:0.60 alpha:1];
            BOOL hasBackground = selected || !VTERM_COLOR_IS_DEFAULT_BG(&cell.bg);
            NSRect cellRect = [self cellRectAtRow:row col:col];
            if (hasBackground) { [bg setFill]; NSRectFill(cellRect); }
            if (CellIsContinuation(cell)) continue;
            NSString *glyph = [self stringForCell:cell];
            if ([glyph isEqualToString:@" "]) continue;
            NSFont *font = self.terminalFont;
            if (cell.attrs.bold || cell.attrs.italic) {
                NSFontTraitMask traits = (cell.attrs.bold ? NSBoldFontMask : 0) | (cell.attrs.italic ? NSItalicFontMask : 0);
                font = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:traits];
            }
            NSMutableDictionary *glyphAttrs = [@{ NSFontAttributeName: font, NSForegroundColorAttributeName: fg } mutableCopy];
            if (cell.attrs.underline) glyphAttrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
            [glyph drawAtPoint:NSMakePoint(NSMinX(cellRect), NSMinY(cellRect) + 1) withAttributes:glyphAttrs];
        }
    }
    if (mica_session_view_offset(tab.session) == 0 && mica_session_cursor_visible(tab.session)) {
        int cursorRow = 0, cursorCol = 0;
        mica_session_cursor(tab.session, &cursorRow, &cursorCol);
        if (cursorRow >= 0 && cursorRow < _rows && cursorCol >= 0 && cursorCol < _cols) {
            NSRect cursorRect = [self cellRectAtRow:cursorRow col:cursorCol];
            [[NSColor colorWithWhite:0.9 alpha:0.55] setFill];
            NSRectFill(NSMakeRect(cursorRect.origin.x, cursorRect.origin.y, 2, cursorRect.size.height));
        }
    }
    if (!mica_session_is_running(tab.session)) {
        NSDictionary *exitAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:10], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.5 alpha:1] };
        [@"process exited · ⌘T opens a new tab" drawAtPoint:NSMakePoint(12, 5) withAttributes:exitAttrs];
    }
    (void)dirtyRect;
}

- (void)keyDown:(NSEvent *)event {
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;
    BOOL control = (flags & NSEventModifierFlagControl) != 0;
    if (command) {
        NSString *key = event.charactersIgnoringModifiers.lowercaseString;
        if ([key isEqualToString:@"t"]) { [self.owner newTabWithName:@"Shell" command:nil]; return; }
        if ([key isEqualToString:@"w"]) { [self.owner closeActiveTab]; return; }
        if (option && (flags & NSEventModifierFlagShift) && [key isEqualToString:@"c"]) { [self.owner newTabWithName:@"Claude Code (resumed)" command:@"unset CLAUDECODE; export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1; yowork --continue"]; return; }
        if (option && (flags & NSEventModifierFlagShift) && [key isEqualToString:@"x"]) { [self.owner newTabWithName:@"Codex (resumed)" command:@"codex resume -c tui.raw_output_mode=true --no-alt-screen --last"]; return; }
        if (option && [key isEqualToString:@"c"]) { [self.owner newTabWithName:@"Claude Code" command:@"unset CLAUDECODE; export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1; yowork"]; return; }
        if (option && [key isEqualToString:@"x"]) { [self.owner newTabWithName:@"Codex" command:@"codex -c tui.raw_output_mode=true --no-alt-screen"]; return; }
        if ([key isEqualToString:@"c"]) { if (_selecting) [self copySelection:nil]; else mica_session_text(tab.session, 'c', VTERM_MOD_CTRL); return; }
        if ([key isEqualToString:@"v"]) { [self paste:nil]; return; }
        if ((flags & NSEventModifierFlagShift) && event.keyCode == 30) { [self.owner selectRelativeTab:1]; return; }
        if ((flags & NSEventModifierFlagShift) && event.keyCode == 33) { [self.owner selectRelativeTab:-1]; return; }
        if ([key isEqualToString:@"+"] || [key isEqualToString:@"="]) { self.terminalFont = [NSFont monospacedSystemFontOfSize:MIN(28, self.terminalFont.pointSize + 1) weight:NSFontWeightRegular]; [self setNeedsDisplay:YES]; return; }
        if ([key isEqualToString:@"-"]) { self.terminalFont = [NSFont monospacedSystemFontOfSize:MAX(8, self.terminalFont.pointSize - 1) weight:NSFontWeightRegular]; [self setNeedsDisplay:YES]; return; }
        return;
    }
    VTermModifier modifiers = VTERM_MOD_NONE;
    if (flags & NSEventModifierFlagShift) modifiers |= VTERM_MOD_SHIFT;
    if (option) modifiers |= VTERM_MOD_ALT;
    if (control) modifiers |= VTERM_MOD_CTRL;
    VTermKey key = VTERM_KEY_NONE;
    switch (event.keyCode) {
        case 36: case 76: key = VTERM_KEY_ENTER; break;
        case 48: key = VTERM_KEY_TAB; break;
        case 51: key = VTERM_KEY_BACKSPACE; break;
        case 53: key = VTERM_KEY_ESCAPE; break;
        case 123: key = VTERM_KEY_LEFT; break;
        case 124: key = VTERM_KEY_RIGHT; break;
        case 125: key = VTERM_KEY_DOWN; break;
        case 126: key = VTERM_KEY_UP; break;
        case 115: key = VTERM_KEY_HOME; break;
        case 119: key = VTERM_KEY_END; break;
        case 116: key = VTERM_KEY_PAGEUP; break;
        case 121: key = VTERM_KEY_PAGEDOWN; break;
        case 117: key = VTERM_KEY_DEL; break;
        case 114: key = VTERM_KEY_INS; break;
        default: break;
    }
    if ((flags & NSEventModifierFlagShift) && event.keyCode == 116) {
        mica_session_scroll(tab.session, MAX(1, (int)_rows - 1));
        _selecting = NO;
        [self setNeedsDisplay:YES];
        return;
    }
    if ((flags & NSEventModifierFlagShift) && event.keyCode == 121) {
        mica_session_scroll(tab.session, -MAX(1, (int)_rows - 1));
        _selecting = NO;
        [self setNeedsDisplay:YES];
        return;
    }
    if (key != VTERM_KEY_NONE) { mica_session_key(tab.session, key, modifiers); _selecting = NO; [self setNeedsDisplay:YES]; return; }
    NSString *characters = control ? event.charactersIgnoringModifiers : event.characters;
    for (NSUInteger i = 0; i < characters.length; i++) {
        unichar first = [characters characterAtIndex:i];
        uint32_t codepoint = first;
        if (CFStringIsSurrogateHighCharacter(first) && i + 1 < characters.length) {
            unichar second = [characters characterAtIndex:i + 1];
            if (CFStringIsSurrogateLowCharacter(second)) { codepoint = CFStringGetLongCharacterForSurrogatePair(first, second); i++; }
        }
        if (codepoint >= 0x20 || codepoint > 0x7e || control) mica_session_text(tab.session, codepoint, modifiers);
    }
    _selecting = NO;
    [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent *)event {
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;
    _scrollRemainder += event.scrollingDeltaY;
    NSInteger lines = (NSInteger)(_scrollRemainder / 24.0);
    if (lines == 0) return;
    _scrollRemainder -= lines * 24.0;
    if (mica_session_reports_mouse(tab.session)) {
        NSPoint point = [self cellForPoint:[self convertPoint:event.locationInWindow fromView:nil]];
        int direction = lines > 0 ? -1 : 1;
        for (NSInteger i = 0; i < labs(lines); i++) mica_session_wheel(tab.session, (int)point.y, (int)point.x, direction);
    } else {
        mica_session_scroll(tab.session, (int)lines);
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (point.y > NSMaxY([self terminalRect])) {
        CGFloat x = 12;
        NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium] };
        for (NSUInteger i = 0; i < self.owner.tabs.count; i++) {
            NSString *title = [self labelForTab:self.owner.tabs[i] active:(i == (NSUInteger)self.owner.activeIndex)];
            CGFloat width = [title sizeWithAttributes:attrs].width + 24;
            if (point.x >= x && point.x < x + width) { [self.owner selectTabAtIndex:(NSInteger)i]; return; }
            x += width + 8;
        }
        return;
    }
    if (mica_session_reports_mouse(self.owner.activeTab.session)) {
        NSPoint cell = [self cellForPoint:point];
        mica_session_mouse(self.owner.activeTab.session, (int)cell.y, (int)cell.x, 1, true);
        _mousePressed = YES;
        _mouseRow = (NSInteger)cell.y;
        _mouseCol = (NSInteger)cell.x;
        return;
    }
    _selecting = YES;
    _selectionStart = point;
    _selectionEnd = point;
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_selecting) return;
    _selectionEnd = [self convertPoint:event.locationInWindow fromView:nil];
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (_mousePressed) {
        mica_session_mouse(self.owner.activeTab.session, (int)_mouseRow, (int)_mouseCol, 1, false);
        _mousePressed = NO;
        return;
    }
    if (!_selecting) return;
    _selectionEnd = [self convertPoint:event.locationInWindow fromView:nil];
    [self setNeedsDisplay:YES];
}

- (void)copySelection:(id)sender {
    (void)sender;
    if (!_selecting || !self.owner.activeTab.session) return;
    NSPoint a = [self cellForPoint:_selectionStart], b = [self cellForPoint:_selectionEnd];
    NSInteger ar = (NSInteger)a.y, ac = (NSInteger)a.x, br = (NSInteger)b.y, bc = (NSInteger)b.x;
    if (ar > br || (ar == br && ac > bc)) { NSInteger tr = ar, tc = ac; ar = br; ac = bc; br = tr; bc = tc; }
    NSMutableString *output = [NSMutableString string];
    for (NSInteger row = ar; row <= br; row++) {
        NSInteger first = row == ar ? ac : 0;
        NSInteger last = row == br ? bc : _cols - 1;
        NSMutableString *line = [NSMutableString string];
        for (NSInteger col = first; col <= last; col++) {
            MicaCell cell;
            if (mica_session_get_cell(self.owner.activeTab.session, (int)row, (int)col, &cell) && !CellIsContinuation(cell))
                [line appendString:[self stringForCell:cell]];
        }
        while ([line hasSuffix:@" "]) [line deleteCharactersInRange:NSMakeRange(line.length - 1, 1)];
        [output appendString:line];
        if (row != br) [output appendString:@"\n"];
    }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:output forType:NSPasteboardTypeString];
}

- (void)copy:(id)sender { [self copySelection:sender]; }

- (void)paste:(id)sender {
    (void)sender;
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!text || !self.owner.activeTab.session) return;
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    mica_session_paste(self.owner.activeTab.session, bytes.bytes, bytes.length);
    [self setNeedsDisplay:YES];
}

- (void)viewDidEndLiveResize { [super viewDidEndLiveResize]; [self.owner resizeActiveSession]; }
@end

@implementation MicaAppDelegate
- (MicaTab *)activeTab {
    if (self.activeIndex < 0 || self.activeIndex >= (NSInteger)self.tabs.count) return nil;
    return self.tabs[(NSUInteger)self.activeIndex];
}

- (NSString *)displayNameForTab:(MicaTab *)tab {
    if (!tab.terminalTitle.length) return tab.name;
    return [NSString stringWithFormat:@"%@ · %@", tab.name, tab.terminalTitle];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.tabs = [NSMutableArray array];
    self.activeIndex = 0;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 1100, 700)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Mica Terminal";
    self.window.minSize = NSMakeSize(600, 300);
    self.window.delegate = self;
    self.terminalView = [[MicaTerminalView alloc] initWithFrame:self.window.contentView.bounds];
    self.terminalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.terminalView.owner = self;
    self.terminalView.terminalFont = [NSFont monospacedSystemFontOfSize:kFontSizeDefault weight:NSFontWeightRegular];
    [self.window setContentView:self.terminalView];
    [self.window makeKeyAndOrderFront:nil];
    [self installMenus];
    [self loadLaunchConfiguration];
    [self.window makeFirstResponder:self.terminalView];
    self.pollTimer = [NSTimer timerWithTimeInterval:0.015 target:self selector:@selector(pollSessions:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)installMenus {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Mica"];
    NSMenuItem *appRoot = [[NSMenuItem alloc] initWithTitle:@"Mica" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Mica"];
    AddMenuItem(appMenu, @"About Mica", @selector(orderFrontStandardAboutPanel:), @"", 0);
    [appMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(appMenu, @"Quit Mica", @selector(terminate:), @"q", NSEventModifierFlagCommand);
    appRoot.submenu = appMenu;
    [main addItem:appRoot];
    NSMenuItem *sessionsRoot = [[NSMenuItem alloc] initWithTitle:@"Session" action:nil keyEquivalent:@""];
    NSMenu *sessionMenu = [[NSMenu alloc] initWithTitle:@"Session"];
    AddMenuItem(sessionMenu, @"New Shell Tab", @selector(newShell:), @"t", NSEventModifierFlagCommand).target = self;
    AddMenuItem(sessionMenu, @"New Claude Code Tab", @selector(newClaude:), @"c", NSEventModifierFlagCommand | NSEventModifierFlagOption).target = self;
    AddMenuItem(sessionMenu, @"New Codex Tab", @selector(newCodex:), @"x", NSEventModifierFlagCommand | NSEventModifierFlagOption).target = self;
    AddMenuItem(sessionMenu, @"Resume Claude Code", @selector(resumeClaude:), @"c", NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagShift).target = self;
    AddMenuItem(sessionMenu, @"Resume Codex", @selector(resumeCodex:), @"x", NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagShift).target = self;
    [sessionMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(sessionMenu, @"Previous Tab", @selector(previousTab:), @"[", NSEventModifierFlagCommand | NSEventModifierFlagShift).target = self;
    AddMenuItem(sessionMenu, @"Next Tab", @selector(nextTab:), @"]", NSEventModifierFlagCommand | NSEventModifierFlagShift).target = self;
    AddMenuItem(sessionMenu, @"Close Tab", @selector(closeTab:), @"w", NSEventModifierFlagCommand).target = self;
    sessionsRoot.submenu = sessionMenu;
    [main addItem:sessionsRoot];
    NSMenuItem *editRoot = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    AddMenuItem(editMenu, @"Copy", @selector(copy:), @"c", NSEventModifierFlagCommand);
    AddMenuItem(editMenu, @"Paste", @selector(paste:), @"v", NSEventModifierFlagCommand);
    editRoot.submenu = editMenu;
    [main addItem:editRoot];
    [NSApp setMainMenu:main];
}

- (void)loadLaunchConfiguration {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSString *layoutPath = nil;
    NSString *cwd = NSFileManager.defaultManager.currentDirectoryPath;
    NSString *command = nil;
    for (NSUInteger i = 1; i + 1 < args.count; i++) {
        if ([args[i] isEqualToString:@"--layout"]) layoutPath = args[++i];
        else if ([args[i] isEqualToString:@"--cwd"]) cwd = args[++i];
        else if ([args[i] isEqualToString:@"--command"]) command = args[++i];
    }
    if (layoutPath) {
        NSString *contents = [NSString stringWithContentsOfFile:layoutPath encoding:NSUTF8StringEncoding error:nil];
        [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            (void)stop;
            if (!line.length || [line hasPrefix:@"#"]) return;
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
            if (parts.count < 2) return;
            NSString *name = parts[0];
            NSString *tabCwd = parts[1].length ? parts[1] : cwd;
            NSMutableString *tabCommand = [NSMutableString string];
            for (NSUInteger i = 2; i < parts.count; i++) {
                if (i > 2) [tabCommand appendString:@"\t"];
                [tabCommand appendString:parts[i]];
            }
            [self addTabWithName:name cwd:tabCwd command:tabCommand.length ? tabCommand : nil];
        }];
    }
    if (!self.tabs.count) [self addTabWithName:@"Shell" cwd:cwd command:command];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)addTabWithName:(NSString *)name cwd:(NSString *)cwd command:(NSString *)command {
    MicaTab *previous = self.activeTab;
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    MicaTab *tab = [[MicaTab alloc] init];
    tab.name = name.length ? name : @"Terminal";
    tab.cwd = cwd.length ? cwd : NSFileManager.defaultManager.currentDirectoryPath;
    tab.command = command;
    tab.session = mica_session_create(tab.cwd.fileSystemRepresentation, command.UTF8String, 24, 80);
    if (!tab.session) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Mica could not create a terminal session";
        alert.informativeText = [NSString stringWithFormat:@"Could not open %@", tab.cwd];
        [alert runModal];
        return;
    }
    tab.revision = UINT64_MAX;
    [self.tabs addObject:tab];
    self.activeIndex = (NSInteger)self.tabs.count - 1;
    if (NSApp.isActive) mica_session_focus(tab.session, true);
    self.window.title = [NSString stringWithFormat:@"%@ — Mica Terminal", [self displayNameForTab:tab]];
    [self resizeActiveSession];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)newTabWithName:(NSString *)name command:(NSString *)command {
    MicaTab *active = self.activeTab;
    [self addTabWithName:name cwd:active.cwd command:command];
    [self.window makeFirstResponder:self.terminalView];
}

- (void)resizeActiveSession { [self.terminalView setNeedsDisplay:YES]; }
- (void)newShell:(id)sender { (void)sender; [self newTabWithName:@"Shell" command:nil]; }
- (void)newClaude:(id)sender { (void)sender; [self newTabWithName:@"Claude Code" command:@"unset CLAUDECODE; export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1; yowork"]; }
- (void)newCodex:(id)sender { (void)sender; [self newTabWithName:@"Codex" command:@"codex -c tui.raw_output_mode=true --no-alt-screen"]; }
- (void)resumeClaude:(id)sender { (void)sender; [self newTabWithName:@"Claude Code (resumed)" command:@"unset CLAUDECODE; export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1; yowork --continue"]; }
- (void)resumeCodex:(id)sender { (void)sender; [self newTabWithName:@"Codex (resumed)" command:@"codex resume -c tui.raw_output_mode=true --no-alt-screen --last"]; }
- (void)closeTab:(id)sender { (void)sender; [self closeActiveTab]; }
- (void)nextTab:(id)sender { (void)sender; [self selectRelativeTab:1]; }
- (void)previousTab:(id)sender { (void)sender; [self selectRelativeTab:-1]; }

- (void)closeActiveTab {
    if (self.tabs.count <= 1) { [self.window performClose:nil]; return; }
    MicaTab *previous = self.activeTab;
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    [self.tabs removeObjectAtIndex:(NSUInteger)self.activeIndex];
    if (self.activeIndex >= (NSInteger)self.tabs.count) self.activeIndex = (NSInteger)self.tabs.count - 1;
    MicaTab *tab = self.activeTab;
    if (NSApp.isActive) mica_session_focus(tab.session, true);
    tab.needsAttention = NO;
    self.window.title = [NSString stringWithFormat:@"%@ — Mica Terminal", [self displayNameForTab:tab]];
    [self resizeActiveSession];
}

- (void)selectRelativeTab:(NSInteger)delta {
    if (self.tabs.count < 2) return;
    NSInteger count = (NSInteger)self.tabs.count;
    [self selectTabAtIndex:(self.activeIndex + delta + count) % count];
}

- (void)selectTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.tabs.count || index == self.activeIndex) return;
    MicaTab *previous = self.activeTab;
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    self.activeIndex = index;
    MicaTab *tab = self.activeTab;
    tab.needsAttention = NO;
    if (NSApp.isActive) mica_session_focus(tab.session, true);
    self.window.title = [NSString stringWithFormat:@"%@ — Mica Terminal", [self displayNameForTab:tab]];
    [self resizeActiveSession];
}

- (void)pollSessions:(NSTimer *)timer {
    (void)timer;
    BOOL redraw = NO;
    for (MicaTab *tab in self.tabs) {
        mica_session_poll(tab.session, 0);
        const char *rawTitle = mica_session_title(tab.session);
        NSString *terminalTitle = rawTitle[0]
            ? [[NSString alloc] initWithBytes:rawTitle length:strlen(rawTitle) encoding:NSUTF8StringEncoding]
            : nil;
        if (terminalTitle != tab.terminalTitle && ![terminalTitle isEqualToString:tab.terminalTitle]) {
            tab.terminalTitle = terminalTitle;
            if (tab == self.activeTab)
                self.window.title = [NSString stringWithFormat:@"%@ — Mica Terminal", [self displayNameForTab:tab]];
            redraw = YES;
        }
        uint64_t attentionCount = mica_session_attention_count(tab.session);
        if (attentionCount != tab.attentionCount) {
            tab.attentionCount = attentionCount;
            if (tab != self.activeTab || !NSApp.isActive) {
                tab.needsAttention = YES;
                if (!NSApp.isActive && self.attentionRequest == 0)
                    self.attentionRequest = [NSApp requestUserAttention:NSInformationalRequest];
                redraw = YES;
            }
        }
        uint64_t revision = mica_session_revision(tab.session);
        if (revision != tab.revision) { tab.revision = revision; if (tab == self.activeTab) redraw = YES; }
    }
    if (redraw) [self.terminalView setNeedsDisplay:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    MicaTab *tab = self.activeTab;
    if (tab.session) mica_session_focus(tab.session, false);
}
- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (self.attentionRequest != 0) {
        [NSApp cancelUserAttentionRequest:self.attentionRequest];
        self.attentionRequest = 0;
    }
    MicaTab *tab = self.activeTab;
    if (tab.session) mica_session_focus(tab.session, true);
    tab.needsAttention = NO;
    [self.terminalView setNeedsDisplay:YES];
}
- (void)windowDidResize:(NSNotification *)notification { (void)notification; [self resizeActiveSession]; }
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        MicaAppDelegate *delegate = [[MicaAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
