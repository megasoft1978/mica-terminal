#import <Cocoa/Cocoa.h>
#import "mica.h"
#import "mica_diagnostics.h"
#import "mica_voice_controller.h"

#include <unistd.h>

static const CGFloat kHeaderHeight = 32.0;
static const CGFloat kStatusHeight = 32.0;
static const CGFloat kFontSizeDefault = 16.0;
static const CGFloat kTabTitleFontSize = 10.5;
static const CGFloat kTabMinimumWidth = 140.0;
static const CGFloat kTabOverflowWidth = 56.0;

typedef NS_ENUM(NSInteger, MicaUIMode) {
    MicaUIModeNormal = 0,
    MicaUIModeTab,
    MicaUIModeScroll,
};

static NSColor *MicaColor(uint32_t rgb) {
    static NSCache<NSNumber *, NSColor *> *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colors = [NSCache new];
        colors.countLimit = 512;
    });
    rgb &= 0x00ffffff;
    NSNumber *key = @(rgb);
    NSColor *cached = [colors objectForKey:key];
    if (cached) return cached;
    NSColor *color = [NSColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                                    green:((rgb >> 8) & 0xff) / 255.0
                                     blue:(rgb & 0xff) / 255.0
                                    alpha:1.0];
    [colors setObject:color forKey:key];
    return color;
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

static NSFont *MicaTerminalFontWithTraits(NSFont *font, NSFontTraitMask traits) {
    if (!font || traits == 0) return font;
    static NSCache<NSString *, NSFont *> *fonts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fonts = [NSCache new];
        fonts.countLimit = 32;
    });
    NSString *key = [NSString stringWithFormat:@"%@-%.2f-%lu",
        font.fontName, font.pointSize, (unsigned long)traits];
    NSFont *cached = [fonts objectForKey:key];
    if (cached) return cached;
    NSFont *styled = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:traits];
    if (!styled) styled = font;
    [fonts setObject:styled forKey:key];
    return styled;
}

@interface MicaTab : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *cwd;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSString *terminalTitle;
@property(nonatomic, copy) NSString *currentCommand;
@property(nonatomic, copy) NSString *agentActivity;
@property(nonatomic, copy) NSString *agentActivityDetail;
@property(nonatomic, assign) NSTimeInterval agentActivityStartedAt;
@property(nonatomic, assign) NSTimeInterval commandStartedAt;
@property(nonatomic, assign) NSInteger commandClockSecond;
@property(nonatomic, assign) NSTimeInterval cwdLastCheck;
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

static NSString *MicaAgentNameForText(NSString *text) {
    NSString *identity = text.lowercaseString ?: @"";
    if ([identity containsString:@"codex"]) return @"Codex";
    if ([identity containsString:@"claude"] || [identity containsString:@"yowork"])
        return @"Claude Code";
    return nil;
}

static NSString *MicaAgentNameForTab(MicaTab *tab) {
    if (tab.currentCommand.length) return MicaAgentNameForText(tab.currentCommand);
    NSString *terminalTitleAgent = MicaAgentNameForText(tab.terminalTitle);
    if (terminalTitleAgent) return terminalTitleAgent;
    NSString *configuredCommandAgent = MicaAgentNameForText(tab.command);
    if (configuredCommandAgent) return configuredCommandAgent;
    return MicaAgentNameForText(tab.name);
}

static BOOL CellIsContinuation(MicaCell cell);

static NSString *MicaAgentActivityForSession(MicaSession *session, NSString **detailOut) {
    if (detailOut) *detailOut = nil;
    if (!session) return @"Starting";
    int rows = mica_session_rows(session);
    int cols = mica_session_cols(session);
    int firstRow = MAX(0, rows - 12);
    NSString *activity = nil;
    NSString *activityLine = nil;
    NSString *recentAction = nil;
    for (int row = rows - 1; row >= firstRow; row--) {
        NSMutableString *line = [NSMutableString string];
        for (int col = 0; col < cols; col++) {
            MicaCell cell;
            if (!mica_session_get_cell(session, row, col, &cell) || CellIsContinuation(cell)) continue;
            for (NSUInteger i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++) {
                uint32_t codepoint = cell.chars[i];
                if (codepoint >= 0x20 && codepoint <= 0x7e) [line appendFormat:@"%c", (char)codepoint];
                else [line appendString:@" "];
            }
        }
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!trimmed.length) continue;
        NSString *upper = trimmed.uppercaseString;
        NSString *lineActivity = nil;
        if ([upper containsString:@"TRUST THIS FOLDER"] || [upper containsString:@"NEEDS APPROVAL"] ||
            [upper containsString:@"APPROVE THIS"] || [upper containsString:@"ALLOW THIS"]) {
            lineActivity = @"Needs approval";
        } else if ([upper containsString:@"RESUME A PREVIOUS SESSION"] ||
                   [upper containsString:@"RESUME SESSION"]) {
            lineActivity = @"Choosing session";
        } else if ([upper containsString:@"COMPACTING"] || [upper containsString:@"COMPACTION"]) {
            lineActivity = @"Compacting";
        } else if ([upper containsString:@"PLANNING"]) {
            lineActivity = @"Planning";
        } else if ([upper containsString:@"SEARCHING"] || [upper containsString:@"SEARCHED FOR"]) {
            lineActivity = @"Searching";
        } else if ([upper containsString:@"READING"] || [upper hasPrefix:@"READ "]) {
            lineActivity = @"Reading";
        } else if ([upper containsString:@"EDITING"] || [upper containsString:@"WRITING"] ||
                   [upper containsString:@"IMPLEMENTING"] || [upper hasPrefix:@"EDITED "] ||
                   [upper hasPrefix:@"WROTE "]) {
            lineActivity = @"Editing";
        } else if ([upper containsString:@"WORKING"] || [upper containsString:@"ESC TO INTERRUPT"]) {
            lineActivity = @"Working";
        } else if ([upper containsString:@"THINKING"]) {
            lineActivity = @"Thinking";
        } else if ([upper containsString:@"RUNNING"] || [upper hasPrefix:@"RAN "]) {
            lineActivity = @"Running";
        } else if ([upper containsString:@"EXPLORING"] || [upper containsString:@"EXPLORED"]) {
            lineActivity = @"Exploring";
        } else if ([upper containsString:@"TESTING"]) {
            lineActivity = @"Testing";
        } else if ([upper containsString:@"ANALYZING"] || [upper containsString:@"INVESTIGATING"]) {
            lineActivity = @"Analyzing";
        } else if ([upper containsString:@"ASK CODEX TO DO ANYTHING"] ||
                   [upper containsString:@"TRY \""]) {
            lineActivity = @"Ready";
        }
        if (!recentAction && ([upper hasPrefix:@"RAN "] || [upper hasPrefix:@"READ "] ||
            [upper hasPrefix:@"SEARCHED "] || [upper hasPrefix:@"EXPLORED"] ||
            [upper hasPrefix:@"EDITED "] || [upper hasPrefix:@"WROTE "] ||
            [upper hasPrefix:@"UPDATED "] || [upper hasPrefix:@"TESTED "])) {
            recentAction = trimmed;
        }
        if (lineActivity && (!activity || [activity isEqualToString:@"Ready"])) {
            activity = lineActivity;
            activityLine = trimmed;
        }
    }
    if (detailOut) *detailOut = recentAction ?: activityLine;
    return activity ?: @"Running";
}

@class MicaAppDelegate;
@interface MicaTerminalView : NSView
@property(nonatomic, weak) MicaAppDelegate *owner;
@property(nonatomic, strong) NSFont *terminalFont;
#if defined(MICA_APP_NO_MAIN)
@property(nonatomic, copy) NSString *testClipboardText;
@property(nonatomic, strong) NSData *testClipboardImage;
@property(nonatomic, copy) NSArray<NSURL *> *testDraggedFileURLs;
#endif
- (NSRect)tabRectAtIndex:(NSUInteger)index;
- (NSRange)visibleTabRange;
- (BOOL)hasTabOverflow;
- (NSRect)tabOverflowRect;
- (NSMenu *)tabOverflowMenu;
- (void)selectOverflowTab:(id)sender;
- (NSInteger)tabIndexAtPoint:(NSPoint)point;
- (NSRect)dirtyRectForRows:(MicaDirtyRows)rows;
- (NSRect)terminalRect;
- (void)updateGridSize;
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data;
- (BOOL)insertFileURLs:(NSArray<NSURL *> *)fileURLs;
- (BOOL)hasTextSelection;
- (void)copySelection:(id)sender;
- (void)clearSelection;
- (void)foldSelectedLines:(id)sender;
- (void)paste:(id)sender;
- (void)copy:(id)sender;
- (NSRect)cellRectAtRow:(NSInteger)row col:(NSInteger)col;
- (NSColor *)colorForVTermColor:(VTermColor)color isForeground:(BOOL)isForeground;
- (NSRect)voiceOverlayRect;
- (NSRect)voiceOverlayActionRect;
- (void)drawVoiceOverlay;
- (void)cancelLeftOptionTracking;
@end

@interface MicaAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, MicaVoiceControllerDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) MicaTerminalView *terminalView;
@property(nonatomic, strong) NSMutableArray<MicaTab *> *tabs;
@property(nonatomic, assign) NSInteger activeIndex;
@property(nonatomic, copy) NSString *projectName;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) MicaVoiceController *voiceController;
@property(nonatomic, strong) MicaTab *voiceTargetTab;
@property(nonatomic, assign) NSInteger attentionRequest;
- (MicaTab *)activeTab;
- (NSString *)displayNameForTab:(MicaTab *)tab;
- (NSString *)windowTitleForTab:(MicaTab *)tab;
- (void)newTabWithName:(NSString *)name command:(NSString *)command;
- (void)addTabWithName:(NSString *)name cwd:(NSString *)cwd command:(NSString *)command prefilled:(BOOL)prefilled;
- (void)closeActiveTab;
- (void)selectRelativeTab:(NSInteger)delta;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)toggleTabPicker;
- (void)toggleScrollback;
- (void)resizeActiveSession;
- (void)installMenus;
- (void)updateWindowTitle;
- (void)pollSessions:(NSTimer *)timer;
- (void)loadLaunchConfiguration;
- (void)loadLaunchConfigurationFromArguments:(NSArray<NSString *> *)arguments bundleInfo:(NSDictionary *)bundleInfo;
- (void)startPushToTalk;
- (void)finishPushToTalk;
- (void)beginDictationForActiveTab;
- (void)cancelDictation;
- (void)openDiagnosticLogs:(id)sender;
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

static BOOL MicaStringChanged(NSString *current, NSString *previous) {
    return current != previous && ![current isEqualToString:previous];
}

static CGFloat MicaCenteredTextBaseline(NSFont *font, CGFloat height) {
    return floor((height - (font.ascender - font.descender)) / 2.0 - font.descender);
}

static NSString *MicaTruncatedText(NSString *text, CGFloat width, NSDictionary *attributes) {
    if (!text.length || width <= 0) return @"";
    if ([text sizeWithAttributes:attributes].width <= width) return text;
    NSString *ellipsis = @"…";
    if ([ellipsis sizeWithAttributes:attributes].width > width) return @"";
    NSMutableArray<NSNumber *> *clusterEnds = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(__unused NSString *substring, NSRange substringRange,
                                       __unused NSRange enclosingRange, __unused BOOL *stop) {
        [clusterEnds addObject:@(NSMaxRange(substringRange))];
    }];
    NSUInteger low = 0;
    NSUInteger high = clusterEnds.count;
    while (low < high) {
        NSUInteger middle = low + (high - low + 1) / 2;
        NSUInteger end = clusterEnds[middle - 1].unsignedIntegerValue;
        NSString *candidate = [[text substringToIndex:end] stringByAppendingString:ellipsis];
        if ([candidate sizeWithAttributes:attributes].width <= width) low = middle;
        else high = middle - 1;
    }
    NSUInteger end = low ? clusterEnds[low - 1].unsignedIntegerValue : 0;
    return [[text substringToIndex:end] stringByAppendingString:ellipsis];
}

static NSString *MicaStandardizedWorkingDirectory(NSString *requestedPath) {
    if (requestedPath.length) return requestedPath.stringByStandardizingPath;
    return NSFileManager.defaultManager.currentDirectoryPath;
}

static NSString *MicaTruncatedPath(NSString *path, CGFloat width, NSDictionary *attributes) {
    if (!path.length || width <= 0) return @"";
    if ([path sizeWithAttributes:attributes].width <= width) return path;

    NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *suffix = [NSMutableArray array];
    for (NSInteger index = (NSInteger)components.count - 1; index >= 0; index--) {
        NSString *component = components[(NSUInteger)index];
        if (!component.length) continue;
        [suffix insertObject:component atIndex:0];
        NSString *candidate = [NSString stringWithFormat:@"…/%@", [suffix componentsJoinedByString:@"/"]];
        if ([candidate sizeWithAttributes:attributes].width > width) {
            [suffix removeObjectAtIndex:0];
            break;
        }
    }
    if (suffix.count) return [NSString stringWithFormat:@"…/%@", [suffix componentsJoinedByString:@"/"]];

    NSMutableString *tail = [path mutableCopy];
    while (tail.length) {
        NSRange first = [tail rangeOfComposedCharacterSequenceAtIndex:0];
        [tail deleteCharactersInRange:first];
        NSString *candidate = [@"…" stringByAppendingString:tail];
        if ([candidate sizeWithAttributes:attributes].width <= width) return candidate;
    }
    return @"…";
}

@implementation MicaTerminalView {
    BOOL _selecting;
    BOOL _selectionPending;
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
    NSToolTipTag _tabToolTipTag;
    NSRect _tabToolTipRect;
    BOOL _hasTabToolTip;
    NSTimer *_leftOptionTimer;
    BOOL _leftOptionIsDown;
    BOOL _leftOptionUsedWithAnotherKey;
    BOOL _leftOptionStartedDictation;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return NO; }

- (void)resetCursorRects {
    [super resetCursorRects];
    NSRect terminal = [self terminalRect];
    if (!NSIsEmptyRect(terminal)) [self addCursorRect:terminal cursor:NSCursor.IBeamCursor];
    NSRect action = [self voiceOverlayActionRect];
    if (!NSIsEmptyRect(action)) [self addCursorRect:action cursor:NSCursor.pointingHandCursor];
    NSRect overflow = [self tabOverflowRect];
    if ([self hasTabOverflow] && !NSIsEmptyRect(overflow))
        [self addCursorRect:overflow cursor:NSCursor.pointingHandCursor];
}

- (void)layout {
    [super layout];
}

- (void)dealloc {
    [_leftOptionTimer invalidate];
}

- (void)leftOptionPressedAlone:(NSTimer *)timer {
    if (_leftOptionTimer != timer) return;
    _leftOptionTimer = nil;
    if (_leftOptionIsDown && !_leftOptionUsedWithAnotherKey) {
        _leftOptionStartedDictation = YES;
        [self.owner startPushToTalk];
    }
}

- (void)cancelLeftOptionTracking {
    BOOL shouldFinish = _leftOptionStartedDictation;
    [_leftOptionTimer invalidate];
    _leftOptionTimer = nil;
    _leftOptionIsDown = NO;
    _leftOptionUsedWithAnotherKey = NO;
    _leftOptionStartedDictation = NO;
    if (shouldFinish) [self.owner finishPushToTalk];
}

- (void)flagsChanged:(NSEvent *)event {
    [super flagsChanged:event];
    if (event.keyCode != 58) return; // Left Option; leave right Option as a normal shell modifier.
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL isDown = (flags & NSEventModifierFlagOption) != 0;
    if (isDown) {
        if (_leftOptionIsDown) return;
        _leftOptionIsDown = YES;
        _leftOptionUsedWithAnotherKey =
            (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
                      NSEventModifierFlagShift | NSEventModifierFlagFunction)) != 0;
        [_leftOptionTimer invalidate];
        _leftOptionTimer = nil;
        if (!_leftOptionUsedWithAnotherKey) {
            _leftOptionTimer = [NSTimer scheduledTimerWithTimeInterval:0.18
                target:self selector:@selector(leftOptionPressedAlone:) userInfo:nil repeats:NO];
        }
    } else {
        BOOL shouldFinish = _leftOptionIsDown && _leftOptionStartedDictation;
        [_leftOptionTimer invalidate];
        _leftOptionTimer = nil;
        _leftOptionIsDown = NO;
        _leftOptionUsedWithAnotherKey = NO;
        _leftOptionStartedDictation = NO;
        if (shouldFinish) [self.owner finishPushToTalk];
    }
}

- (NSColor *)colorForVTermColor:(VTermColor)color isForeground:(BOOL)isForeground {
    if (isForeground && VTERM_COLOR_IS_DEFAULT_FG(&color)) return MicaForegroundColor();
    if (!isForeground && VTERM_COLOR_IS_DEFAULT_BG(&color)) return MicaBackgroundColor();
    if (VTERM_COLOR_IS_RGB(&color))
        return MicaColor(((uint32_t)color.rgb.red << 16) | ((uint32_t)color.rgb.green << 8) | color.rgb.blue);
    return isForeground ? MicaForegroundColor() : MicaBackgroundColor();
}

- (NSFont *)fontForCell:(MicaCell)cell {
    NSFontTraitMask traits = (cell.attrs.bold ? NSBoldFontMask : 0) |
        (cell.attrs.italic ? NSItalicFontMask : 0);
    return MicaTerminalFontWithTraits(self.terminalFont, traits);
}

- (void)drawTextRun:(NSString *)text row:(NSInteger)row startCol:(NSInteger)col
               font:(NSFont *)font foreground:(NSColor *)foreground underline:(BOOL)underline {
    if (!text.length) return;
    NSMutableDictionary *attributes = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: foreground,
        NSLigatureAttributeName: @0
    } mutableCopy];
    if (underline) attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    NSRect firstCell = [self cellRectAtRow:row col:col];
    [text drawAtPoint:NSMakePoint(NSMinX(firstCell), NSMinY(firstCell) + 1)
       withAttributes:attributes];
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

- (NSRect)voiceOverlayRect {
    if (!self.owner.voiceController || self.owner.voiceController.state == MicaVoiceControllerStateIdle)
        return NSZeroRect;
    CGFloat width = MIN(680, MAX(0, [self terminalRect].size.width - 32));
    if (width < 120) return NSZeroRect;
    return NSMakeRect(16, kStatusHeight + 14, width, 146);
}

- (NSRect)voiceOverlayActionRect {
    return NSZeroRect;
}

- (void)updateGridSize {
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;
    NSDictionary *attrs = @{ NSFontAttributeName: self.terminalFont };
    NSSize cell = [@"M" sizeWithAttributes:attrs];
    // Use the font's real monospaced advance. Rounding every cell up makes a
    // batched text run drift away from the cell grid across each terminal row.
    _charWidth = MAX(1.0, cell.width);
    _lineHeight = MAX(1.0, ceil(self.terminalFont.ascender - self.terminalFont.descender + self.terminalFont.leading + 1.0));
    NSRect area = [self terminalRect];
    NSInteger cols = MAX(2, floor(area.size.width / _charWidth));
    NSInteger rows = MAX(2, floor(area.size.height / _lineHeight));
    CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1.0;
    int pixelWidth = (int)lrint(area.size.width * scale);
    int pixelHeight = (int)lrint(area.size.height * scale);
    BOOL gridChanged = cols != _cols || rows != _rows || _sizedSession != tab.session;
    BOOL pixelSizeChanged = pixelWidth != _pixelWidth || pixelHeight != _pixelHeight;
    // AppKit can report transient cell-grid changes while the window is being
    // dragged. Defer both PTY grid and pixel updates until resize settles.
    if ((gridChanged || pixelSizeChanged) && !self.inLiveResize) {
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

- (NSRect)tabRectAtIndex:(NSUInteger)index {
    NSUInteger count = self.owner.tabs.count;
    if (index >= count || count == 0) return NSZeroRect;
    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight,
                               self.bounds.size.width, kHeaderHeight);
    NSRange visible = [self visibleTabRange];
    if (index < visible.location || index >= NSMaxRange(visible)) return NSZeroRect;
    CGFloat tabWidth = header.size.width / (CGFloat)count;
    CGFloat x = index * tabWidth;
    if ([self hasTabOverflow]) {
        CGFloat tabsWidth = MAX(0, header.size.width - kTabOverflowWidth);
        tabWidth = visible.length ? tabsWidth / (CGFloat)visible.length : 0;
        x = (index - visible.location) * tabWidth;
    }
    return NSMakeRect(x, NSMinY(header), tabWidth, header.size.height);
}

- (NSRange)visibleTabRange {
    NSUInteger count = self.owner.tabs.count;
    CGFloat width = self.bounds.size.width;
    if (count == 0) return NSMakeRange(0, 0);
    if (width <= 0 || count * kTabMinimumWidth <= width) return NSMakeRange(0, count);
    NSUInteger capacity = (NSUInteger)floor(MAX(0, width - kTabOverflowWidth) / kTabMinimumWidth);
    capacity = MIN(count, MAX((NSUInteger)1, capacity));
    NSUInteger active = self.owner.activeIndex >= 0 ? (NSUInteger)self.owner.activeIndex : 0;
    active = MIN(active, count - 1);
    NSUInteger start = active >= capacity ? active - capacity + 1 : 0;
    if (start + capacity > count) start = count - capacity;
    return NSMakeRange(start, capacity);
}

- (BOOL)hasTabOverflow {
    return [self visibleTabRange].length < self.owner.tabs.count;
}

- (NSRect)tabOverflowRect {
    if (![self hasTabOverflow]) return NSZeroRect;
    CGFloat width = MIN(kTabOverflowWidth, self.bounds.size.width);
    return NSMakeRect(self.bounds.size.width - width,
        NSMaxY(self.bounds) - kHeaderHeight, width, kHeaderHeight);
}

- (NSMenu *)tabOverflowMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Other Tabs"];
    NSRange visible = [self visibleTabRange];
    for (NSUInteger index = 0; index < self.owner.tabs.count; index++) {
        if (NSLocationInRange(index, visible)) continue;
        MicaTab *tab = self.owner.tabs[index];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[self labelForTab:tab active:NO]
            action:@selector(selectOverflowTab:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(index);
        [menu addItem:item];
    }
    return menu;
}

- (void)selectOverflowTab:(id)sender {
    if (![sender isKindOfClass:NSMenuItem.class]) return;
    NSNumber *index = [(NSMenuItem *)sender representedObject];
    if (index) [self.owner selectTabAtIndex:index.integerValue];
}

- (NSRect)dirtyRectForRows:(MicaDirtyRows)rows {
    if (_rows <= 0 || _lineHeight <= 0 || rows.start_row >= rows.end_row) return NSZeroRect;
    NSInteger first = MIN(MAX(rows.start_row, 0), _rows);
    NSInteger last = MIN(MAX(rows.end_row, 0), _rows);
    if (first >= last) return NSZeroRect;
    NSRect terminal = [self terminalRect];
    CGFloat top = NSMaxY(terminal);
    CGFloat bottom = top - last * _lineHeight;
    NSRect damagedRows = NSMakeRect(0, bottom - 1, self.bounds.size.width,
                                    (last - first) * _lineHeight + 2);
    return NSIntersectionRect(damagedRows, terminal);
}

- (NSInteger)tabIndexAtPoint:(NSPoint)point {
    NSUInteger count = self.owner.tabs.count;
    CGFloat width = self.bounds.size.width;
    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight, width, kHeaderHeight);
    if (count == 0 || width <= 0 || !NSPointInRect(point, header)) return NSNotFound;
    if (NSPointInRect(point, [self tabOverflowRect])) return NSNotFound;
    NSRange visible = [self visibleTabRange];
    CGFloat tabsWidth = [self hasTabOverflow] ? MAX(0, width - kTabOverflowWidth) : width;
    if (tabsWidth <= 0 || visible.length == 0) return NSNotFound;
    NSUInteger visibleIndex = MIN((NSUInteger)(point.x / tabsWidth * (CGFloat)visible.length), visible.length - 1);
    return (NSInteger)(visible.location + visibleIndex);
}

- (void)updateTabToolTip {
    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight,
                               self.bounds.size.width, kHeaderHeight);
    BOOL shouldHaveToolTip = self.owner.tabs.count > 0 && !NSIsEmptyRect(header);
    if (_hasTabToolTip && (!shouldHaveToolTip || !NSEqualRects(header, _tabToolTipRect))) {
        [self removeToolTip:_tabToolTipTag];
        _hasTabToolTip = NO;
    }
    if (shouldHaveToolTip && !_hasTabToolTip) {
        _tabToolTipTag = [self addToolTipRect:header owner:self userData:NULL];
        _tabToolTipRect = header;
        _hasTabToolTip = YES;
    }
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view;
    (void)tag;
    (void)data;
    if (NSPointInRect(point, [self tabOverflowRect])) {
        NSUInteger hidden = self.owner.tabs.count - [self visibleTabRange].length;
        return [NSString stringWithFormat:@"%lu more terminal tab%@", (unsigned long)hidden, hidden == 1 ? @"" : @"s"];
    }
    NSInteger index = [self tabIndexAtPoint:point];
    if (index == NSNotFound || index >= (NSInteger)self.owner.tabs.count) return nil;
    MicaTab *tab = self.owner.tabs[(NSUInteger)index];
    NSString *label = [self labelForTab:tab active:index == self.owner.activeIndex];
    NSString *agent = MicaAgentNameForTab(tab);
    if (agent && tab.currentCommand.length) {
        NSString *command = tab.currentCommand.length ? tab.currentCommand : (tab.command ?: agent);
        NSString *folder = tab.cwd;
        NSMutableArray<NSString *> *details = [NSMutableArray arrayWithObjects:
            [NSString stringWithFormat:@"Tab: %@", tab.name ?: @"Terminal"],
            [NSString stringWithFormat:@"Status: %@", label],
            [NSString stringWithFormat:@"Command: %@", command], nil];
        if (tab.agentActivityDetail.length)
            [details addObject:[NSString stringWithFormat:@"Recent activity: %@", tab.agentActivityDetail]];
        [details addObject:[NSString stringWithFormat:@"Folder: %@", folder ?: @"/"]];
        return [details componentsJoinedByString:@"\n"];
    }
    return label;
}

- (BOOL)hasTextSelection { return _selecting; }

- (BOOL)insertFileURLs:(NSArray<NSURL *> *)fileURLs {
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session || fileURLs.count == 0) return NO;
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:fileURLs.count];
    NSCharacterSet *safePathCharacters = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-"];
    for (NSURL *url in fileURLs) {
        if (![url isFileURL]) continue;
        NSString *path = url.path;
        if (!path.length) continue;
        if ([path rangeOfCharacterFromSet:safePathCharacters.invertedSet].location != NSNotFound) {
            NSString *quotedPath = [path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
            path = [NSString stringWithFormat:@"'%@'", quotedPath];
        }
        [paths addObject:path];
    }
    if (paths.count == 0) return NO;
    NSData *paste = [[paths componentsJoinedByString:@" "] dataUsingEncoding:NSUTF8StringEncoding];
    mica_session_paste(tab.session, paste.bytes, paste.length);
    [self clearSelection];
    return YES;
}

- (NSArray<NSURL *> *)fileURLsFromPasteboard:(NSPasteboard *)pasteboard {
#if defined(MICA_APP_NO_MAIN)
    if (self.testDraggedFileURLs) return self.testDraggedFileURLs;
#endif
    return [pasteboard readObjectsForClasses:@[NSURL.class]
                                     options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }] ?: @[];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPoint point = [self convertPoint:sender.draggingLocation fromView:nil];
    if (!NSPointInRect(point, [self terminalRect]) ||
        [self fileURLsFromPasteboard:sender.draggingPasteboard].count == 0)
        return NSDragOperationNone;
    return NSDragOperationCopy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self draggingEntered:sender];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return [self draggingEntered:sender] == NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPoint point = [self convertPoint:sender.draggingLocation fromView:nil];
    if (!NSPointInRect(point, [self terminalRect])) return NO;
    return [self insertFileURLs:[self fileURLsFromPasteboard:sender.draggingPasteboard]];
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
    int viewOffset = tab.session ? mica_session_view_offset(tab.session) : 0;
    BOOL scrolled = viewOffset > 0;
    BOOL scrollView = mode == MicaUIModeScroll || scrolled;
    NSString *modeName = mode == MicaUIModeTab ? @"TAB PICKER" : (scrollView ? @"SCROLLBACK" : nil);
    NSColor *modeColor = scrollView ? NSColor.systemPurpleColor : NSColor.controlAccentColor;
    NSDictionary *modeAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.alternateSelectedControlTextColor
    };
    CGFloat contextX = 12;
    if (modeName) {
        NSSize modeSize = [modeName sizeWithAttributes:modeAttrs];
        NSRect badge = NSMakeRect(12, floor((kStatusHeight - 18) / 2), modeSize.width + 18, 18);
        [modeColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:badge xRadius:5 yRadius:5] fill];
        NSFont *modeFont = modeAttrs[NSFontAttributeName];
        [modeName drawAtPoint:NSMakePoint(NSMinX(badge) + 9,
            NSMinY(badge) + MicaCenteredTextBaseline(modeFont, badge.size.height)) withAttributes:modeAttrs];
        contextX = NSMaxX(badge) + 12;
    }

    NSString *folderName = tab.cwd.length ? tab.cwd : @"/";
    NSString *context = [NSString stringWithFormat:@"Folder: %@", folderName];
    NSColor *contextColor = [NSColor.labelColor colorWithAlphaComponent:0.76];
    if (mode == MicaUIModeTab) {
        context = @"Choose a tab";
    } else if (mode == MicaUIModeScroll) {
        context = @"Use arrows or j/k to scroll";
    } else if (tab.currentCommand.length) {
        NSString *agent = MicaAgentNameForTab(tab);
        if (agent) {
            NSString *activity = tab.agentActivityDetail.length
                ? tab.agentActivityDetail : (tab.agentActivity.length ? tab.agentActivity : @"Starting");
            context = [NSString stringWithFormat:@"%@ · %@", agent, activity];
        } else {
            NSTimeInterval elapsed = MAX(0, NSProcessInfo.processInfo.systemUptime - tab.commandStartedAt);
            NSUInteger seconds = (NSUInteger)elapsed;
            NSString *commandName = tab.currentCommand.lastPathComponent.length ? tab.currentCommand.lastPathComponent : tab.currentCommand;
            context = [NSString stringWithFormat:@"Running %@ · %lu:%02lu", commandName,
                (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
        }
        contextColor = [NSColor.systemGreenColor blendedColorWithFraction:0.40 ofColor:NSColor.labelColor];
    } else if (tab.completedCommand) {
        NSString *result = tab.completionStatus == 0 ? @"finished successfully" :
            [NSString stringWithFormat:@"exited with status %d", tab.completionStatus];
        context = [NSString stringWithFormat:@"%@ %@", tab.completionLabel.length ? tab.completionLabel : @"Process", result];
        contextColor = tab.completionStatus == 0 ? NSColor.systemGreenColor : NSColor.systemRedColor;
    } else if (viewOffset > 0) {
        context = [NSString stringWithFormat:@"%d lines back · Esc returns live", viewOffset];
    }
    NSDictionary *contextAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5],
        NSForegroundColorAttributeName: contextColor
    };

    NSArray<NSString *> *hintParts = @[@"⌥ Dictate", @"⌘1–8 Switch tab", @"⌘T New tab"];
    NSDictionary *hintAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5],
        NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:0.70]
    };
    NSFont *hintFont = hintAttrs[NSFontAttributeName];
    CGFloat hintWidth = 0;
    for (NSString *part in hintParts) hintWidth += [part sizeWithAttributes:hintAttrs].width;
    hintWidth += (hintParts.count - 1) * 16;
    CGFloat hintRight = self.bounds.size.width - 12;
    CGFloat hintX = MAX(contextX + 18, hintRight - hintWidth);
    CGFloat availableWidth = MAX(0, hintX - contextX - 18);
    if (!modeName && !tab.currentCommand.length && !tab.completedCommand && viewOffset == 0) {
        NSString *folderLabel = @"Folder: ";
        CGFloat labelWidth = [folderLabel sizeWithAttributes:contextAttrs].width;
        CGFloat pathWidth = MAX(0, availableWidth - labelWidth);
        context = [folderLabel stringByAppendingString:
            MicaTruncatedPath(folderName, pathWidth, contextAttrs)];
    }
    CGFloat contextWidth = availableWidth;
    contextWidth = MIN(contextWidth, [context sizeWithAttributes:contextAttrs].width);
    NSString *shortContext = MicaTruncatedText(context, contextWidth, contextAttrs);
    [shortContext drawAtPoint:NSMakePoint(contextX,
        MicaCenteredTextBaseline(contextAttrs[NSFontAttributeName], kStatusHeight)) withAttributes:contextAttrs];
    [NSColor.separatorColor setStroke];
    NSBezierPath *contextDivider = [NSBezierPath bezierPath];
    [contextDivider moveToPoint:NSMakePoint(hintX - 8, 6)];
    [contextDivider lineToPoint:NSMakePoint(hintX - 8, kStatusHeight - 6)];
    [contextDivider stroke];

    CGFloat x = hintX;
    for (NSUInteger index = 0; index < hintParts.count; index++) {
        NSString *part = hintParts[index];
        [part drawAtPoint:NSMakePoint(x, MicaCenteredTextBaseline(hintFont, kStatusHeight))
             withAttributes:hintAttrs];
        x += [part sizeWithAttributes:hintAttrs].width;
        if (index + 1 < hintParts.count) {
            x += 8;
            NSBezierPath *hintDivider = [NSBezierPath bezierPath];
            [hintDivider moveToPoint:NSMakePoint(x, 6)];
            [hintDivider lineToPoint:NSMakePoint(x, kStatusHeight - 6)];
            [hintDivider stroke];
            x += 8;
        }
    }
}

- (void)drawVoiceOverlay {
    NSRect panel = [self voiceOverlayRect];
    if (NSIsEmptyRect(panel)) return;
    MicaVoiceController *voice = self.owner.voiceController;
    MicaVoiceControllerState state = voice.state;
    NSColor *accent = state == MicaVoiceControllerStateFailed ? NSColor.systemRedColor : NSColor.controlAccentColor;
    NSBezierPath *panelPath = [NSBezierPath bezierPathWithRoundedRect:panel xRadius:12 yRadius:12];
    [[NSColor colorWithRed:0.10 green:0.12 blue:0.15 alpha:0.96] setFill];
    [panelPath fill];
    [accent setStroke];
    panelPath.lineWidth = 1.4;
    [panelPath stroke];

    NSString *status = voice.statusText ?: @"";
    if (state == MicaVoiceControllerStateListening) {
        NSUInteger seconds = (NSUInteger)MAX(0, voice.elapsedSeconds);
        status = [NSString stringWithFormat:@"Listening · %02lu:%02lu",
                  (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
    }
    NSDictionary *statusAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    [status drawWithRect:NSMakeRect(NSMinX(panel) + 14, NSMaxY(panel) - 28,
                                    panel.size.width - 28, 17)
                 options:NSStringDrawingTruncatesLastVisibleLine
              attributes:statusAttrs];

    NSString *text = voice.transcript ?: @"";
    if (text.length > 220) {
        NSRange tail = [text rangeOfComposedCharacterSequencesForRange:
            NSMakeRange(text.length - 220, 220)];
        text = [@"…" stringByAppendingString:[text substringFromIndex:tail.location]];
    }
    NSRect transcriptRect = NSMakeRect(NSMinX(panel) + 14, NSMinY(panel) + 24,
                                       panel.size.width - 28, 82);
    if (text.length == 0) {
        switch (state) {
            case MicaVoiceControllerStateListening:
                text = @"Listening… your words will appear here as you speak.";
                break;
            case MicaVoiceControllerStatePreparing:
                text = @"Checking the local model and preparing the microphone…";
                break;
            case MicaVoiceControllerStateTranscribing:
                text = @"Finishing speech recognition…";
                break;
            case MicaVoiceControllerStateFailed:
                text = @"Dictation could not finish. Press Escape to dismiss and try again.";
                break;
            default:
                text = @"Preparing local speech recognition…";
                break;
        }
    }
    NSMutableParagraphStyle *transcriptStyle = [[NSMutableParagraphStyle alloc] init];
    transcriptStyle.lineBreakMode = NSLineBreakByWordWrapping;
    NSMutableAttributedString *preview = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: MicaTerminalFont(13),
        NSForegroundColorAttributeName: [NSColor.whiteColor colorWithAlphaComponent:0.68],
        NSParagraphStyleAttributeName: transcriptStyle
    }];
    NSString *confirmed = voice.confirmedTranscript ?: @"";
    if (confirmed.length && text.length <= voice.transcript.length && [voice.transcript hasSuffix:text] &&
        [text hasPrefix:confirmed] && confirmed.length <= preview.length) {
        [preview addAttribute:NSForegroundColorAttributeName value:NSColor.whiteColor
                         range:NSMakeRange(0, confirmed.length)];
    }
    [preview drawWithRect:transcriptRect options:NSStringDrawingUsesLineFragmentOrigin];

    BOOL showsActivity = state == MicaVoiceControllerStatePreparing ||
        state == MicaVoiceControllerStateTranscribing;
    if (voice.hasProgress || showsActivity) {
        NSRect track = NSMakeRect(NSMinX(panel) + 14, NSMinY(panel) + 10, panel.size.width - 28, 4);
        [[NSColor.whiteColor colorWithAlphaComponent:0.18] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
        NSRect fill = track;
        if (voice.hasProgress) {
            fill.size.width *= voice.progress;
        } else {
            CGFloat segmentWidth = MIN(140, track.size.width * 0.2);
            CGFloat travel = MAX(0, track.size.width - segmentWidth);
            CGFloat phase = fmod(NSProcessInfo.processInfo.systemUptime / 1.25, 2.0);
            if (phase > 1.0) phase = 2.0 - phase;
            fill.origin.x += travel * phase;
            fill.size.width = segmentWidth;
        }
        [accent setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2 yRadius:2] fill];
    }
}

- (BOOL)handleNavigationModeKey:(NSEvent *)event key:(NSString *)key control:(BOOL)control {
    MicaUIMode mode = self.owner.uiMode;
    MicaTab *tab = self.owner.activeTab;
    if (mode == MicaUIModeNormal || (!tab.session && mode != MicaUIModeTab)) return NO;
    if (event.keyCode == 53) {
        self.owner.uiMode = MicaUIModeNormal;
        if (mode == MicaUIModeScroll && tab.session) mica_session_scroll_to_bottom(tab.session);
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
    [self updateTabToolTip];
    [self updateGridSize];
    [MicaBackgroundColor() setFill];
    NSRectFill(NSIntersectionRect(dirtyRect, self.bounds));
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;

    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight, self.bounds.size.width, kHeaderHeight);
    if (NSIntersectsRect(dirtyRect, header)) {
        [NSColor.controlBackgroundColor setFill];
        NSRectFill(header);
        [NSColor.separatorColor setStroke];
        NSBezierPath *headerSeparator = [NSBezierPath bezierPath];
        [headerSeparator moveToPoint:NSMakePoint(0, NSMinY(header) + 0.5)];
        [headerSeparator lineToPoint:NSMakePoint(NSMaxX(header), NSMinY(header) + 0.5)];
        [headerSeparator stroke];
        NSFont *tabFont = [NSFont systemFontOfSize:kTabTitleFontSize weight:NSFontWeightMedium];
        NSMutableParagraphStyle *tabParagraphStyle = [[NSMutableParagraphStyle alloc] init];
        tabParagraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;
        NSRange visibleTabs = [self visibleTabRange];
        for (NSUInteger i = 0; i < self.owner.tabs.count; i++) {
            if (NSIsEmptyRect([self tabRectAtIndex:i])) continue;
            MicaTab *candidate = self.owner.tabs[i];
            BOOL active = i == (NSUInteger)self.owner.activeIndex;
            NSString *label = [self labelForTab:candidate active:active];
            NSRect tabRect = [self tabRectAtIndex:i];
            NSRect textRect = NSInsetRect(tabRect, 12, 3);
            if (active) {
                NSRect selectedTab = NSInsetRect(tabRect, 3, 3);
                [[NSColor.controlAccentColor colorWithAlphaComponent:0.20] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:selectedTab xRadius:7 yRadius:7] fill];
            }
            NSDictionary *tabAttrs = @{
                NSFontAttributeName: tabFont,
                NSForegroundColorAttributeName: active ? NSColor.labelColor
                    : [NSColor.labelColor colorWithAlphaComponent:0.72],
                NSParagraphStyleAttributeName: tabParagraphStyle
            };
            if (textRect.size.width > 0) {
                NSString *shortLabel = MicaTruncatedText(label, textRect.size.width, tabAttrs);
                [shortLabel drawAtPoint:NSMakePoint(NSMinX(textRect),
                    NSMinY(tabRect) + MicaCenteredTextBaseline(tabFont, tabRect.size.height))
                    withAttributes:tabAttrs];
            }
        }
        [NSColor.separatorColor setStroke];
        for (NSUInteger i = visibleTabs.location; i + 1 < NSMaxRange(visibleTabs); i++) {
            NSRect tabRect = [self tabRectAtIndex:i];
            if (NSIsEmptyRect(tabRect)) continue;
            NSBezierPath *tabDivider = [NSBezierPath bezierPath];
            [tabDivider moveToPoint:NSMakePoint(NSMaxX(tabRect) - 0.5, NSMinY(header) + 7)];
            [tabDivider lineToPoint:NSMakePoint(NSMaxX(tabRect) - 0.5, NSMaxY(header) - 7)];
            [tabDivider stroke];
        }
        if ([self hasTabOverflow]) {
            NSRange visible = [self visibleTabRange];
            NSUInteger hidden = self.owner.tabs.count - visible.length;
            NSRect moreRect = NSInsetRect([self tabOverflowRect], 4, 3);
            [[NSColor.controlBackgroundColor colorWithAlphaComponent:0.8] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:moreRect xRadius:7 yRadius:7] fill];
            NSMutableParagraphStyle *moreStyle = [[NSMutableParagraphStyle alloc] init];
            moreStyle.alignment = NSTextAlignmentCenter;
            NSDictionary *moreAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:kTabTitleFontSize weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: NSColor.labelColor,
                NSParagraphStyleAttributeName: moreStyle
            };
            NSString *moreLabel = [NSString stringWithFormat:@"… %lu", (unsigned long)hidden];
            [moreLabel drawInRect:NSInsetRect(moreRect, 2, 4) withAttributes:moreAttrs];
        }
    }
    for (NSInteger row = 0; row < _rows; row++) {
        NSRect rowRect = [self cellRectAtRow:row col:0];
        rowRect.origin.x = 0;
        rowRect.size.width = [self terminalRect].size.width;
        if (!NSIntersectsRect(rowRect, dirtyRect)) continue;
        size_t hiddenRows = 0;
        if (mica_session_fold_info_at_view_row(tab.session, (int)row, &hiddenRows)) {
            NSRect foldRect = NSInsetRect(rowRect, 2, 1);
            [[NSColor.controlAccentColor colorWithAlphaComponent:0.12] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:foldRect xRadius:4 yRadius:4] fill];
            NSString *foldLabel = [NSString stringWithFormat:@"⌄  %lu lines folded  ·  click to expand",
                (unsigned long)hiddenRows];
            NSDictionary *foldAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor
            };
            [foldLabel drawWithRect:NSInsetRect(foldRect, 7, 1)
                            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                         attributes:foldAttrs];
            continue;
        }
        NSInteger skipGlyphThroughCol = -1;
        NSMutableString *textRun = [NSMutableString string];
        __block NSInteger textRunStartCol = -1;
        __block NSFont *textRunFont = nil;
        __block NSColor *textRunForeground = nil;
        __block BOOL textRunUnderline = NO;
        __block BOOL textRunHasInk = NO;
        void (^flushTextRun)(void) = ^{
            if (textRunHasInk && textRun.length && textRunStartCol >= 0) {
                [self drawTextRun:textRun row:row startCol:textRunStartCol
                             font:textRunFont foreground:textRunForeground underline:textRunUnderline];
            }
            [textRun setString:@""];
            textRunStartCol = -1;
            textRunFont = nil;
            textRunForeground = nil;
            textRunHasInk = NO;
        };
        for (NSInteger col = 0; col < _cols; col++) {
            MicaCell cell;
            if (!mica_session_get_cell(tab.session, (int)row, (int)col, &cell)) continue;
            BOOL selected = [self point:NSZeroPoint isWithinSelectionAtRow:row col:col];
            NSColor *fg = [self colorForVTermColor:cell.fg isForeground:YES];
            NSColor *bg = [self colorForVTermColor:cell.bg isForeground:NO];
            if (cell.attrs.reverse) { NSColor *swap = fg; fg = bg; bg = swap; }
            if (selected) bg = NSColor.selectedTextBackgroundColor;
            BOOL hasBackground = selected || cell.attrs.reverse || !VTERM_COLOR_IS_DEFAULT_BG(&cell.bg);
            NSRect cellRect = [self cellRectAtRow:row col:col];
            if (hasBackground) { [bg setFill]; NSRectFill(cellRect); }
            if (CellIsContinuation(cell) || col <= skipGlyphThroughCol) continue;
            NSString *baseGlyph = [self stringForCell:cell];
            uint32_t firstCodepoint = cell.chars[0];
            uint32_t lastCodepoint = CellLastCodepoint(cell);
            BOOL flagPair = IsRegionalIndicator(firstCodepoint);
            BOOL addedFlagMate = NO;
            NSInteger nextCol = col + MAX((NSInteger)cell.width, 1);
            NSMutableString *mergedGlyph = nil;
            while (nextCol < _cols) {
                MicaCell nextCell;
                if (!mica_session_get_cell(tab.session, (int)row, (int)nextCol, &nextCell)) break;
                if (CellIsContinuation(nextCell)) { nextCol++; continue; }
                uint32_t nextFirst = nextCell.chars[0];
                BOOL merge = lastCodepoint == 0x200d || IsEmojiModifier(nextFirst) ||
                    IsVariationSelector(nextFirst) || IsCombiningMark(nextFirst) ||
                    (flagPair && !addedFlagMate && IsRegionalIndicator(nextFirst));
                if (!merge) break;
                if (!mergedGlyph) mergedGlyph = [baseGlyph mutableCopy];
                [mergedGlyph appendString:[self stringForCell:nextCell]];
                skipGlyphThroughCol = nextCol + MAX((NSInteger)nextCell.width, 1) - 1;
                if (flagPair) addedFlagMate = YES;
                lastCodepoint = CellLastCodepoint(nextCell);
                nextCol += MAX((NSInteger)nextCell.width, 1);
                if (flagPair && addedFlagMate) break;
            }
            NSString *glyph = mergedGlyph ?: baseGlyph;
            BOOL simpleASCII = cell.width == 1 && firstCodepoint >= 0x20 && firstCodepoint < 0x80 &&
                !mergedGlyph && !cell.attrs.strike;
            if (simpleASCII) {
                NSFont *font = [self fontForCell:cell];
                BOOL underline = cell.attrs.underline;
                BOOL canAppend = textRunStartCol >= 0 && col == textRunStartCol + (NSInteger)textRun.length &&
                    [textRunFont isEqual:font] && [textRunForeground isEqual:fg] &&
                    textRunUnderline == underline;
                if (!canAppend) flushTextRun();
                if (textRunStartCol < 0) {
                    textRunStartCol = col;
                    textRunFont = font;
                    textRunForeground = fg;
                    textRunUnderline = underline;
                }
                [textRun appendString:glyph];
                if (firstCodepoint != ' ') textRunHasInk = YES;
                continue;
            }
            flushTextRun();
            if ([glyph isEqualToString:@" "]) continue;
            NSFont *font = [self fontForCell:cell];
            NSMutableDictionary *glyphAttrs = [@{ NSFontAttributeName: font, NSForegroundColorAttributeName: fg } mutableCopy];
            if (cell.attrs.underline) glyphAttrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
            [glyph drawAtPoint:NSMakePoint(NSMinX(cellRect), NSMinY(cellRect) + 1) withAttributes:glyphAttrs];
        }
        flushTextRun();
    }
    if (mica_session_view_offset(tab.session) == 0 && mica_session_cursor_visible(tab.session)) {
        int cursorRow = 0, cursorCol = 0;
        mica_session_cursor(tab.session, &cursorRow, &cursorCol);
        if (cursorRow >= 0 && cursorRow < _rows && cursorCol >= 0 && cursorCol < _cols) {
            NSRect cursorRect = [self cellRectAtRow:cursorRow col:cursorCol];
            MicaCell cursorCell;
            if (mica_session_get_cell(tab.session, cursorRow, cursorCol, &cursorCell)) {
                NSInteger cellWidth = MIN(MAX((NSInteger)cursorCell.width, 1), _cols - cursorCol);
                cursorRect.size.width = _charWidth * cellWidth;
                NSColor *cursorFill = [self colorForVTermColor:cursorCell.fg isForeground:YES];
                NSColor *cursorGlyph = [self colorForVTermColor:cursorCell.bg isForeground:NO];
                if (cursorCell.attrs.reverse) {
                    NSColor *swap = cursorFill;
                    cursorFill = cursorGlyph;
                    cursorGlyph = swap;
                }
                NSColor *rgbFill = [cursorFill colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                CGFloat luminance = rgbFill.redComponent * 0.2126 +
                    rgbFill.greenComponent * 0.7152 + rgbFill.blueComponent * 0.0722;
                if (luminance < 0.4) {
                    cursorFill = MicaForegroundColor();
                    cursorGlyph = MicaBackgroundColor();
                }
                if (NSIntersectsRect(cursorRect, dirtyRect)) {
                    [cursorFill setFill];
                    NSRectFill(cursorRect);
                    NSString *glyph = [self stringForCell:cursorCell];
                    if (glyph.length && ![glyph isEqualToString:@" "]) {
                        NSDictionary *attributes = @{
                            NSFontAttributeName: self.terminalFont,
                            NSForegroundColorAttributeName: cursorGlyph
                        };
                        [glyph drawAtPoint:NSMakePoint(NSMinX(cursorRect), NSMinY(cursorRect) + 1)
                            withAttributes:attributes];
                    }
                }
            }
        }
    }
    if (!mica_session_is_running(tab.session)) {
        int exitStatus = mica_session_exit_status(tab.session);
        NSString *exitMessage = exitStatus == 0 ? @"Shell exited" : [NSString stringWithFormat:@"Shell exited with status %d", exitStatus];
        NSRect exitRect = NSMakeRect(0, kStatusHeight, [self terminalRect].size.width, 28);
        NSDictionary *exitAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
        if (NSIntersectsRect(exitRect, dirtyRect))
            [exitMessage drawAtPoint:NSMakePoint(12, kStatusHeight + 4) withAttributes:exitAttrs];
    }
    NSRect voiceOverlay = [self voiceOverlayRect];
    if (!NSIsEmptyRect(voiceOverlay) && NSIntersectsRect(voiceOverlay, dirtyRect))
        [self drawVoiceOverlay];
    NSRect status = NSMakeRect(0, 0, self.bounds.size.width, kStatusHeight);
    if (NSIntersectsRect(status, dirtyRect)) [self drawStatusBarForTab:tab];
    (void)dirtyRect;
}

- (void)keyDown:(NSEvent *)event {
    MicaTab *tab = self.owner.activeTab;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;
    BOOL control = (flags & NSEventModifierFlagControl) != 0;
    NSString *keyString = event.charactersIgnoringModifiers.lowercaseString;
    if (event.keyCode != 58 && _leftOptionIsDown && !_leftOptionStartedDictation) {
        _leftOptionUsedWithAnotherKey = YES;
        [_leftOptionTimer invalidate];
        _leftOptionTimer = nil;
    }
    MicaVoiceControllerState voiceState = self.owner.voiceController.state;
    BOOL voiceBusy = voiceState == MicaVoiceControllerStatePreparing ||
        voiceState == MicaVoiceControllerStateListening ||
        voiceState == MicaVoiceControllerStateTranscribing;
    if (event.keyCode == 53 && (voiceBusy || voiceState == MicaVoiceControllerStateFailed)) {
        [self.owner cancelDictation];
        return;
    }
    if (command && (flags & NSEventModifierFlagShift) && [keyString isEqualToString:@"p"]) {
        [self.owner toggleTabPicker];
        return;
    }
    if (command && (flags & NSEventModifierFlagShift) && [keyString isEqualToString:@"s"]) {
        [self.owner toggleScrollback];
        return;
    }
    if (!command && [self handleNavigationModeKey:event key:keyString control:control]) return;
    if (command) {
        if (keyString.length == 1 && keyString.integerValue >= 1 &&
            keyString.integerValue <= 9 && [keyString characterAtIndex:0] >= '1' &&
            [keyString characterAtIndex:0] <= '9') {
            NSInteger index = keyString.integerValue == 9
                ? (NSInteger)self.owner.tabs.count - 1 : keyString.integerValue - 1;
            [self.owner selectTabAtIndex:index];
            return;
        }
        if ([keyString isEqualToString:@"t"]) { [self.owner newTabWithName:@"Shell" command:nil]; return; }
        if ([keyString isEqualToString:@"w"]) { [self.owner closeActiveTab]; return; }
        if ([keyString isEqualToString:@"c"]) { if (_selecting) [self copySelection:nil]; else if (tab.session) mica_session_text(tab.session, 'c', VTERM_MOD_CTRL); return; }
        if ([keyString isEqualToString:@"v"]) { [self paste:nil]; return; }
        if ((flags & NSEventModifierFlagShift) && event.keyCode == 30) { [self.owner selectRelativeTab:1]; return; }
        if ((flags & NSEventModifierFlagShift) && event.keyCode == 33) { [self.owner selectRelativeTab:-1]; return; }
        if ([keyString isEqualToString:@"+"] || [keyString isEqualToString:@"="]) { self.terminalFont = MicaTerminalFont(MIN(28, self.terminalFont.pointSize + 1)); [self setNeedsDisplay:YES]; return; }
        if ([keyString isEqualToString:@"-"]) { self.terminalFont = MicaTerminalFont(MAX(8, self.terminalFont.pointSize - 1)); [self setNeedsDisplay:YES]; return; }
        return;
    }
    if (!tab.session) return;
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
    if (key != VTERM_KEY_NONE) {
        mica_session_key(tab.session, key, modifiers);
        _selecting = NO;
        _selectionPending = NO;
        return;
    }
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
    _selectionPending = NO;
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
    if (_leftOptionIsDown && !_leftOptionStartedDictation) {
        _leftOptionUsedWithAnotherKey = YES;
        [_leftOptionTimer invalidate];
        _leftOptionTimer = nil;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect voicePanel = [self voiceOverlayRect];
    if (!NSIsEmptyRect(voicePanel) && NSPointInRect(point, voicePanel)) return;
    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight,
                               self.bounds.size.width, kHeaderHeight);
    if (NSPointInRect(point, header)) {
        if (NSPointInRect(point, [self tabOverflowRect])) {
            [[self tabOverflowMenu] popUpMenuPositioningItem:nil atLocation:point inView:self];
            return;
        }
        NSInteger index = [self tabIndexAtPoint:point];
        if (index != NSNotFound) [self.owner selectTabAtIndex:index];
        return;
    }
    NSRect terminal = [self terminalRect];
    if (!NSPointInRect(point, terminal)) return;
    if (!self.owner.activeTab.session) return;
    NSPoint cell = [self cellForPoint:point];
    if (mica_session_toggle_fold_at_view_row(self.owner.activeTab.session, (int)cell.y)) {
        [self clearSelection];
        [self setNeedsDisplay:YES];
        return;
    }
    BOOL option = (event.modifierFlags & NSEventModifierFlagOption) != 0;
    if (mica_session_reports_mouse(self.owner.activeTab.session) && !option) {
        _selecting = NO;
        _selectionPending = NO;
        mica_session_mouse(self.owner.activeTab.session, (int)cell.y, (int)cell.x, 1, true);
        _mousePressed = YES;
        _mouseRow = (NSInteger)cell.y;
        _mouseCol = (NSInteger)cell.x;
        return;
    }
    _selecting = NO;
    _selectionPending = YES;
    _selectionStart = point;
    _selectionEnd = point;
}

- (void)mouseDragged:(NSEvent *)event {
    if (_mousePressed) {
        NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
        NSPoint cell = [self cellForPoint:point];
        _mouseRow = (NSInteger)cell.y;
        _mouseCol = (NSInteger)cell.x;
        mica_session_mouse(self.owner.activeTab.session, (int)_mouseRow, (int)_mouseCol, 1, true);
        return;
    }
    if (!_selectionPending && !_selecting) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!_selecting && hypot(point.x - _selectionStart.x, point.y - _selectionStart.y) < 3.0) return;
    _selecting = YES;
    _selectionPending = NO;
    _selectionEnd = point;
    [self setNeedsDisplay:YES];
}

- (void)clearSelection {
    _selecting = NO;
    _selectionPending = NO;
}

- (void)foldSelectedLines:(id)sender {
    (void)sender;
    if (!_selecting || !self.owner.activeTab.session) return;
    NSPoint start = [self cellForPoint:_selectionStart];
    NSPoint end = [self cellForPoint:_selectionEnd];
    NSInteger firstRow = MIN((NSInteger)start.y, (NSInteger)end.y);
    NSInteger lastRow = MAX((NSInteger)start.y, (NSInteger)end.y);
    if (mica_session_fold_visible_rows(self.owner.activeTab.session, (int)firstRow, (int)lastRow)) {
        [self clearSelection];
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (_mousePressed) {
        mica_session_mouse(self.owner.activeTab.session, (int)_mouseRow, (int)_mouseCol, 1, false);
        _mousePressed = NO;
        return;
    }
    if (!_selecting) {
        _selectionPending = NO;
        return;
    }
    _selectionEnd = [self convertPoint:event.locationInWindow fromView:nil];
    _selectionPending = NO;
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
#if defined(MICA_APP_NO_MAIN)
    if (self.testClipboardImage) {
        mica_session_text(tab.session, 'v', VTERM_MOD_CTRL);
        [self setNeedsDisplay:YES];
        return;
    }
    if (self.testClipboardText) {
        NSData *bytes = [self.testClipboardText dataUsingEncoding:NSUTF8StringEncoding];
        mica_session_paste(tab.session, bytes.bytes, bytes.length);
        [self setNeedsDisplay:YES];
        return;
    }
#endif
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
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
    if (layoutPath.length) {
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
    if (tab.currentCommand.length) {
        NSString *agent = MicaAgentNameForTab(tab);
        if (agent) {
            NSString *activity = tab.agentActivity.length ? tab.agentActivity : @"Starting";
            NSString *work = tab.agentActivityDetail.length ? tab.agentActivityDetail : activity;
            return [NSString stringWithFormat:@"%@ · %@", agent, work];
        }
        NSTimeInterval elapsed = tab.commandStartedAt > 0 ? NSProcessInfo.processInfo.systemUptime - tab.commandStartedAt : 0;
        NSUInteger seconds = (NSUInteger)MAX(0, elapsed);
        NSString *command = tab.currentCommand.lastPathComponent.length ? tab.currentCommand.lastPathComponent : tab.currentCommand;
        return [NSString stringWithFormat:@"%@ · %lu:%02lu", command,
            (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
    }
    if (!tab.terminalTitle.length) return tab.name;
    return [NSString stringWithFormat:@"%@ · %@", tab.name, tab.terminalTitle];
}

- (void)updateWindowTitle {
    if (self.window) self.window.title = [self windowTitleForTab:self.activeTab];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    MicaDiagnosticsLog(@"launch", [NSString stringWithFormat:@"opened app=%@ bundle=%@ pid=%d",
        NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: @"Mica",
        NSBundle.mainBundle.bundleIdentifier ?: @"unknown", getpid()]);
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
    NSURL *voiceHelperURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/mica-voice"];
    self.voiceController = [[MicaVoiceController alloc] initWithHelperURL:voiceHelperURL];
    self.voiceController.delegate = self;
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
    AddMenuItem(appMenu, @"New Instance", @selector(newInstance:), @"",
                NSEventModifierFlagCommand | NSEventModifierFlagOption).target = self;
    [appMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(appMenu, @"Quit Mica", @selector(terminate:), @"q", NSEventModifierFlagCommand);
    appRoot.submenu = appMenu;
    [main addItem:appRoot];
    NSMenuItem *sessionsRoot = [[NSMenuItem alloc] initWithTitle:@"Session" action:nil keyEquivalent:@""];
    NSMenu *sessionMenu = [[NSMenu alloc] initWithTitle:@"Session"];
    AddMenuItem(sessionMenu, @"New Shell Tab", @selector(newShell:), @"t", NSEventModifierFlagCommand).target = self;
    AddMenuItem(sessionMenu, @"Choose Tab…", @selector(toggleTabPicker), @"p",
                NSEventModifierFlagCommand | NSEventModifierFlagShift).target = self;
    AddMenuItem(sessionMenu, @"Browse Scrollback", @selector(toggleScrollback), @"s",
                NSEventModifierFlagCommand | NSEventModifierFlagShift).target = self;
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
    AddMenuItem(editMenu, @"Fold Selected Lines", @selector(foldSelectedLines:), @"f",
                NSEventModifierFlagCommand | NSEventModifierFlagOption).target = self.terminalView;
    editRoot.submenu = editMenu;
    [main addItem:editRoot];
    NSMenuItem *helpRoot = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    AddMenuItem(helpMenu, @"Open Diagnostic Logs", @selector(openDiagnosticLogs:), @"", 0).target = self;
    helpRoot.submenu = helpMenu;
    [main addItem:helpRoot];
    NSApp.helpMenu = helpMenu;
    [NSApp setMainMenu:main];
}

- (void)openDiagnosticLogs:(id)sender {
    (void)sender;
    NSURL *directory = MicaDiagnosticsLogDirectory();
    if (!directory) {
        MicaDiagnosticsLog(@"diagnostics", @"could not locate the diagnostic log folder");
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:directory];
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
    NSArray<NSDictionary *> *tabSpecs = configuration[@"tabs"];
    MicaDiagnosticsLog(@"launch", [NSString stringWithFormat:@"configuration project=%@ layout=%d tabs=%lu",
        self.projectName ?: @"Mica Terminal", [configuration[@"layoutLoaded"] boolValue],
        (unsigned long)tabSpecs.count]);
    NSMutableArray<NSNumber *> *tabIndexMap = [NSMutableArray arrayWithCapacity:tabSpecs.count];
    for (NSDictionary *spec in tabSpecs) {
        NSString *command = [spec[@"command"] length] ? spec[@"command"] : nil;
        // Older layouts used a built-in Git view. Keep them useful by turning
        // that entry into the regular lazygit shell command.
        if ([command isEqualToString:@"mica-git"]) command = @"lazygit";
        [tabIndexMap addObject:@(self.tabs.count)];
        [self addTabWithName:spec[@"name"] cwd:spec[@"cwd"] command:command
                   prefilled:[spec[@"prefilled"] boolValue]];
    }
    if (self.tabs.count == 0) {
        NSString *cwd = configuration[@"cwd"] ?: NSFileManager.defaultManager.currentDirectoryPath;
        [self addTabWithName:@"Shell" cwd:cwd command:nil prefilled:NO];
    }
    if ([configuration[@"layoutLoaded"] boolValue] && self.tabs.count > 1) {
        NSInteger sourceIndex = [configuration[@"activeIndex"] integerValue];
        NSUInteger targetIndex = NSNotFound;
        if (sourceIndex >= 0 && sourceIndex < (NSInteger)tabIndexMap.count) {
            NSUInteger mapped = tabIndexMap[(NSUInteger)sourceIndex].unsignedIntegerValue;
            if (mapped != NSNotFound && mapped < self.tabs.count) targetIndex = mapped;
        }
        if (targetIndex == NSNotFound) {
            for (NSInteger index = MIN(sourceIndex, (NSInteger)tabIndexMap.count - 1); index >= 0; index--) {
                NSUInteger mapped = tabIndexMap[(NSUInteger)index].unsignedIntegerValue;
                if (mapped != NSNotFound && mapped < self.tabs.count) { targetIndex = mapped; break; }
            }
        }
        if (targetIndex == NSNotFound) targetIndex = 0;
        [self selectTabAtIndex:(NSInteger)targetIndex];
    }
    [self updateWindowTitle];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)addTabWithName:(NSString *)name cwd:(NSString *)cwd command:(NSString *)command prefilled:(BOOL)prefilled {
    MicaTab *previous = self.activeTab;
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    [self.terminalView clearSelection];
    MicaTab *tab = [[MicaTab alloc] init];
    tab.name = name.length ? name : @"Terminal";
    // Do not probe Desktop/Documents access synchronously on AppKit's main
    // thread. macOS privacy checks can wait for user consent; the PTY child
    // resolves the requested path after the window and tabs are on screen.
    tab.cwd = MicaStandardizedWorkingDirectory(cwd);
    tab.command = command;
    tab.session = prefilled
        ? mica_session_create_prefilled(tab.cwd.fileSystemRepresentation, command.UTF8String, 24, 80)
        : mica_session_create(tab.cwd.fileSystemRepresentation, command.UTF8String, 24, 80);
    if (!tab.session) {
        MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"session start failed tab=%@ folder=%@",
            tab.name, tab.cwd]);
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Mica could not create a terminal session";
        alert.informativeText = [NSString stringWithFormat:@"Could not open %@", tab.cwd];
        [alert runModal];
        return;
    }
    MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"session started tab=%@ folder=%@ pid=%d command_prefilled=%d",
        tab.name, tab.cwd, (int)mica_session_pid(tab.session), command.length > 0]);
    if (tab.session) {
        tab.commandCompletionCount = mica_session_command_completion_count(tab.session);
        tab.tracksCompletion = command.length > 0;
        tab.completionLabel = command.length ? command.pathComponents.lastObject : @"Process";
    }
    tab.revision = UINT64_MAX;
    [self.tabs addObject:tab];
    self.activeIndex = (NSInteger)self.tabs.count - 1;
    if (tab.session && NSApp.isActive) mica_session_focus(tab.session, true);
    [self updateWindowTitle];
    [self resizeActiveSession];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)newTabWithName:(NSString *)name command:(NSString *)command {
    MicaTab *active = self.activeTab;
    [self addTabWithName:name cwd:active.cwd command:command prefilled:NO];
    [self.window makeFirstResponder:self.terminalView];
}

- (void)resizeActiveSession { [self.terminalView setNeedsDisplay:YES]; }
- (void)newShell:(id)sender { (void)sender; [self newTabWithName:@"Shell" command:nil]; }
- (void)closeTab:(id)sender { (void)sender; [self closeActiveTab]; }
- (void)nextTab:(id)sender { (void)sender; [self selectRelativeTab:1]; }
- (void)previousTab:(id)sender { (void)sender; [self selectRelativeTab:-1]; }

- (void)newInstance:(id)sender {
    (void)sender;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[@"-n", NSBundle.mainBundle.bundleURL.path];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        MicaDiagnosticsLog(@"launch", [NSString stringWithFormat:@"new instance failed: %@", error.localizedDescription]);
    } else {
        MicaDiagnosticsLog(@"launch", @"requested new app instance with open -n");
    }
}

- (void)startPushToTalk {
    [self beginDictationForActiveTab];
}

- (void)beginDictationForActiveTab {
    MicaTab *tab = self.activeTab;
    if (!tab.session || !self.voiceController) return;
    MicaVoiceControllerState state = self.voiceController.state;
    BOOL inProgress = state == MicaVoiceControllerStatePreparing || state == MicaVoiceControllerStateListening ||
        state == MicaVoiceControllerStateTranscribing;
    if (!inProgress) self.voiceTargetTab = tab;

    char path[4096] = {0};
    NSString *workingDirectory = tab.cwd;
    if (mica_session_working_directory(tab.session, path, sizeof(path))) {
        NSString *liveDirectory = [NSFileManager.defaultManager stringWithFileSystemRepresentation:path
                                                                                           length:strlen(path)];
        if (liveDirectory.length) {
            workingDirectory = liveDirectory;
            tab.cwd = liveDirectory;
        }
    }
    [self.voiceController startPushToTalkForWorkingDirectory:workingDirectory];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)finishPushToTalk {
    [self.voiceController finishPushToTalk];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)cancelDictation {
    [self.voiceController cancel];
    self.voiceTargetTab = nil;
    [self.terminalView setNeedsDisplay:YES];
}

- (void)voiceControllerDidUpdate:(MicaVoiceController *)controller {
    (void)controller;
    [self.terminalView setNeedsDisplay:YES];
}

- (BOOL)voiceController:(MicaVoiceController *)controller
      didFinishTranscript:(NSString *)transcript {
    (void)controller;
    MicaTab *target = self.voiceTargetTab;
    if (!target || ![self.tabs containsObject:target] || !target.session ||
        !mica_session_is_running(target.session)) return NO;
    NSData *bytes = [transcript dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes.length) return NO;
    mica_session_paste(target.session, bytes.bytes, bytes.length);
    self.voiceTargetTab = nil;
    if (target == self.activeTab) {
        [self.terminalView clearSelection];
        [self.terminalView setNeedsDisplay:YES];
    }
    return YES;
}

- (void)closeActiveTab {
    if (self.tabs.count <= 1) { [self.window performClose:nil]; return; }
    MicaTab *previous = self.activeTab;
    MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"tab closed name=%@ folder=%@",
        previous.name ?: @"Terminal", previous.cwd ?: @"unknown"]);
    if (previous == self.voiceTargetTab) [self cancelDictation];
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    self.uiMode = MicaUIModeNormal;
    [self.terminalView clearSelection];
    [self.tabs removeObjectAtIndex:(NSUInteger)self.activeIndex];
    if (self.activeIndex >= (NSInteger)self.tabs.count) self.activeIndex = (NSInteger)self.tabs.count - 1;
    MicaTab *tab = self.activeTab;
    if (tab.session && NSApp.isActive) mica_session_focus(tab.session, true);
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
    if (self.uiMode != MicaUIModeTab) self.uiMode = MicaUIModeNormal;
    [self.terminalView clearSelection];
    self.activeIndex = index;
    MicaTab *tab = self.activeTab;
    tab.needsAttention = NO;
    if (tab.session && NSApp.isActive) mica_session_focus(tab.session, true);
    [self updateWindowTitle];
    [self resizeActiveSession];
}

- (void)toggleTabPicker {
    self.uiMode = self.uiMode == MicaUIModeTab ? MicaUIModeNormal : MicaUIModeTab;
    [self.terminalView setNeedsDisplay:YES];
}

- (void)toggleScrollback {
    MicaTab *tab = self.activeTab;
    if (!tab.session) return;
    if (self.uiMode == MicaUIModeScroll) {
        mica_session_scroll_to_bottom(tab.session);
        self.uiMode = MicaUIModeNormal;
    } else {
        self.uiMode = MicaUIModeScroll;
    }
    [self.terminalView setNeedsDisplay:YES];
}

- (void)pollSessions:(NSTimer *)timer {
    (void)timer;
    BOOL redraw = NO;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (MicaTab *tab in self.tabs) {
        if (!tab.session) continue;
        mica_session_poll(tab.session, 0);
        MicaDirtyRows dirtyRows = {0};
        BOOL hasDirtyRows = mica_session_take_dirty_rows(tab.session, &dirtyRows);
        const char *rawTitle = mica_session_title(tab.session);
        NSString *terminalTitle = rawTitle[0]
            ? [[NSString alloc] initWithBytes:rawTitle length:strlen(rawTitle) encoding:NSUTF8StringEncoding]
            : nil;
        if (MicaStringChanged(terminalTitle, tab.terminalTitle)) {
            tab.terminalTitle = terminalTitle;
            if (tab == self.activeTab) [self updateWindowTitle];
            redraw = YES;
        }
        const char *rawCommand = mica_session_current_command(tab.session);
        NSString *currentCommand = rawCommand[0]
            ? [[NSString alloc] initWithBytes:rawCommand length:strlen(rawCommand) encoding:NSUTF8StringEncoding]
            : nil;
        if (MicaStringChanged(currentCommand, tab.currentCommand)) {
            tab.currentCommand = currentCommand;
            tab.commandStartedAt = currentCommand.length ? now : 0;
            tab.commandClockSecond = -1;
            tab.completedCommand = NO;
            tab.agentActivity = currentCommand.length && MicaAgentNameForTab(tab) ? @"Starting" : nil;
            tab.agentActivityDetail = nil;
            tab.agentActivityStartedAt = currentCommand.length ? now : 0;
            if (tab == self.activeTab) [self updateWindowTitle];
            redraw = YES;
        }
        if (currentCommand.length) {
            BOOL isAgent = MicaAgentNameForTab(tab) != nil;
            NSTimeInterval startedAt = isAgent && tab.agentActivityStartedAt > 0
                ? tab.agentActivityStartedAt : tab.commandStartedAt;
            NSInteger second = (NSInteger)MAX(0, floor(now - startedAt));
            if (second != tab.commandClockSecond) {
                tab.commandClockSecond = second;
                if (tab == self.activeTab) [self updateWindowTitle];
                redraw = YES;
            }
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
            tab.tracksCompletion = NO;
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
        if (revision != tab.revision) {
            tab.revision = revision;
            if (currentCommand.length && MicaAgentNameForTab(tab)) {
                NSString *detail = nil;
                NSString *activity = MicaAgentActivityForSession(tab.session, &detail);
                if (MicaStringChanged(activity, tab.agentActivity)) {
                    tab.agentActivity = activity;
                    tab.agentActivityDetail = detail;
                    tab.agentActivityStartedAt = now;
                    tab.commandClockSecond = -1;
                    if (tab == self.activeTab) [self updateWindowTitle];
                    redraw = YES;
                } else if (MicaStringChanged(detail, tab.agentActivityDetail)) {
                    tab.agentActivityDetail = detail;
                    if (tab == self.activeTab) [self updateWindowTitle];
                    redraw = YES;
                }
            }
            if (tab == self.activeTab && hasDirtyRows) {
                NSRect dirtyRect = [self.terminalView dirtyRectForRows:dirtyRows];
                if (!NSIsEmptyRect(dirtyRect)) [self.terminalView setNeedsDisplayInRect:dirtyRect];
            }
        }
    }
    MicaTab *active = self.activeTab;
    if (active.session && now - active.cwdLastCheck >= 1.0) {
        active.cwdLastCheck = now;
        char path[4096] = {0};
        if (mica_session_working_directory(active.session, path, sizeof(path))) {
            NSString *cwd = [NSFileManager.defaultManager stringWithFileSystemRepresentation:path
                                                                                       length:strlen(path)];
            if (cwd.length && ![cwd isEqualToString:active.cwd]) {
                MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"folder changed tab=%@ folder=%@",
                    active.name ?: @"Terminal", cwd]);
                active.cwd = cwd;
                redraw = YES;
            }
        }
    }
    NSMutableArray<MicaTab *> *exitedTabs = [NSMutableArray array];
    for (MicaTab *tab in self.tabs)
        if (tab.session && !mica_session_is_running(tab.session)) [exitedTabs addObject:tab];
    for (MicaTab *tab in exitedTabs) {
        NSUInteger index = [self.tabs indexOfObjectIdenticalTo:tab];
        if (index == NSNotFound) continue;
        MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"session exited tab=%@ status=%d",
            tab.name ?: @"Terminal", mica_session_exit_status(tab.session)]);
        if (self.voiceTargetTab == tab) [self cancelDictation];
        if (self.tabs.count <= 1) {
            [self.window performClose:nil];
            return;
        }
        if ((NSInteger)index == self.activeIndex) {
            [self closeActiveTab];
        } else {
            [self.tabs removeObjectAtIndex:index];
            if ((NSInteger)index < self.activeIndex) self.activeIndex--;
            [self updateWindowTitle];
            [self resizeActiveSession];
        }
        redraw = YES;
    }
    if (redraw) [self.terminalView setNeedsDisplay:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    MicaDiagnosticsLog(@"app", @"application is terminating");
    [self.voiceController cancel];
}
- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.terminalView cancelLeftOptionTracking];
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
        MicaDiagnosticsInitialize();
        MicaDiagnosticsLog(@"startup", [NSString stringWithFormat:@"Mica %@ revision %@ launching pid=%d bundle=%@ folder=%@",
            @MICA_VERSION, @MICA_REVISION, getpid(), NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
            NSFileManager.defaultManager.currentDirectoryPath ?: @"unknown"]);
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        MicaAppDelegate *delegate = [[MicaAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
#endif
