#import <Cocoa/Cocoa.h>
#import "mica.h"
#import "mica_diagnostics.h"
#import "mica_voice_controller.h"
#import "mica_pomodoro.h"
#import <UserNotifications/UserNotifications.h>

#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <sys/file.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#include <unistd.h>

static const CGFloat kHeaderHeight = 28.0;
static const CGFloat kStatusHeight = 32.0;
static NSTimeInterval gLastVoiceAnimationAt = 0;
static const NSTimeInterval kAgentActivityQuietInterval = 2.5;
static const CGFloat kFontSizeDefault = 16.0;
static const CGFloat kTabTitleFontSize = 10.5;
static const CGFloat kTabMinimumWidth = 140.0;
static const CGFloat kTabMaximumWidth = 240.0;
static const CGFloat kTabOverflowWidth = 56.0;
static const NSInteger kDefaultFocusMinutes = 60;
static const NSInteger kDefaultBreakMinutes = 15;
static const NSInteger kMaximumFocusMinutes = 240;
static const NSInteger kMaximumBreakMinutes = 120;

static NSString *MicaProjectMark(NSString *name) {
    NSArray<NSString *> *words = [name componentsSeparatedByCharactersInSet:
        NSCharacterSet.alphanumericCharacterSet.invertedSet];
    NSMutableString *mark = [NSMutableString string];
    for (NSString *word in words) {
        if (word.length && mark.length < 2) {
            unichar first = [word characterAtIndex:0];
            [mark appendString:[[NSString stringWithCharacters:&first length:1] uppercaseString]];
        }
    }
    if (mark.length == 1 && words.count == 1) {
        NSUInteger first = [name rangeOfComposedCharacterSequenceAtIndex:0].length;
        if (first < name.length) {
            NSRange next = [name rangeOfComposedCharacterSequenceAtIndex:first];
            [mark appendString:[[name substringWithRange:next] uppercaseString]];
        }
    }
    if (mark.length == 0 && name.length) {
        NSRange range = [name rangeOfComposedCharacterSequenceAtIndex:0];
        [mark appendString:[[name substringWithRange:range] uppercaseString]];
    }
    return mark.length ? mark : @"M";
}

static NSImage *MicaProjectApplicationIcon(NSImage *baseIcon, NSString *projectName) {
    if (!baseIcon || !projectName.length) return baseIcon;
    const CGFloat size = 512;
    NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [icon lockFocus];
    [baseIcon drawInRect:NSMakeRect(0, 0, size, size) fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1];
    uint32_t hash = 2166136261u;
    for (NSUInteger i = 0; i < projectName.length; i++) {
        hash = (hash ^ [projectName characterAtIndex:i]) * 16777619u;
    }
    CGFloat diameter = 116;
    NSRect badge = NSMakeRect(size - diameter - 12, size - diameter - 12, diameter, diameter);
    NSColor *accent = [NSColor colorWithHue:(CGFloat)(hash % 360u) / 360.0
        saturation:0.78 brightness:0.48 alpha:1];
    [[NSColor colorWithWhite:0.08 alpha:0.96] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(badge, -7, -7)] fill];
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:badge];
    circle.lineWidth = 5;
    [accent setFill];
    [NSColor.whiteColor setStroke];
    [circle fill];
    [circle stroke];
    NSString *mark = MicaProjectMark(projectName);
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:mark.length > 1 ? 42 : 52
        weight:NSFontWeightHeavy], NSForegroundColorAttributeName: NSColor.whiteColor};
    NSSize text = [mark sizeWithAttributes:attrs];
    [mark drawAtPoint:NSMakePoint(NSMidX(badge) - text.width / 2,
        NSMidY(badge) - text.height / 2) withAttributes:attrs];
    [icon unlockFocus];
    return icon;
}

static double MicaContinuousTimeSeconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return (double)mach_continuous_time() * (double)timebase.numer /
        (double)timebase.denom / 1000000000.0;
}

static NSString *MicaBootSessionID(void) {
    struct timeval bootTime = {0};
    size_t length = sizeof(bootTime);
    if (sysctlbyname("kern.boottime", &bootTime, &length, NULL, 0) != 0) return @"unknown";
    return [NSString stringWithFormat:@"%lld.%06d", (long long)bootTime.tv_sec, (int)bootTime.tv_usec];
}

static NSInteger MicaMinutesFromText(NSString *text, NSInteger fallback, NSInteger maximum) {
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    NSInteger value = 0;
    if (![scanner scanInteger:&value] || !scanner.isAtEnd || value < 1 || value > maximum) return fallback;
    return value;
}

static void MicaLogSessionCleanup(pid_t pid, const char *stage, bool started, double elapsedMilliseconds) {
    MicaDiagnosticsLog(@"shutdown", [NSString stringWithFormat:
        @"pid=%d stage=%s phase=%@ duration_ms=%.1f", pid, stage ?: "unknown",
        started ? @"start" : @"end", elapsedMilliseconds]);
}

typedef NS_ENUM(NSInteger, MicaUIMode) {
    MicaUIModeNormal = 0,
    MicaUIModeTab,
    MicaUIModeScroll,
};

typedef NS_ENUM(NSInteger, MicaTabActivityState) {
    MicaTabActivityStateIdle = 0,
    MicaTabActivityStateRunning,
    MicaTabActivityStateWaiting,
    MicaTabActivityStateComplete,
    MicaTabActivityStateNeedsAttention,
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
- (void)destroySession;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *cwd;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSString *terminalTitle;
@property(nonatomic, copy) NSString *currentCommand;
@property(nonatomic, copy) NSString *agentActivity;
@property(nonatomic, copy) NSString *agentActivityDetail;
@property(nonatomic, assign) NSInteger displayedActivityState;
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
@property(nonatomic, assign) NSTimeInterval outputMetricsStartedAt;
@property(nonatomic, assign) NSTimeInterval lastOutputReadAt;
@property(nonatomic, assign) NSTimeInterval lastOutputDrawnAt;
@property(nonatomic, assign) NSUInteger outputBytes;
@property(nonatomic, assign) NSUInteger outputReadCalls;
@property(nonatomic, assign) NSUInteger outputLargestRead;
@property(nonatomic, assign) double outputParseMilliseconds;
@property(nonatomic, assign) double outputPollMilliseconds;
@property(nonatomic, assign) double outputToDrawMaximumMilliseconds;
@property(nonatomic, assign) NSTimeInterval lastActivityScanAt;
@end
@implementation MicaTab
- (void)destroySession {
    if (!_session) return;
    mica_session_destroy(_session);
    _session = NULL;
}
- (void)dealloc { [self destroySession]; }
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
    BOOL hasInputPromptGlyph = NO;
    for (int row = rows - 1; row >= firstRow; row--) {
        NSMutableString *line = [NSMutableString string];
        for (int col = 0; col < cols; col++) {
            MicaCell cell;
            if (!mica_session_get_cell(session, row, col, &cell) || CellIsContinuation(cell)) continue;
            for (NSUInteger i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++) {
                uint32_t codepoint = cell.chars[i];
                if (row >= rows - 2 && (codepoint == 0x276f || codepoint == 0x203a))
                    hasInputPromptGlyph = YES;
                if (codepoint >= 0x20 && codepoint <= 0x7e) [line appendFormat:@"%c", (char)codepoint];
                else [line appendString:@" "];
            }
        }
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!trimmed.length) continue;
        NSString *upper = trimmed.uppercaseString;
        NSString *lineActivity = nil;
        if ([upper containsString:@"TRUST THIS FOLDER"] || [upper containsString:@"NEEDS APPROVAL"] ||
            [upper containsString:@"WAITING FOR APPROVAL"] || [upper containsString:@"CONFIRMATION REQUIRED"] ||
            [upper containsString:@"APPROVE THIS"] || [upper containsString:@"ALLOW THIS"]) {
            lineActivity = @"Needs approval";
        } else if ([upper containsString:@"WAITING FOR YOUR INPUT"] ||
                   [upper containsString:@"WAITING FOR INPUT"] ||
                   [upper containsString:@"PRESS ENTER TO CONTINUE"] ||
                   [upper containsString:@"PRESS RETURN TO CONTINUE"] ||
                   [upper containsString:@"SELECT AN OPTION"] || [upper containsString:@"CHOOSE AN OPTION"] ||
                   [upper containsString:@"TYPE YOUR ANSWER"] || [upper containsString:@"ENTER TO SUBMIT"] ||
                   [upper containsString:@"(Y/N)"] || [upper containsString:@"[Y/N]"]) {
            lineActivity = @"Needs input";
        } else if ([upper containsString:@"RESUME A PREVIOUS SESSION"] ||
                   [upper containsString:@"RESUME SESSION"]) {
            lineActivity = @"Choosing session";
        } else if ([upper containsString:@"COMPACTING"] || [upper containsString:@"COMPACTION"]) {
            lineActivity = @"Compacting";
        } else if ([upper containsString:@"PLANNING"]) {
            lineActivity = @"Planning";
        } else if ([upper containsString:@"SEARCHING"]) {
            lineActivity = @"Searching";
        } else if ([upper containsString:@"READING"]) {
            lineActivity = @"Reading";
        } else if ([upper containsString:@"EDITING"] || [upper containsString:@"WRITING"] ||
                   [upper containsString:@"IMPLEMENTING"]) {
            lineActivity = @"Editing";
        } else if ([upper containsString:@"WORKING"] || [upper containsString:@"ESC TO INTERRUPT"]) {
            lineActivity = @"Working";
        } else if ([upper containsString:@"THINKING"]) {
            lineActivity = @"Thinking";
        } else if ([upper containsString:@"RUNNING"]) {
            lineActivity = @"Running";
        } else if ([upper containsString:@"EXPLORING"]) {
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
    if (hasInputPromptGlyph && (!activity || [activity isEqualToString:@"Ready"] ||
                                [activity isEqualToString:@"Running"])) {
        activity = @"Needs input";
        if (!activityLine) activityLine = @"Input prompt";
    }
    if (detailOut) *detailOut = recentAction ?: activityLine;
    return activity ?: @"Idle";
}

@class MicaAppDelegate;
@interface MicaTabAccessibilityElement : NSAccessibilityElement
@property(nonatomic, copy) BOOL (^pressHandler)(void);
@end
@implementation MicaTabAccessibilityElement
- (BOOL)accessibilityPerformPress { return self.pressHandler ? self.pressHandler() : NO; }
@end

@interface MicaTerminalView : NSView <NSTextInputClient>
@property(nonatomic, weak) MicaAppDelegate *owner;
@property(nonatomic, strong) NSFont *terminalFont;
@property(nonatomic, strong) NSTimer *gridResizeTimer;
@property(nonatomic, assign) NSTimeInterval gridResizeStartedAt;
@property(nonatomic, assign) NSUInteger gridResizeEventCount;
@property(nonatomic, assign) NSRect gridResizeInitialWindowFrame;
@property(nonatomic, assign) NSTimeInterval drawingStatsStartedAt;
@property(nonatomic, assign) NSUInteger drawingStatsCount;
@property(nonatomic, assign) NSTimeInterval drawingStatsTotalDuration;
@property(nonatomic, assign) NSTimeInterval drawingStatsMaximumDuration;
#if defined(MICA_APP_NO_MAIN)
@property(nonatomic, copy) NSString *testClipboardText;
@property(nonatomic, strong) NSData *testClipboardImage;
@property(nonatomic, copy) NSArray<NSURL *> *testDraggedFileURLs;
@property(nonatomic, copy) void (^testOpenURLHandler)(NSURL *url);
#endif
- (NSRect)tabRectAtIndex:(NSUInteger)index;
- (CGFloat)projectBadgeWidth;
- (NSRange)visibleTabRange;
- (BOOL)hasTabOverflow;
- (NSRect)tabOverflowRect;
- (NSMenu *)tabOverflowMenu;
- (void)selectOverflowTab:(id)sender;
- (NSInteger)tabIndexAtPoint:(NSPoint)point;
- (NSRect)dirtyRectForRows:(MicaDirtyRows)rows;
- (NSRect)terminalRect;
- (NSRect)pomodoroControlRect;
- (void)showPomodoroControlMenu:(id)sender;
- (void)updateGridSize;
- (void)scheduleGridResize;
- (void)commitGridResize:(NSTimer *)timer;
- (void)recordDrawDuration:(NSTimeInterval)duration;
- (NSString *)labelForTab:(MicaTab *)tab active:(BOOL)active;
- (MicaTabActivityState)activityStateForTab:(MicaTab *)tab;
- (void)drawActivityIndicatorForTab:(MicaTab *)tab at:(NSPoint)center;
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
- (NSRect)dictationStatusRect;
- (void)drawDictationStatusBar:(MicaVoiceController *)voice inRect:(NSRect)status;
- (void)openHyperlinkID:(uint32_t)hyperlinkID forTab:(MicaTab *)tab;
- (void)cancelLeftOptionTracking;
@end

@interface MicaAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, MicaVoiceControllerDelegate,
                                       UNUserNotificationCenterDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) MicaTerminalView *terminalView;
@property(nonatomic, strong) NSMutableArray<MicaTab *> *tabs;
@property(nonatomic, assign) NSInteger activeIndex;
@property(nonatomic, copy) NSString *projectName;
@property(nonatomic, strong) NSImage *baseApplicationIcon;
@property(nonatomic, copy) NSString *projectLayoutPath;
@property(nonatomic, strong) id projectSettingsController;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, assign) NSTimeInterval lastSlowPollLogAt;
@property(nonatomic, assign) NSTimeInterval lastPollTimerTickAt;
@property(nonatomic, assign) BOOL terminationCleanupStarted;
@property(nonatomic, strong) NSTimer *terminationReplyTimer;
@property(nonatomic, strong) dispatch_group_t terminationCleanupGroup;
@property(nonatomic, assign) NSTimeInterval lastActivityAnimationAt;
@property(nonatomic, assign) NSUInteger activityAnimationFrame;
@property(nonatomic, strong) MicaVoiceController *voiceController;
@property(nonatomic, strong) MicaTab *voiceTargetTab;
@property(nonatomic) NSInteger lastVoiceState;
@property(nonatomic) NSUInteger idlePollTicks;
@property(nonatomic) BOOL pollSawOutput;
@property(nonatomic) BOOL pollIsSlow;
@property(nonatomic, copy) NSString *appliedIconProjectName;
@property(nonatomic, assign) NSInteger attentionRequest;
@property(nonatomic, assign) NSInteger focusDurationMinutes;
@property(nonatomic, assign) NSInteger breakDurationMinutes;
@property(nonatomic, assign) NSInteger pomodoroCycleFocusMinutes;
@property(nonatomic, assign) NSInteger pomodoroCycleBreakMinutes;
@property(nonatomic, assign) MicaPomodoro pomodoro;
@property(nonatomic, strong) NSURL *pomodoroStateURL;
@property(nonatomic, strong) NSURL *pomodoroLockURL;
@property(nonatomic, strong) NSURL *pomodoroSettingsURL;
@property(nonatomic, assign) int pomodoroLockFD;
@property(nonatomic, assign) BOOL pomodoroOwnsLock;
@property(nonatomic, assign) NSTimeInterval lastPomodoroTickAt;
#if defined(MICA_APP_NO_MAIN)
@property(nonatomic, strong) NSURL *pomodoroStorageDirectoryOverride;
#endif
- (MicaTab *)activeTab;
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
- (void)wakePollTimer;
- (void)loadLaunchConfiguration;
- (void)loadLaunchConfigurationFromArguments:(NSArray<NSString *> *)arguments bundleInfo:(NSDictionary *)bundleInfo;
- (void)startPushToTalk;
- (void)finishPushToTalk;
- (void)beginDictationForActiveTab;
- (void)cancelDictation;
- (void)openDiagnosticLogs:(id)sender;
- (void)showKeyboardShortcuts:(id)sender;
- (void)openProjectSettings:(id)sender;
- (void)startPomodoro:(id)sender;
- (void)togglePomodoroPause:(id)sender;
- (void)resetPomodoro:(id)sender;
- (void)openPomodoroSettings:(id)sender;
- (void)configurePomodoro;
- (void)refreshPomodoroState;
- (BOOL)savePomodoroDurationsFocusMinutes:(NSInteger)focusMinutes breakMinutes:(NSInteger)breakMinutes;
- (void)savePomodoroState;
- (void)updatePomodoroTimer;
- (NSString *)currentPomodoroNotificationIdentifier;
@property(nonatomic, assign) MicaUIMode uiMode;
@end

@interface MicaProjectSettingsController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, weak) MicaAppDelegate *appDelegate;
@property(nonatomic, strong) NSTextField *projectNameField;
@property(nonatomic, copy) NSString *originalLayoutContents;
- (BOOL)layoutChangedOnDisk;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSMutableArray<NSMutableArray<NSString *> *> *rows;
- (instancetype)initWithOwner:(MicaAppDelegate *)owner;
- (void)save:(id)sender;
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
    return (height - (font.ascender - font.descender)) / 2.0 - font.descender;
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

static NSURL *MicaSafeHyperlinkURL(NSString *rawURL) {
    if (!rawURL.length || rawURL.length > 2048 ||
        [rawURL rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [rawURL rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:rawURL];
    NSString *scheme = parts.scheme.lowercaseString;
    if ((! [scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) ||
        !parts.host.length || parts.user.length || parts.password.length) return nil;
    return parts.URL;
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
    uint64_t _selectionHistoryLines;
    MicaTab *_imeTab;
    NSFont *_styledFontBase;
    NSFont *__strong _styledFonts[4];
    NSString *_markedText;
    MicaSession *_selectionSession;
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

#pragma mark NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    _markedText = nil;
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : string;
    MicaTab *tab = _imeTab ?: self.owner.activeTab;
    if (!tab.session) return;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar first = [text characterAtIndex:i];
        uint32_t codepoint = first;
        if (CFStringIsSurrogateHighCharacter(first) && i + 1 < text.length) {
            unichar second = [text characterAtIndex:i + 1];
            if (CFStringIsSurrogateLowCharacter(second)) { codepoint = CFStringGetLongCharacterForSurrogatePair(first, second); i++; }
        }
        if (codepoint >= 0x20) mica_session_text(tab.session, codepoint, VTERM_MOD_NONE);
    }
}
- (void)doCommandBySelector:(SEL)selector { (void)selector; }
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    (void)selectedRange; (void)replacementRange;
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : string;
    _markedText = text.length ? [text copy] : nil;
}
- (void)unmarkText { _markedText = nil; }
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)markedRange { return _markedText ? NSMakeRange(0, _markedText.length) : NSMakeRange(NSNotFound, 0); }
- (BOOL)hasMarkedText { return _markedText != nil; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range; (void)actualRange; return nil;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range; (void)actualRange;
    // Place IME candidate windows at the top-left of the terminal grid; cursor tracking is not exposed here.
    NSRect rect = NSMakeRect(NSMinX(self.bounds), NSMaxY(self.bounds) - kHeaderHeight - _lineHeight, _charWidth, _lineHeight);
    return [self.window convertRectToScreen:[self convertRect:rect toView:nil]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { (void)point; return NSNotFound; }

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityTextAreaRole; }
- (NSString *)accessibilityLabel {
    NSString *project = self.owner.projectName;
    return project.length ? [NSString stringWithFormat:@"Terminal, %@", project] : @"Terminal";
}
- (NSArray *)accessibilityChildren {
    // Expose each visible tab as a selectable button so VoiceOver can switch tabs.
    NSMutableArray *children = [NSMutableArray array];
    NSRange visible = [self visibleTabRange];
    for (NSUInteger index = visible.location; index < NSMaxRange(visible); index++) {
        MicaTab *tab = self.owner.tabs[index];
        __weak typeof(self) weakSelf = self;
        MicaTabAccessibilityElement *element = [MicaTabAccessibilityElement accessibilityElementWithRole:NSAccessibilityButtonRole
            frame:[self.window convertRectToScreen:[self convertRect:[self tabRectAtIndex:index] toView:nil]]
            label:[self labelForTab:tab active:(NSInteger)index == self.owner.activeIndex] parent:self];
        element.pressHandler = ^BOOL{ [weakSelf.owner selectTabAtIndex:(NSInteger)index]; return YES; };
        [children addObject:element];
    }
    return children;
}
- (id)accessibilityValue {
    // Expose the visible screen text so VoiceOver can read terminal output.
    MicaSession *session = self.owner.activeTab.session;
    if (!session) return @"";
    NSMutableString *text = [NSMutableString string];
    int rows = mica_session_rows(session), cols = mica_session_cols(session);
    for (int row = 0; row < rows; row++) {
        NSMutableString *line = [NSMutableString string];
        for (int col = 0; col < cols; col++) {
            MicaCell cell;
            if (!mica_session_get_cell(session, row, col, &cell) || cell.width == 0) continue;
            uint32_t ch = cell.chars[0];
            if (ch == 0) { [line appendString:@" "]; continue; }
            NSString *glyph = [[NSString alloc] initWithBytes:&ch length:4 encoding:NSUTF32LittleEndianStringEncoding];
            [line appendString:glyph ?: @" "];
        }
        NSRange end = [line rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet.invertedSet options:NSBackwardsSearch];
        [text appendString:end.location == NSNotFound ? @"" : [line substringToIndex:NSMaxRange(end)]];
        [text appendString:@"\n"];
    }
    return text;
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
    MicaTab *tab = self.owner.activeTab;
    if (tab.session) {
        // Validate each distinct link once instead of parsing its URL for every cell.
        NSMutableDictionary<NSNumber *, NSNumber *> *safeLinks = [NSMutableDictionary dictionary];
        for (NSInteger row = 0; row < _rows; row++) {
            for (NSInteger col = 0; col < _cols; col++) {
                MicaCell cell;
                if (!mica_session_get_cell(tab.session, (int)row, (int)col, &cell) || !cell.hyperlink_id) continue;
                NSNumber *key = @(cell.hyperlink_id);
                NSNumber *safe = safeLinks[key];
                if (!safe) {
                    safe = @(MicaSafeHyperlinkURL([NSString stringWithUTF8String:
                        mica_session_hyperlink_uri(tab.session, cell.hyperlink_id) ?: ""]) != nil);
                    safeLinks[key] = safe;
                }
                if (safe.boolValue) [self addCursorRect:[self cellRectAtRow:row col:col] cursor:NSCursor.pointingHandCursor];
            }
        }
    }
    NSRect overflow = [self tabOverflowRect];
    if ([self hasTabOverflow] && !NSIsEmptyRect(overflow))
        [self addCursorRect:overflow cursor:NSCursor.pointingHandCursor];
    NSRect timerControl = [self pomodoroControlRect];
    if (!NSIsEmptyRect(timerControl)) [self addCursorRect:timerControl cursor:NSCursor.pointingHandCursor];
}

- (void)layout {
    [super layout];
}

- (void)dealloc {
    [_leftOptionTimer invalidate];
    [_gridResizeTimer invalidate];
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
    if (!cell.attrs.bold && !cell.attrs.italic) return self.terminalFont;
    // Four prebuilt variants avoid a string-keyed cache lookup for every styled cell.
    if (_styledFontBase != self.terminalFont) {
        _styledFontBase = self.terminalFont;
        for (int i = 0; i < 4; i++) _styledFonts[i] = nil;
    }
    int slot = (cell.attrs.bold ? 1 : 0) | (cell.attrs.italic ? 2 : 0);
    if (!_styledFonts[slot]) {
        NSFontTraitMask traits = (cell.attrs.bold ? NSBoldFontMask : 0) |
            (cell.attrs.italic ? NSItalicFontMask : 0);
        _styledFonts[slot] = MicaTerminalFontWithTraits(self.terminalFont, traits);
    }
    return _styledFonts[slot];
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

- (void)openHyperlinkID:(uint32_t)hyperlinkID forTab:(MicaTab *)tab {
    if (!tab.session || !hyperlinkID) return;
    const char *raw = mica_session_hyperlink_uri(tab.session, hyperlinkID);
    if (!raw) return;
    NSURL *url = MicaSafeHyperlinkURL([NSString stringWithUTF8String:raw]);
    if (!url) return;
#if defined(MICA_APP_NO_MAIN)
    if (self.testOpenURLHandler) { self.testOpenURLHandler(url); return; }
#endif
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (NSRect)terminalRect {
    return NSMakeRect(0, kStatusHeight, self.bounds.size.width,
                      MAX(0, self.bounds.size.height - kHeaderHeight - kStatusHeight));
}

- (NSRect)pomodoroControlRect {
    if (self.owner.voiceController.state != MicaVoiceControllerStateIdle) return NSZeroRect;
    CGFloat x = 12;
    MicaUIMode mode = self.owner.uiMode;
    int offset = self.owner.activeTab.session ? mica_session_view_offset(self.owner.activeTab.session) : 0;
    NSString *modeName = mode == MicaUIModeTab ? @"TAB PICKER" :
        ((mode == MicaUIModeScroll || offset > 0) ? @"SCROLLBACK" : nil);
    if (modeName) {
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold]};
        x = 12 + [modeName sizeWithAttributes:attributes].width + 18 + 12;
    }
    return NSMakeRect(x, floor((kStatusHeight - 23) / 2), 190, 23);
}

- (void)showPomodoroControlMenu:(id)sender {
    (void)sender;
    MicaPomodoro timer = self.owner.pomodoro;
    NSString *toggleTitle = timer.phase == MICA_POMODORO_IDLE ? @"Start Focus" :
        (mica_pomodoro_is_paused(&timer) ? @"Resume Timer" : @"Pause Timer");
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Focus Timer"];
    AddMenuItem(menu, toggleTitle, @selector(togglePomodoroPause:), @"", 0).target = self.owner;
    AddMenuItem(menu, @"Reset Timer", @selector(resetPomodoro:), @"", 0).target = self.owner;
    [menu addItem:NSMenuItem.separatorItem];
    AddMenuItem(menu, @"Timer Settings…", @selector(openPomodoroSettings:), @"", 0).target = self.owner;
    NSPoint location = [self convertPoint:NSEvent.mouseLocation fromView:nil];
    [menu popUpMenuPositioningItem:nil atLocation:location inView:self];
}

- (NSRect)dictationStatusRect {
    if (!self.owner.voiceController || self.owner.voiceController.state == MicaVoiceControllerStateIdle)
        return NSZeroRect;
    return NSMakeRect(0, 0, self.bounds.size.width, kStatusHeight);
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
        NSInteger oldCols = _cols;
        NSInteger oldRows = _rows;
        int oldPixelWidth = _pixelWidth;
        int oldPixelHeight = _pixelHeight;
        _cols = cols;
        _rows = rows;
        _pixelWidth = pixelWidth;
        _pixelHeight = pixelHeight;
        _sizedSession = tab.session;
        mica_session_resize_pixels(tab.session, (int)rows, (int)cols, pixelWidth, pixelHeight);
        MicaDiagnosticsLog(@"resize", [NSString stringWithFormat:
            @"pty-size pid=%d grid=%ldx%ld->%ldx%ld pixels=%dx%d->%dx%d live=%d",
            mica_session_pid(tab.session), (long)oldCols, (long)oldRows,
            (long)cols, (long)rows, oldPixelWidth, oldPixelHeight,
            pixelWidth, pixelHeight, self.inLiveResize]);
    }
}

- (void)scheduleGridResize {
    if (self.gridResizeEventCount == 0) {
        self.gridResizeStartedAt = NSProcessInfo.processInfo.systemUptime;
        self.gridResizeInitialWindowFrame = self.window.frame;
    }
    self.gridResizeEventCount++;
    [self.gridResizeTimer invalidate];
    self.gridResizeTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
        target:self selector:@selector(commitGridResize:) userInfo:nil repeats:NO];
}

- (void)commitGridResize:(NSTimer *)timer {
    if (timer != self.gridResizeTimer) return;
    self.gridResizeTimer = nil;
    if (self.inLiveResize) return;
    NSUInteger resizeEvents = self.gridResizeEventCount;
    NSTimeInterval resizeDuration = MAX(0,
        NSProcessInfo.processInfo.systemUptime - self.gridResizeStartedAt);
    NSRect initialFrame = self.gridResizeInitialWindowFrame;
    self.gridResizeEventCount = 0;
    self.gridResizeStartedAt = 0;
    [self updateGridSize];
    if (resizeEvents) {
        MicaTab *tab = self.owner.activeTab;
        MicaDiagnosticsLog(@"resize", [NSString stringWithFormat:
            @"settled events=%lu duration_ms=%.1f frame=%@->%@ grid=%ldx%ld pid=%d",
            (unsigned long)resizeEvents, resizeDuration * 1000.0,
            NSStringFromRect(initialFrame), NSStringFromRect(self.window.frame),
            (long)_cols, (long)_rows, tab.session ? mica_session_pid(tab.session) : -1]);
    }
    [self setNeedsDisplay:YES];
}

- (void)recordDrawDuration:(NSTimeInterval)duration {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    MicaTab *activeTab = self.owner.activeTab;
    if (activeTab.lastOutputReadAt > activeTab.lastOutputDrawnAt) {
        double outputToDraw = MAX(0, now - activeTab.lastOutputReadAt) * 1000.0;
        activeTab.outputToDrawMaximumMilliseconds = MAX(activeTab.outputToDrawMaximumMilliseconds, outputToDraw);
        activeTab.lastOutputDrawnAt = activeTab.lastOutputReadAt;
    }
    if (self.drawingStatsStartedAt == 0) self.drawingStatsStartedAt = now;
    self.drawingStatsCount++;
    self.drawingStatsTotalDuration += duration;
    self.drawingStatsMaximumDuration = MAX(self.drawingStatsMaximumDuration, duration);
    NSTimeInterval windowDuration = now - self.drawingStatsStartedAt;
    if (windowDuration < 5.0) return;
    if (self.drawingStatsCount >= 150 || self.drawingStatsMaximumDuration >= 0.03) {
        MicaTab *tab = self.owner.activeTab;
        MicaDiagnosticsLog(@"performance", [NSString stringWithFormat:
            @"terminal-render seconds=%.1f draws=%lu draws_per_second=%.1f avg_ms=%.2f max_ms=%.2f tab=%@ pid=%d",
            windowDuration, (unsigned long)self.drawingStatsCount,
            self.drawingStatsCount / windowDuration,
            self.drawingStatsTotalDuration * 1000.0 / MAX(1, self.drawingStatsCount),
            self.drawingStatsMaximumDuration * 1000.0, tab.name ?: @"none",
            tab.session ? mica_session_pid(tab.session) : -1]);
    }
    self.drawingStatsStartedAt = now;
    self.drawingStatsCount = 0;
    self.drawingStatsTotalDuration = 0;
    self.drawingStatsMaximumDuration = 0;
}

- (NSRect)cellRectAtRow:(NSInteger)row col:(NSInteger)col {
    NSRect area = [self terminalRect];
    CGFloat top = NSMaxY(area);
    return NSMakeRect(col * _charWidth, top - (row + 1) * _lineHeight, _charWidth, _lineHeight);
}

- (NSString *)labelForTab:(MicaTab *)tab active:(BOOL)active {
    (void)active;
    return tab.name.length ? tab.name : @"Terminal";
}

- (MicaTabActivityState)activityStateForTab:(MicaTab *)tab {
    if (!tab) return MicaTabActivityStateIdle;
    if (tab.currentCommand.length) {
        if ([tab.agentActivity isEqualToString:@"Needs approval"] ||
            [tab.agentActivity isEqualToString:@"Needs input"] ||
            [tab.agentActivity isEqualToString:@"Choosing session"])
            return MicaTabActivityStateWaiting;
        if (tab.needsAttention) return MicaTabActivityStateNeedsAttention;
        if (MicaAgentNameForTab(tab)) {
            NSString *activity = tab.agentActivity;
            if (!activity.length || [activity isEqualToString:@"Idle"] ||
                [activity isEqualToString:@"Ready"])
                return MicaTabActivityStateIdle;
        }
        NSTimeInterval lastOutputAt = tab.lastOutputReadAt;
        if (lastOutputAt <= 0 ||
            NSProcessInfo.processInfo.systemUptime - lastOutputAt > kAgentActivityQuietInterval)
            return MicaTabActivityStateIdle;
        return MicaTabActivityStateRunning;
    }
    if (tab.needsAttention) return MicaTabActivityStateNeedsAttention;
    if (tab.completedCommand) return MicaTabActivityStateComplete;
    return MicaTabActivityStateIdle;
}

- (void)drawActivityIndicatorForTab:(MicaTab *)tab at:(NSPoint)center {
    MicaTabActivityState state = [self activityStateForTab:tab];
    if (state == MicaTabActivityStateIdle) return;
    CGFloat phase = (CGFloat)(self.owner.activityAnimationFrame % 8) / 8.0;
    if (state == MicaTabActivityStateRunning) {
        for (NSUInteger index = 0; index < 8; index++) {
            CGFloat angle = (CGFloat)index * (CGFloat)M_PI / 4.0;
            CGFloat x = cos(angle), y = sin(angle);
            CGFloat alpha = 0.15 + 0.85 * (CGFloat)((index + 8 - self.owner.activityAnimationFrame % 8) % 8) / 7.0;
            NSBezierPath *spoke = [NSBezierPath bezierPath];
            spoke.lineWidth = 1.6;
            [spoke moveToPoint:NSMakePoint(center.x + x * 2.0, center.y + y * 2.0)];
            [spoke lineToPoint:NSMakePoint(center.x + x * 4.7, center.y + y * 4.7)];
            [[NSColor.controlAccentColor colorWithAlphaComponent:alpha] setStroke];
            [spoke stroke];
        }
        return;
    }
    if (state == MicaTabActivityStateWaiting || state == MicaTabActivityStateNeedsAttention) {
        CGFloat pulse = state == MicaTabActivityStateNeedsAttention
            ? 0.62 + 0.38 * sin(phase * (CGFloat)(2.0 * M_PI)) : 1.0;
        NSColor *color = state == MicaTabActivityStateWaiting ? NSColor.systemOrangeColor : NSColor.systemRedColor;
        [[color colorWithAlphaComponent:pulse] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - 5.5, center.y - 5.5, 11, 11)] fill];
        NSDictionary *attributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: NSColor.whiteColor,
        };
        [@"!" drawAtPoint:NSMakePoint(center.x - 2.1, center.y - 4.3) withAttributes:attributes];
        return;
    }
    NSColor *color = tab.completionStatus == 0 ? NSColor.systemGreenColor : NSColor.systemRedColor;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: color,
    };
    [(tab.completionStatus == 0 ? @"✓" : @"×") drawAtPoint:NSMakePoint(center.x - 4.5, center.y - 5.5)
        withAttributes:attributes];
}

- (NSRect)tabRectAtIndex:(NSUInteger)index {
    NSUInteger count = self.owner.tabs.count;
    if (index >= count || count == 0) return NSZeroRect;
    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight,
                               self.bounds.size.width - [self projectBadgeWidth], kHeaderHeight);
    NSRange visible = [self visibleTabRange];
    if (index < visible.location || index >= NSMaxRange(visible)) return NSZeroRect;
    CGFloat tabWidth = MIN(header.size.width / (CGFloat)count, kTabMaximumWidth);
    CGFloat x = index * tabWidth;
    if ([self hasTabOverflow]) {
        CGFloat tabsWidth = MAX(0, header.size.width - kTabOverflowWidth);
        tabWidth = visible.length ? MIN(tabsWidth / (CGFloat)visible.length, kTabMaximumWidth) : 0;
        x = (index - visible.location) * tabWidth;
    }
    return NSMakeRect(x, NSMinY(header), tabWidth, header.size.height);
}

- (CGFloat)projectBadgeWidth {
    NSString *name = self.owner.projectName;
    if (!name.length) return 0;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:kTabTitleFontSize
        weight:NSFontWeightSemibold]};
    return MIN(220, MAX(100, [name sizeWithAttributes:attrs].width + 26));
}

- (NSRange)visibleTabRange {
    NSUInteger count = self.owner.tabs.count;
    CGFloat width = MAX(0, self.bounds.size.width - [self projectBadgeWidth]);
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
    CGFloat availableWidth = MAX(0, self.bounds.size.width - [self projectBadgeWidth]);
    CGFloat width = MIN(kTabOverflowWidth, availableWidth);
    return NSMakeRect(availableWidth - width,
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
    // Hit-test against the exact rects used for drawing so clicks and tabs never disagree.
    if (self.owner.tabs.count == 0 || self.bounds.size.width <= 0) return NSNotFound;
    if (NSPointInRect(point, [self tabOverflowRect])) return NSNotFound;
    NSRange visible = [self visibleTabRange];
    for (NSUInteger index = visible.location; index < NSMaxRange(visible); index++) {
        if (NSPointInRect(point, [self tabRectAtIndex:index])) return (NSInteger)index;
    }
    return NSNotFound;
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
    [self.owner wakePollTimer];
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

    MicaVoiceController *voice = self.owner.voiceController;
    if (voice && voice.state != MicaVoiceControllerStateIdle) {
        [self drawDictationStatusBar:voice inRect:status];
        return;
    }

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

    MicaPomodoro timer = self.owner.pomodoro;
    MicaPomodoroPhase timerPhase = timer.phase;
    BOOL paused = mica_pomodoro_is_paused(&timer);
    BOOL focus = timerPhase == MICA_POMODORO_FOCUS || timerPhase == MICA_POMODORO_PAUSED_FOCUS ||
        timerPhase == MICA_POMODORO_IDLE;
    NSInteger intervalMinutes = focus ? (self.owner.focusDurationMinutes ?: kDefaultFocusMinutes) :
        (self.owner.breakDurationMinutes ?: kDefaultBreakMinutes);
    double intervalSeconds = MAX(1, intervalMinutes) * 60.0;
    double remaining = timerPhase == MICA_POMODORO_IDLE ? intervalSeconds :
        mica_pomodoro_remaining(&timer, MicaContinuousTimeSeconds());
    NSUInteger secondsLeft = (NSUInteger)ceil(remaining);
    NSString *timerText = [NSString stringWithFormat:@"%@ · %02lu:%02lu",
        timerPhase == MICA_POMODORO_IDLE ? @"Ready" : (paused ? @"Paused" : (focus ? @"Focus" : @"Break")),
        (unsigned long)(secondsLeft / 60), (unsigned long)(secondsLeft % 60)];
    NSColor *timerColor = timerPhase == MICA_POMODORO_IDLE || paused ? NSColor.secondaryLabelColor :
        (focus ? NSColor.systemGreenColor : NSColor.systemOrangeColor);
    NSRect timerControl = [self pomodoroControlRect];
    [[timerColor colorWithAlphaComponent:0.14] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:timerControl xRadius:7 yRadius:7] fill];
    NSPoint ringCenter = NSMakePoint(NSMinX(timerControl) + 14, NSMidY(timerControl));
    NSBezierPath *ringTrack = [NSBezierPath bezierPath];
    [ringTrack appendBezierPathWithOvalInRect:NSMakeRect(ringCenter.x - 5.5, ringCenter.y - 5.5, 11, 11)];
    ringTrack.lineWidth = 2;
    [[timerColor colorWithAlphaComponent:0.24] setStroke];
    [ringTrack stroke];
    double progress = timerPhase == MICA_POMODORO_IDLE ? 0 : MIN(1, MAX(0, 1 - remaining / intervalSeconds));
    if (progress > 0) {
        NSBezierPath *ringProgress = [NSBezierPath bezierPath];
        [ringProgress appendBezierPathWithArcWithCenter:ringCenter radius:5.5 startAngle:90
            endAngle:90 - progress * 360 clockwise:YES];
        ringProgress.lineWidth = 2;
        [timerColor setStroke];
        [ringProgress stroke];
    }
    NSDictionary *timerAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    [timerText drawAtPoint:NSMakePoint(NSMinX(timerControl) + 25,
        MicaCenteredTextBaseline(timerAttrs[NSFontAttributeName], timerControl.size.height) + NSMinY(timerControl))
        withAttributes:timerAttrs];
    CGFloat actionX = NSMaxX(timerControl) - 55;
    [NSColor.separatorColor setStroke];
    NSBezierPath *actionDivider = [NSBezierPath bezierPath];
    [actionDivider moveToPoint:NSMakePoint(actionX - 7, NSMinY(timerControl) + 5)];
    [actionDivider lineToPoint:NSMakePoint(actionX - 7, NSMaxY(timerControl) - 5)];
    [actionDivider stroke];
    NSDictionary *actionAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };
    NSString *toggleGlyph = mica_pomodoro_is_running(&timer) ? @"Ⅱ" : @"▶";
    [toggleGlyph drawAtPoint:NSMakePoint(actionX,
        MicaCenteredTextBaseline(actionAttrs[NSFontAttributeName], timerControl.size.height) + NSMinY(timerControl))
        withAttributes:actionAttrs];
    [@"↻" drawAtPoint:NSMakePoint(actionX + 27,
        MicaCenteredTextBaseline(actionAttrs[NSFontAttributeName], timerControl.size.height) + NSMinY(timerControl))
        withAttributes:actionAttrs];
    contextX = NSMaxX(timerControl) + 12;

    NSString *folderName = tab.cwd.length ? tab.cwd : @"/";
    NSString *context = [NSString stringWithFormat:@"Ready · Folder: %@", folderName];
    NSColor *contextColor = [NSColor.labelColor colorWithAlphaComponent:0.76];
    if (mode == MicaUIModeTab) {
        context = @"Choose a tab";
    } else if (mode == MicaUIModeScroll) {
        context = @"Use arrows or j/k to scroll";
    } else if (tab.currentCommand.length &&
               [self activityStateForTab:tab] == MicaTabActivityStateWaiting) {
        NSString *tool = MicaAgentNameForTab(tab) ?: tab.currentCommand.lastPathComponent;
        context = [NSString stringWithFormat:@"Needs your input · %@", tool];
        contextColor = NSColor.systemOrangeColor;
    } else if (tab.currentCommand.length) {
        NSString *agent = MicaAgentNameForTab(tab);
        if (agent) {
            MicaTabActivityState agentState = [self activityStateForTab:tab];
            NSString *activity = agentState == MicaTabActivityStateIdle
                ? @"Ready" : (tab.agentActivityDetail.length
                    ? tab.agentActivityDetail : (tab.agentActivity.length ? tab.agentActivity : @"Starting"));
            context = [NSString stringWithFormat:@"%@ · %@", agent, activity];
            contextColor = agentState == MicaTabActivityStateRunning
                ? [NSColor.systemGreenColor blendedColorWithFraction:0.40 ofColor:NSColor.labelColor]
                : [NSColor.secondaryLabelColor colorWithAlphaComponent:0.85];
        } else if ([self activityStateForTab:tab] == MicaTabActivityStateIdle) {
            NSString *commandName = tab.currentCommand.lastPathComponent.length
                ? tab.currentCommand.lastPathComponent : tab.currentCommand;
            context = [NSString stringWithFormat:@"%@ · idle", commandName];
            contextColor = [NSColor.secondaryLabelColor colorWithAlphaComponent:0.85];
        } else {
            NSTimeInterval elapsed = MAX(0, NSProcessInfo.processInfo.systemUptime - tab.commandStartedAt);
            NSUInteger seconds = (NSUInteger)elapsed;
            NSString *commandName = tab.currentCommand.lastPathComponent.length ? tab.currentCommand.lastPathComponent : tab.currentCommand;
            context = [NSString stringWithFormat:@"Running %@ · %lu:%02lu", commandName,
                (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
            contextColor = [NSColor.systemGreenColor blendedColorWithFraction:0.40 ofColor:NSColor.labelColor];
        }
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

    NSArray<NSString *> *hintParts = @[@"⌘/ Shortcuts", @"⌥ Dictate", @"⌘1–8 Switch tab",
        @"⌘T New tab", @"⌘Q Quit"];
    NSDictionary *hintAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5],
        NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:0.70]
    };
    NSFont *hintFont = hintAttrs[NSFontAttributeName];
    CGFloat hintWidth = 0;
    CGFloat hintRight = self.bounds.size.width - 12;
    // Drop trailing hints that would run over the context text at narrow widths.
    while (hintParts.count > 1) {
        hintWidth = (hintParts.count - 1) * 16;
        for (NSString *part in hintParts) hintWidth += [part sizeWithAttributes:hintAttrs].width;
        if (hintRight - hintWidth >= contextX + 18) break;
        hintParts = [hintParts subarrayWithRange:NSMakeRange(0, hintParts.count - 1)];
    }
    if (hintParts.count == 1) hintWidth = [hintParts[0] sizeWithAttributes:hintAttrs].width;
    CGFloat hintX = MAX(contextX + 18, hintRight - hintWidth);
    CGFloat availableWidth = MAX(0, hintX - contextX - 18);
    if (!modeName && !tab.currentCommand.length && !tab.completedCommand && viewOffset == 0) {
        NSString *folderLabel = @"Ready · ";
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

- (void)drawDictationStatusBar:(MicaVoiceController *)voice inRect:(NSRect)status {
    MicaVoiceControllerState state = voice.state;
    NSColor *accent = state == MicaVoiceControllerStateFailed ? NSColor.systemRedColor : NSColor.controlAccentColor;
    NSString *statusText = voice.statusText ?: @"";
    if (state == MicaVoiceControllerStateListening) {
        NSUInteger seconds = (NSUInteger)MAX(0, voice.elapsedSeconds);
        statusText = [NSString stringWithFormat:@"Listening · %02lu:%02lu",
                  (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
    } else if (state == MicaVoiceControllerStatePreparing) {
        statusText = @"Preparing speech…";
    } else if (state == MicaVoiceControllerStateTranscribing) {
        statusText = @"Finishing transcript…";
    } else if (state == MicaVoiceControllerStateFailed) {
        statusText = @"Dictation failed · Esc to dismiss";
    }

    NSDictionary *statusAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: state == MicaVoiceControllerStateFailed
            ? NSColor.systemRedColor : NSColor.labelColor
    };
    CGFloat centerY = NSMidY(status);
    if (state == MicaVoiceControllerStateListening && voice.transcript.length == 0) {
        for (NSInteger bar = 0; bar < 4; bar++) {
            CGFloat phase = NSProcessInfo.processInfo.systemUptime * 5.0 + bar * 0.8;
            CGFloat barHeight = 4 + (sin(phase) + 1.0) * 5.0;
            NSRect wave = NSMakeRect(13 + bar * 4.5, centerY - barHeight / 2.0, 2.5, barHeight);
            [accent setFill];
            [[NSBezierPath bezierPathWithRoundedRect:wave xRadius:1.2 yRadius:1.2] fill];
        }
    } else {
        NSBezierPath *micDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(15, centerY - 3, 6, 6)];
        [accent setFill];
        [micDot fill];
    }
    [statusText drawAtPoint:NSMakePoint(38,
        MicaCenteredTextBaseline(statusAttrs[NSFontAttributeName], status.size.height))
        withAttributes:statusAttrs];

    NSString *text = voice.transcript.length ? voice.transcript :
        (state == MicaVoiceControllerStateFailed ? (voice.statusText ?: @"Press Escape to dismiss") :
            (state == MicaVoiceControllerStateListening ? @"Speak to see your words here" : @""));
    NSMutableParagraphStyle *tailStyle = [NSMutableParagraphStyle new];
    tailStyle.lineBreakMode = NSLineBreakByTruncatingHead;
    NSDictionary *transcriptAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5],
        NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:0.82],
        NSParagraphStyleAttributeName: tailStyle
    };
    CGFloat transcriptX = 205;
    NSRect transcriptRect = NSMakeRect(transcriptX, 0,
        MAX(0, status.size.width - transcriptX - 12), status.size.height);
    [text drawInRect:transcriptRect withAttributes:transcriptAttrs];

    BOOL showsActivity = state == MicaVoiceControllerStatePreparing ||
        state == MicaVoiceControllerStateTranscribing;
    if (voice.hasProgress || showsActivity) {
        NSRect track = NSMakeRect(0, 0, status.size.width, 2);
        [[accent colorWithAlphaComponent:0.16] setFill];
        NSRectFill(track);
        NSRect fill = track;
        if (voice.hasProgress) {
            fill.size.width *= voice.progress;
        } else {
            CGFloat segmentWidth = MIN(100, track.size.width * 0.2);
            CGFloat travel = MAX(0, track.size.width - segmentWidth);
            CGFloat phase = fmod(NSProcessInfo.processInfo.systemUptime / 1.25, 2.0);
            if (phase > 1.0) phase = 2.0 - phase;
            fill.origin.x += travel * phase;
            fill.size.width = segmentWidth;
        }
        [accent setFill];
        NSRectFill(fill);
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
        if (event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49) {
            self.owner.uiMode = MicaUIModeNormal;
        } else if (key.length == 1 && key.integerValue >= 1 && key.integerValue <= 9 &&
            [key characterAtIndex:0] >= '1' && [key characterAtIndex:0] <= '9') {
            if ((NSUInteger)key.integerValue <= self.owner.tabs.count) {
                [self.owner selectTabAtIndex:key.integerValue - 1];
                self.owner.uiMode = MicaUIModeNormal;
            }
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
    NSTimeInterval drawStartedAt = NSProcessInfo.processInfo.systemUptime;
    [self updateTabToolTip];
    [self syncSelectionWithHistory];
    [MicaBackgroundColor() setFill];
    NSRectFill(NSIntersectionRect(dirtyRect, self.bounds));
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) {
        [self recordDrawDuration:NSProcessInfo.processInfo.systemUptime - drawStartedAt];
        return;
    }

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
            NSRect textRect = NSMakeRect(NSMinX(tabRect) + 28, NSMinY(tabRect) + 2,
                                         MAX(0, tabRect.size.width - 36), tabRect.size.height - 4);
            if (active) {
                NSRect selectedTab = NSInsetRect(tabRect, 3, 3);
                [[NSColor.controlAccentColor colorWithAlphaComponent:0.20] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:selectedTab xRadius:7 yRadius:7] fill];
            }
            [self drawActivityIndicatorForTab:candidate at:NSMakePoint(NSMinX(tabRect) + 15,
                NSMidY(tabRect))];
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
        if (self.owner.projectName.length) {
            CGFloat badgeWidth = [self projectBadgeWidth];
            NSRect badge = NSMakeRect(self.bounds.size.width - badgeWidth,
                NSMinY(header), badgeWidth, header.size.height);
            NSBezierPath *divider = [NSBezierPath bezierPath];
            [divider moveToPoint:NSMakePoint(NSMinX(badge) + 0.5, NSMinY(header) + 6)];
            [divider lineToPoint:NSMakePoint(NSMinX(badge) + 0.5, NSMaxY(header) - 6)];
            [divider stroke];
            NSMutableParagraphStyle *projectStyle = [NSMutableParagraphStyle new];
            projectStyle.lineBreakMode = NSLineBreakByTruncatingTail;
            NSDictionary *projectAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:kTabTitleFontSize weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
                NSParagraphStyleAttributeName: projectStyle
            };
            NSRect projectText = NSInsetRect(badge, 10, 2);
            NSString *projectTitle = MicaTruncatedText(self.owner.projectName,
                projectText.size.width, projectAttrs);
            [projectTitle drawInRect:projectText withAttributes:projectAttrs];
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
                NSForegroundColorAttributeName: [MicaForegroundColor() colorWithAlphaComponent:0.6]
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
            BOOL linked = cell.hyperlink_id != 0;
            if (linked && !selected) fg = [NSColor colorWithSRGBRed:0.45 green:0.68 blue:1.0 alpha:1.0];  // readable on the fixed dark terminal
            if (cell.attrs.reverse) { NSColor *swap = fg; fg = bg; bg = swap; }
            if (selected) {
                fg = NSColor.selectedTextColor;
                bg = NSColor.selectedTextBackgroundColor;
            }
            BOOL hasBackground = selected || cell.attrs.reverse || !VTERM_COLOR_IS_DEFAULT_BG(&cell.bg);
            NSRect cellRect = [self cellRectAtRow:row col:col];
            // Snap to device pixels so adjacent colored cells meet without hairline seams on Retina.
            if (hasBackground) { [bg setFill]; NSRectFill([self backingAlignedRect:cellRect options:NSAlignAllEdgesNearest]); }
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
                BOOL underline = cell.attrs.underline || linked;
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
            if (cell.attrs.underline || linked) glyphAttrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
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
        NSDictionary *exitAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: [MicaForegroundColor() colorWithAlphaComponent:0.6] };
        if (NSIntersectsRect(exitRect, dirtyRect))
            [exitMessage drawAtPoint:NSMakePoint(12, kStatusHeight + 4) withAttributes:exitAttrs];
    }
    NSRect status = NSMakeRect(0, 0, self.bounds.size.width, kStatusHeight);
    if (NSIntersectsRect(status, dirtyRect)) [self drawStatusBarForTab:tab];
    (void)dirtyRect;
    [self recordDrawDuration:NSProcessInfo.processInfo.systemUptime - drawStartedAt];
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
        if ([keyString isEqualToString:@"q"]) { [NSApp terminate:nil]; return; }
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
        if ([keyString isEqualToString:@"+"] || [keyString isEqualToString:@"="]) { self.terminalFont = MicaTerminalFont(MIN(28, self.terminalFont.pointSize + 1)); [self.owner resizeActiveSession]; return; }
        if ([keyString isEqualToString:@"-"]) { self.terminalFont = MicaTerminalFont(MAX(8, self.terminalFont.pointSize - 1)); [self.owner resizeActiveSession]; return; }
        return;
    }
    if (!tab.session) return;
    if (event.keyCode == 53 && mica_session_view_offset(tab.session) > 0) {
        mica_session_scroll_to_bottom(tab.session);
        _selecting = NO;
        [self setNeedsDisplay:YES];
        return;
    }
    [self.owner wakePollTimer];
    if ([self hasMarkedText]) {
        // While an input method is composing, it owns Enter, Backspace, Esc and the arrows.
        _imeTab = tab;
        [self interpretKeyEvents:@[event]];
        _imeTab = nil;
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
    // Option dead keys (Option+E on US layouts) produce no characters yet; let the input system compose them.
    if ((!option && !control) || (option && !control && event.characters.length == 0)) {
        // Plain typing goes through the text input system so dead keys and IMEs compose.
        _imeTab = tab;
        [self interpretKeyEvents:@[event]];
        _imeTab = nil;
        _selecting = NO;
        _selectionPending = NO;
        return;
    }
    NSString *characters = control ? event.charactersIgnoringModifiers : event.characters;
    // On layouts where Option composes ASCII punctuation (@ # [ ] { } on Italian, German,
    // Spanish), send that character as typed instead of an ESC-prefixed Meta key.
    if (option && !control && characters.length == 1) {
        unichar composed = [characters characterAtIndex:0];
        if (composed >= 0x21 && composed <= 0x7e &&
            ![characters isEqualToString:event.charactersIgnoringModifiers]) modifiers &= ~VTERM_MOD_ALT;
    }
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
    [self.owner wakePollTimer];
    MicaTab *tab = self.owner.activeTab;
    if (!tab.session) return;
    // Notched mouse wheels report line deltas (about 1 per notch), trackpads report pixels.
    _scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 24.0;
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
    [self.owner wakePollTimer];
    if (_selecting) {
        [self clearSelection];
        [self setNeedsDisplay:YES];
    }
    [self.window makeFirstResponder:self];
    if (_leftOptionIsDown && !_leftOptionStartedDictation) {
        _leftOptionUsedWithAnotherKey = YES;
        [_leftOptionTimer invalidate];
        _leftOptionTimer = nil;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect timerControl = [self pomodoroControlRect];
    if (NSPointInRect(point, timerControl)) {
        if (point.x >= NSMaxX(timerControl) - 29) [self.owner resetPomodoro:nil];
        else [self.owner togglePomodoroPause:nil];
        return;
    }
    NSRect dictationStatus = [self dictationStatusRect];
    if (!NSIsEmptyRect(dictationStatus) && NSPointInRect(point, dictationStatus)) return;
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
    BOOL commandClick = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    if (commandClick) {
        MicaCell hit;
        if (mica_session_get_cell(self.owner.activeTab.session, (int)cell.y, (int)cell.x, &hit) &&
            hit.hyperlink_id) {
            [self openHyperlinkID:hit.hyperlink_id forTab:self.owner.activeTab];
            return;
        }
    }
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
    _selectionSession = self.owner.activeTab.session;
    _selectionHistoryLines = _selectionSession ? mica_session_scrolled_lines(_selectionSession) : 0;
}

// New output scrolls lines into history; move the selection up with its text.
- (void)syncSelectionWithHistory {
    if (!_selecting && !_selectionPending) return;
    MicaSession *session = self.owner.activeTab.session;
    if (!session || session != _selectionSession) { [self clearSelection]; return; }
    uint64_t current = mica_session_scrolled_lines(session);
    if (current == _selectionHistoryLines) return;
    if (mica_session_view_offset(session) == 0 && current > _selectionHistoryLines) {
        CGFloat shift = (CGFloat)(current - _selectionHistoryLines) * _lineHeight;
        _selectionStart.y += shift;
        _selectionEnd.y += shift;
        if (MAX(_selectionStart.y, _selectionEnd.y) > NSMaxY(self.bounds)) { [self clearSelection]; return; }
    } else if (current < _selectionHistoryLines) {
        [self clearSelection];
    }
    _selectionHistoryLines = current;
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, [self pomodoroControlRect])) {
        [self showPomodoroControlMenu:nil];
        return;
    }
    [super rightMouseDown:event];
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
    // Repaint only the band of rows the selection can have changed, not the whole terminal.
    CGFloat oldEndY = _selecting ? _selectionEnd.y : _selectionStart.y;
    _selecting = YES;
    _selectionPending = NO;
    _selectionEnd = point;
    CGFloat low = MIN(MIN(oldEndY, point.y), _selectionStart.y) - _lineHeight;
    CGFloat high = MAX(MAX(oldEndY, point.y), _selectionStart.y) + _lineHeight;
    [self setNeedsDisplayInRect:NSMakeRect(0, low, self.bounds.size.width, high - low)];
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
    [self syncSelectionWithHistory];
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
    [self.owner wakePollTimer];
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
    // Apps such as browsers put both text and an image on the pasteboard; text wins.
    BOOL hasText = [pasteboard.types containsObject:NSPasteboardTypeString];
    for (NSPasteboardType imageType in hasText ? @[] : imageTypes) {
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
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self scheduleGridResize]; }
@end

static NSDictionary *MicaResolveLaunchConfiguration(NSArray<NSString *> *args, NSDictionary *bundleInfo,
                                                     NSString *defaultCwd) {
    id bundledProjectName = bundleInfo[@"MicaProjectName"];
    NSString *projectName = [bundledProjectName isKindOfClass:NSString.class] ? bundledProjectName : @"";
    id bundledLayoutPath = bundleInfo[@"MicaProjectLayout"];
    NSString *layoutPath = [bundledLayoutPath isKindOfClass:NSString.class] ? bundledLayoutPath : @"";
    NSString *cwd = defaultCwd.length ? defaultCwd : NSFileManager.defaultManager.currentDirectoryPath;
    NSString *command = @"";
    __block NSString *layoutProjectName = @"";
    for (NSUInteger i = 1; i + 1 < args.count; i++) {
        if ([args[i] isEqualToString:@"--layout"]) layoutPath = args[++i];
        else if ([args[i] isEqualToString:@"--project-name"]) projectName = args[++i];
        else if ([args[i] isEqualToString:@"--cwd"]) cwd = args[++i];
        else if ([args[i] isEqualToString:@"--command"]) command = args[++i];
    }

    NSMutableArray<NSDictionary *> *tabs = [NSMutableArray array];
    if (layoutPath.length) {
        NSString *contents = [NSString stringWithContentsOfFile:layoutPath encoding:NSUTF8StringEncoding error:nil];
        [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            (void)stop;
            if ([line hasPrefix:@"# Mica project: "]) {
                layoutProjectName = [line substringFromIndex:[@"# Mica project: " length]];
                return;
            }
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
    if (layoutProjectName.length) projectName = layoutProjectName;
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

@implementation MicaProjectSettingsController
- (instancetype)initWithOwner:(MicaAppDelegate *)owner {
    self = [super initWithWindow:nil];
    if (!self) return nil;
    self.appDelegate = owner;
    self.rows = [NSMutableArray array];
    NSString *layout = owner.projectLayoutPath;
    NSString *contents = [NSString stringWithContentsOfFile:layout encoding:NSUTF8StringEncoding error:nil] ?: @"";
    self.originalLayoutContents = contents;
    [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if (!line.length || [line hasPrefix:@"#"]) return;
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
        if (parts.count < 2) return;
        NSMutableArray<NSString *> *row = [NSMutableArray arrayWithObjects:parts[0], parts[1], @"", nil];
        if (parts.count > 2) row[2] = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@"\t"];
        [self.rows addObject:row];
    }];

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 510)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Project Settings";
    window.releasedWhenClosed = NO;
    self.window = window;
    NSView *content = window.contentView;

    NSTextField *nameLabel = [NSTextField labelWithString:@"Project name"];
    self.projectNameField = [NSTextField textFieldWithString:owner.projectName ?: @""];
    NSTextField *tabsLabel = [NSTextField labelWithString:@"Startup tabs — changes take effect the next time this project opens"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.gridStyleMask = NSTableViewSolidHorizontalGridLineMask | NSTableViewSolidVerticalGridLineMask;
    self.tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    NSArray<NSString *> *titles = @[@"Tab name", @"Working folder", @"Startup command (optional)"];
    NSArray<NSString *> *identifiers = @[@"name", @"folder", @"command"];
    NSArray<NSNumber *> *widths = @[@140, @300, @260];
    for (NSUInteger index = 0; index < identifiers.count; index++) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifiers[index]];
        column.title = titles[index];
        column.width = widths[index].doubleValue;
        column.editable = YES;
        [self.tableView addTableColumn:column];
    }
    scroll.documentView = self.tableView;
    NSButton *addButton = [NSButton buttonWithTitle:@"Add Tab" target:self action:@selector(addTab:)];
    NSButton *removeButton = [NSButton buttonWithTitle:@"Remove Tab" target:self action:@selector(removeTab:)];
    NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    NSButton *saveButton = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
    saveButton.keyEquivalent = @"\r";
    cancelButton.keyEquivalent = @"\033";

    for (NSView *view in @[nameLabel, self.projectNameField, tabsLabel, scroll, addButton,
                           removeButton, cancelButton, saveButton]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [nameLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [nameLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [self.projectNameField.leadingAnchor constraintEqualToAnchor:nameLabel.trailingAnchor constant:14],
        [self.projectNameField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.projectNameField.centerYAnchor constraintEqualToAnchor:nameLabel.centerYAnchor],
        [tabsLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [tabsLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:22],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [scroll.topAnchor constraintEqualToAnchor:tabsLabel.bottomAnchor constant:8],
        [scroll.bottomAnchor constraintEqualToAnchor:addButton.topAnchor constant:-12],
        [addButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [addButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18],
        [removeButton.leadingAnchor constraintEqualToAnchor:addButton.trailingAnchor constant:8],
        [removeButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor],
        [saveButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [saveButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor],
        [cancelButton.trailingAnchor constraintEqualToAnchor:saveButton.leadingAnchor constant:-8],
        [cancelButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor]
    ]];
    return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return (NSInteger)self.rows.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    NSUInteger field = [@{@"name": @0, @"folder": @1, @"command": @2}[column.identifier] unsignedIntegerValue];
    return self.rows[(NSUInteger)row][field];
}
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    NSNumber *field = @{@"name": @0, @"folder": @1, @"command": @2}[column.identifier];
    if (field && row >= 0 && row < (NSInteger)self.rows.count)
        self.rows[(NSUInteger)row][field.unsignedIntegerValue] = [value isKindOfClass:NSString.class] ? value : @"";
}
- (void)addTab:(id)sender {
    (void)sender;
    NSString *folder = self.rows.lastObject.count > 1 ? self.rows.lastObject[1] : NSFileManager.defaultManager.currentDirectoryPath;
    [self.rows addObject:[NSMutableArray arrayWithObjects:@"Shell", folder, @"", nil]];
    [self.tableView reloadData];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:self.rows.count - 1] byExtendingSelection:NO];
    [self.tableView editColumn:0 row:(NSInteger)self.rows.count - 1 withEvent:nil select:YES];
}
- (void)removeTab:(id)sender {
    (void)sender;
    NSInteger selected = self.tableView.selectedRow;
    if (selected < 0 || selected >= (NSInteger)self.rows.count) return;
    [self.rows removeObjectAtIndex:(NSUInteger)selected];
    [self.tableView reloadData];
}
- (void)cancel:(id)sender {
    (void)sender;
    [self.appDelegate.window endSheet:self.window returnCode:NSModalResponseCancel];
    [self.window orderOut:nil];
}
- (BOOL)layoutChangedOnDisk {
    NSURL *url = [NSURL fileURLWithPath:self.appDelegate.projectLayoutPath];
    NSString *current = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    return !current || ![current isEqualToString:self.originalLayoutContents ?: @""];
}
- (void)save:(id)sender {
    (void)sender;
    [self.tableView.window makeFirstResponder:self.tableView];
    NSString *name = [self.projectNameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || [name rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
        [name containsString:@"\t"] || [name rangeOfString:@"\0"].location != NSNotFound) {
        [self showError:@"Enter a project name on one line without tab characters."];
        return;
    }
    if (self.rows.count == 0) {
        [self showError:@"A project layout must contain at least one startup tab."];
        return;
    }
    NSMutableString *contents = [NSMutableString stringWithFormat:@"# Mica layout v1\n# Mica project: %@\n", name];
    [self.originalLayoutContents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if ([line hasPrefix:@"#"] && ![line hasPrefix:@"# Mica layout v"] &&
            ![line hasPrefix:@"# Mica project: "] && ![line hasPrefix:@"# Mica focus-minutes: "] &&
            ![line hasPrefix:@"# Mica break-minutes: "])
            [contents appendFormat:@"%@\n", line];
    }];
    for (NSUInteger index = 0; index < self.rows.count; index++) {
        NSArray<NSString *> *row = self.rows[index];
        NSString *tabName = [row[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *folder = [row[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *command = row[2];
        if (!tabName.length || !folder.length ||
            [tabName rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
            [folder rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
            [command rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
            [tabName hasPrefix:@"#"] || [tabName containsString:@"\t"] || [folder containsString:@"\t"] ||
            [tabName rangeOfString:@"\0"].location != NSNotFound || [folder rangeOfString:@"\0"].location != NSNotFound ||
            [command rangeOfString:@"\0"].location != NSNotFound) {
            [self showError:[NSString stringWithFormat:@"Tab %lu has an empty name or folder, or contains an unsupported tab/newline.", (unsigned long)(index + 1)]];
            return;
        }
        NSString *expandedFolder = folder.stringByExpandingTildeInPath;
        BOOL isDirectory = NO;
        if (![expandedFolder isAbsolutePath] || ![NSFileManager.defaultManager fileExistsAtPath:expandedFolder isDirectory:&isDirectory] || !isDirectory) {
            [self showError:[NSString stringWithFormat:@"The working folder for “%@” must be an existing folder.", tabName]];
            return;
        }
        [contents appendFormat:@"%@\t%@\t%@\n", tabName, expandedFolder, command];
    }
    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:self.appDelegate.projectLayoutPath];
    if ([self layoutChangedOnDisk]) {
        [self showError:@"This project layout changed after these settings were opened. Close this sheet, reopen Project Settings, and apply your edits to the latest version."];
        return;
    }
    if (![contents writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self showError:error.localizedDescription ?: @"Mica could not save the project layout."];
        return;
    }
    self.appDelegate.projectName = name;
    [self.appDelegate updateWindowTitle];
    [self.appDelegate.window endSheet:self.window returnCode:NSModalResponseOK];
    [self.window orderOut:nil];
}
- (void)showError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Project settings could not be saved";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
@end

@implementation MicaAppDelegate
- (NSString *)windowTitleForTab:(MicaTab *)tab {
    NSString *tabName = tab.name.length ? tab.name : @"Terminal";
    if (self.projectName.length) return [NSString stringWithFormat:@"%@ — %@", self.projectName, tabName];
    return @"Mica Terminal";
}

- (void)finishTerminationWhenCleanupCompletes:(NSTimer *)timer {
    (void)timer;
    if (!self.terminationCleanupGroup ||
        dispatch_group_wait(self.terminationCleanupGroup, DISPATCH_TIME_NOW) != 0) return;
    [self.terminationReplyTimer invalidate];
    self.terminationReplyTimer = nil;
    MicaDiagnosticsLog(@"shutdown", @"all session cleanup complete; replying to AppKit");
    [NSApp replyToApplicationShouldTerminate:YES];
}

- (BOOL)acquirePomodoroLock {
    if (self.pomodoroOwnsLock) return YES;
    if (!self.pomodoroLockURL) return NO;
    NSError *error = nil;
    NSURL *directory = [self.pomodoroLockURL URLByDeletingLastPathComponent];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:&error]) return NO;
    int fd = open(self.pomodoroLockURL.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return NO;
    // Never block the main thread on another (possibly stopped) Mica instance.
    BOOL locked = NO;
    for (int attempt = 0; attempt < 10 && !locked; attempt++) {
        locked = flock(fd, LOCK_EX | LOCK_NB) == 0;
        if (!locked) usleep(5000);
    }
    if (!locked) { close(fd); return NO; }
    self.pomodoroLockFD = fd;
    self.pomodoroOwnsLock = YES;
    return YES;
}

- (void)releasePomodoroLock {
    if (self.pomodoroOwnsLock && self.pomodoroLockFD >= 0) {
        flock(self.pomodoroLockFD, LOCK_UN);
        close(self.pomodoroLockFD);
    }
    self.pomodoroLockFD = -1;
    self.pomodoroOwnsLock = NO;
}

- (void)loadPomodoroSettingsFromDisk {
    NSDictionary *settings = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfURL:self.pomodoroSettingsURL] ?: NSData.data
        options:0 error:nil];
    NSInteger focus = [settings[@"focusMinutes"] integerValue];
    NSInteger pause = [settings[@"breakMinutes"] integerValue];
    self.focusDurationMinutes = focus >= 1 && focus <= kMaximumFocusMinutes ? focus : kDefaultFocusMinutes;
    self.breakDurationMinutes = pause >= 1 && pause <= kMaximumBreakMinutes ? pause : kDefaultBreakMinutes;
}

- (BOOL)savePomodoroDurationsFocusMinutes:(NSInteger)focusMinutes breakMinutes:(NSInteger)breakMinutes {
    if (focusMinutes < 1 || focusMinutes > kMaximumFocusMinutes ||
        breakMinutes < 1 || breakMinutes > kMaximumBreakMinutes || ![self acquirePomodoroLock]) return NO;
    NSDictionary *settings = @{@"focusMinutes": @(focusMinutes), @"breakMinutes": @(breakMinutes)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:settings options:0 error:nil];
    BOOL saved = data && [data writeToURL:self.pomodoroSettingsURL options:NSDataWritingAtomic error:nil];
    if (saved) {
        self.focusDurationMinutes = focusMinutes;
        self.breakDurationMinutes = breakMinutes;
    }
    [self releasePomodoroLock];
    return saved;
}

- (void)savePomodoroState {
    if (!self.pomodoroOwnsLock || !self.pomodoroStateURL) return;
    if (self.pomodoro.phase == MICA_POMODORO_IDLE) {
        [NSFileManager.defaultManager removeItemAtURL:self.pomodoroStateURL error:nil];
        return;
    }
    double now = MicaContinuousTimeSeconds();
    NSMutableDictionary *state = [@{
        @"phase": @(self.pomodoro.phase),
        @"completedFocuses": @(self.pomodoro.completed_focuses),
        @"cycleFocusMinutes": @(self.pomodoroCycleFocusMinutes),
        @"cycleBreakMinutes": @(self.pomodoroCycleBreakMinutes)
    } mutableCopy];
    if (mica_pomodoro_is_running(&_pomodoro)) {
        state[@"deadline"] = @(NSDate.date.timeIntervalSince1970 + mica_pomodoro_remaining(&_pomodoro, now));
        state[@"continuousDeadline"] = @(self.pomodoro.deadline);
        state[@"bootSession"] = MicaBootSessionID();
    } else state[@"remaining"] = @(mica_pomodoro_remaining(&_pomodoro, now));
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (!data || ![data writeToURL:self.pomodoroStateURL options:NSDataWritingAtomic error:nil])
        MicaDiagnosticsLog(@"pomodoro", @"could not persist shared timer state");
}

- (void)loadPomodoroStateFromDisk {
    [self loadPomodoroSettingsFromDisk];
    NSData *data = [NSData dataWithContentsOfURL:self.pomodoroStateURL];
    NSDictionary *saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![saved isKindOfClass:NSDictionary.class]) { mica_pomodoro_reset(&_pomodoro); return; }
    NSInteger cycleFocus = [saved[@"cycleFocusMinutes"] integerValue];
    NSInteger cycleBreak = [saved[@"cycleBreakMinutes"] integerValue];
    self.pomodoroCycleFocusMinutes = cycleFocus >= 1 ? cycleFocus : self.focusDurationMinutes;
    self.pomodoroCycleBreakMinutes = cycleBreak >= 1 ? cycleBreak : self.breakDurationMinutes;
    MicaPomodoro restored = {0};
    restored.phase = (MicaPomodoroPhase)[saved[@"phase"] integerValue];
    restored.completed_focuses = [saved[@"completedFocuses"] unsignedLongLongValue];
    double now = MicaContinuousTimeSeconds();
    BOOL expired = NO;
    if (restored.phase == MICA_POMODORO_FOCUS || restored.phase == MICA_POMODORO_BREAK) {
        BOOL sameBoot = [saved[@"bootSession"] isEqualToString:MicaBootSessionID()];
        double left = sameBoot ? [saved[@"continuousDeadline"] doubleValue] - now
                               : [saved[@"deadline"] doubleValue] - NSDate.date.timeIntervalSince1970;
        restored.deadline = now + MAX(0, left);
        if (left <= 0) expired = mica_pomodoro_advance(&restored, now,
            self.pomodoroCycleFocusMinutes * 60.0, self.pomodoroCycleBreakMinutes * 60.0);
    } else if (restored.phase == MICA_POMODORO_PAUSED_FOCUS || restored.phase == MICA_POMODORO_PAUSED_BREAK) {
        restored.paused_remaining = MAX(0, [saved[@"remaining"] doubleValue]);
    } else mica_pomodoro_reset(&restored);
    self.pomodoro = restored;
    if (expired) [self savePomodoroState];
}

- (void)refreshPomodoroState {
    if (![self acquirePomodoroLock]) return;
    [self loadPomodoroStateFromDisk];
    BOOL running = mica_pomodoro_is_running(&_pomodoro);
    [self releasePomodoroLock];
    if (running) [self schedulePomodoroNotification];
}

- (void)configurePomodoro {
    NSURL *directory = nil;
#if defined(MICA_APP_NO_MAIN)
    directory = self.pomodoroStorageDirectoryOverride;
#endif
    if (!directory) {
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
            inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
        directory = [support URLByAppendingPathComponent:@"Mica/Pomodoro" isDirectory:YES];
    }
    self.pomodoroStateURL = [directory URLByAppendingPathComponent:@"timer.json"];
    self.pomodoroLockURL = [directory URLByAppendingPathComponent:@"timer.lock"];
    self.pomodoroSettingsURL = [directory URLByAppendingPathComponent:@"settings.json"];
    [self refreshPomodoroState];
}

- (NSString *)currentPomodoroNotificationIdentifier {
    NSString *phase = self.pomodoro.phase == MICA_POMODORO_FOCUS ? @"focus" : @"break";
    return [NSString stringWithFormat:@"com.megasoft78.mica.pomodoro.computer.%@.%llu", phase,
        self.pomodoro.completed_focuses];
}

- (void)schedulePomodoroNotification {
    if (!mica_pomodoro_is_running(&_pomodoro)) return;
#if defined(MICA_APP_NO_MAIN)
    return;
#else
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusAuthorized &&
            settings.authorizationStatus != UNAuthorizationStatusProvisional) return;
        double seconds = mica_pomodoro_remaining(&self->_pomodoro, MicaContinuousTimeSeconds());
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = self.pomodoro.phase == MICA_POMODORO_FOCUS ? @"Focus complete" : @"Break complete";
        content.body = self.pomodoro.phase == MICA_POMODORO_FOCUS
            ? [NSString stringWithFormat:@"Time for a %ld-minute break.", (long)self.pomodoroCycleBreakMinutes]
            : @"Break complete. Your next focus block is ready.";
        content.sound = UNNotificationSound.defaultSound;
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger
            triggerWithTimeInterval:MAX(1, seconds) repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:
            [self currentPomodoroNotificationIdentifier] content:content trigger:trigger];
        [center addNotificationRequest:request withCompletionHandler:nil];
    }];
#endif
}

- (void)startPomodoro:(id)sender {
    (void)sender;
    if (![self acquirePomodoroLock]) return;
    [self loadPomodoroStateFromDisk];
    double now = MicaContinuousTimeSeconds();
    if (mica_pomodoro_is_paused(&_pomodoro)) mica_pomodoro_toggle_pause(&_pomodoro, now);
    else if (self.pomodoro.phase == MICA_POMODORO_IDLE) {
        self.pomodoroCycleFocusMinutes = self.focusDurationMinutes;
        self.pomodoroCycleBreakMinutes = self.breakDurationMinutes;
        mica_pomodoro_start(&_pomodoro, now, self.pomodoroCycleFocusMinutes * 60.0);
    }
    [self savePomodoroState];
    [self releasePomodoroLock];
#if !defined(MICA_APP_NO_MAIN)
    [self requestPomodoroNotifications];
#endif
    [self schedulePomodoroNotification];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)togglePomodoroPause:(id)sender {
    (void)sender;
    if (![self acquirePomodoroLock]) return;
    [self loadPomodoroStateFromDisk];
#if !defined(MICA_APP_NO_MAIN)
    NSString *oldNotification = [self currentPomodoroNotificationIdentifier];
#endif
    BOOL changed = mica_pomodoro_toggle_pause(&_pomodoro, MicaContinuousTimeSeconds());
    if (changed) [self savePomodoroState];
    [self releasePomodoroLock];
    if (!changed) { [self startPomodoro:nil]; return; }
#if !defined(MICA_APP_NO_MAIN)
    [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[oldNotification]];
#endif
    [self schedulePomodoroNotification];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)resetPomodoro:(id)sender {
    (void)sender;
    if (![self acquirePomodoroLock]) return;
    [self loadPomodoroStateFromDisk];
#if !defined(MICA_APP_NO_MAIN)
    NSString *oldNotification = [self currentPomodoroNotificationIdentifier];
#endif
    mica_pomodoro_reset(&_pomodoro);
    [self savePomodoroState];
    [self releasePomodoroLock];
#if !defined(MICA_APP_NO_MAIN)
    [UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:@[oldNotification]];
#endif
    [self.terminalView setNeedsDisplay:YES];
}

- (void)updatePomodoroTimer {
    NSTimeInterval systemNow = NSProcessInfo.processInfo.systemUptime;
    if (systemNow - self.lastPomodoroTickAt < 1.0) return;
    self.lastPomodoroTickAt = systemNow;
    if (![self acquirePomodoroLock]) return;
    MicaPomodoroPhase oldPhase = self.pomodoro.phase;
    uint64_t oldCompletedFocuses = self.pomodoro.completed_focuses;
    [self loadPomodoroStateFromDisk];
    BOOL changed = oldPhase != self.pomodoro.phase || oldCompletedFocuses != self.pomodoro.completed_focuses;
    changed = mica_pomodoro_advance(&_pomodoro, MicaContinuousTimeSeconds(),
        self.pomodoroCycleFocusMinutes * 60.0, self.pomodoroCycleBreakMinutes * 60.0) || changed;
    if (changed) [self savePomodoroState];
    [self releasePomodoroLock];
    if (changed) {
        [self schedulePomodoroNotification];
        if (!NSApp.isActive && self.attentionRequest == 0)
            self.attentionRequest = [NSApp requestUserAttention:NSInformationalRequest];
    }
    if (self.pomodoro.phase != MICA_POMODORO_IDLE)
        [self.terminalView setNeedsDisplayInRect:NSMakeRect(0, 0, self.terminalView.bounds.size.width, kStatusHeight)];
}

- (void)requestPomodoroNotifications {
#if !defined(MICA_APP_NO_MAIN)
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    center.delegate = self;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) {
            if (error) MicaDiagnosticsLog(@"pomodoro", [NSString stringWithFormat:@"notification permission failed: %@", error]);
            if (granted) dispatch_async(dispatch_get_main_queue(), ^{ [self schedulePomodoroNotification]; });
        }];
#endif
}

- (void)openPomodoroSettings:(id)sender {
    (void)sender;
    [self refreshPomodoroState];
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 76)];
    NSTextField *focusLabel = [NSTextField labelWithString:@"Focus (minutes)"];
    NSTextField *breakLabel = [NSTextField labelWithString:@"Break (minutes)"];
    NSTextField *focusField = [NSTextField textFieldWithString:@(self.focusDurationMinutes).stringValue];
    NSTextField *breakField = [NSTextField textFieldWithString:@(self.breakDurationMinutes).stringValue];
    focusField.frame = NSMakeRect(205, 43, 65, 24); breakField.frame = NSMakeRect(205, 7, 65, 24);
    focusLabel.frame = NSMakeRect(0, 43, 190, 24); breakLabel.frame = NSMakeRect(0, 7, 190, 24);
    [accessory addSubview:focusLabel]; [accessory addSubview:focusField];
    [accessory addSubview:breakLabel]; [accessory addSubview:breakField];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Computer-wide Focus Timer";
    alert.informativeText = @"Every Mica window shares this timer. Changes apply to the next focus or break interval.";
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSInteger focus = MicaMinutesFromText(focusField.stringValue, 0, kMaximumFocusMinutes);
        NSInteger pause = MicaMinutesFromText(breakField.stringValue, 0, kMaximumBreakMinutes);
        if (![self savePomodoroDurationsFocusMinutes:focus breakMinutes:pause]) {
            NSAlert *error = [NSAlert new]; error.messageText = @"Enter valid timer lengths";
            error.informativeText = [NSString stringWithFormat:@"Focus: 1–%ld minutes. Break: 1–%ld minutes.",
                (long)kMaximumFocusMinutes, (long)kMaximumBreakMinutes];
            [error addButtonWithTitle:@"OK"]; [error beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (MicaTab *)activeTab {
    if (self.activeIndex < 0 || self.activeIndex >= (NSInteger)self.tabs.count) return nil;
    return self.tabs[(NSUInteger)self.activeIndex];
}

- (void)updateWindowTitle {
    if (self.window) self.window.title = [self windowTitleForTab:self.activeTab];
    if (!self.baseApplicationIcon)
        self.baseApplicationIcon = [NSImage imageNamed:NSImageNameApplicationIcon];
    // Rebuilding the Dock icon on every tab change allocates and flickers; only redo it when the project changes.
    if (!self.appliedIconProjectName || ![self.appliedIconProjectName isEqualToString:self.projectName ?: @""]) {
        self.appliedIconProjectName = self.projectName ?: @"";
        NSApp.applicationIconImage = MicaProjectApplicationIcon(self.baseApplicationIcon, self.projectName);
    }
    // Each project window remembers where it was last placed.
    if (self.window && self.projectName.length && !getenv("MICA_TEST_NO_STARTUP") && !self.window.frameAutosaveName.length)
        [self.window setFrameAutosaveName:[@"MicaWindow-" stringByAppendingString:self.projectName]];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    mica_session_set_cleanup_logger(MicaLogSessionCleanup);
    MicaDiagnosticsLog(@"launch", [NSString stringWithFormat:@"opened app=%@ bundle=%@ pid=%d",
        NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: @"Mica",
        NSBundle.mainBundle.bundleIdentifier ?: @"unknown", getpid()]);
    self.tabs = [NSMutableArray array];
    self.activeIndex = 0;
    self.pomodoroLockFD = -1;
    self.focusDurationMinutes = kDefaultFocusMinutes;
    self.breakDurationMinutes = kDefaultBreakMinutes;
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
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
    [self installMenus];
    self.uiMode = MicaUIModeNormal;
    [self loadLaunchConfiguration];
    // Show the window only after the project name restored its saved frame, so it never jumps.
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.terminalView];
    [self restartPollTimerWithInterval:0.015];
}

- (void)installMenus {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Mica"];
    NSMenuItem *appRoot = [[NSMenuItem alloc] initWithTitle:@"Mica" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Mica"];
    AddMenuItem(appMenu, @"About Mica", @selector(orderFrontStandardAboutPanel:), @"", 0);
    AddMenuItem(appMenu, @"New Instance", @selector(newInstance:), @"",
                NSEventModifierFlagCommand | NSEventModifierFlagOption).target = self;
    [appMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(appMenu, @"Hide Mica", @selector(hide:), @"h", NSEventModifierFlagCommand);
    AddMenuItem(appMenu, @"Hide Others", @selector(hideOtherApplications:), @"h",
                NSEventModifierFlagCommand | NSEventModifierFlagOption);
    AddMenuItem(appMenu, @"Show All", @selector(unhideAllApplications:), @"", 0);
    [appMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(appMenu, @"Quit Mica", @selector(terminate:), @"q", NSEventModifierFlagCommand);
    appRoot.submenu = appMenu;
    [main addItem:appRoot];
    NSMenuItem *focusRoot = [[NSMenuItem alloc] initWithTitle:@"Focus" action:nil keyEquivalent:@""];
    NSMenu *focusMenu = [[NSMenu alloc] initWithTitle:@"Focus"];
    AddMenuItem(focusMenu, @"Start / Resume Focus Timer", @selector(startPomodoro:), @"", 0).target = self;
    AddMenuItem(focusMenu, @"Pause / Resume Timer", @selector(togglePomodoroPause:), @"", 0).target = self;
    AddMenuItem(focusMenu, @"Reset Timer", @selector(resetPomodoro:), @"", 0).target = self;
    [focusMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(focusMenu, @"Timer Settings…", @selector(openPomodoroSettings:), @"", 0).target = self;
    focusRoot.submenu = focusMenu;
    [main addItem:focusRoot];
    NSMenuItem *projectRoot = [[NSMenuItem alloc] initWithTitle:@"Project" action:nil keyEquivalent:@""];
    NSMenu *projectMenu = [[NSMenu alloc] initWithTitle:@"Project"];
    AddMenuItem(projectMenu, @"Settings…", @selector(openProjectSettings:), @",", NSEventModifierFlagCommand).target = self;
    projectRoot.submenu = projectMenu;
    [main addItem:projectRoot];
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
    NSMenuItem *windowRoot = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    AddMenuItem(windowMenu, @"Minimize", @selector(performMiniaturize:), @"m", NSEventModifierFlagCommand);
    AddMenuItem(windowMenu, @"Zoom", @selector(performZoom:), @"", 0);
    AddMenuItem(windowMenu, @"Enter Full Screen", @selector(toggleFullScreen:), @"f",
                NSEventModifierFlagCommand | NSEventModifierFlagControl);
    [windowMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(windowMenu, @"Bring All to Front", @selector(arrangeInFront:), @"", 0);
    windowRoot.submenu = windowMenu;
    [main addItem:windowRoot];
    NSApp.windowsMenu = windowMenu;
    NSMenuItem *helpRoot = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    AddMenuItem(helpMenu, @"Keyboard Shortcuts…", @selector(showKeyboardShortcuts:), @"/",
                NSEventModifierFlagCommand).target = self;
    [helpMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(helpMenu, @"Open Diagnostic Logs", @selector(openDiagnosticLogs:), @"", 0).target = self;
    helpRoot.submenu = helpMenu;
    [main addItem:helpRoot];
    NSApp.helpMenu = helpMenu;
    [NSApp setMainMenu:main];
}

- (void)showKeyboardShortcuts:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Keyboard Shortcuts";
    alert.informativeText = [@[
        @"⌘Q  Quit Mica",
        @"⌘T  New shell tab",
        @"⌘W  Close tab",
        @"⌘1–8  Switch to tab",
        @"⌘9  Switch to last tab",
        @"⌘⇧P  Choose tab",
        @"⌘⇧S  Browse scrollback",
        @"⌘⇧[ / ⌘⇧]  Previous / next tab",
        @"⌘+ / ⌘−  Increase / decrease font size",
        @"⌘-click  Open an OSC 8 web link",
        @"Hold left ⌥  Dictate; release to finish",
        @"Esc  Cancel dictation or return to live terminal"
    ] componentsJoinedByString:@"\n"];
    [alert addButtonWithTitle:@"Done"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
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

- (void)openProjectSettings:(id)sender {
    (void)sender;
    if (!self.projectLayoutPath.length) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"This window has no project layout";
        alert.informativeText = @"Open Mica with a project .mica layout to edit its startup tabs.";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    MicaProjectSettingsController *settings = [[MicaProjectSettingsController alloc] initWithOwner:self];
    self.projectSettingsController = settings;
    [self.window beginSheet:settings.window completionHandler:^(NSModalResponse returnCode) {
        (void)returnCode;
        self.projectSettingsController = nil;
    }];
}

- (void)loadLaunchConfiguration {
    [self loadLaunchConfigurationFromArguments:NSProcessInfo.processInfo.arguments
                                    bundleInfo:NSBundle.mainBundle.infoDictionary];
}

- (void)loadLaunchConfigurationFromArguments:(NSArray<NSString *> *)args bundleInfo:(NSDictionary *)bundleInfo {
    NSDictionary *configuration = MicaResolveLaunchConfiguration(args, bundleInfo,
        NSFileManager.defaultManager.currentDirectoryPath);
    NSString *projectName = configuration[@"projectName"];
    self.projectLayoutPath = configuration[@"layoutPath"];
    self.projectName = projectName.length ? projectName : nil;
    [self updateWindowTitle];
    [self configurePomodoro];
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

- (void)resizeActiveSession {
    [self.terminalView.gridResizeTimer invalidate];
    self.terminalView.gridResizeTimer = nil;
    self.terminalView.gridResizeEventCount = 0;
    self.terminalView.gridResizeStartedAt = 0;
    [self.terminalView updateGridSize];
    [self.terminalView setNeedsDisplay:YES];
}
- (void)newShell:(id)sender { (void)sender; [self newTabWithName:@"Shell" command:nil]; }
- (void)closeTab:(id)sender { (void)sender; [self closeActiveTab]; }
- (void)nextTab:(id)sender { (void)sender; [self selectRelativeTab:1]; }
- (void)previousTab:(id)sender { (void)sender; [self selectRelativeTab:-1]; }

- (void)newInstance:(id)sender {
    (void)sender;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[@"-n", NSBundle.mainBundle.bundleURL.path];
    task.terminationHandler = ^(NSTask *finishedTask) {
        MicaDiagnosticsLog(@"launch", [NSString stringWithFormat:
            @"new-instance open exited status=%d reason=%@",
            finishedTask.terminationStatus,
            finishedTask.terminationReason == NSTaskTerminationReasonExit ? @"exit" : @"signal"]);
    };
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
    // Progress ticks repaint only the status strip; a state change may alter layout.
    NSInteger state = (NSInteger)controller.state;
    if (state != self.lastVoiceState) {
        self.lastVoiceState = state;
        [self.terminalView setNeedsDisplay:YES];
    } else {
        [self.terminalView setNeedsDisplayInRect:[self.terminalView dictationStatusRect]];
    }
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
    MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"tab closed name=%@ folder=%@ pid=%d",
        previous.name ?: @"Terminal", previous.cwd ?: @"unknown",
        previous.session ? mica_session_pid(previous.session) : -1]);
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

- (void)restartPollTimerWithInterval:(NSTimeInterval)interval {
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(pollSessions:) userInfo:nil repeats:YES];
    self.pollTimer.tolerance = interval / 3.0;
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
    self.pollIsSlow = interval > 0.02;
}

// Typing or new output returns polling to full speed after an idle stretch.
- (void)wakePollTimer {
    self.idlePollTicks = 0;
    if (self.pollIsSlow && self.pollTimer) [self restartPollTimerWithInterval:0.015];
}

- (void)pollSessions:(NSTimer *)timer {
    (void)timer;
    BOOL redraw = NO;
    // Idle backoff: after ~5 s without output, poll at 50 ms instead of 15 ms.
    BOOL justWoke = NO;
    if (self.pollSawOutput) { self.pollSawOutput = NO; justWoke = self.pollIsSlow; [self wakePollTimer]; }
    else if (!self.pollIsSlow && ++self.idlePollTicks > 330 && self.pollTimer) [self restartPollTimerWithInterval:0.050];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    MicaVoiceController *voice = self.voiceController;
    if (voice.state == MicaVoiceControllerStateListening && voice.transcript.length == 0 &&
        now - gLastVoiceAnimationAt >= 0.10) {
        gLastVoiceAnimationAt = now;
        [self.terminalView setNeedsDisplayInRect:[self.terminalView dictationStatusRect]];
    }
    NSTimeInterval pollStartedAt = now;
    if (!justWoke && self.lastPollTimerTickAt > 0 && now - self.lastPollTimerTickAt >= (self.pollIsSlow ? 0.150 : 0.050) &&
        now - self.lastSlowPollLogAt >= 1.0) {
        MicaDiagnosticsLog(@"performance", [NSString stringWithFormat:
            @"poll-timer-gap duration_ms=%.1f tabs=%lu", (now - self.lastPollTimerTickAt) * 1000.0,
            (unsigned long)self.tabs.count]);
        self.lastSlowPollLogAt = now;
    }
    self.lastPollTimerTickAt = now;
    [self updatePomodoroTimer];
    for (MicaTab *tab in self.tabs) {
        if (!tab.session) continue;
        NSTimeInterval tabPollStartedAt = NSProcessInfo.processInfo.systemUptime;
        mica_session_poll(tab.session, 0);
        NSTimeInterval tabPollEndedAt = NSProcessInfo.processInfo.systemUptime;
        MicaSessionOutputMetrics outputMetrics = {0};
        BOOL receivedOutput = mica_session_take_output_metrics(tab.session, &outputMetrics);
        if (tab.outputMetricsStartedAt == 0) tab.outputMetricsStartedAt = now;
        tab.outputPollMilliseconds += (tabPollEndedAt - tabPollStartedAt) * 1000.0;
        if (receivedOutput) {
            self.pollSawOutput = YES;
            tab.outputBytes += outputMetrics.bytes_read;
            tab.outputReadCalls += outputMetrics.read_calls;
            tab.outputLargestRead = MAX(tab.outputLargestRead, outputMetrics.largest_read);
            tab.outputParseMilliseconds += outputMetrics.parse_milliseconds;
            tab.lastOutputReadAt = tabPollEndedAt;
        }
        NSTimeInterval outputWindow = now - tab.outputMetricsStartedAt;
        if (outputWindow >= 1.0) {
            if (tab.outputBytes) {
                MicaDiagnosticsLog(@"performance", [NSString stringWithFormat:
                    @"pty-output tab=%@ pid=%d bytes_per_sec=%.0f reads_per_sec=%.1f largest_read=%lu parse_ms=%.2f poll_ms=%.2f read_to_draw_max_ms=%.1f",
                    tab.name ?: @"Terminal", mica_session_pid(tab.session),
                    tab.outputBytes / outputWindow, tab.outputReadCalls / outputWindow,
                    (unsigned long)tab.outputLargestRead, tab.outputParseMilliseconds,
                    tab.outputPollMilliseconds, tab.outputToDrawMaximumMilliseconds]);
            }
            tab.outputMetricsStartedAt = now;
            tab.outputBytes = 0;
            tab.outputReadCalls = 0;
            tab.outputLargestRead = 0;
            tab.outputParseMilliseconds = 0;
            tab.outputPollMilliseconds = 0;
            tab.outputToDrawMaximumMilliseconds = 0;
        }
        MicaDirtyRows dirtyRows = {0};
        BOOL hasDirtyRows = mica_session_take_dirty_rows(tab.session, &dirtyRows);
        const char *rawTitle = mica_session_title(tab.session);
        NSString *terminalTitle = rawTitle[0]
            ? [[NSString alloc] initWithBytes:rawTitle length:strlen(rawTitle) encoding:NSUTF8StringEncoding]
            : nil;
        if (MicaStringChanged(terminalTitle, tab.terminalTitle)) {
            tab.terminalTitle = terminalTitle;
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
            redraw = YES;
        }
        if (currentCommand.length) {
            NSTimeInterval startedAt = tab.commandStartedAt;
            NSInteger second = (NSInteger)MAX(0, floor(now - startedAt));
            if (second != tab.commandClockSecond) {
                tab.commandClockSecond = second;
                if (tab == self.activeTab) {
                    NSRect status = NSMakeRect(0, 0, self.terminalView.bounds.size.width, kStatusHeight);
                    [self.terminalView setNeedsDisplayInRect:status];
                }
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
            if (currentCommand.length && now - tab.lastActivityScanAt >= 0.20) {
                tab.lastActivityScanAt = now;
                NSString *detail = nil;
                NSString *activity = MicaAgentActivityForSession(tab.session, &detail);
                if (MicaStringChanged(activity, tab.agentActivity)) {
                    tab.agentActivity = activity;
                    tab.agentActivityDetail = detail;
                    tab.commandClockSecond = -1;
                    redraw = YES;
                } else if (MicaStringChanged(detail, tab.agentActivityDetail)) {
                    tab.agentActivityDetail = detail;
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
    BOOL animatesTab = NO;
    BOOL activityIndicatorChanged = NO;
    for (MicaTab *tab in self.tabs) {
        MicaTabActivityState state = [self.terminalView activityStateForTab:tab];
        if (tab.displayedActivityState != state) {
            tab.displayedActivityState = state;
            activityIndicatorChanged = YES;
        }
        if (state == MicaTabActivityStateRunning || state == MicaTabActivityStateNeedsAttention)
            animatesTab = YES;
    }
    BOOL activityAnimationTick = animatesTab && now - self.lastActivityAnimationAt >= 0.12;
    if (activityAnimationTick || activityIndicatorChanged) {
        if (activityAnimationTick) {
            self.lastActivityAnimationAt = now;
            self.activityAnimationFrame++;
        }
        NSRect header = NSMakeRect(0, MAX(0, self.terminalView.bounds.size.height - kHeaderHeight),
            self.terminalView.bounds.size.width, kHeaderHeight);
        [self.terminalView setNeedsDisplayInRect:header];
    }
    if (redraw) [self.terminalView setNeedsDisplay:YES];
    NSTimeInterval pollEndedAt = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval pollDuration = pollEndedAt - pollStartedAt;
    if (pollDuration >= 0.075 && pollEndedAt - self.lastSlowPollLogAt >= 1.0) {
        self.lastSlowPollLogAt = pollEndedAt;
        MicaTab *activeTab = self.activeTab;
        MicaDiagnosticsLog(@"performance", [NSString stringWithFormat:
            @"slow-session-poll duration_ms=%.1f tabs=%lu active=%@ active_pid=%d",
            pollDuration * 1000.0, (unsigned long)self.tabs.count,
            activeTab.name ?: @"none",
            activeTab.session ? mica_session_pid(activeTab.session) : -1]);
    }
}

- (BOOL)confirmEndingRunningCommandsFor:(NSString *)action {
    if (getenv("MICA_TEST_NO_STARTUP")) return YES;
    NSMutableArray<NSString *> *running = [NSMutableArray array];
    for (MicaTab *tab in self.tabs) {
        // An exited shell can leave a stale command label behind; only live sessions count.
        if (!tab.currentCommand.length || !tab.session || !mica_session_is_running(tab.session)) continue;
        [running addObject:tab.currentCommand.lastPathComponent.length
            ? tab.currentCommand.lastPathComponent : tab.currentCommand];
    }
    if (!running.count) return YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"%@?", action];
    alert.informativeText = [NSString stringWithFormat:@"%@ still running. This ends it.",
        running.count == 1 ? [NSString stringWithFormat:@"“%@” is", running[0]]
                           : [NSString stringWithFormat:@"%lu commands are", (unsigned long)running.count]];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:action];
    return [alert runModal] == NSAlertSecondButtonReturn;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    return [self confirmEndingRunningCommandsFor:@"Close Window"];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (self.terminationCleanupStarted) return NSTerminateLater;
    if (![self confirmEndingRunningCommandsFor:@"Quit Mica"]) return NSTerminateCancel;
    self.terminationCleanupStarted = YES;
    MicaDiagnosticsLog(@"app", @"application termination requested");
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.voiceController cancel];
    NSMutableArray<NSValue *> *sessions = [NSMutableArray arrayWithCapacity:self.tabs.count];
    for (MicaTab *tab in self.tabs) {
        if (!tab.session) continue;
        MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"queued session cleanup tab=%@ pid=%d",
            tab.name ?: @"Terminal", mica_session_pid(tab.session)]);
        [sessions addObject:[NSValue valueWithPointer:tab.session]];
        tab.session = NULL;
    }
    MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"queued all sessions count=%lu",
        (unsigned long)sessions.count]);
    self.terminationCleanupGroup = dispatch_group_create();
    dispatch_group_enter(self.terminationCleanupGroup);
    self.terminationReplyTimer = [NSTimer timerWithTimeInterval:0.05
        target:self selector:@selector(finishTerminationWhenCleanupCompletes:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.terminationReplyTimer forMode:NSModalPanelRunLoopMode];
    [[NSRunLoop mainRunLoop] addTimer:self.terminationReplyTimer forMode:NSDefaultRunLoopMode];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            for (NSValue *sessionValue in sessions) {
                MicaSession *session = sessionValue.pointerValue;
                pid_t sessionPID = mica_session_pid(session);
                mica_session_destroy(session);
                MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"session cleanup complete pid=%d", sessionPID]);
            }
        }
        dispatch_group_leave(self.terminationCleanupGroup);
    });
    // Never let a hung child teardown keep Quit waiting forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [NSApp replyToApplicationShouldTerminate:YES];
    });
    return NSTerminateLater;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    MicaDiagnosticsLog(@"app", @"application is terminating");
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
- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    [self.terminalView scheduleGridResize];
}
@end

#ifndef MICA_APP_NO_MAIN
int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        MicaDiagnosticsInitialize();
        MicaDiagnosticsLog(@"startup", [NSString stringWithFormat:@"Mica %@ revision %@ launching pid=%d parent_pid=%d bundle=%@ path=%@ folder=%@",
            @MICA_VERSION, @MICA_REVISION, getpid(), getppid(), NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
            NSBundle.mainBundle.bundleURL.path ?: @"unknown",
            NSFileManager.defaultManager.currentDirectoryPath ?: @"unknown"]);
        // A dead speech helper must surface as a write error, not kill every terminal with SIGPIPE.
signal(SIGPIPE, SIG_IGN);
NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        MicaAppDelegate *delegate = [[MicaAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
#endif
