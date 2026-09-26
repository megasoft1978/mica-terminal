#import <Cocoa/Cocoa.h>
#import "mica.h"

static const CGFloat kHeaderHeight = 40.0;
static const CGFloat kStatusHeight = 34.0;
static const CGFloat kFontSizeDefault = 16.0;

typedef NS_ENUM(NSInteger, MicaUIMode) {
    MicaUIModeNormal = 0,
    MicaUIModeTab,
    MicaUIModeScroll,
};

static NSColor *MicaColor(uint32_t rgb) {
    return [NSColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0
                           alpha:1.0];
}

static NSColor *MicaBackgroundColor(void) {
    static NSColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = MicaColor(0x1e1e1e); });
    return color;
}

static NSColor *MicaForegroundColor(void) {
    static NSColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = MicaColor(0xd4d4d4); });
    return color;
}

static NSFont *MicaTerminalFont(CGFloat size) {
    NSFont *font = [NSFont fontWithName:@"JetBrainsMono-Regular" size:size];
    return font ?: [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}

@interface MicaTab : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *cwd;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSString *terminalTitle;
@property(nonatomic, assign) MicaSession *session;
@property(nonatomic, assign) uint64_t revision;
@property(nonatomic, assign) uint64_t attentionCount;
@property(nonatomic, assign) BOOL needsAttention;
@property(nonatomic, assign) uint64_t commandCompletionCount;
@property(nonatomic, assign) BOOL tracksCompletion;
@property(nonatomic, assign) BOOL completedCommand;
@property(nonatomic, assign) BOOL reportedProcessExit;
@property(nonatomic, assign) int completionStatus;
@property(nonatomic, copy) NSString *completionLabel;
@end
@implementation MicaTab
- (void)dealloc { if (_session) mica_session_destroy(_session); }
@end

@class MicaAppDelegate;
@interface MicaTerminalView : NSView
@property(nonatomic, weak) MicaAppDelegate *owner;
@property(nonatomic, strong) NSFont *terminalFont;
- (void)copySelection:(id)sender;
- (void)clearSelection;
- (void)paste:(id)sender;
- (void)copy:(id)sender;
@end

@interface MicaAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) MicaTerminalView *terminalView;
@property(nonatomic, strong) NSMutableArray<MicaTab *> *tabs;
@property(nonatomic, assign) NSInteger activeIndex;
@property(nonatomic, copy) NSString *projectName;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *agentCommands;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, assign) NSInteger attentionRequest;
- (MicaTab *)activeTab;
- (NSString *)displayNameForTab:(MicaTab *)tab;
- (NSString *)windowTitleForTab:(MicaTab *)tab;
- (void)newTabWithName:(NSString *)name command:(NSString *)command;
- (void)addTabWithName:(NSString *)name cwd:(NSString *)cwd command:(NSString *)command prefilled:(BOOL)prefilled;
- (void)closeActiveTab;
- (void)selectRelativeTab:(NSInteger)delta;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)resizeActiveSession;
- (void)installMenus;
- (void)updateWindowTitle;
- (void)pollSessions:(NSTimer *)timer;
- (void)launchAgentCommand:(NSString *)key tabName:(NSString *)name;
- (void)newClaude:(id)sender;
- (void)newCodex:(id)sender;
- (void)resumeClaude:(id)sender;
- (void)resumeCodex:(id)sender;
- (void)loadLaunchConfiguration;
- (void)loadLaunchConfigurationFromArguments:(NSArray<NSString *> *)arguments bundleInfo:(NSDictionary *)bundleInfo;
@property(nonatomic, assign) MicaUIMode uiMode;
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

static uint32_t CellLastCodepoint(MicaCell cell) {
    uint32_t last = 0;
    for (NSUInteger i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++)
        if (cell.chars[i] <= 0x10ffff) last = cell.chars[i];
    return last;
}

static BOOL IsRegionalIndicator(uint32_t codepoint) {
    return codepoint >= 0x1f1e6 && codepoint <= 0x1f1ff;
}

static BOOL IsEmojiModifier(uint32_t codepoint) {
    return codepoint >= 0x1f3fb && codepoint <= 0x1f3ff;
}

static BOOL IsVariationSelector(uint32_t codepoint) {
    return (codepoint >= 0xfe00 && codepoint <= 0xfe0f) ||
           (codepoint >= 0xe0100 && codepoint <= 0xe01ef);
}

static BOOL IsCombiningMark(uint32_t codepoint) {
    return (codepoint >= 0x0300 && codepoint <= 0x036f) ||
           (codepoint >= 0x1ab0 && codepoint <= 0x1aff) ||
           (codepoint >= 0x1dc0 && codepoint <= 0x1dff) ||
           (codepoint >= 0x20d0 && codepoint <= 0x20ff) ||
           (codepoint >= 0xfe20 && codepoint <= 0xfe2f);
}

@implementation MicaTerminalView {
    BOOL _selecting;
    NSPoint _selectionStart;
    NSPoint _selectionEnd;
    CGFloat _charWidth;
    CGFloat _lineHeight;
    NSInteger _rows;
    NSInteger _cols;
    int _pixelWidth;
    int _pixelHeight;
    CGFloat _scrollRemainder;
    MicaSession *_sizedSession;
    BOOL _mousePressed;
    NSInteger _mouseRow;
    NSInteger _mouseCol;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return NO; }

- (NSColor *)colorForVTermColor:(VTermColor)color isForeground:(BOOL)isForeground {
    if (isForeground && VTERM_COLOR_IS_DEFAULT_FG(&color)) return MicaForegroundColor();
    if (!isForeground && VTERM_COLOR_IS_DEFAULT_BG(&color)) return MicaBackgroundColor();
    if (VTERM_COLOR_IS_RGB(&color))
        return MicaColor(((uint32_t)color.rgb.red << 16) | ((uint32_t)color.rgb.green << 8) | color.rgb.blue);
    return isForeground ? MicaForegroundColor() : MicaBackgroundColor();
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
    return NSMakeRect(0, kStatusHeight, self.bounds.size.width,
                      MAX(0, self.bounds.size.height - kHeaderHeight - kStatusHeight));
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
    CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1.0;
    int pixelWidth = (int)lrint(self.bounds.size.width * scale);
    int pixelHeight = (int)lrint(area.size.height * scale);
    if (cols != _cols || rows != _rows || _sizedSession != tab.session ||
        pixelWidth != _pixelWidth || pixelHeight != _pixelHeight) {
        _cols = cols;
        _rows = rows;
        _pixelWidth = pixelWidth;
        _pixelHeight = pixelHeight;
        _sizedSession = tab.session;
        mica_session_resize_pixels(tab.session, (int)rows, (int)cols, pixelWidth, pixelHeight);
    }
}

- (NSRect)cellRectAtRow:(NSInteger)row col:(NSInteger)col {
    NSRect area = [self terminalRect];
    CGFloat top = NSMaxY(area);
    return NSMakeRect(col * _charWidth, top - (row + 1) * _lineHeight, _charWidth, _lineHeight);
}

- (NSString *)labelForTab:(MicaTab *)tab active:(BOOL)active {
    NSUInteger index = [self.owner.tabs indexOfObjectIdenticalTo:tab] + 1;
    NSString *marker = tab.needsAttention ? @"! " :
        (tab.completedCommand ? (tab.completionStatus == 0 ? @"✓ " : @"× ") : (active ? @"● " : @""));
    return [NSString stringWithFormat:@"%lu %@%@", (unsigned long)index, marker, [self.owner displayNameForTab:tab]];
}

- (void)drawStatusBarForTab:(MicaTab *)tab {
    NSRect status = NSMakeRect(0, 0, self.bounds.size.width, kStatusHeight);
    [NSColor.controlBackgroundColor setFill];
    NSRectFill(status);
    [NSColor.separatorColor setStroke];
    NSBezierPath *separator = [NSBezierPath bezierPath];
    [separator moveToPoint:NSMakePoint(0, NSMaxY(status) - 0.5)];
    [separator lineToPoint:NSMakePoint(NSMaxX(status), NSMaxY(status) - 0.5)];
    [separator stroke];

    MicaUIMode mode = self.owner.uiMode;
    BOOL scrolled = mica_session_view_offset(tab.session) > 0;
    BOOL scrollView = mode == MicaUIModeScroll || scrolled;
    NSString *modeName = mode == MicaUIModeTab ? @"TAB" : (scrollView ? @"SCROLL" : @"NORMAL");
    NSColor *modeColor = scrollView ? NSColor.systemPurpleColor : NSColor.controlAccentColor;
    NSDictionary *modeAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.alternateSelectedControlTextColor
    };
    NSSize modeSize = [modeName sizeWithAttributes:modeAttrs];
    NSRect badge = NSMakeRect(12, 8, modeSize.width + 18, 19);
    [modeColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:badge xRadius:5 yRadius:5] fill];
    [modeName drawAtPoint:NSMakePoint(NSMinX(badge) + 9, NSMinY(badge) + 2) withAttributes:modeAttrs];

    NSString *context = tab.cwd.lastPathComponent.length ? tab.cwd.lastPathComponent : @"/";
    NSColor *contextColor = NSColor.secondaryLabelColor;
    if (tab.completedCommand) {
        NSString *result = tab.completionStatus == 0 ? @"finished successfully" :
            [NSString stringWithFormat:@"exited with status %d", tab.completionStatus];
        context = [NSString stringWithFormat:@"%@ %@", tab.completionLabel.length ? tab.completionLabel : @"Process", result];
        contextColor = tab.completionStatus == 0 ? NSColor.systemGreenColor : NSColor.systemRedColor;
    } else if (mica_session_view_offset(tab.session) > 0) {
        context = [NSString stringWithFormat:@"%@  ·  %d lines back", context, mica_session_view_offset(tab.session)];
    }
    NSDictionary *contextAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: contextColor
    };
    [context drawAtPoint:NSMakePoint(NSMaxX(badge) + 12, 9) withAttributes:contextAttrs];

    NSString *hints = mode == MicaUIModeTab
        ? @"←/h previous   →/l next   1–9 jump   n new   x close   Esc done"
        : (mode == MicaUIModeScroll
            ? @"↑/↓, j/k line   ←/→, h/l page   ^F/^B page   Esc live"
            : (scrolled
                ? @"scrollback   Esc live   ^S scroll mode   ⌘Tab switch app"
                : @"^T tabs   ^S scroll   ⌘T shell   ⌥⌘C Claude   ⌥⌘X Codex   ⌘Tab switch app"));
    NSDictionary *hintAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };
    NSSize hintSize = [hints sizeWithAttributes:hintAttrs];
    [hints drawAtPoint:NSMakePoint(MAX(NSMaxX(badge) + 200, self.bounds.size.width - hintSize.width - 14), 9)
         withAttributes:hintAttrs];
}

- (BOOL)handleNavigationModeKey:(NSEvent *)event key:(NSString *)key control:(BOOL)control {
    MicaUIMode mode = self.owner.uiMode;
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session || mode == MicaUIModeNormal) return NO;
    BOOL modeToggle = control &&
        ((mode == MicaUIModeTab && [key isEqualToString:@"t"]) ||
         (mode == MicaUIModeScroll && ([key isEqualToString:@"s"] || [key isEqualToString:@"c"])));
    if (event.keyCode == 53 || modeToggle) {
        self.owner.uiMode = MicaUIModeNormal;
        if (mode == MicaUIModeScroll) mica_session_scroll_to_bottom(tab.session);
        [self setNeedsDisplay:YES];
        return YES;
    }
    if (mode == MicaUIModeTab) {
        if (key.length == 1 && key.integerValue >= 1 && key.integerValue <= 9 &&
            [key characterAtIndex:0] >= '1' && [key characterAtIndex:0] <= '9') {
            [self.owner selectTabAtIndex:key.integerValue - 1];
            self.owner.uiMode = MicaUIModeNormal;
        } else if ([key isEqualToString:@"h"] || [key isEqualToString:@"k"] || event.keyCode == 123 || event.keyCode == 126) {
            [self.owner selectRelativeTab:-1];
        } else if ([key isEqualToString:@"j"] || [key isEqualToString:@"l"] || event.keyCode == 124 || event.keyCode == 125) {
            [self.owner selectRelativeTab:1];
        } else if ([key isEqualToString:@"n"]) {
            [self.owner newTabWithName:@"Shell" command:nil];
            self.owner.uiMode = MicaUIModeNormal;
        } else if ([key isEqualToString:@"x"]) {
            [self.owner closeActiveTab];
            self.owner.uiMode = MicaUIModeNormal;
        } else {
            return YES;
        }
    } else {
        NSInteger lines = 0;
        if (event.keyCode == 116 || event.keyCode == 123 || [key isEqualToString:@"h"] ||
            (control && [key isEqualToString:@"b"])) lines = MAX(1, (int)_rows - 1);
        else if (event.keyCode == 121 || event.keyCode == 124 || [key isEqualToString:@"l"] ||
            (control && [key isEqualToString:@"f"])) lines = -MAX(1, (int)_rows - 1);
        else if (event.keyCode == 126 || [key isEqualToString:@"k"]) lines = 1;
        else if (event.keyCode == 125 || [key isEqualToString:@"j"]) lines = -1;
        else if ([key isEqualToString:@"u"]) lines = MAX(1, (int)_rows / 2);
        else if ([key isEqualToString:@"d"]) lines = -MAX(1, (int)_rows / 2);
        else return YES;
        mica_session_scroll(tab.session, (int)lines);
    }
    [self setNeedsDisplay:YES];
    return YES;
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
    [MicaBackgroundColor() setFill];
    NSRectFill(self.bounds);
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;

    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight, self.bounds.size.width, kHeaderHeight);
    [NSColor.controlBackgroundColor setFill];
    NSRectFill(header);
    [NSColor.separatorColor setStroke];
    NSBezierPath *headerSeparator = [NSBezierPath bezierPath];
    [headerSeparator moveToPoint:NSMakePoint(0, NSMinY(header) + 0.5)];
    [headerSeparator lineToPoint:NSMakePoint(NSMaxX(header), NSMinY(header) + 0.5)];
    [headerSeparator stroke];
    CGFloat tabX = 14;
    NSDictionary *tabAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
    for (NSUInteger i = 0; i < self.owner.tabs.count; i++) {
        MicaTab *candidate = self.owner.tabs[i];
        BOOL active = i == (NSUInteger)self.owner.activeIndex;
        NSString *label = [self labelForTab:candidate active:active];
        NSSize labelSize = [label sizeWithAttributes:tabAttrs];
        NSRect labelRect = NSMakeRect(tabX, NSMinY(header) + 12, labelSize.width + 20, 18);
        if (active) {
            NSRect selectedTab = NSMakeRect(tabX - 7, NSMinY(header) + 5, labelRect.size.width + 4, 30);
            [[NSColor.controlAccentColor colorWithAlphaComponent:0.20] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:selectedTab xRadius:7 yRadius:7] fill];
            NSDictionary *activeAttrs = @{ NSFontAttributeName: tabAttrs[NSFontAttributeName], NSForegroundColorAttributeName: NSColor.labelColor };
            [label drawAtPoint:NSMakePoint(tabX, NSMinY(header) + 12) withAttributes:activeAttrs];
        } else {
            [label drawAtPoint:NSMakePoint(tabX, NSMinY(header) + 12) withAttributes:tabAttrs];
        }
        tabX += labelRect.size.width + 14;
    }
    for (NSInteger row = 0; row < _rows; row++) {
        NSInteger skipGlyphThroughCol = -1;
        for (NSInteger col = 0; col < _cols; col++) {
            MicaCell cell;
            if (!mica_session_get_cell(tab.session, (int)row, (int)col, &cell)) continue;
            BOOL selected = [self point:NSZeroPoint isWithinSelectionAtRow:row col:col];
            NSColor *fg = [self colorForVTermColor:cell.fg isForeground:YES];
            NSColor *bg = [self colorForVTermColor:cell.bg isForeground:NO];
            if (cell.attrs.reverse) { NSColor *swap = fg; fg = bg; bg = swap; }
            if (selected) bg = NSColor.selectedTextBackgroundColor;
            BOOL hasBackground = selected || !VTERM_COLOR_IS_DEFAULT_BG(&cell.bg);
            NSRect cellRect = [self cellRectAtRow:row col:col];
            if (hasBackground) { [bg setFill]; NSRectFill(cellRect); }
            if (CellIsContinuation(cell) || col <= skipGlyphThroughCol) continue;
            NSMutableString *glyph = [[self stringForCell:cell] mutableCopy];
            uint32_t firstCodepoint = cell.chars[0];
            uint32_t lastCodepoint = CellLastCodepoint(cell);
            BOOL flagPair = IsRegionalIndicator(firstCodepoint);
            BOOL addedFlagMate = NO;
            NSInteger nextCol = col + MAX((NSInteger)cell.width, 1);
            while (nextCol < _cols) {
                MicaCell nextCell;
                if (!mica_session_get_cell(tab.session, (int)row, (int)nextCol, &nextCell)) break;
                if (CellIsContinuation(nextCell)) { nextCol++; continue; }
                uint32_t nextFirst = nextCell.chars[0];
                BOOL merge = lastCodepoint == 0x200d || IsEmojiModifier(nextFirst) ||
                    IsVariationSelector(nextFirst) || IsCombiningMark(nextFirst) ||
                    (flagPair && !addedFlagMate && IsRegionalIndicator(nextFirst));
                if (!merge) break;
                [glyph appendString:[self stringForCell:nextCell]];
                skipGlyphThroughCol = nextCol + MAX((NSInteger)nextCell.width, 1) - 1;
                if (flagPair) addedFlagMate = YES;
                lastCodepoint = CellLastCodepoint(nextCell);
                nextCol += MAX((NSInteger)nextCell.width, 1);
                if (flagPair && addedFlagMate) break;
            }
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
            [NSColor.textColor setFill];
            NSRectFill(NSMakeRect(cursorRect.origin.x, cursorRect.origin.y, 2, cursorRect.size.height));
        }
    }
    if (!mica_session_is_running(tab.session)) {
        int exitStatus = mica_session_exit_status(tab.session);
        NSString *exitMessage = exitStatus == 0 ? @"Shell exited" : [NSString stringWithFormat:@"Shell exited with status %d", exitStatus];
        NSDictionary *exitAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
        [exitMessage drawAtPoint:NSMakePoint(12, kStatusHeight + 4) withAttributes:exitAttrs];
    }
    [self drawStatusBarForTab:tab];
    (void)dirtyRect;
}

- (void)keyDown:(NSEvent *)event {
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;
    BOOL control = (flags & NSEventModifierFlagControl) != 0;
    NSString *keyString = event.charactersIgnoringModifiers.lowercaseString;
    if (!command && control && [keyString isEqualToString:@"t"]) {
        self.owner.uiMode = self.owner.uiMode == MicaUIModeTab ? MicaUIModeNormal : MicaUIModeTab;
        [self setNeedsDisplay:YES];
        return;
    }
    if (!command && control && [keyString isEqualToString:@"s"]) {
        if (self.owner.uiMode == MicaUIModeScroll) {
            mica_session_scroll_to_bottom(tab.session);
            self.owner.uiMode = MicaUIModeNormal;
        } else {
            self.owner.uiMode = MicaUIModeScroll;
        }
        [self setNeedsDisplay:YES];
        return;
    }
    if (!command && [self handleNavigationModeKey:event key:keyString control:control]) return;
    if (command) {
        if ([keyString isEqualToString:@"t"]) { [self.owner newTabWithName:@"Shell" command:nil]; return; }
        if ([keyString isEqualToString:@"w"]) { [self.owner closeActiveTab]; return; }
        if (option && (flags & NSEventModifierFlagShift) && [keyString isEqualToString:@"c"]) { [self.owner resumeClaude:nil]; return; }
        if (option && (flags & NSEventModifierFlagShift) && [keyString isEqualToString:@"x"]) { [self.owner resumeCodex:nil]; return; }
        if (option && [keyString isEqualToString:@"c"]) { [self.owner newClaude:nil]; return; }
        if (option && [keyString isEqualToString:@"x"]) { [self.owner newCodex:nil]; return; }
        if ([keyString isEqualToString:@"c"]) { if (_selecting) [self copySelection:nil]; else mica_session_text(tab.session, 'c', VTERM_MOD_CTRL); return; }
        if ([keyString isEqualToString:@"v"]) { [self paste:nil]; return; }
        if ((flags & NSEventModifierFlagShift) && event.keyCode == 30) { [self.owner selectRelativeTab:1]; return; }
        if ((flags & NSEventModifierFlagShift) && event.keyCode == 33) { [self.owner selectRelativeTab:-1]; return; }
        if ([keyString isEqualToString:@"+"] || [keyString isEqualToString:@"="]) { self.terminalFont = MicaTerminalFont(MIN(28, self.terminalFont.pointSize + 1)); [self setNeedsDisplay:YES]; return; }
        if ([keyString isEqualToString:@"-"]) { self.terminalFont = MicaTerminalFont(MAX(8, self.terminalFont.pointSize - 1)); [self setNeedsDisplay:YES]; return; }
        return;
    }
    if (event.keyCode == 53 && mica_session_view_offset(tab.session) > 0) {
        mica_session_scroll_to_bottom(tab.session);
        _selecting = NO;
        [self setNeedsDisplay:YES];
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
        case 122: key = VTERM_KEY_FUNCTION(1); break;
        case 120: key = VTERM_KEY_FUNCTION(2); break;
        case 99: key = VTERM_KEY_FUNCTION(3); break;
        case 118: key = VTERM_KEY_FUNCTION(4); break;
        case 96: key = VTERM_KEY_FUNCTION(5); break;
        case 97: key = VTERM_KEY_FUNCTION(6); break;
        case 98: key = VTERM_KEY_FUNCTION(7); break;
        case 100: key = VTERM_KEY_FUNCTION(8); break;
        case 101: key = VTERM_KEY_FUNCTION(9); break;
        case 109: key = VTERM_KEY_FUNCTION(10); break;
        case 103: key = VTERM_KEY_FUNCTION(11); break;
        case 111: key = VTERM_KEY_FUNCTION(12); break;
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
    _selecting = NO;
    if (self.owner.uiMode != MicaUIModeScroll && mica_session_reports_mouse(tab.session)) {
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
    NSRect terminal = [self terminalRect];
    if (point.y < NSMinY(terminal)) return;
    if (point.y > NSMaxY(terminal)) {
        CGFloat x = 12;
        NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium] };
        for (NSUInteger i = 0; i < self.owner.tabs.count; i++) {
            NSString *title = [self labelForTab:self.owner.tabs[i] active:(i == (NSUInteger)self.owner.activeIndex)];
            CGFloat width = [title sizeWithAttributes:attrs].width + 24;
            if (point.x >= x && point.x < x + width) { [self.owner selectTabAtIndex:(NSInteger)i]; return; }
            x += width + 8;
        }
        return;
    }
    BOOL option = (event.modifierFlags & NSEventModifierFlagOption) != 0;
    if (mica_session_reports_mouse(self.owner.activeTab.session) && !option) {
        _selecting = NO;
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

- (void)clearSelection {
    _selecting = NO;
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
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;
    NSString *testPasteboardName = NSProcessInfo.processInfo.environment[@"MICA_TEST_PASTEBOARD_NAME"];
    NSPasteboard *pasteboard = testPasteboardName.length
        ? [NSPasteboard pasteboardWithName:testPasteboardName]
        : NSPasteboard.generalPasteboard;
    NSArray<NSPasteboardType> *imageTypes = @[
        NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg"
    ];
    for (NSPasteboardType imageType in imageTypes) {
        if ([pasteboard.types containsObject:imageType]) {
            // Claude Code and other agent TUIs read image data from the OS
            // clipboard when they receive Ctrl+V. Cmd+V is Mica's native paste key.
            mica_session_text(tab.session, 'v', VTERM_MOD_CTRL);
            [self setNeedsDisplay:YES];
            return;
        }
    }
    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    if (!text) return;
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    mica_session_paste(tab.session, bytes.bytes, bytes.length);
    [self setNeedsDisplay:YES];
}

- (void)viewDidEndLiveResize { [super viewDidEndLiveResize]; [self.owner resizeActiveSession]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self.owner resizeActiveSession]; }
@end

static NSDictionary *MicaResolveLaunchConfiguration(NSArray<NSString *> *args, NSDictionary *bundleInfo,
                                                     NSString *defaultCwd) {
    id bundledProjectName = bundleInfo[@"MicaProjectName"];
    NSString *projectName = [bundledProjectName isKindOfClass:NSString.class] ? bundledProjectName : @"";
    id bundledLayoutPath = bundleInfo[@"MicaProjectLayout"];
    NSString *layoutPath = [bundledLayoutPath isKindOfClass:NSString.class] ? bundledLayoutPath : @"";
    NSString *cwd = defaultCwd.length ? defaultCwd : NSFileManager.defaultManager.currentDirectoryPath;
    NSString *command = @"";
    for (NSUInteger i = 1; i + 1 < args.count; i++) {
        if ([args[i] isEqualToString:@"--layout"]) layoutPath = args[++i];
        else if ([args[i] isEqualToString:@"--cwd"]) cwd = args[++i];
        else if ([args[i] isEqualToString:@"--command"]) command = args[++i];
    }

    NSMutableArray<NSDictionary *> *tabs = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *agentCommands = [NSMutableDictionary dictionary];
    if (layoutPath.length) {
        NSString *contents = [NSString stringWithContentsOfFile:layoutPath encoding:NSUTF8StringEncoding error:nil];
        [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            (void)stop;
            if (!line.length || [line hasPrefix:@"#"]) return;
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
            if (parts.count < 2) return;
            NSString *setting = parts[0];
            if ([setting hasPrefix:@"agent."]) {
                NSString *key = [setting substringFromIndex:6];
                NSSet<NSString *> *allowedKeys = [NSSet setWithArray:@[
                    @"claude.start", @"claude.resume", @"codex.start", @"codex.resume"
                ]];
                if ([allowedKeys containsObject:key]) {
                    NSMutableString *configuredCommand = [NSMutableString string];
                    for (NSUInteger i = 1; i < parts.count; i++) {
                        if (i > 1) [configuredCommand appendString:@"\t"];
                        [configuredCommand appendString:parts[i]];
                    }
                    if (configuredCommand.length) agentCommands[key] = configuredCommand;
                }
                return;
            }
            NSString *name = parts[0];
            NSString *tabCwd = parts[1].length ? parts[1] : cwd;
            NSMutableString *tabCommand = [NSMutableString string];
            for (NSUInteger i = 2; i < parts.count; i++) {
                if (i > 2) [tabCommand appendString:@"\t"];
                [tabCommand appendString:parts[i]];
            }
            [tabs addObject:@{
                @"name": name,
                @"cwd": tabCwd,
                @"command": tabCommand,
                @"prefilled": @YES
            }];
        }];
    }
    BOOL layoutLoaded = tabs.count > 0;
    if (!layoutLoaded) {
        [tabs addObject:@{
            @"name": @"Shell",
            @"cwd": cwd,
            @"command": command,
            @"prefilled": @NO
        }];
    }
    return @{
        @"projectName": projectName,
        @"layoutPath": layoutPath,
        @"cwd": cwd,
        @"command": command,
        @"tabs": tabs,
        @"agentCommands": agentCommands,
        @"layoutLoaded": @(layoutLoaded),
        @"activeIndex": @0
    };
}

@implementation MicaAppDelegate
- (NSString *)windowTitleForTab:(MicaTab *)tab {
    NSString *tabName = tab ? [self displayNameForTab:tab] : @"Mica";
    if (self.projectName.length)
        return [NSString stringWithFormat:@"%@ — %@ — Mica", tabName, self.projectName];
    return [NSString stringWithFormat:@"%@ — Mica Terminal", tabName];
}

- (MicaTab *)activeTab {
    if (self.activeIndex < 0 || self.activeIndex >= (NSInteger)self.tabs.count) return nil;
    return self.tabs[(NSUInteger)self.activeIndex];
}

- (NSString *)displayNameForTab:(MicaTab *)tab {
    if (!tab.terminalTitle.length) return tab.name;
    return [NSString stringWithFormat:@"%@ · %@", tab.name, tab.terminalTitle];
}

- (void)updateWindowTitle {
    if (self.window) self.window.title = [self windowTitleForTab:self.activeTab];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.tabs = [NSMutableArray array];
    self.activeIndex = 0;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 1100, 700)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.projectName = nil;
    self.window.title = @"Mica Terminal";
    self.window.backgroundColor = NSColor.windowBackgroundColor;
    self.window.minSize = NSMakeSize(600, 300);
    self.window.delegate = self;
    self.terminalView = [[MicaTerminalView alloc] initWithFrame:self.window.contentView.bounds];
    self.terminalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.terminalView.owner = self;
    self.terminalView.terminalFont = MicaTerminalFont(kFontSizeDefault);
    [self.window setContentView:self.terminalView];
    [self.window makeKeyAndOrderFront:nil];
    [self installMenus];
    self.uiMode = MicaUIModeNormal;
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
    [self loadLaunchConfigurationFromArguments:NSProcessInfo.processInfo.arguments
                                    bundleInfo:NSBundle.mainBundle.infoDictionary];
}

- (void)loadLaunchConfigurationFromArguments:(NSArray<NSString *> *)args bundleInfo:(NSDictionary *)bundleInfo {
    NSDictionary *configuration = MicaResolveLaunchConfiguration(args, bundleInfo,
        NSFileManager.defaultManager.currentDirectoryPath);
    NSString *projectName = configuration[@"projectName"];
    self.projectName = projectName.length ? projectName : nil;
    self.agentCommands = configuration[@"agentCommands"] ?: @{};
    NSArray<NSDictionary *> *tabSpecs = configuration[@"tabs"];
    for (NSDictionary *spec in tabSpecs) {
        NSString *command = [spec[@"command"] length] ? spec[@"command"] : nil;
        [self addTabWithName:spec[@"name"] cwd:spec[@"cwd"] command:command
                   prefilled:[spec[@"prefilled"] boolValue]];
    }
    if ([configuration[@"layoutLoaded"] boolValue] && self.tabs.count > 1)
        [self selectTabAtIndex:[configuration[@"activeIndex"] integerValue]];
    [self updateWindowTitle];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)addTabWithName:(NSString *)name cwd:(NSString *)cwd command:(NSString *)command prefilled:(BOOL)prefilled {
    MicaTab *previous = self.activeTab;
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    [self.terminalView clearSelection];
    MicaTab *tab = [[MicaTab alloc] init];
    tab.name = name.length ? name : @"Terminal";
    tab.cwd = cwd.length ? cwd : NSFileManager.defaultManager.currentDirectoryPath;
    tab.command = command;
    tab.session = prefilled
        ? mica_session_create_prefilled(tab.cwd.fileSystemRepresentation, command.UTF8String, 24, 80)
        : mica_session_create(tab.cwd.fileSystemRepresentation, command.UTF8String, 24, 80);
    if (!tab.session) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Mica could not create a terminal session";
        alert.informativeText = [NSString stringWithFormat:@"Could not open %@", tab.cwd];
        [alert runModal];
        return;
    }
    tab.commandCompletionCount = mica_session_command_completion_count(tab.session);
    tab.revision = UINT64_MAX;
    [self.tabs addObject:tab];
    self.activeIndex = (NSInteger)self.tabs.count - 1;
    if (NSApp.isActive) mica_session_focus(tab.session, true);
    [self updateWindowTitle];
    [self resizeActiveSession];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)newTabWithName:(NSString *)name command:(NSString *)command {
    MicaTab *active = self.activeTab;
    [self addTabWithName:name cwd:active.cwd command:command prefilled:NO];
    [self.window makeFirstResponder:self.terminalView];
}

- (void)launchAgentCommand:(NSString *)key tabName:(NSString *)name {
    NSString *command = self.agentCommands[key];
    if (!command.length) {
        [self newTabWithName:@"Shell" command:nil];
        return;
    }
    [self newTabWithName:name command:command];
    self.activeTab.tracksCompletion = YES;
    self.activeTab.completionLabel = name;
}

- (void)resizeActiveSession { [self.terminalView setNeedsDisplay:YES]; }
- (void)newShell:(id)sender { (void)sender; [self newTabWithName:@"Shell" command:nil]; }
- (void)newClaude:(id)sender { (void)sender; [self launchAgentCommand:@"claude.start" tabName:@"Claude Code"]; }
- (void)newCodex:(id)sender { (void)sender; [self launchAgentCommand:@"codex.start" tabName:@"Codex"]; }
- (void)resumeClaude:(id)sender { (void)sender; [self launchAgentCommand:@"claude.resume" tabName:@"Claude Code (resumed)"]; }
- (void)resumeCodex:(id)sender { (void)sender; [self launchAgentCommand:@"codex.resume" tabName:@"Codex (resumed)"]; }
- (void)closeTab:(id)sender { (void)sender; [self closeActiveTab]; }
- (void)nextTab:(id)sender { (void)sender; [self selectRelativeTab:1]; }
- (void)previousTab:(id)sender { (void)sender; [self selectRelativeTab:-1]; }

- (void)closeActiveTab {
    if (self.tabs.count <= 1) { [self.window performClose:nil]; return; }
    MicaTab *previous = self.activeTab;
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    [self.terminalView clearSelection];
    [self.tabs removeObjectAtIndex:(NSUInteger)self.activeIndex];
    if (self.activeIndex >= (NSInteger)self.tabs.count) self.activeIndex = (NSInteger)self.tabs.count - 1;
    MicaTab *tab = self.activeTab;
    if (NSApp.isActive) mica_session_focus(tab.session, true);
    tab.needsAttention = NO;
    [self updateWindowTitle];
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
    [self.terminalView clearSelection];
    self.activeIndex = index;
    MicaTab *tab = self.activeTab;
    tab.needsAttention = NO;
    if (NSApp.isActive) mica_session_focus(tab.session, true);
    [self updateWindowTitle];
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
            if (tab == self.activeTab) [self updateWindowTitle];
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
        uint64_t completionCount = mica_session_command_completion_count(tab.session);
        if (tab.tracksCompletion && completionCount > tab.commandCompletionCount) {
            tab.commandCompletionCount = completionCount;
            tab.completedCommand = YES;
            tab.completionStatus = mica_session_command_exit_status(tab.session);
            if (tab != self.activeTab || !NSApp.isActive) {
                tab.needsAttention = YES;
                if (!NSApp.isActive && self.attentionRequest == 0)
                    self.attentionRequest = [NSApp requestUserAttention:NSInformationalRequest];
            }
            redraw = YES;
        }
        if (tab.tracksCompletion && !mica_session_is_running(tab.session) && !tab.reportedProcessExit) {
            tab.reportedProcessExit = YES;
            if (!tab.completedCommand) {
                tab.completedCommand = YES;
                tab.completionStatus = mica_session_exit_status(tab.session);
                if (tab != self.activeTab || !NSApp.isActive) {
                    tab.needsAttention = YES;
                    if (!NSApp.isActive && self.attentionRequest == 0)
                        self.attentionRequest = [NSApp requestUserAttention:NSInformationalRequest];
                }
            }
            redraw = YES;
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

#ifndef MICA_APP_NO_MAIN
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
#endif
