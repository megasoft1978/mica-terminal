#import <Cocoa/Cocoa.h>
#import "mica.h"
#import "mica_diagnostics.h"
#import "mica_voice_controller.h"
#import "mica_vocabulary.h"
#import "mica_pomodoro.h"
#import "mica_status_item.h"
#import "mica_hook_server.h"
#import "mica_hook_install.h"
#import "mica_agent_detect.h"
#import "mica_agent_state.h"
#import "mica_attention.h"
#import "mica_resume.h"
#import "mica_agent_rss.h"
#import "mica_status_context.h"
#import "mica_ssh_profile.h"
#import <UserNotifications/UserNotifications.h>
#import <Carbon/Carbon.h>

#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <libproc.h>
#import <sys/resource.h>
#import <mach/mach_time.h>
#import <sys/time.h>
#import <sys/stat.h>
#import <limits.h>
#include <errno.h>
#include <unistd.h>

static const CGFloat kHeaderHeight = 28.0;
static const CGFloat kStatusHeight = 32.0;
static const CGFloat kDictationPreviewHeight = 104.0;
static const CGFloat kTerminalPaddingX = 10.0;   // breathing room between the window edge and the first column
static const CGFloat kTrafficLightInset = 78.0;  // tab strip starts after the window buttons in the merged title bar
static const NSTimeInterval kAgentActivityQuietInterval = 2.5;
static const CGFloat kFontSizeDefault = 16.0;
static const CGFloat kTabTitleFontSize = 12.0;
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
    // 256 points is plenty for the Dock and saves several MB over a 512-point bitmap held for the app's lifetime.
    const CGFloat size = 256;
    const CGFloat k = size / 512.0;
    NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [icon lockFocus];
    [baseIcon drawInRect:NSMakeRect(0, 0, size, size) fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1];
    uint32_t hash = 2166136261u;
    for (NSUInteger i = 0; i < projectName.length; i++) {
        hash = (hash ^ [projectName characterAtIndex:i]) * 16777619u;
    }
    CGFloat diameter = 116 * k;
    NSRect badge = NSMakeRect(size - diameter - 12 * k, size - diameter - 12 * k, diameter, diameter);
    NSColor *accent = [NSColor colorWithHue:(CGFloat)(hash % 360u) / 360.0
        saturation:0.78 brightness:0.48 alpha:1];
    [[NSColor colorWithWhite:0.08 alpha:0.96] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(badge, -7 * k, -7 * k)] fill];
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:badge];
    circle.lineWidth = 5 * k;
    [accent setFill];
    [NSColor.whiteColor setStroke];
    [circle fill];
    [circle stroke];
    NSString *mark = MicaProjectMark(projectName);
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:(mark.length > 1 ? 42 : 52) * k
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

static NSTimer *gMicaPomodoroTimer;

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

static uint64_t gMicaNextTabIdentifier = 1;
static MicaAttentionInbox *MicaAttention(void) {
    static MicaAttentionInbox *inbox;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inbox = [MicaAttentionInbox new]; });
    return inbox;
}
static BOOL MicaShouldDeliverAttention(BOOL appActive, BOOL selectedInKeyWindow) {
    return !appActive || !selectedInKeyWindow;
}

static UNMutableNotificationContent *MicaNotificationContentForAttention(NSDictionary *event) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = event[@"title"] ?: @"Mica";
    content.body = event[@"body"] ?: @"";
    content.sound = nil;
    content.userInfo = @{ @"tabID": event[@"tabID"] ?: @0, @"kind": event[@"kind"] ?: @0 };
    return content;
}

// The terminal draws on a fixed surface (dark by default, white in the light theme), independent of the system appearance.
static BOOL gMicaLightTheme = NO;
static BOOL gMicaFollowSystemTheme = NO;
static BOOL gMicaTestIncreaseContrast = NO;
static NSUserDefaults *gMicaDefaultsOverride;
static MicaStatusItem *gMicaStatusItem;
#if defined(MICA_APP_NO_MAIN)
static BOOL (*gMicaTimerStatusItemLifecycleHook)(BOOL enable);
static BOOL gMicaTimerStatusItemEnabledForTests;
#endif

// Optional global shortcut (Control-Option-Space) that brings Mica forward. Carbon hot keys need no
// Accessibility permission. Registration goes through a replaceable function so tests never touch the system.
static EventHotKeyRef gMicaHotKey;
static EventHandlerRef gMicaHotKeyHandler;
static BOOL gMicaShortcutRegistered;
static BOOL (*gMicaHotKeyRegistrar)(BOOL enable);

static OSStatus MicaHotKeyPressed(EventHandlerCallRef next, EventRef event, void *context) {
    (void)next; (void)event; (void)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        NSWindow *target = NSApp.keyWindow ?: NSApp.mainWindow;
        for (NSWindow *window in NSApp.windows) if (!target && window.isVisible) target = window;
        if (!target) for (NSWindow *window in NSApp.windows) if (window.canBecomeMainWindow) { target = window; break; }
        if (target.isMiniaturized) [target deminiaturize:nil];
        [target makeKeyAndOrderFront:nil];
    });
    return noErr;
}

static BOOL MicaRegisterSystemHotKey(BOOL enable) {
    if (enable == (gMicaHotKey != NULL)) return YES;
    if (!enable) {
        UnregisterEventHotKey(gMicaHotKey);
        gMicaHotKey = NULL;
        return YES;
    }
    if (!gMicaHotKeyHandler) {
        EventTypeSpec type = { kEventClassKeyboard, kEventHotKeyPressed };
        if (InstallApplicationEventHandler(&MicaHotKeyPressed, 1, &type, NULL, &gMicaHotKeyHandler) != noErr) return NO;
    }
    EventHotKeyID hotKeyID = { 'mica', 1 };
    return RegisterEventHotKey(kVK_Space, controlKey | optionKey, hotKeyID, GetApplicationEventTarget(), 0, &gMicaHotKey) == noErr;
}

static BOOL MicaSetGlobalShortcutEnabled(BOOL enable) {
    BOOL ok = (gMicaHotKeyRegistrar ?: MicaRegisterSystemHotKey)(enable);
    gMicaShortcutRegistered = ok ? enable : gMicaShortcutRegistered;
    return ok;
}
static NSURL *gMicaSessionStateURLOverride;
static BOOL MicaIncreaseContrastEnabled(void) {
    return gMicaTestIncreaseContrast || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
}
static NSURL *MicaMicrophoneSettingsURL(void) {
    return [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"];
}
static NSInteger gMicaCursorStyle = 0;   // 0 block, 1 bar, 2 underline

static NSColor *MicaBackgroundColor(void) {
    return MicaColor(gMicaLightTheme ? 0xffffff : 0x1e1e1e);
}

static NSColor *MicaForegroundColor(void) {
    return MicaColor(gMicaLightTheme ? 0x24292f : 0xd4d4d4);
}

static NSColor *MicaSeparatorColor(void) {
    return MicaIncreaseContrastEnabled()
        ? MicaColor(gMicaLightTheme ? 0x595959 : 0xbdbdbd) : NSColor.separatorColor;
}

static NSColor *MicaSecondaryLabelColor(CGFloat alpha) {
    return MicaIncreaseContrastEnabled()
        ? MicaColor(gMicaLightTheme ? 0x595959 : 0xbdbdbd) : [NSColor.secondaryLabelColor colorWithAlphaComponent:alpha];
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
@property(nonatomic, assign) uint64_t identifier;
@property(nonatomic, copy) NSString *cwd;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *remoteProfile;
@property(nonatomic, copy) NSString *terminalTitle;
@property(nonatomic, copy) NSString *currentCommand;
@property(nonatomic, copy) NSString *agentActivity;
@property(nonatomic, copy) NSString *agentActivityDetail;
@property(nonatomic, copy) NSString *hookToken;
@property(nonatomic, copy) NSString *agentKind;
@property(nonatomic, copy) NSString *processAgentKind;
@property(nonatomic, copy) NSString *agentState;
@property(nonatomic, copy) NSString *agentStateSource;
@property(nonatomic, copy) NSString *agentSessionID;
@property(nonatomic, copy) NSString *agentLastMessage;
@property(nonatomic, copy) NSDate *agentUpdatedAt;
@property(nonatomic, copy) NSDictionary *lastHookEvent;
@property(nonatomic, assign) BOOL receivedAgentHook;
@property(nonatomic, assign) NSInteger displayedActivityState;
@property(nonatomic, assign) NSTimeInterval commandStartedAt;
@property(nonatomic, assign) NSInteger commandClockSecond;
@property(nonatomic, assign) BOOL cwdLookupPending;
@property(nonatomic, assign) uint64_t cwdLookupCompletionCount;
@property(nonatomic, assign) MicaSession *session;
@property(nonatomic, strong) dispatch_source_t ioSource;
@property(nonatomic, assign) uint64_t revision;
@property(nonatomic, assign) uint64_t attentionCount;
@property(nonatomic, assign) uint64_t agentRSSBytes;
@property(nonatomic, copy) NSString *gitBranch;
@property(nonatomic, copy) NSArray<NSString *> *vocabularyFileTerms;
@property(nonatomic, copy) NSArray<NSString *> *gitVocabularyTerms;
@property(nonatomic, copy) NSString *recentVisibleText;
@property(nonatomic, strong) NSDate *recentVisibleCapturedAt;
@property(nonatomic, copy) NSString *gitBranchLookupPath;
@property(nonatomic, assign) NSTimeInterval lastSelectedAt;
@property(nonatomic, assign) NSInteger clipboardDecision;  // 0 ask, 2 deny in this tab
@property(nonatomic, copy) NSString *pendingClipboardText;
@property(nonatomic, assign) BOOL syncHeld;
@property(nonatomic, assign) BOOL needsAttention;
@property(nonatomic, assign) BOOL muteNotifications;
@property(nonatomic, assign) uint64_t commandCompletionCount;
@property(nonatomic, assign) BOOL tracksCompletion;
@property(nonatomic, assign) BOOL completedCommand;
@property(nonatomic, assign) BOOL reportedProcessExit;
@property(nonatomic, assign) int completionStatus;
@property(nonatomic, copy) NSString *completionLabel;
@property(nonatomic, assign) NSTimeInterval lastOutputReadAt;
@property(nonatomic, assign) NSTimeInterval lastActivityScanAt;
@end
@implementation MicaTab
- (void)destroySession {
    if (_ioSource) { dispatch_source_cancel(_ioSource); _ioSource = nil; }
    if (!_session) return;
    mica_session_destroy(_session);
    _session = NULL;
}
- (void)dealloc { [self destroySession]; }
@end

static NSString *MicaAgentNameForText(NSString *text) {
    NSString *identity = text.lowercaseString ?: @"";
    if ([identity containsString:@"codex"]) return @"Codex";
    if ([identity containsString:@"claude"])
        return @"Claude Code";
    return nil;
}


// Keep the newest words in the reserved live transcript preview.
static NSString *MicaLastWords(NSString *text, NSUInteger count) {
    NSArray<NSString *> *words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *word in words) if (word.length) [kept addObject:word];
    if (kept.count <= count) return [kept componentsJoinedByString:@" "];
    NSArray *tail = [kept subarrayWithRange:NSMakeRange(kept.count - count, count)];
    return [@"… " stringByAppendingString:[tail componentsJoinedByString:@" "]];
}

static NSString *MicaAgentStateForTab(MicaTab *tab) { return tab.agentState ?: @"idle"; }

static NSString *MicaAgentNameForTab(MicaTab *tab) {
    if ([tab.agentKind isEqualToString:@"claude"]) return @"Claude Code";
    if ([tab.agentKind isEqualToString:@"codex"]) return @"Codex";
    if ([tab.agentKind isEqualToString:@"other"]) return @"Agent";
    if ([tab.processAgentKind isEqualToString:@"claude"]) return @"Claude Code";
    if ([tab.processAgentKind isEqualToString:@"codex"]) return @"Codex";
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
        BOOL lineHasPromptGlyph = NO;
        char lineBuffer[1024];
        size_t lineLength = 0;
        for (int col = 0; col < cols; col++) {
            MicaCell cell;
            if (!mica_session_get_cell(session, row, col, &cell) || CellIsContinuation(cell)) continue;
            for (NSUInteger i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++) {
                uint32_t codepoint = cell.chars[i];
                if (row >= rows - 2 && (codepoint == 0x276f || codepoint == 0x203a))
                    lineHasPromptGlyph = YES;
                if (lineLength + 1 < sizeof(lineBuffer))
                    lineBuffer[lineLength++] = (codepoint >= 0x20 && codepoint <= 0x7e)
                        ? (char)codepoint : ' ';
            }
        }
        lineBuffer[lineLength] = '\0';
        NSString *line = [[NSString alloc] initWithBytes:lineBuffer length:lineLength encoding:NSASCIIStringEncoding] ?: @"";
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!trimmed.length) continue;
        NSString *upper = trimmed.uppercaseString;
        NSString *lineActivity = nil;
        if (lineHasPromptGlyph && ([upper containsString:@"TRUST THIS FOLDER"] || [upper containsString:@"NEEDS APPROVAL"] ||
            [upper containsString:@"WAITING FOR APPROVAL"] || [upper containsString:@"CONFIRMATION REQUIRED"] ||
            [upper containsString:@"APPROVE THIS"] || [upper containsString:@"ALLOW THIS"])) {
            lineActivity = @"Needs approval";
        } else if (lineHasPromptGlyph && ([upper containsString:@"WAITING FOR YOUR INPUT"] ||
                   [upper containsString:@"WAITING FOR INPUT"] ||
                   [upper containsString:@"PRESS ENTER TO CONTINUE"] ||
                   [upper containsString:@"PRESS RETURN TO CONTINUE"] ||
                   [upper containsString:@"SELECT AN OPTION"] || [upper containsString:@"CHOOSE AN OPTION"] ||
                   [upper containsString:@"TYPE YOUR ANSWER"] || [upper containsString:@"ENTER TO SUBMIT"] ||
                   [upper containsString:@"(Y/N)"] || [upper containsString:@"[Y/N]"])) {
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
    if (detailOut) *detailOut = recentAction ?: activityLine;
    return activity ?: @"Idle";
}

@class MicaAppDelegate;
@class MicaTerminalView;
@interface MicaTabAccessibilityElement : NSAccessibilityElement
@property(nonatomic, copy) BOOL (^pressHandler)(void);
@end

@interface MicaAgentSidebarView : NSView
@property(nonatomic, weak) MicaAppDelegate *owner;
@property(nonatomic, copy) NSString *lastRowsSignature;
- (void)refreshRows;
@end

@interface MicaWindowContentView : NSView
@property(nonatomic, weak) MicaAppDelegate *owner;
@property(nonatomic, strong) MicaTerminalView *terminalView;
@property(nonatomic, strong) MicaAgentSidebarView *sidebarView;
@property(nonatomic, getter=isSidebarVisible) BOOL sidebarVisible;
- (void)setSidebarVisible:(BOOL)visible;
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
@property(nonatomic, assign) NSRect dictationLabelTextRect;
@property(nonatomic, assign) NSRect dictationWordsTextRect;
@property(nonatomic, assign) NSRect dictationHintTextRect;
@property(nonatomic, assign) BOOL quickSelectActive;
@property(nonatomic, copy) NSArray<NSDictionary *> *quickSelectMatches;
@property(nonatomic, copy) NSString *quickSelectPrefix;
@property(nonatomic, copy) void (^testCopyHandler)(NSString *text);
#if defined(MICA_APP_NO_MAIN)
@property(nonatomic, copy) NSString *testClipboardText;
@property(nonatomic, strong) NSData *testClipboardImage;
@property(nonatomic, copy) NSArray<NSURL *> *testDraggedFileURLs;
@property(nonatomic, copy) void (^testOpenURLHandler)(NSURL *url);
@property(nonatomic, copy) void (^testRevealURLHandler)(NSURL *url);
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
- (NSString *)pomodoroStatusText;
- (void)showPomodoroControlMenu:(id)sender;
- (void)updateGridSize;
- (void)scheduleGridResize;
- (void)commitGridResize:(NSTimer *)timer;
- (void)recordDrawDuration:(NSTimeInterval)duration;
- (NSString *)labelForTab:(MicaTab *)tab;
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
- (void)toggleQuickSelect:(id)sender;
- (void)finishQuickSelectWithLabel:(NSString *)label option:(BOOL)option;
- (NSArray<NSDictionary *> *)quickSelectCandidates;
- (NSRect)cellRectAtRow:(NSInteger)row col:(NSInteger)col;
- (NSColor *)colorForVTermColor:(VTermColor)color isForeground:(BOOL)isForeground;
- (NSRect)dictationPreviewRect;
- (NSRect)microphoneSettingsButtonRect;
- (NSRect)terminalHitRect;
- (CGFloat)tabsLeadingInset;
- (BOOL)windowIsActive;
- (void)drawDictationPreview:(MicaVoiceController *)voice inRect:(NSRect)preview;
- (void)openHyperlinkID:(uint32_t)hyperlinkID forTab:(MicaTab *)tab;
- (void)cancelLeftOptionTracking;
@end

@interface MicaAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, MicaVoiceControllerDelegate,
                                       UNUserNotificationCenterDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) MicaTerminalView *terminalView;
@property(nonatomic, strong) MicaWindowContentView *windowContentView;
@property(nonatomic, assign) BOOL sidebarVisible;
@property(nonatomic, strong) NSMutableArray<MicaTab *> *tabs;
@property(nonatomic, assign) NSInteger activeIndex;
@property(nonatomic, copy) NSString *projectName;
@property(nonatomic, strong) NSImage *baseApplicationIcon;
@property(nonatomic, copy) NSString *projectLayoutPath;
@property(nonatomic) BOOL explicitLayoutLaunch;
@property(nonatomic, copy) NSArray<NSDictionary *> *savedTabsForWindow;
@property(nonatomic, strong) id projectSettingsController;
@property(nonatomic, strong) id sshProfilesController;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, weak) MicaTab *dispatchPollTab;
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
@property(nonatomic) NSTimeInterval lastVoiceAnimationAt;
@property(nonatomic, copy) NSString *memoryLabel;
@property(nonatomic) NSTimeInterval memoryCheckedAt;
@property(nonatomic) BOOL clipboardPromptShowing;
@property(nonatomic, copy) NSString *appliedIconProjectName;
@property(nonatomic, assign) NSInteger attentionRequest;
@property(nonatomic, assign) NSInteger focusDurationMinutes;
@property(nonatomic, assign) NSInteger breakDurationMinutes;
@property(nonatomic, assign) BOOL autoStartFocus;
@property(nonatomic, assign) BOOL autoStartBreaks;
@property(nonatomic, assign) NSInteger pomodoroCycleFocusMinutes;
@property(nonatomic, assign) NSInteger pomodoroCycleBreakMinutes;
@property(nonatomic, assign) MicaPomodoro pomodoro;
@property(nonatomic, copy) NSString *pomodoroLabel;
@property(nonatomic, strong) NSTimer *pomodoroTimer;
@property(nonatomic, strong) NSTimer *agentRSSTimer;
@property(nonatomic, strong) MicaAgentRSSMonitor *agentRSSMonitor;
@property(nonatomic, assign) BOOL agentRSSStatusMenuOpen;
@property(nonatomic, assign) BOOL dictationToggleMode;
@property(nonatomic, copy) NSString *lastDictationText;
@property(nonatomic, copy) NSString *lastDictationRawText;
@property(nonatomic, weak) MicaTab *lastDictationTab;
@property(nonatomic, assign) BOOL dictationUndoValid;
@property(nonatomic, strong) NSURL *dictationSnippetsURLOverride;
@property(nonatomic, strong) NSPanel *commandPalettePanel;
@property(nonatomic, strong) NSTextField *commandPaletteSearch;
@property(nonatomic, strong) NSTableView *commandPaletteTable;
@property(nonatomic, copy) NSArray<NSDictionary *> *commandPaletteRows;
#if defined(MICA_APP_NO_MAIN)
@property(nonatomic, copy) void (^testAgentNotificationHandler)(NSString *title, NSString *body, MicaTab *tab);
#endif
- (MicaTab *)activeTab;
- (NSString *)windowTitleForTab:(MicaTab *)tab;
- (void)newTabWithName:(NSString *)name command:(NSString *)command;
- (void)addTabWithName:(NSString *)name cwd:(NSString *)cwd command:(NSString *)command prefilled:(BOOL)prefilled;
- (void)refreshVocabularyForTab:(MicaTab *)tab;
- (NSString *)visibleTextForTab:(MicaTab *)tab;
- (void)closeActiveTab;
- (void)selectRelativeTab:(NSInteger)delta;
- (void)jumpToNextWaitingTab:(id)sender;
- (void)selectTabAtIndex:(NSInteger)index;
- (void)toggleTabPicker;
- (void)toggleCommandPalette:(id)sender;
- (void)filterCommandPalette:(id)sender;
- (void)runCommandPaletteSelection:(id)sender;
- (void)moveCommandPaletteSelection:(NSInteger)delta;
- (void)toggleScrollback;
- (void)resizeActiveSession;
- (void)installMenus;
- (void)updateWindowTitle;
- (void)pollSessions:(NSTimer *)timer;
- (void)setLightTheme:(BOOL)light;
- (BOOL)systemAppearanceIsLight;
- (void)applySystemAppearanceIfNeeded;
- (void)setCursorStyle:(id)sender;
- (void)openPreferences:(id)sender;
- (void)prefShortcutChanged:(NSButton *)sender;
- (void)prefDictationModeChanged:(NSPopUpButton *)sender;
- (void)undoLastDictation:(id)sender;
- (void)applyStoredShortcutPreference;
- (NSInteger)storedScrollbackLines;
+ (NSInteger)scrollbackIndexForLines:(NSInteger)lines;
- (void)applyStoredScrollbackPreference;
- (void)prefScrollbackChanged:(NSPopUpButton *)sender;
- (void)refreshPreferencesSizeLabel;
- (void)newWorktreeTab:(id)sender;
- (void)toggleMuteNotificationsForTab:(id)sender;
- (NSMenu *)notificationMenuForTab:(MicaTab *)tab;
- (NSString *)agentNotificationTitleForTab:(MicaTab *)tab waiting:(BOOL)waiting;
- (void)startWindowWithArguments:(NSArray<NSString *> *)arguments;
- (void)openProjectWindowWithArguments:(NSArray<NSString *> *)arguments;
- (void)takeMenuOwnership;
- (void)handleHookEvent:(MicaHookEvent)event forTab:(MicaTab *)tab;
- (void)setupAgentHooks:(id)sender;
- (void)buildMenus;
- (void)teardownWindow;
- (NSArray<NSValue *> *)detachSessionsForTermination;
- (void)prefThemeChanged:(NSPopUpButton *)sender;
- (void)toggleSidebar:(id)sender;
@property(nonatomic, strong) NSWindow *preferencesWindow;
@property(nonatomic, assign) BOOL observesSystemAppearance;
- (void)toggleLightTheme:(id)sender;
- (void)handleClipboardWrite:(NSString *)text fromTab:(MicaTab *)tab;
- (void)loadLaunchConfiguration;
- (void)loadLaunchConfigurationFromArguments:(NSArray<NSString *> *)arguments bundleInfo:(NSDictionary *)bundleInfo;
- (NSUserDefaults *)micaDefaults;
- (void)loadStoredThemePreference;
- (NSURL *)sessionStateURL;
- (void)saveSessionState;
- (NSArray<NSDictionary *> *)readSessionState;
- (void)startPushToTalk;
- (void)finishPushToTalk;
- (void)beginDictationForActiveTab;
- (void)cancelDictation;
- (void)openDiagnosticLogs:(id)sender;
- (void)showKeyboardShortcuts:(id)sender;
- (void)openProjectSettings:(id)sender;
- (void)openSSHProfiles:(id)sender;
- (void)connectSSHProfile:(id)sender;
- (void)openSSHProfile:(NSDictionary<NSString *, NSString *> *)profile;
- (void)startPomodoro:(id)sender;
- (void)takePomodoroBreak:(id)sender;
- (void)prefStatusTimerChanged:(NSButton *)sender;
- (void)editPomodoroLabel:(id)sender;
- (void)updateFocusMenuLabel;
- (void)togglePomodoroPause:(id)sender;
- (void)skipPomodoroPhase:(id)sender;
- (void)resetPomodoro:(id)sender;
- (void)openPomodoroSettings:(id)sender;
- (void)configurePomodoro;
- (void)refreshPomodoroState;
- (BOOL)savePomodoroDurationsFocusMinutes:(NSInteger)focusMinutes breakMinutes:(NSInteger)breakMinutes;
- (BOOL)savePomodoroSettingsFocusMinutes:(NSInteger)focusMinutes breakMinutes:(NSInteger)breakMinutes
    autoStartFocus:(BOOL)autoStartFocus autoStartBreaks:(BOOL)autoStartBreaks;
- (NSView *)pomodoroSettingsAccessory;
- (BOOL)savePomodoroSettingsFromAccessory:(NSView *)accessory;
- (void)savePomodoroState;
- (void)updatePomodoroTimer;
- (void)pomodoroTimerFired:(NSTimer *)timer;
- (void)prefMenuBarTimerChanged:(NSButton *)sender;
- (void)prefDiagnosticsChanged:(NSButton *)sender;
- (void)prefAgentRSSWarningChanged:(NSPopUpButton *)sender;
- (void)updateMenuBarTimer;
- (void)applyMenuBarTimerPreference;
- (void)updateAgentRSSTimer;
- (void)agentRSSTimerFired:(NSTimer *)timer;
- (void)prefAgentRSSWarningChanged:(NSPopUpButton *)sender;
- (NSDictionary<NSString *, id> *)menuBarTimerPresentationAtTime:(double)now;
@property(nonatomic, assign) MicaUIMode uiMode;
@end

@implementation MicaAgentSidebarView
- (BOOL)isFlipped { return YES; }
- (NSString *)stateTextForTab:(MicaTab *)tab {
    if (tab.receivedAgentHook) {
        NSString *state = MicaAgentStateForTab(tab);
        if ([state isEqualToString:@"working"]) return @"Working";
        if ([state isEqualToString:@"waitingPermission"]) return @"Needs permission";
        if ([state isEqualToString:@"waitingInput"]) return @"Needs input";
        if ([state isEqualToString:@"done"]) return @"Done";
        if ([state isEqualToString:@"error"]) return @"Error";
        return @"Idle";
    }
    MicaTabActivityState state = [self.owner.terminalView activityStateForTab:tab];
    return state == MicaTabActivityStateWaiting ? @"Needs input" :
        state == MicaTabActivityStateRunning ? @"Running" : state == MicaTabActivityStateComplete ? @"Finished" :
        state == MicaTabActivityStateNeedsAttention ? @"Needs attention" : @"Idle";
}
- (NSString *)previewForTab:(MicaTab *)tab {
    NSString *message = [tab.agentLastMessage stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    message = [message stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (message.length > 80) message = [[message substringToIndex:79] stringByAppendingString:@"…"];
    return message ?: @"";
}
- (void)refreshRows {
    NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:self.owner.tabs.count];
    for (NSUInteger i = 0; i < self.owner.tabs.count; i++) {
        MicaTab *tab = self.owner.tabs[i];
        [rows addObject:[NSString stringWithFormat:@"%llu|%@|%@|%@|%ld|%d|%@|%@|%llu",
            (unsigned long long)tab.identifier, tab.name ?: @"Terminal",
            tab.cwd.lastPathComponent ?: @"/", tab.gitBranch ?: @"",
            (long)[self.owner.terminalView activityStateForTab:tab], tab.needsAttention,
            MicaAgentStateForTab(tab), tab.agentLastMessage ?: @"", (unsigned long long)tab.agentRSSBytes]];
    }
    NSString *signature = [NSString stringWithFormat:@"%ld:%@", (long)self.owner.activeIndex,
        [rows componentsJoinedByString:@"\n"]];
    if ([signature isEqualToString:self.lastRowsSignature]) return;
    self.lastRowsSignature = signature;
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds);
    NSDictionary *titleAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
    [@"TABS" drawAtPoint:NSMakePoint(14, 14) withAttributes:titleAttrs];
    CGFloat y = 42;
    for (NSUInteger i = 0; i < self.owner.tabs.count; i++, y += 70) {
        MicaTab *tab = self.owner.tabs[i];
        NSRect row = NSMakeRect(6, y - 5, self.bounds.size.width - 12, 65);
        BOOL selected = (NSInteger)i == self.owner.activeIndex;
        if (selected) { [NSColor.selectedContentBackgroundColor setFill]; [[NSBezierPath bezierPathWithRoundedRect:row xRadius:6 yRadius:6] fill]; }
        NSColor *fg = selected ? NSColor.selectedMenuItemTextColor : NSColor.labelColor;
        NSDictionary *nameAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium], NSForegroundColorAttributeName:fg};
        NSDictionary *detailAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:10], NSForegroundColorAttributeName:selected ? fg : NSColor.secondaryLabelColor};
        NSString *name = tab.name.length ? tab.name : @"Terminal";
        [name drawInRect:NSMakeRect(14, y, self.bounds.size.width - 42, 17) withAttributes:nameAttrs];
        NSString *folder = tab.cwd.lastPathComponent.length ? tab.cwd.lastPathComponent : @"/";
        NSString *branch = tab.gitBranch.length ? [NSString stringWithFormat:@" · %@", tab.gitBranch] : @"";
        [([folder stringByAppendingString:branch]) drawInRect:NSMakeRect(14, y + 20, self.bounds.size.width - 25, 15) withAttributes:detailAttrs];
        MicaTabActivityState state = [self.owner.terminalView activityStateForTab:tab];
        NSString *stateText = [self stateTextForTab:tab];
        NSColor *stateColor = state == MicaTabActivityStateWaiting ? NSColor.systemOrangeColor :
            state == MicaTabActivityStateNeedsAttention ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
        CGFloat stateWidth = tab.agentRSSBytes ? self.bounds.size.width - 82 : self.bounds.size.width - 28;
        [stateText drawInRect:NSMakeRect(14, y + 36, stateWidth, 13)
            withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:9], NSForegroundColorAttributeName:selected ? fg : stateColor}];
        NSString *symbol = [stateText isEqualToString:@"Needs permission"] ? @"!" :
            [stateText isEqualToString:@"Needs input"] ? @"?" :
            [stateText isEqualToString:@"Working"] || [stateText isEqualToString:@"Running"] ? @"●" :
            [stateText isEqualToString:@"Done"] || [stateText isEqualToString:@"Finished"] ? @"✓" :
            [stateText isEqualToString:@"Error"] ? @"×" : @"";
        if (symbol.length) [symbol drawAtPoint:NSMakePoint(self.bounds.size.width - 25, y + 1) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightBold], NSForegroundColorAttributeName:state == MicaTabActivityStateWaiting ? NSColor.systemOrangeColor : fg}];
        if (tab.needsAttention) [@"•" drawAtPoint:NSMakePoint(self.bounds.size.width - 23, y + 20) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14 weight:NSFontWeightBold], NSForegroundColorAttributeName:NSColor.systemRedColor}];
        NSString *preview = [self previewForTab:tab];
        if (preview.length) [preview drawInRect:NSMakeRect(14, y + 51, self.bounds.size.width - 28, 12)
            withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:9], NSForegroundColorAttributeName:NSColor.secondaryLabelColor}];
        if (tab.agentRSSBytes) {
            NSString *rss = [NSString stringWithFormat:@"%.1f GB", (double)tab.agentRSSBytes / (1024.0 * 1024.0 * 1024.0)];
            [rss drawInRect:NSMakeRect(self.bounds.size.width - 58, y + 36, 48, 13)
                withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:9], NSForegroundColorAttributeName:selected ? fg : NSColor.secondaryLabelColor}];
        }
    }
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index = (NSInteger)floor((point.y - 42) / 70.0);
    if (index >= 0 && index < (NSInteger)self.owner.tabs.count) [self.owner selectTabAtIndex:index];
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    NSInteger delta = event.keyCode == 126 ? -1 : event.keyCode == 125 ? 1 : 0;
    if (delta) [self.owner selectTabAtIndex:MAX(0, MIN((NSInteger)self.owner.tabs.count - 1, self.owner.activeIndex + delta))];
    else if (event.keyCode == 36 || event.keyCode == 76) [self.owner selectTabAtIndex:self.owner.activeIndex];
    else [super keyDown:event];
}
- (BOOL)isAccessibilityElement { return NO; }
- (NSArray *)accessibilityChildren {
    NSMutableArray *children = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.owner.tabs.count; i++) {
        MicaTab *tab = self.owner.tabs[i];
        NSString *state = [self stateTextForTab:tab];
        NSString *preview = [self previewForTab:tab];
        NSString *rss = tab.agentRSSBytes ? [NSString stringWithFormat:@", %.1f GB memory", (double)tab.agentRSSBytes / (1024.0 * 1024.0 * 1024.0)] : @"";
        NSString *label = [NSString stringWithFormat:@"%@%@, folder %@, branch %@, %@%@%@%@", tab.name ?: @"Terminal", (NSInteger)i == self.owner.activeIndex ? @", selected" : @"", tab.cwd.lastPathComponent ?: @"/", tab.gitBranch ?: @"no branch", state, tab.needsAttention ? @", unread attention" : @"", rss, preview.length ? [@", message " stringByAppendingString:preview] : @""];
        MicaTabAccessibilityElement *element = [MicaTabAccessibilityElement accessibilityElementWithRole:NSAccessibilityButtonRole frame:[self.window convertRectToScreen:[self convertRect:NSMakeRect(6, 37 + i * 70, self.bounds.size.width - 12, 65) toView:nil]] label:label parent:self];
        uint64_t tabID = tab.identifier;
        __weak typeof(self) weakSelf = self; element.pressHandler = ^BOOL {
            for (NSUInteger index = 0; index < weakSelf.owner.tabs.count; index++)
                if (weakSelf.owner.tabs[index].identifier == tabID) { [weakSelf.owner selectTabAtIndex:(NSInteger)index]; break; }
            return YES;
        };
        [children addObject:element];
    }
    return children;
}
@end

@implementation MicaWindowContentView
- (void)layout {
    [super layout];
    CGFloat width = self.sidebarVisible ? 220 : 0;
    self.sidebarView.frame = NSMakeRect(0, 0, width, self.bounds.size.height);
    self.terminalView.frame = NSMakeRect(width, 0, MAX(0, self.bounds.size.width - width), self.bounds.size.height);
    [self.terminalView updateGridSize];
}
- (void)setSidebarVisible:(BOOL)visible {
    if (_sidebarVisible == visible) return;
    _sidebarVisible = visible;
    if (visible) {
        MicaAgentSidebarView *sidebar = [MicaAgentSidebarView new];
        sidebar.owner = self.owner;
        sidebar.autoresizingMask = NSViewHeightSizable;
        self.sidebarView = sidebar;
        [self addSubview:sidebar positioned:NSWindowBelow relativeTo:self.terminalView];
    } else {
        [self.sidebarView removeFromSuperview];
        self.sidebarView = nil;
    }
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
    [self.owner resizeActiveSession];
}
@end

@interface MicaPaletteSearchField : NSTextField
@property(nonatomic, weak) MicaAppDelegate *paletteOwner;
@end
@interface MicaPaletteTableView : NSTableView
@property(nonatomic, weak) MicaAppDelegate *paletteOwner;
@end
@interface MicaPaletteRowView : NSTableRowView
@property(nonatomic, copy) NSString *paletteAccessibilityLabel;
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

@interface MicaSSHProfilesController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, weak) MicaAppDelegate *appDelegate;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *rows;
- (instancetype)initWithOwner:(MicaAppDelegate *)owner;
- (void)save:(id)sender;
- (void)connectSelected:(id)sender;
@end

// One process can host many project windows. Each window has its own MicaAppDelegate acting as a window
// controller; the first one is also the NSApplication delegate. Sharing one process avoids repeating the
// roughly 55 MB base cost for every project window.
static NSMutableArray<MicaAppDelegate *> *MicaControllers(void) {
    static NSMutableArray<MicaAppDelegate *> *controllers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controllers = [NSMutableArray array]; });
    return controllers;
}

static NSInteger MicaAgentRSSWarningGB(NSUserDefaults *defaults) {
    id stored = [defaults objectForKey:@"MicaAgentRSSWarningGB"];
    NSInteger value = [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : 4;
    return value == 0 || value == 2 || value == 4 || value == 8 || value == 16 ? value : 4;
}

static uint64_t MicaAgentRSSWarningBytes(NSUserDefaults *defaults) {
    return (uint64_t)MicaAgentRSSWarningGB(defaults) * 1024ULL * 1024ULL * 1024ULL;
}

static NSMutableArray<NSURL *> *MicaPendingOpenURLs(void) {
    static NSMutableArray<NSURL *> *pending;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableArray array]; });
    return pending;
}

// mica://open?layout=<path to a .mica file>&name=<project name>  ->  launch-style arguments, or nil.
// Only layouts inside ~/.config/mica/layouts are accepted, so a web page cannot point Mica at an arbitrary file.
static NSArray<NSString *> *MicaArgumentsForOpenURL(NSURL *url, NSString *layoutsDirectory) {
    if (![url.scheme.lowercaseString isEqualToString:@"mica"] || ![url.host.lowercaseString isEqualToString:@"open"]) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *layout = nil, *name = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"layout"]) layout = item.value;
        else if ([item.name isEqualToString:@"name"]) name = item.value;
    }
    if (!layout.length) return nil;
    NSString *resolved = [layout stringByResolvingSymlinksInPath];
    NSString *root = [layoutsDirectory stringByResolvingSymlinksInPath];
    if (!resolved.isAbsolutePath || ![resolved.pathExtension isEqualToString:@"mica"] ||
        ![resolved hasPrefix:[root stringByAppendingString:@"/"]]) return nil;
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"mica", @"--layout", resolved, nil];
    NSString *cleanName = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (cleanName.length && cleanName.length <= 100 &&
        [cleanName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound)
        [arguments addObjectsFromArray:@[@"--project-name", cleanName]];
    return arguments;
}

static NSString *MicaDefaultLayoutsDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/mica/layouts"];
}

static NSMutableArray<NSMenuItem *> *gControllerMenuItems;   // menu items whose target is the key window's controller
static NSMutableArray<NSMenuItem *> *gViewMenuItems;         // ... and those whose target is its terminal view
static BOOL gMenuBuilt;
static NSString *gAppliedIconProject;

static void MicaDeliverHook(MicaHookEvent event) {
    NSString *token = [NSString stringWithUTF8String:event.token];
    if (!token.length) return;
    for (MicaAppDelegate *controller in MicaControllers()) {
        for (MicaTab *tab in controller.tabs) {
            if ([tab.hookToken isEqualToString:token]) {
                [controller handleHookEvent:event forTab:tab];
                return;
            }
        }
    }
}

// Apple's physical footprint for a process: the same number Activity Monitor calls Memory.
static uint64_t MicaFootprintBytes(pid_t pid) {
    if (pid <= 0) return 0;
    struct rusage_info_v4 info;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) return 0;
    return info.ri_phys_footprint;
}

static NSString *MicaWorkingDirectoryForPID(pid_t pid) {
    if (pid <= 0) return nil;
    struct proc_vnodepathinfo paths;
    int bytes = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, sizeof(paths));
    if (bytes < (int)sizeof(paths) || paths.pvi_cdir.vip_path[0] == '\0') return nil;
    size_t length = strnlen(paths.pvi_cdir.vip_path, sizeof(paths.pvi_cdir.vip_path));
    if (!length || length >= sizeof(paths.pvi_cdir.vip_path)) return nil;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:paths.pvi_cdir.vip_path length:length];
}

// "58 MB", or "58 + 36 MB" while the speech helper is running. Nothing else is hidden: this is everything
// Mica (window, shells' bookkeeping, timer) and its dictation helper occupy right now.
static NSString *MicaMemoryLabel(uint64_t appBytes, uint64_t helperBytes) {
    double app = appBytes / 1048576.0, helper = helperBytes / 1048576.0;
    return helperBytes ? [NSString stringWithFormat:@"%.0f + %.0f MB", app, helper]
                       : [NSString stringWithFormat:@"%.0f MB", app];
}

static NSMenuItem *AddMenuItem(NSMenu *menu, NSString *title, SEL selector, NSString *key, NSEventModifierFlags modifiers) {
    // Menu titles go through the localization table so translations can be dropped in as .lproj/Localizable.strings.
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(title, nil) action:selector keyEquivalent:key ?: @""];
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

// Draws one line of text vertically centered in `rect`, optionally centered or right-aligned horizontally.
// (drawInRect: top-aligns text, which made some labels sit higher than their neighbours.)
static void MicaDrawCenteredLine(NSString *text, NSRect rect, NSDictionary *attributes, NSTextAlignment alignment) {
    if (!text.length) return;
    NSFont *font = attributes[NSFontAttributeName];
    CGFloat width = [text sizeWithAttributes:attributes].width;
    CGFloat x = NSMinX(rect);
    if (alignment == NSTextAlignmentCenter) x += MAX(0, (rect.size.width - width) / 2.0);
    else if (alignment == NSTextAlignmentRight) x += MAX(0, rect.size.width - width);
    [text drawAtPoint:NSMakePoint(x, NSMinY(rect) + MicaCenteredTextBaseline(font, rect.size.height))
       withAttributes:attributes];
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

// The current git branch (or short commit when detached) for a folder, read straight from .git/HEAD:
// no process is started, and linked worktrees (where .git is a file pointing at the real directory) work too.
static NSString *MicaGitBranchForDirectory(NSString *directory) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *current = directory.stringByStandardizingPath;
    for (int depth = 0; depth < 40 && current.length > 1; depth++, current = current.stringByDeletingLastPathComponent) {
        NSString *dotGit = [current stringByAppendingPathComponent:@".git"];
        BOOL isDirectory = NO;
        if (![manager fileExistsAtPath:dotGit isDirectory:&isDirectory]) continue;
        NSString *gitDirectory = dotGit;
        if (!isDirectory) {
            NSString *pointer = [NSString stringWithContentsOfFile:dotGit encoding:NSUTF8StringEncoding error:nil];
            if (![pointer hasPrefix:@"gitdir:"]) return nil;
            gitDirectory = [[pointer substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!gitDirectory.isAbsolutePath) gitDirectory = [current stringByAppendingPathComponent:gitDirectory];
        }
        NSString *head = [[NSString stringWithContentsOfFile:[gitDirectory stringByAppendingPathComponent:@"HEAD"]
            encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([head hasPrefix:@"ref: refs/heads/"]) return [head substringFromIndex:16];
        if ([head hasPrefix:@"ref: "]) return [head.lastPathComponent copy];
        return head.length >= 7 ? [head substringToIndex:7] : nil;
    }
    return nil;
}

// A plain http(s) address at `index` in a line of terminal text, with trailing punctuation removed.
// Agents print bare URLs constantly; OSC 8 links are the only ones terminals get for free.
static NSURL *MicaBareURLInLine(NSString *line, NSUInteger index) {
    if (index >= line.length) return nil;
    NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@" \t<>\"'`|"];
    if ([breaks characterIsMember:[line characterAtIndex:index]]) return nil;
    NSUInteger start = index, end = index;
    while (start > 0 && ![breaks characterIsMember:[line characterAtIndex:start - 1]]) start--;
    while (end + 1 < line.length && ![breaks characterIsMember:[line characterAtIndex:end + 1]]) end++;
    NSString *token = [line substringWithRange:NSMakeRange(start, end - start + 1)];
    // Markdown and prose wrap addresses in brackets and end them with punctuation.
    while (token.length && [@".,;:!?)]}>" containsString:[token substringFromIndex:token.length - 1]]) token = [token substringToIndex:token.length - 1];
    NSRange scheme = [token rangeOfString:@"http" options:NSCaseInsensitiveSearch];
    if (scheme.location == NSNotFound) return nil;
    token = [token substringFromIndex:scheme.location];   // drops a leading "(" or "["
    if (![token.lowercaseString hasPrefix:@"http://"] && ![token.lowercaseString hasPrefix:@"https://"]) return nil;
    return MicaSafeHyperlinkURL(token);
}

static NSString *MicaStandardizedWorkingDirectory(NSString *requestedPath) {
    if (requestedPath.length) return requestedPath.stringByStandardizingPath;
    // A Finder or Dock launch starts in "/"; a home folder is a friendlier first shell.
    NSString *current = NSFileManager.defaultManager.currentDirectoryPath;
    return [current isEqualToString:@"/"] ? NSHomeDirectory() : current;
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

typedef struct {
    NSRect contextRect;
    NSRect hintsRect;
    NSRect memoryRect;
    NSArray<NSString *> *hints;
} MicaStatusBarLayout;

static MicaStatusBarLayout MicaComputeStatusBarLayout(CGFloat width, CGFloat contextX,
        CGFloat minimumContextWidth, CGFloat memoryWidth, NSArray<NSString *> *hints,
        NSDictionary<NSAttributedStringKey, id> *hintAttrs) {
    MicaStatusBarLayout layout = {0};
    layout.memoryRect = NSMakeRect(width - 12 - memoryWidth, 0, memoryWidth, kStatusHeight);
    CGFloat hintRight = NSMinX(layout.memoryRect) - 18;
    CGFloat hintWidth = 0;
    while (hints.count) {
        hintWidth = MAX(0, (hints.count - 1) * 16);
        for (NSString *part in hints) hintWidth += [part sizeWithAttributes:hintAttrs].width;
        if (hintRight - hintWidth >= contextX + minimumContextWidth) break;
        hints = [hints subarrayWithRange:NSMakeRange(0, hints.count - 1)];
    }
    CGFloat hintX = hints.count ? hintRight - hintWidth : hintRight;
    layout.contextRect = NSMakeRect(contextX, 0, MAX(0, hintX - contextX - 18), kStatusHeight);
    layout.hintsRect = NSMakeRect(hintX, 0, hintWidth, kStatusHeight);
    layout.hints = hints;
    return layout;
}

@implementation MicaTerminalView {
    BOOL _selecting;
    BOOL _selectionPending;
    NSPoint _selectionStart;
    NSPoint _selectionEnd;
    uint64_t _selectionHistoryLines;
    MicaTab *_imeTab;
    MicaTab *_draggingTab;
    NSString *_findQuery;
    long _findRow;
    MicaSession *_findSession;
    uint64_t _findScrolled;
    long _findHistory;
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
    NSTimer *_gridSizeRetryTimer;
    BOOL _gridSizeFailureLogged;
    BOOL _leftOptionIsDown;
    BOOL _leftOptionUsedWithAnotherKey;
    BOOL _leftOptionStartedDictation;
}

#pragma mark NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    if (self.owner.dictationUndoValid) self.owner.dictationUndoValid = NO;
    _markedText = nil;
    [self setNeedsDisplay:YES];
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
    [self setNeedsDisplay:YES];
}
- (void)unmarkText { _markedText = nil; [self setNeedsDisplay:YES]; }
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)markedRange { return _markedText ? NSMakeRange(0, _markedText.length) : NSMakeRange(NSNotFound, 0); }
- (BOOL)hasMarkedText { return _markedText != nil; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range; (void)actualRange; return nil;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range; (void)actualRange;
    // Anchor candidate windows to the terminal cursor.
    int row = 0, col = 0;
    MicaSession *session = self.owner.activeTab.session;
    if (session) mica_session_cursor(session, &row, &col);
    NSRect rect = [self cellRectAtRow:row col:col];
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
            label:[self labelForTab:tab] parent:self];
        uint64_t tabID = tab.identifier;
        element.pressHandler = ^BOOL{
            for (NSUInteger current = 0; current < weakSelf.owner.tabs.count; current++)
                if (weakSelf.owner.tabs[current].identifier == tabID) { [weakSelf.owner selectTabAtIndex:(NSInteger)current]; break; }
            return YES;
        };
        [children addObject:element];
    }
    // The focus timer is drawn text in the status strip; expose it as a button that starts, pauses or resumes it.
    NSRect timerRect = [self pomodoroControlRect];
    if (!NSIsEmptyRect(timerRect)) {
        __weak typeof(self) weakSelf = self;
        MicaPomodoro state = self.owner.pomodoro;
        BOOL paused = mica_pomodoro_is_paused(&state);
        BOOL focus = state.phase == MICA_POMODORO_IDLE || state.phase == MICA_POMODORO_FOCUS ||
            state.phase == MICA_POMODORO_PAUSED_FOCUS;
        NSInteger minutes = focus ? self.owner.focusDurationMinutes : self.owner.breakDurationMinutes;
        double remaining = state.phase == MICA_POMODORO_IDLE ? MAX(1, minutes) * 60.0 :
            mica_pomodoro_remaining(&state, MicaContinuousTimeSeconds());
        NSUInteger secondsLeft = (NSUInteger)ceil(remaining);
        NSString *phaseLabel = state.phase == MICA_POMODORO_IDLE ? @"Ready" :
            (paused ? (focus ? @"Paused focus" : @"Paused break") : (focus ? @"Focus" : @"Break"));
        NSString *actionLabel = state.phase == MICA_POMODORO_IDLE ? @"Start focus" :
            (paused ? @"Resume timer" : @"Pause timer");
        NSString *timerLabel = [NSString stringWithFormat:@"Focus timer, %@%@, %02lu:%02lu remaining, %@, %llu focus session%@ completed",
            phaseLabel, self.owner.pomodoroLabel.length ? [NSString stringWithFormat:@", %@", self.owner.pomodoroLabel] : @"",
            (unsigned long)(secondsLeft / 60), (unsigned long)(secondsLeft % 60), actionLabel,
            (unsigned long long)state.completed_focuses, state.completed_focuses == 1 ? @"" : @"s"];
        NSRect resetRect = NSMakeRect(NSMaxX(timerRect) - 29, NSMinY(timerRect), 29, timerRect.size.height);
        NSRect toggleRect = timerRect;
        toggleRect.size.width -= resetRect.size.width;
        MicaTabAccessibilityElement *timer = [MicaTabAccessibilityElement accessibilityElementWithRole:NSAccessibilityButtonRole
            frame:[self.window convertRectToScreen:[self convertRect:toggleRect toView:nil]]
            label:timerLabel parent:self];
        timer.pressHandler = ^BOOL{ [weakSelf.owner togglePomodoroPause:nil]; return YES; };
        if (state.phase != MICA_POMODORO_IDLE) {
            NSString *skipLabel = focus ? @"End focus and start break" : @"End break and start focus";
            timer.accessibilityCustomActions = @[[[NSAccessibilityCustomAction alloc] initWithName:skipLabel handler:^BOOL{
                MicaAppDelegate *owner = weakSelf.owner;
                if (!owner) return NO;
                [owner skipPomodoroPhase:nil];
                return YES;
            }]];
        }
        [children addObject:timer];
        MicaTabAccessibilityElement *reset = [MicaTabAccessibilityElement accessibilityElementWithRole:NSAccessibilityButtonRole
            frame:[self.window convertRectToScreen:[self convertRect:resetRect toView:nil]]
            label:@"Reset focus timer" parent:self];
        reset.pressHandler = ^BOOL{ [weakSelf.owner resetPomodoro:nil]; return YES; };
        [children addObject:reset];
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
    [_gridSizeRetryTimer invalidate];
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
        if (!_leftOptionUsedWithAnotherKey && self.owner.dictationToggleMode) {
            MicaVoiceControllerState state = self.owner.voiceController.state;
            if (state == MicaVoiceControllerStatePreparing || state == MicaVoiceControllerStateListening)
                [self.owner finishPushToTalk];
            else [self.owner beginDictationForActiveTab];
            _leftOptionStartedDictation = NO;
        } else if (!_leftOptionUsedWithAnotherKey) {
            _leftOptionTimer = [NSTimer scheduledTimerWithTimeInterval:0.28
                target:self selector:@selector(leftOptionPressedAlone:) userInfo:nil repeats:NO];
        }
    } else {
        BOOL shouldFinish = _leftOptionIsDown && _leftOptionStartedDictation;
        [_leftOptionTimer invalidate];
        _leftOptionTimer = nil;
        _leftOptionIsDown = NO;
        _leftOptionUsedWithAnotherKey = NO;
        _leftOptionStartedDictation = NO;
        if (shouldFinish && !self.owner.dictationToggleMode) [self.owner finishPushToTalk];
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
    // Link text and target are independent in OSC 8. If the visible text looks like a different address, confirm first.
    NSMutableString *visible = [NSMutableString string];
    for (int row = 0; row < mica_session_rows(tab.session); row++) {
        for (int col = 0; col < mica_session_cols(tab.session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(tab.session, row, col, &cell) || cell.hyperlink_id != hyperlinkID || !cell.chars[0]) continue;
            NSString *glyph = [[NSString alloc] initWithBytes:&cell.chars[0] length:4 encoding:NSUTF32LittleEndianStringEncoding];
            if (glyph) [visible appendString:glyph];
        }
    }
    NSString *shownText = [visible.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *host = url.host.lowercaseString ?: @"";
    if ([shownText containsString:@"."] && ![shownText containsString:@" "] && host.length && ![shownText containsString:host]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"Open a link to %@?", host];
        alert.informativeText = [NSString stringWithFormat:@"The link text reads “%@”, but it points to:\n\n%@",
            shownText.length > 120 ? [[shownText substringToIndex:120] stringByAppendingString:@"…"] : shownText, url.absoluteString];
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Open"];
        if ([alert runModal] != NSAlertSecondButtonReturn) return;
    }
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (NSRect)terminalRect {
    CGFloat previewHeight = self.owner.voiceController.state == MicaVoiceControllerStateIdle ? 0 : kDictationPreviewHeight;
    return NSMakeRect(kTerminalPaddingX, kStatusHeight, MAX(0, self.bounds.size.width - 2 * kTerminalPaddingX),
                      MAX(0, self.bounds.size.height - kHeaderHeight - kStatusHeight - previewHeight));
}

// The full-width band the terminal occupies, padding included, for hit-testing drops and clicks.
// False when another window or app has focus; tests always count as active so renders stay deterministic.
- (BOOL)windowIsActive {
    if (getenv("MICA_TEST_NO_STARTUP")) return YES;
    return self.window.isKeyWindow || self.window == nil;
}

- (NSRect)terminalHitRect {
    NSRect terminal = [self terminalRect];
    return NSMakeRect(0, kStatusHeight, self.bounds.size.width,
                      MAX(0, NSMaxY(terminal) - kStatusHeight));
}

// Room reserved at the left of the tab strip for the traffic lights (none in full screen).
- (CGFloat)tabsLeadingInset {
    return (self.window.styleMask & NSWindowStyleMaskFullScreen) ? 8.0 : kTrafficLightInset;
}

- (NSRect)pomodoroControlRect {
    if (![[self.owner micaDefaults] boolForKey:@"MicaShowStatusTimer"] ||
        self.owner.pomodoro.phase == MICA_POMODORO_IDLE) return NSZeroRect;
    CGFloat x = 12;
    MicaUIMode mode = self.owner.uiMode;
    int offset = self.owner.activeTab.session ? mica_session_view_offset(self.owner.activeTab.session) : 0;
    NSString *modeName = mode == MicaUIModeTab ? @"Tab picker" :
        ((mode == MicaUIModeScroll || offset > 0) ? @"Scrollback" : nil);
    if (modeName) {
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]};
        x = 12 + [modeName sizeWithAttributes:attributes].width + 18 + 12;
    }
    return NSMakeRect(x, floor((kStatusHeight - 23) / 2), 76, 23);
}

- (NSString *)pomodoroStatusText {
    MicaPomodoro timer = self.owner.pomodoro;
    BOOL focus = timer.phase == MICA_POMODORO_IDLE || timer.phase == MICA_POMODORO_FOCUS ||
        timer.phase == MICA_POMODORO_PAUSED_FOCUS;
    NSInteger minutes = focus ? self.owner.focusDurationMinutes : self.owner.breakDurationMinutes;
    double remaining = timer.phase == MICA_POMODORO_IDLE ? MAX(1, minutes) * 60.0 :
        mica_pomodoro_remaining(&timer, MicaContinuousTimeSeconds());
    NSUInteger secondsLeft = (NSUInteger)ceil(remaining);
    return [NSString stringWithFormat:@"%02lu:%02lu",
        (unsigned long)(secondsLeft / 60), (unsigned long)(secondsLeft % 60)];
}

- (void)showPomodoroControlMenu:(id)sender {
    (void)sender;
    MicaPomodoro timer = self.owner.pomodoro;
    NSString *toggleTitle = timer.phase == MICA_POMODORO_IDLE ? @"Start Focus" :
        (mica_pomodoro_is_paused(&timer) ? @"Resume Timer" : @"Pause Timer");
    BOOL focus = timer.phase == MICA_POMODORO_FOCUS || timer.phase == MICA_POMODORO_PAUSED_FOCUS;
    NSString *skipTitle = focus ? @"End Focus & Start Break" : @"End Break & Start Focus";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Focus Timer"];
    NSString *sessionCount = [NSString stringWithFormat:@"%llu focus session%@ completed",
        (unsigned long long)timer.completed_focuses, timer.completed_focuses == 1 ? @"" : @"s"];
    NSMenuItem *summary = AddMenuItem(menu, sessionCount, nil, @"", 0);
    summary.enabled = NO;
    if (self.owner.pomodoroLabel.length) {
        NSMenuItem *label = AddMenuItem(menu, [NSString stringWithFormat:@"Label: %@", self.owner.pomodoroLabel], nil, @"", 0);
        label.enabled = NO;
    }
    AddMenuItem(menu, @"Label…", @selector(editPomodoroLabel:), @"", 0).target = self.owner;
    [menu addItem:NSMenuItem.separatorItem];
    AddMenuItem(menu, toggleTitle, @selector(togglePomodoroPause:), @"", 0).target = self.owner;
    NSMenuItem *skip = AddMenuItem(menu, skipTitle, @selector(skipPomodoroPhase:), @"", 0);
    skip.target = self.owner;
    skip.enabled = timer.phase != MICA_POMODORO_IDLE;
    AddMenuItem(menu, @"Reset Timer", @selector(resetPomodoro:), @"", 0).target = self.owner;
    [menu addItem:NSMenuItem.separatorItem];
    AddMenuItem(menu, @"Timer Settings…", @selector(openPomodoroSettings:), @"", 0).target = self.owner;
    NSPoint location = [self convertPoint:NSEvent.mouseLocation fromView:nil];
    [menu popUpMenuPositioningItem:nil atLocation:location inView:self];
}

- (NSRect)dictationPreviewRect {
    if (!self.owner.voiceController || self.owner.voiceController.state == MicaVoiceControllerStateIdle)
        return NSZeroRect;
    NSRect terminal = [self terminalRect];
    return NSMakeRect(0, NSMaxY(terminal), self.bounds.size.width, kDictationPreviewHeight);
}

- (NSRect)microphoneSettingsButtonRect {
    MicaVoiceController *voice = self.owner.voiceController;
    BOOL denied = voice.state == MicaVoiceControllerStateFailed &&
        ([voice.statusText containsString:@"Microphone access was denied"] ||
         [voice.statusText containsString:@"Microphone access is off"]);
    NSRect preview = [self dictationPreviewRect];
    return denied ? NSMakeRect(MAX(0, self.bounds.size.width - 190), NSMinY(preview) + 12, 178, 24) : NSZeroRect;
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
        if (!mica_session_resize_pixels(tab.session, (int)rows, (int)cols, pixelWidth, pixelHeight)) {
            if (!_gridSizeFailureLogged) {
                MicaDiagnosticsLog(@"resize", [NSString stringWithFormat:
                    @"pty-size resize deferred pid=%d grid=%ldx%ld requested=%ldx%ld; history-index allocation failed",
                    mica_session_pid(tab.session), (long)oldCols, (long)oldRows, (long)cols, (long)rows]);
                _gridSizeFailureLogged = YES;
            }
            if (!_gridSizeRetryTimer) {
                __weak typeof(self) weakSelf = self;
                _gridSizeRetryTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO
                    block:^(NSTimer *timer) {
                        MicaTerminalView *view = weakSelf;
                        if (!view || timer != view->_gridSizeRetryTimer) return;
                        view->_gridSizeRetryTimer = nil;
                        [view updateGridSize];
                    }];
            }
            return;
        }
        [_gridSizeRetryTimer invalidate];
        _gridSizeRetryTimer = nil;
        _gridSizeFailureLogged = NO;
        if (gridChanged) [self clearSelection];
        _cols = cols;
        _rows = rows;
        _pixelWidth = pixelWidth;
        _pixelHeight = pixelHeight;
        _sizedSession = tab.session;
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
    if (self.drawingStatsStartedAt == 0) self.drawingStatsStartedAt = now;
    self.drawingStatsCount++;
    self.drawingStatsTotalDuration += duration;
    self.drawingStatsMaximumDuration = MAX(self.drawingStatsMaximumDuration, duration);
    NSTimeInterval windowDuration = now - self.drawingStatsStartedAt;
    if (windowDuration < 5.0) return;
    if (self.drawingStatsCount >= 150 || self.drawingStatsMaximumDuration >= 0.03) {
        MicaTab *tab = self.owner.activeTab;
        MicaDiagnosticsLog(@"performance", [NSString stringWithFormat:
            @"terminal-render seconds=%.1f draws=%lu draws_per_second=%.1f avg_ms=%.2f max_ms=%.2f pid=%d",
            windowDuration, (unsigned long)self.drawingStatsCount,
            self.drawingStatsCount / windowDuration,
            self.drawingStatsTotalDuration * 1000.0 / MAX(1, self.drawingStatsCount),
            self.drawingStatsMaximumDuration * 1000.0,
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
    return NSMakeRect(NSMinX(area) + col * _charWidth, top - (row + 1) * _lineHeight, _charWidth, _lineHeight);
}

- (NSString *)labelForTab:(MicaTab *)tab {
    return tab.name.length ? tab.name : @"Terminal";
}

- (MicaTabActivityState)activityStateForTab:(MicaTab *)tab {
    if (!tab) return MicaTabActivityStateIdle;
    if (tab.receivedAgentHook) {
        NSString *state = MicaAgentStateForTab(tab);
        if ([state isEqualToString:@"waitingPermission"] || [state isEqualToString:@"waitingInput"]) return MicaTabActivityStateWaiting;
        if ([state isEqualToString:@"working"]) return MicaTabActivityStateRunning;
        if ([state isEqualToString:@"done"]) return MicaTabActivityStateComplete;
        if ([state isEqualToString:@"error"]) return MicaTabActivityStateNeedsAttention;
        return tab.needsAttention ? MicaTabActivityStateNeedsAttention : MicaTabActivityStateIdle;
    }
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
        // Full-screen programs (lazygit, yazi, vim) redraw constantly; that is not work in progress.
        if (!MicaAgentNameForTab(tab) && tab.session && mica_session_alt_screen(tab.session))
            return MicaTabActivityStateIdle;
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
    CGFloat inset = [self tabsLeadingInset];
    NSRect header = NSMakeRect(inset, NSMaxY(self.bounds) - kHeaderHeight,
                               MAX(0, self.bounds.size.width - [self projectBadgeWidth] - inset), kHeaderHeight);
    NSRange visible = [self visibleTabRange];
    if (index < visible.location || index >= NSMaxRange(visible)) return NSZeroRect;
    CGFloat tabWidth = MIN(header.size.width / (CGFloat)count, kTabMaximumWidth);
    CGFloat x = NSMinX(header) + index * tabWidth;
    if ([self hasTabOverflow]) {
        CGFloat tabsWidth = MAX(0, header.size.width - kTabOverflowWidth);
        tabWidth = visible.length ? MIN(tabsWidth / (CGFloat)visible.length, kTabMaximumWidth) : 0;
        x = NSMinX(header) + (index - visible.location) * tabWidth;
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
    CGFloat width = MAX(0, self.bounds.size.width - [self projectBadgeWidth] - [self tabsLeadingInset]);
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
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[self labelForTab:tab]
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
    NSString *label = [self labelForTab:tab];
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
    if (!NSPointInRect(point, [self terminalHitRect]) ||
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
    if (!NSPointInRect(point, [self terminalHitRect])) return NO;
    return [self insertFileURLs:[self fileURLsFromPasteboard:sender.draggingPasteboard]];
}

- (void)drawStatusBarForTab:(MicaTab *)tab {
    NSRect status = NSMakeRect(0, 0, self.bounds.size.width, kStatusHeight);
    [NSColor.controlBackgroundColor setFill];
    NSRectFill(status);
    [MicaSeparatorColor() setStroke];
    NSBezierPath *separator = [NSBezierPath bezierPath];
    [separator moveToPoint:NSMakePoint(0, NSMaxY(status) - 0.5)];
    [separator lineToPoint:NSMakePoint(NSMaxX(status), NSMaxY(status) - 0.5)];
    [separator stroke];

    MicaUIMode mode = self.owner.uiMode;
    int viewOffset = tab.session ? mica_session_view_offset(tab.session) : 0;
    BOOL scrolled = viewOffset > 0;
    BOOL scrollView = mode == MicaUIModeScroll || scrolled;
    NSString *modeName = mode == MicaUIModeTab ? @"Tab picker" : (scrollView ? @"Scrollback" : nil);
    NSColor *modeColor = scrollView ? NSColor.systemPurpleColor : NSColor.controlAccentColor;
    NSDictionary *modeAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: modeColor
    };
    CGFloat contextX = 12;
    if (modeName) {
        NSSize modeSize = [modeName sizeWithAttributes:modeAttrs];
        NSRect badge = NSMakeRect(12, floor((kStatusHeight - 18) / 2), modeSize.width + 18, 18);
        [[modeColor colorWithAlphaComponent:0.18] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:badge xRadius:9 yRadius:9] fill];
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
    NSString *timerText = [self pomodoroStatusText];
    NSColor *timerColor = timerPhase == MICA_POMODORO_IDLE || paused ? MicaSecondaryLabelColor(1.0) :
        (focus ? NSColor.systemGreenColor : NSColor.systemOrangeColor);
    NSRect timerControl = [self pomodoroControlRect];
    if (!NSIsEmptyRect(timerControl)) {
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
            NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: timerColor
        };
        [[timerText uppercaseString] drawAtPoint:NSMakePoint(NSMinX(timerControl) + 25,
            MicaCenteredTextBaseline(timerAttrs[NSFontAttributeName], timerControl.size.height) + NSMinY(timerControl))
            withAttributes:timerAttrs];
        NSString *timerTip = [NSString stringWithFormat:@"%@ · %llu completed today",
            self.owner.pomodoroLabel.length ? self.owner.pomodoroLabel : (self.owner.projectName ?: @"Focus"),
            (unsigned long long)[[self.owner micaDefaults] integerForKey:@"MicaDailyFocusCount"]];
        [self removeAllToolTips];
        self.toolTip = timerTip;
        contextX = NSMaxX(timerControl) + 12;
    } else {
        [self removeAllToolTips];
        self.toolTip = nil;
    }

    NSString *folderName = tab.cwd.length ? tab.cwd : @"/";
    NSString *context = tab.remoteProfile
        ? [NSString stringWithFormat:@"SSH · %@ · %@", tab.remoteProfile[@"name"],
           [tab.remoteProfile[@"remoteDirectory"] length] ? tab.remoteProfile[@"remoteDirectory"] : @"Remote home"]
        : [NSString stringWithFormat:@"Ready · Folder: %@", folderName];
    NSColor *contextColor = MicaSecondaryLabelColor(0.76);
    if (mode == MicaUIModeTab) {
        context = @"Choose a tab";
    } else if (mode == MicaUIModeScroll) {
        context = @"Use arrows or j/k to scroll";
    } else if (tab.remoteProfile && tab.currentCommand.length) {
        context = [NSString stringWithFormat:@"SSH · %@ · Connecting", tab.remoteProfile[@"name"]];
        contextColor = [NSColor.systemGreenColor blendedColorWithFraction:0.40 ofColor:NSColor.labelColor];
    } else if (tab.remoteProfile && tab.tracksCompletion && tab.completedCommand) {
        context = [NSString stringWithFormat:@"SSH · %@ · Disconnected", tab.remoteProfile[@"name"]];
        contextColor = tab.completionStatus == 0 ? MicaSecondaryLabelColor(0.85) : NSColor.systemRedColor;
    } else if (tab.currentCommand.length || MicaAgentNameForTab(tab)) {
        NSString *agent = MicaAgentNameForTab(tab);
        MicaTabActivityState tabState = [self activityStateForTab:tab];
        MicaStatusActivity statusActivity = tabState == MicaTabActivityStateWaiting ? MicaStatusActivityWaiting :
            tabState == MicaTabActivityStateNeedsAttention ? MicaStatusActivityNeedsAttention :
            tabState == MicaTabActivityStateComplete ? MicaStatusActivityFinished :
            tabState == MicaTabActivityStateRunning ? MicaStatusActivityRunning : MicaStatusActivityIdle;
        if (!agent && tab.currentCommand.length && statusActivity == MicaStatusActivityIdle &&
            !(tab.session && mica_session_alt_screen(tab.session))) statusActivity = MicaStatusActivityRunning;
        NSString *commandName = tab.currentCommand.lastPathComponent.length ? tab.currentCommand.lastPathComponent : tab.currentCommand;
        context = MicaStatusContextForCommand(commandName, agent, MicaAgentStateForTab(tab),
            tab.agentActivity, statusActivity, tab.receivedAgentHook, tab.completedCommand, tab.completionStatus);
        contextColor = statusActivity == MicaStatusActivityWaiting ? NSColor.systemOrangeColor :
            statusActivity == MicaStatusActivityNeedsAttention ? NSColor.systemRedColor :
            (statusActivity == MicaStatusActivityFinished ?
                (tab.completionStatus == 0 ? NSColor.systemGreenColor : NSColor.systemRedColor) :
            (statusActivity == MicaStatusActivityRunning ?
                [NSColor.systemGreenColor blendedColorWithFraction:0.40 ofColor:NSColor.labelColor] :
                MicaSecondaryLabelColor(0.85)));
    } else if (tab.completedCommand) {
        NSString *result = tab.completionStatus == 0 ? @"finished successfully" :
            [NSString stringWithFormat:@"exited with status %d", tab.completionStatus];
        context = [NSString stringWithFormat:@"%@ %@", tab.completionLabel.length ? tab.completionLabel : @"Process", result];
        contextColor = tab.completionStatus == 0 ? NSColor.systemGreenColor : NSColor.systemRedColor;
    } else if (viewOffset > 0) {
        context = [NSString stringWithFormat:@"%d lines back · Esc returns live", viewOffset];
    }
    NSDictionary *contextAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5],
        NSForegroundColorAttributeName: contextColor
    };

    NSArray<NSString *> *hintParts = @[@"⌘/ Shortcuts", @"⌥ Dictate", @"⌘1–8 Switch tab",
        @"⌘T New tab", @"⌘Q Quit"];
    NSDictionary *hintAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5],
        NSForegroundColorAttributeName: MicaSecondaryLabelColor(0.70)
    };
    CGFloat minimumContextWidth = 18;
    if (!modeName && !tab.currentCommand.length && !tab.completedCommand && viewOffset == 0) {
        NSString *folderTail = [NSString stringWithFormat:@"…/%@", folderName.lastPathComponent];
        minimumContextWidth += [@"Ready · " sizeWithAttributes:contextAttrs].width +
            [folderTail sizeWithAttributes:contextAttrs].width;
    }
    NSFont *hintFont = hintAttrs[NSFontAttributeName];
    // Live memory readout on the far right; hints use the space that is left.
    NSString *memoryText = self.owner.memoryLabel ?: @"Memory —";
    NSDictionary *memoryAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: MicaSecondaryLabelColor(0.70)
    };
    CGFloat memoryWidth = [memoryText sizeWithAttributes:memoryAttrs].width;
    MicaStatusBarLayout layout = MicaComputeStatusBarLayout(self.bounds.size.width, contextX,
        minimumContextWidth, memoryWidth, hintParts, hintAttrs);
    hintParts = layout.hints;
    CGFloat hintX = NSMinX(layout.hintsRect);
    CGFloat availableWidth = layout.contextRect.size.width;
    MicaDrawCenteredLine(memoryText, layout.memoryRect, memoryAttrs, NSTextAlignmentRight);
    if (!modeName && !tab.currentCommand.length && !tab.completedCommand && viewOffset == 0) {
        NSString *branchSuffix = tab.gitBranch.length ? [NSString stringWithFormat:@"  ·  %@", tab.gitBranch] : @"";
        CGFloat branchWidth = [branchSuffix sizeWithAttributes:contextAttrs].width;
        if (branchWidth > availableWidth * 0.5) { branchSuffix = @""; branchWidth = 0; }
        NSString *folderLabel = @"Ready · ";
        CGFloat labelWidth = [folderLabel sizeWithAttributes:contextAttrs].width;
        CGFloat pathWidth = MAX(0, availableWidth - labelWidth - branchWidth);
        context = [[folderLabel stringByAppendingString:
            MicaTruncatedPath(folderName, pathWidth, contextAttrs)] stringByAppendingString:branchSuffix];
    }
    MicaVoiceController *prefetchVoice = self.owner.voiceController;
    BOOL prefetching = prefetchVoice.isPrefetchingModel;
    if (prefetching) {
        double fraction = prefetchVoice.prefetchFraction;
        context = fraction > 0
            ? [NSString stringWithFormat:@"%@ · %.0f%%", prefetchVoice.prefetchStatus, fraction * 100.0]
            : (prefetchVoice.prefetchStatus.length ? prefetchVoice.prefetchStatus : @"Preparing speech");
        if (![context hasSuffix:@"%"] && ![context hasSuffix:@"…"]) context = [context stringByAppendingString:@"…"];
    }
    CGFloat contextWidth = availableWidth;
    contextWidth = MIN(contextWidth, [context sizeWithAttributes:contextAttrs].width);
    NSString *shortContext = MicaTruncatedText(context, contextWidth, contextAttrs);
    [shortContext drawAtPoint:NSMakePoint(contextX,
        MicaCenteredTextBaseline(contextAttrs[NSFontAttributeName], kStatusHeight)) withAttributes:contextAttrs];
    [MicaSeparatorColor() setStroke];
    NSBezierPath *contextDivider = [NSBezierPath bezierPath];
    [contextDivider moveToPoint:NSMakePoint(floor(hintX - 8) + 0.5, 6)];
    [contextDivider lineToPoint:NSMakePoint(floor(hintX - 8) + 0.5, kStatusHeight - 6)];
    [contextDivider stroke];

    CGFloat x = hintX;
    for (NSUInteger index = 0; index < hintParts.count; index++) {
        NSString *part = hintParts[index];
        [part drawAtPoint:NSMakePoint(x, MicaCenteredTextBaseline(hintFont, kStatusHeight))
             withAttributes:hintAttrs];
        x += [part sizeWithAttributes:hintAttrs].width;
        if (index + 1 < hintParts.count) {
            x += 8;
            [MicaSeparatorColor() setStroke];
            NSBezierPath *hintDivider = [NSBezierPath bezierPath];
            [hintDivider moveToPoint:NSMakePoint(floor(x) + 0.5, 6)];
            [hintDivider lineToPoint:NSMakePoint(floor(x) + 0.5, kStatusHeight - 6)];
            [hintDivider stroke];
            x += 8;
        }
    }
    if (prefetching) {
        NSRect track = NSMakeRect(0, 0, self.bounds.size.width, 2);
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.16] setFill];
        NSRectFill(track);
        double fraction = prefetchVoice.prefetchFraction;
        NSRect fill = track;
        if (fraction > 0) {
            fill.size.width *= fraction;
        } else {
            CGFloat segmentWidth = MIN(100, track.size.width * 0.2);
            CGFloat phase = fmod(NSProcessInfo.processInfo.systemUptime / 1.25, 2.0);
            if (phase > 1.0) phase = 2.0 - phase;
            fill.origin.x += MAX(0, track.size.width - segmentWidth) * phase;
            fill.size.width = segmentWidth;
        }
        [NSColor.controlAccentColor setFill];
        NSRectFill(fill);
    }
}

- (void)drawDictationPreview:(MicaVoiceController *)voice inRect:(NSRect)preview {
    MicaVoiceControllerState state = voice.state;
    NSColor *accent = state == MicaVoiceControllerStateFailed ? NSColor.systemRedColor : NSColor.controlAccentColor;
    NSString *heading = voice.statusText ?: @"";
    if (state == MicaVoiceControllerStateListening) {
        NSUInteger seconds = (NSUInteger)MAX(0, voice.elapsedSeconds);
        heading = self.owner.dictationToggleMode ? @"Listening · press ⌥ to stop" :
            [NSString stringWithFormat:@"Listening · %02lu:%02lu", (unsigned long)(seconds / 60), (unsigned long)(seconds % 60)];
    } else if (state == MicaVoiceControllerStatePreparing) {
        heading = @"Preparing speech…";
    } else if (state == MicaVoiceControllerStateTranscribing) {
        heading = @"Finishing transcript…";
    } else if (state == MicaVoiceControllerStateFailed) {
        heading = @"Dictation failed";
    }
    [NSColor.controlBackgroundColor setFill]; NSRectFill(preview);
    [MicaSeparatorColor() setStroke];
    NSBezierPath *edge = [NSBezierPath bezierPath];
    [edge moveToPoint:NSMakePoint(0, NSMinY(preview) + 0.5)];
    [edge lineToPoint:NSMakePoint(NSMaxX(preview), NSMinY(preview) + 0.5)];
    [edge moveToPoint:NSMakePoint(0, NSMaxY(preview) - 0.5)];
    [edge lineToPoint:NSMakePoint(NSMaxX(preview), NSMaxY(preview) - 0.5)]; [edge stroke];
    NSDictionary *statusAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: state == MicaVoiceControllerStateFailed
            ? NSColor.systemRedColor : NSColor.labelColor
    };
    CGFloat titleY = NSMaxY(preview) - 26;
    BOOL meter = state == MicaVoiceControllerStateListening ||
        (state == MicaVoiceControllerStatePreparing && voice.isCapturing);
    if (meter) {
        static const CGFloat weights[5] = { 0.55, 0.85, 1.0, 0.8, 0.5 };
        CGFloat level = voice.audioLevel;
        for (NSInteger bar = 0; bar < 5; bar++) {
            CGFloat wobble = 0.85 + 0.15 * sin(NSProcessInfo.processInfo.systemUptime * 9.0 + bar * 1.7);
            CGFloat barHeight = 3 + level * 15 * weights[bar] * wobble;
            NSRect wave = NSMakeRect(16 + bar * 4.5, titleY + 3, 2.5, barHeight);
            [[accent colorWithAlphaComponent:state == MicaVoiceControllerStateListening ? 1.0 : 0.6] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:wave xRadius:1.25 yRadius:1.25] fill];
        }
    } else if (state == MicaVoiceControllerStatePreparing || state == MicaVoiceControllerStateTranscribing) {
        CGFloat start = fmod(NSProcessInfo.processInfo.systemUptime * 300.0, 360.0);
        NSBezierPath *arc = [NSBezierPath bezierPath];
        arc.lineWidth = 2;
        arc.lineCapStyle = NSLineCapStyleRound;
        [arc appendBezierPathWithArcWithCenter:NSMakePoint(26, titleY + 8) radius:6
            startAngle:start endAngle:start + 260];
        [accent setStroke];
        [arc stroke];
    } else {
        NSBezierPath *micDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(23, titleY + 5, 6, 6)];
        [accent setFill];
        [micDot fill];
    }
    NSString *text;
    if (state == MicaVoiceControllerStatePreparing) {
        text = voice.statusText.length ? voice.statusText : @"Getting the speech model ready…";
        if (voice.isCapturing) text = @"Getting ready. Keep talking, nothing is lost";
        if (voice.hasProgress)
            text = [NSString stringWithFormat:@"%@  %.0f%%", text, MIN(1.0, MAX(0.0, voice.progress)) * 100.0];
    } else if (state == MicaVoiceControllerStateFailed) {
        text = voice.statusText ?: @"Press Escape to dismiss";
    } else if (voice.transcript.length) {
        text = MicaLastWords(voice.transcript, 20);
    } else {
        text = state == MicaVoiceControllerStateListening ? @"Listening. Your words appear in a few seconds" : @"";
    }
    NSMutableParagraphStyle *tailStyle = [NSMutableParagraphStyle new];
    tailStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *transcriptAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: state == MicaVoiceControllerStateFailed ? NSColor.secondaryLabelColor : NSColor.labelColor,
        NSParagraphStyleAttributeName: tailStyle
    };
    [heading drawAtPoint:NSMakePoint(38, titleY) withAttributes:statusAttrs];
    NSString *keyHint = state == MicaVoiceControllerStateListening ?
        (self.owner.dictationToggleMode ? @"Esc to cancel" : @"Release ⌥ to insert · Esc to cancel") :
        (state == MicaVoiceControllerStateFailed ? @"Esc to dismiss" : @"Esc to cancel");
    NSDictionary *hintAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor
    };
    NSRect settingsButton = [self microphoneSettingsButtonRect];
    CGFloat right = !NSIsEmptyRect(settingsButton) ? NSMinX(settingsButton) - 10 : preview.size.width - 16;
    NSRect transcriptRect = NSMakeRect(16, NSMinY(preview) + 22, MAX(0, right - 16), 50);
    if ((state == MicaVoiceControllerStateListening || state == MicaVoiceControllerStateTranscribing) && voice.transcript.length) {
        for (NSUInteger wordCount = 20; wordCount > 1; wordCount--) {
            text = MicaLastWords(voice.transcript, wordCount);
            NSRect measured = [text boundingRectWithSize:transcriptRect.size
                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading attributes:transcriptAttrs];
            if (measured.size.height <= transcriptRect.size.height) break;
        }
    }
    self.dictationLabelTextRect = NSMakeRect(38, titleY, MAX(0, right - 38), 16);
    self.dictationWordsTextRect = transcriptRect;
    [text drawInRect:transcriptRect withAttributes:transcriptAttrs];
    NSRect hintRect = NSMakeRect(16, NSMinY(preview) + 5, MAX(0, right - 16), 14);
    self.dictationHintTextRect = hintRect;
    [keyHint drawInRect:hintRect withAttributes:hintAttrs];
    if (!NSIsEmptyRect(settingsButton)) {
        NSRect button = settingsButton;
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.14] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:button xRadius:6 yRadius:6] fill];
        NSDictionary *buttonAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: NSColor.controlAccentColor
        };
        MicaDrawCenteredLine(@"Open Microphone Settings", button, buttonAttrs, NSTextAlignmentCenter);
    }

    BOOL showsActivity = state == MicaVoiceControllerStatePreparing || state == MicaVoiceControllerStateTranscribing;
    if (voice.hasProgress || showsActivity) {
        NSRect track = NSMakeRect(0, NSMinY(preview), preview.size.width, 2);
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
    NSInteger col = (NSInteger)floor((point.x - NSMinX([self terminalRect])) / MAX(_charWidth, 1));
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
        [MicaSeparatorColor() setStroke];
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
            NSString *label = [self labelForTab:candidate];
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
                NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:
                    ([self windowIsActive] ? (active ? 1.0 : 0.72) : (active ? 0.6 : 0.42))],
                NSParagraphStyleAttributeName: tabParagraphStyle
            };
            if (textRect.size.width > 0) {
                NSString *shortLabel = MicaTruncatedText(label, textRect.size.width, tabAttrs);
                [shortLabel drawAtPoint:NSMakePoint(NSMinX(textRect),
                    NSMinY(tabRect) + MicaCenteredTextBaseline(tabFont, tabRect.size.height))
                    withAttributes:tabAttrs];
            }
        }
        [MicaSeparatorColor() setStroke];
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
            MicaDrawCenteredLine(moreLabel, moreRect, moreAttrs, NSTextAlignmentCenter);
        }
        if (self.owner.projectName.length) {
            CGFloat badgeWidth = [self projectBadgeWidth];
            NSRect badge = NSMakeRect(self.bounds.size.width - badgeWidth,
                NSMinY(header), badgeWidth, header.size.height);
            NSRect capsule = NSInsetRect(badge, 4, 5);
            [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.16] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:capsule
                xRadius:capsule.size.height / 2 yRadius:capsule.size.height / 2] fill];
            NSMutableParagraphStyle *projectStyle = [NSMutableParagraphStyle new];
            projectStyle.lineBreakMode = NSLineBreakByTruncatingTail;
            NSDictionary *projectAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:kTabTitleFontSize weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: MicaSecondaryLabelColor(1.0),
                NSParagraphStyleAttributeName: projectStyle
            };
            NSRect projectText = NSInsetRect(capsule, 10, 0);
            NSString *projectTitle = MicaTruncatedText(self.owner.projectName,
                projectText.size.width, projectAttrs);
            MicaDrawCenteredLine(projectTitle, projectText, projectAttrs, NSTextAlignmentCenter);
        }
    }
    for (NSInteger row = 0; row < _rows; row++) {
        NSRect rowRect = [self cellRectAtRow:row col:0];
        rowRect.origin.x = 0;
        rowRect.size.width = self.bounds.size.width;
        if (!NSIntersectsRect(rowRect, dirtyRect)) continue;
        int landmarkStatus = 0;
        (void)mica_session_row_landmark(tab.session, (int)row, &landmarkStatus);
        if (landmarkStatus != 0) {
            NSDictionary *failedAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: NSColor.systemRedColor };
            [@"!" drawAtPoint:NSMakePoint(4, NSMinY(rowRect) + 2) withAttributes:failedAttrs];
        }
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
                BOOL cursorFocused = [self windowIsActive];
                if (NSIntersectsRect(cursorRect, dirtyRect) && !cursorFocused) {
                    // Unfocused windows show a hollow cursor so it is obvious where typing will not go.
                    [cursorFill setStroke];
                    NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(cursorRect, 0.75, 0.75)];
                    outline.lineWidth = 1.5;
                    [outline stroke];
                } else if (NSIntersectsRect(cursorRect, dirtyRect) && gMicaCursorStyle != 0) {
                    // Bar and underline cursors leave the glyph readable and only mark its position.
                    [cursorFill setFill];
                    NSRectFill(gMicaCursorStyle == 1
                        ? NSMakeRect(NSMinX(cursorRect), NSMinY(cursorRect), 2.0, cursorRect.size.height)
                        : NSMakeRect(NSMinX(cursorRect), NSMinY(cursorRect), cursorRect.size.width, 2.0));
                } else if (NSIntersectsRect(cursorRect, dirtyRect)) {
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
    if (_markedText.length && mica_session_view_offset(tab.session) == 0) {
        // Show an input method's uncommitted text at the cursor, underlined, until it is committed.
        int markedRow = 0, markedCol = 0;
        mica_session_cursor(tab.session, &markedRow, &markedCol);
        NSRect origin = [self cellRectAtRow:markedRow col:markedCol];
        NSDictionary *markedAttributes = @{
            NSFontAttributeName: self.terminalFont,
            NSForegroundColorAttributeName: MicaForegroundColor(),
            NSBackgroundColorAttributeName: [MicaForegroundColor() colorWithAlphaComponent:0.18],
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
        };
        [_markedText drawAtPoint:NSMakePoint(NSMinX(origin), NSMinY(origin) + 1) withAttributes:markedAttributes];
    }
    if (!mica_session_is_running(tab.session)) {
        int exitStatus = mica_session_exit_status(tab.session);
        NSString *exitMessage = exitStatus == 0 ? @"Shell exited" : [NSString stringWithFormat:@"Shell exited with status %d", exitStatus];
        NSRect exitRect = NSMakeRect(0, kStatusHeight, [self terminalRect].size.width, 28);
        NSDictionary *exitAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: [MicaForegroundColor() colorWithAlphaComponent:0.8] };
        if (NSIntersectsRect(exitRect, dirtyRect))
            [exitMessage drawAtPoint:NSMakePoint(12, kStatusHeight + 4) withAttributes:exitAttrs];
    }
    NSRect status = NSMakeRect(0, 0, self.bounds.size.width, kStatusHeight);
    if (NSIntersectsRect(status, dirtyRect)) [self drawStatusBarForTab:tab];
    NSRect dictationPreview = [self dictationPreviewRect];
    if (!NSIsEmptyRect(dictationPreview) && NSIntersectsRect(dictationPreview, dirtyRect))
        [self drawDictationPreview:self.owner.voiceController inRect:dictationPreview];
    if (self.quickSelectActive) {
        NSDictionary *attrs = @{ NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: NSColor.whiteColor };
        for (NSDictionary *match in self.quickSelectMatches) {
            NSRect rect = [self cellRectAtRow:[match[@"row"] integerValue] col:[match[@"col"] integerValue]];
            NSString *label = match[@"label"];
            NSSize size = [label sizeWithAttributes:attrs];
            rect.origin.y = NSMaxY(rect) - size.height - 1; rect.size = NSMakeSize(size.width + 6, size.height + 3);
            NSColor *hintColor=[match[@"kind"] isEqualToString:@"path"] ? [NSColor.systemGreenColor colorWithAlphaComponent:0.92] :
                ([match[@"kind"] isEqualToString:@"hash"] ? [NSColor.systemPurpleColor colorWithAlphaComponent:0.92] :
                 [NSColor.controlAccentColor colorWithAlphaComponent:0.95]);
            [hintColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:3 yRadius:3] fill];
            [label drawAtPoint:NSMakePoint(NSMinX(rect) + 3, NSMinY(rect) + 1) withAttributes:attrs];
        }
    }
    (void)dirtyRect;
    [self recordDrawDuration:NSProcessInfo.processInfo.systemUptime - drawStartedAt];
}

- (void)keyDown:(NSEvent *)event {
    if (self.quickSelectActive) {
        NSEventModifierFlags quickFlags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSString *label = event.charactersIgnoringModifiers.uppercaseString;
        if (event.keyCode == 53) { self.quickSelectActive = NO; self.quickSelectMatches = nil; self.quickSelectPrefix=nil; [self setNeedsDisplay:YES]; return; }
        if ((event.keyCode == 36 || event.keyCode == 76) && self.quickSelectPrefix.length) {
            [self finishQuickSelectWithLabel:self.quickSelectPrefix option:(quickFlags & NSEventModifierFlagOption) != 0]; return;
        }
        if (!(quickFlags & NSEventModifierFlagCommand) && label.length == 1 &&
            [@"ABCDEFGHIJKLMNOPQRSTUVWXYZ" containsString:label]) {
            NSString *candidate=[(self.quickSelectPrefix ?: @"") stringByAppendingString:label];
            BOOL prefix=NO;
            for (NSDictionary *entry in self.quickSelectMatches) if ([entry[@"label"] hasPrefix:candidate]) { prefix=YES; break; }
            if (prefix) {
                self.quickSelectPrefix=candidate;
                BOOL exact=NO; for (NSDictionary *entry in self.quickSelectMatches) if ([entry[@"label"] isEqualToString:candidate]) { exact=YES; break; }
                if (exact && ![self.quickSelectMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@ AND label != %@",candidate,candidate]].count)
                    [self finishQuickSelectWithLabel:candidate option:(quickFlags & NSEventModifierFlagOption) != 0];
                return;
            }
        }
        return;
    }
    if (self.owner.dictationUndoValid) self.owner.dictationUndoValid = NO;
    MicaTab *tab = self.owner.activeTab;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    BOOL option = (flags & NSEventModifierFlagOption) != 0;
    BOOL control = (flags & NSEventModifierFlagControl) != 0;
    if (command && (event.keyCode == 126 || event.keyCode == 125) && tab.session &&
        !mica_session_alt_screen(tab.session) && mica_session_osc133_state(tab.session) == 'A') {
        if (mica_session_jump_prompt(tab.session, event.keyCode == 126 ? -1 : 1)) {
            [self clearSelection]; [self setNeedsDisplay:YES];
            return;
        }
    }
    NSString *keyString = event.charactersIgnoringModifiers.lowercaseString;
    if (event.keyCode != 58 && _leftOptionIsDown && !_leftOptionStartedDictation) {
        _leftOptionUsedWithAnotherKey = YES;
        [_leftOptionTimer invalidate];
        _leftOptionTimer = nil;
    } else if (event.keyCode != 58 && _leftOptionIsDown && _leftOptionStartedDictation &&
               option && !command && event.characters.length > 0) {
        // Option is also how Italian, German and Spanish layouts type @ # [ ] { }. If the hold turned into
        // dictation just before the character key arrived, drop the dictation and type the character.
        _leftOptionStartedDictation = NO;
        _leftOptionUsedWithAnotherKey = YES;
        [self.owner cancelDictation];
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
        [self.owner toggleCommandPalette:nil];
        return;
    }
    if (command && (flags & NSEventModifierFlagShift) && [keyString isEqualToString:@"u"]) { [self toggleQuickSelect:nil]; return; }
    if (command && (flags & NSEventModifierFlagShift) && [keyString isEqualToString:@"s"]) {
        [self.owner toggleScrollback];
        return;
    }
    if (!command && [self handleNavigationModeKey:event key:keyString control:control]) return;
    BOOL commandArrow = command && (event.keyCode == 126 || event.keyCode == 125);
    if (command && !commandArrow) {
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
        if ([keyString isEqualToString:@"0"]) { self.terminalFont = MicaTerminalFont(kFontSizeDefault); [self.owner resizeActiveSession]; return; }
        if ([keyString isEqualToString:@"k"]) { if (tab.session) { mica_session_clear_scrollback(tab.session); [self clearSelection]; [self setNeedsDisplay:YES]; } return; }
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
        BOOL punctuation = composed >= 0x21 && composed <= 0x7e && !isalnum((int)composed);
        if (composed >= 0x21 && composed <= 0x7e &&
            (punctuation || ![characters isEqualToString:event.charactersIgnoringModifiers]))
            modifiers &= ~VTERM_MOD_ALT;
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
    _draggingTab = nil;
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
        [self.owner togglePomodoroPause:nil];
        return;
    }
    NSRect dictationStatus = [self dictationPreviewRect];
    NSRect microphoneSettings = [self microphoneSettingsButtonRect];
    if (!NSIsEmptyRect(microphoneSettings) && NSPointInRect(point, microphoneSettings)) {
        [NSWorkspace.sharedWorkspace openURL:MicaMicrophoneSettingsURL()];
        return;
    }
    if (!NSIsEmptyRect(dictationStatus) && NSPointInRect(point, dictationStatus)) return;
    NSRect header = NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight,
                               self.bounds.size.width, kHeaderHeight);
    if (NSPointInRect(point, header)) {
        if (NSPointInRect(point, [self tabOverflowRect])) {
            [[self tabOverflowMenu] popUpMenuPositioningItem:nil atLocation:point inView:self];
            return;
        }
        NSInteger index = [self tabIndexAtPoint:point];
        if (index != NSNotFound) {
            [self.owner selectTabAtIndex:index];
            _draggingTab = self.owner.tabs[(NSUInteger)index];
        } else if (event.clickCount == 2) {
            [self.window performZoom:nil];   // double-click empty title area, like any Mac title bar
        } else {
            [self.window performWindowDragWithEvent:event];
        }
        return;
    }
    NSRect terminal = [self terminalHitRect];
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
        // No OSC 8 link here: open a plain http(s) address if one is under the pointer.
        MicaSession *clickSession = self.owner.activeTab.session;
        NSMutableString *line = [NSMutableString string];
        int firstRow = (int)cell.y, lastRow = (int)cell.y;
        while (mica_session_row_continues(clickSession, firstRow)) firstRow--;
        while (lastRow + 1 < mica_session_rows(clickSession) &&
               mica_session_row_continues(clickSession, lastRow + 1)) lastRow++;
        NSUInteger clickedIndex = 0;
        for (int row = firstRow; row <= lastRow; row++) {
            if (row > firstRow) {
                while (line.length && [line characterAtIndex:line.length - 1] == ' ')
                    [line deleteCharactersInRange:NSMakeRange(line.length - 1, 1)];
            }
            for (int col = 0; col < mica_session_cols(clickSession); col++) {
                MicaCell probe;
                if (!mica_session_get_cell(clickSession, row, col, &probe) || CellIsContinuation(probe)) continue;
                if (row == (int)cell.y && col <= (int)cell.x) clickedIndex = line.length;
                uint32_t codepoint = probe.chars[0] ? probe.chars[0] : ' ';
                NSString *glyph = [[NSString alloc] initWithBytes:&codepoint length:4 encoding:NSUTF32LittleEndianStringEncoding];
                [line appendString:glyph ?: @" "];
            }
        }
        NSURL *bare = MicaBareURLInLine(line, clickedIndex);
        if (bare) {
#if defined(MICA_APP_NO_MAIN)
            if (self.testOpenURLHandler) { self.testOpenURLHandler(bare); return; }
#endif
            [NSWorkspace.sharedWorkspace openURL:bare];
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
    NSInteger tabIndex = [self tabIndexAtPoint:point];
    if (tabIndex != NSNotFound) {
        MicaTab *tab = self.owner.tabs[(NSUInteger)tabIndex];
        [NSMenu popUpContextMenu:[self.owner notificationMenuForTab:tab] withEvent:event forView:self];
        return;
    }
    if (NSPointInRect(point, [self pomodoroControlRect])) {
        [self showPomodoroControlMenu:nil];
        return;
    }
    [super rightMouseDown:event];
}

- (void)mouseDragged:(NSEvent *)event {
    if (_draggingTab) {
        // Drag a tab sideways to reorder it; the active tab stays active.
        NSPoint dragPoint = [self convertPoint:event.locationInWindow fromView:nil];
        if (dragPoint.y < NSMaxY(self.bounds) - kHeaderHeight - 24) { _draggingTab = nil; return; }
        NSInteger target = [self tabIndexAtPoint:dragPoint];
        NSMutableArray<MicaTab *> *tabs = self.owner.tabs;
        NSUInteger current = [tabs indexOfObjectIdenticalTo:_draggingTab];
        if (target != NSNotFound && current != NSNotFound && (NSUInteger)target != current) {
            MicaTab *active = self.owner.activeTab;
            [tabs removeObjectAtIndex:current];
            [tabs insertObject:_draggingTab atIndex:(NSUInteger)target];
            self.owner.activeIndex = (NSInteger)[tabs indexOfObjectIdenticalTo:active];
            [self setNeedsDisplayInRect:NSMakeRect(0, NSMaxY(self.bounds) - kHeaderHeight, self.bounds.size.width, kHeaderHeight)];
        }
        return;
    }
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

- (void)findInScrollback:(id)sender {
    (void)sender;
    MicaSession *session = self.owner.activeTab.session;
    if (!session) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Find in Scrollback";
    alert.informativeText = @"Search is case-insensitive. Use ⌘G and ⇧⌘G to step through matches.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = _findQuery ?: @"";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Find"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    if ([alert runModal] != NSAlertFirstButtonReturn || !field.stringValue.length) return;
    _findQuery = [field.stringValue copy];
    _findRow = -1;
    [self findNext:YES];
}

- (void)findNext:(BOOL)backward {
    MicaSession *session = self.owner.activeTab.session;
    if (!session || !_findQuery.length) { NSBeep(); return; }
    // Keep the remembered match valid: reset per session, and rebase when full scrollback drops old lines.
    uint64_t scrolledNow = mica_session_scrolled_lines(session);
    long historyNow = (long)mica_session_history_lines(session);
    if (session != _findSession) { _findSession = session; _findRow = -1; }
    else if (_findRow >= 0) {
        long dropped = (long)(scrolledNow - _findScrolled) - (historyNow - _findHistory);
        if (dropped > 0) _findRow = MAX(-1, _findRow - dropped);
    }
    _findScrolled = scrolledNow;
    _findHistory = historyNow;
    [self clearSelection];
    if (!mica_session_find(session, _findQuery.UTF8String, backward, &_findRow)) NSBeep();
    else {
        // Highlight the matching line by selecting it (so it can also be copied).
        long viewRow = _findRow - (long)mica_session_history_lines(session) + (long)mica_session_view_offset(session);
        if (viewRow >= 0 && viewRow < _rows) {
            NSRect rect = [self cellRectAtRow:viewRow col:0];
            CGFloat midY = NSMidY(rect);
            _selectionStart = NSMakePoint(NSMinX([self terminalRect]) + 0.5, midY);
            _selectionEnd = NSMakePoint(NSMinX([self terminalRect]) + _cols * _charWidth - 0.5, midY);
            _selecting = YES;
            _selectionPending = NO;
            _selectionSession = session;
            _selectionHistoryLines = mica_session_scrolled_lines(session);
        }
    }
    [self setNeedsDisplay:YES];
}
- (void)findNextMatch:(id)sender { (void)sender; [self findNext:NO]; }
- (void)findPreviousMatch:(id)sender { (void)sender; [self findNext:YES]; }

- (void)clearScrollbackMenu:(id)sender {
    (void)sender;
    MicaSession *session = self.owner.activeTab.session;
    if (!session) return;
    mica_session_clear_scrollback(session);
    [self clearSelection];
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
    _draggingTab = nil;
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
    if (self.testCopyHandler) self.testCopyHandler(output);
    else {
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        [pasteboard setString:output forType:NSPasteboardTypeString];
    }
}

- (void)selectLastCommandOutput:(id)sender {
    (void)sender;
    MicaSession *session = self.owner.activeTab.session;
    if (!session) return;
    NSInteger end = -1, start = -1;
    for (NSInteger row = 0; row < _rows; row++) {
        int status = 0;
        uint8_t mark = mica_session_row_landmark(session, (int)row, &status);
        if (mark & MICA_LANDMARK_FINISHED) end = row;
    }
    if (end < 0) return;
    for (NSInteger row = end; row >= 0; row--) {
        if (mica_session_row_landmark(session, (int)row, NULL) & MICA_LANDMARK_COMMAND) { start = row; break; }
    }
    if (start < 0 || start > end) return;
    NSRect first = [self cellRectAtRow:start col:0], last = [self cellRectAtRow:end col:MAX(0, _cols - 1)];
    _selectionStart = NSMakePoint(NSMinX(first), NSMidY(first));
    _selectionEnd = NSMakePoint(NSMaxX(last), NSMidY(last));
    _selectionSession = session;
    _selectionHistoryLines = mica_session_scrolled_lines(session);
    _selecting = YES; _selectionPending = NO;
    [self setNeedsDisplay:YES];
}

- (void)copyLastCommandOutput:(id)sender {
    [self selectLastCommandOutput:sender];
    [self copySelection:sender];
}

- (NSArray<NSDictionary *> *)quickSelectCandidates {
    MicaSession *session = self.owner.activeTab.session;
    if (!session) return @[];
    NSMutableString *text = [NSMutableString string]; NSMutableArray<NSValue *> *positions = [NSMutableArray array];
    int rows = mica_session_rows(session), cols = mica_session_cols(session);
    for (int row = 0; row < rows; row++) {
        if (row && !mica_session_row_continues(session, row)) [text appendString:@"\n"];
        for (int col = 0; col < cols; col++) {
            MicaCell cell; if (!mica_session_get_cell(session, row, col, &cell) || CellIsContinuation(cell)) continue;
            uint32_t cp = cell.chars[0] ?: ' ';
            NSString *glyph = [[NSString alloc] initWithBytes:&cp length:4 encoding:NSUTF32LittleEndianStringEncoding] ?: @" ";
            NSUInteger n = glyph.length; [text appendString:glyph];
            for (NSUInteger i = 0; i < n; i++) [positions addObject:[NSValue valueWithPoint:NSMakePoint(col, row)]];
        }
    }
    NSMutableArray *found = [NSMutableArray array];
    NSArray *patterns = @[@"https?://[^\\s<>\\\"'`|]+", @"(?<![A-Za-z0-9])[0-9a-fA-F]{7,40}(?![A-Za-z0-9])",
        @"\\\"[^\\\"\\n]+\\\"|(?:\\./|\\.\\./|/|~/)[^\\s<>\\\"'`|]+|(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+"];
    NSArray *kinds = @[@"url", @"hash", @"path"];
    for (NSUInteger p = 0; p < patterns.count; p++) {
        if (found.count >= 64) break;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:patterns[p] options:0 error:nil];
        for (NSTextCheckingResult *m in [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
            if (found.count >= 64) break;
            NSString *value = [text substringWithRange:m.range];
            while (value.length && [@".,;:!?)]}" containsString:[value substringFromIndex:value.length-1]]) value = [value substringToIndex:value.length-1];
            if (!value.length) continue;
            if (p == 0 && !MicaSafeHyperlinkURL(value)) continue;
            if (p == 2) {
                if ([value hasPrefix:@"\""] && value.length > 1) value = [value substringWithRange:NSMakeRange(1,value.length-2)];
                NSString *path = [value stringByExpandingTildeInPath];
                if (![path isAbsolutePath]) path = [self.owner.activeTab.cwd stringByAppendingPathComponent:path];
                value = path;
            }
            NSUInteger ix = m.range.location; if (ix >= positions.count) continue;
            NSPoint point = positions[ix].pointValue;
            [found addObject:@{@"value":value,@"kind":kinds[p],@"row":@((NSInteger)point.y),@"col":@((NSInteger)point.x),@"offset":@(m.range.location)}];
        }
    }
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"offset"] compare:b[@"offset"]]; }];
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i=0; i<found.count; i++) {
        NSUInteger v=i+1; NSMutableString *label=[NSMutableString string];
        while (v) { NSUInteger digit=(v-1)%26; [label insertString:[NSString stringWithFormat:@"%C",(unichar)('A'+digit)] atIndex:0]; v=(v-1)/26; }
        NSMutableDictionary *item=[found[i] mutableCopy]; item[@"label"]=label; [result addObject:item];
    }
    return result;
}
- (void)toggleQuickSelect:(id)sender {
    (void)sender;
    if (self.quickSelectActive) { self.quickSelectActive=NO; self.quickSelectMatches=nil; [self setNeedsDisplay:YES]; return; }
    NSArray *candidates=[self quickSelectCandidates];
    NSMutableArray *paths=[NSMutableArray array];
    for (NSDictionary *item in candidates) if ([item[@"kind"] isEqual:@"path"] && paths.count < 64) [paths addObject:item];
    if (!paths.count) { self.quickSelectMatches=candidates; self.quickSelectPrefix=nil; self.quickSelectActive=candidates.count>0; [self setNeedsDisplay:YES]; return; }
    NSString *base=self.owner.activeTab.cwd ?: @"/";
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+0.5;
        NSMutableSet *existing=[NSMutableSet set]; NSFileManager *fm=NSFileManager.defaultManager;
        for (NSDictionary *item in paths) {
            if (NSProcessInfo.processInfo.systemUptime >= deadline) break;
            NSString *path=[item[@"value"] stringByExpandingTildeInPath];
            if (![path isAbsolutePath]) path=[base stringByAppendingPathComponent:path];
            if ([fm fileExistsAtPath:path]) [existing addObject:item[@"value"]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            MicaTerminalView *view=weakSelf; if (!view) return;
            NSMutableArray *matches=[NSMutableArray array];
            for (NSDictionary *item in candidates) if (![item[@"kind"] isEqual:@"path"] || [existing containsObject:item[@"value"]]) [matches addObject:item];
            for (NSUInteger i=0;i<matches.count;i++) {
                NSUInteger value=i+1; NSMutableString *label=[NSMutableString string];
                while (value) { NSUInteger digit=(value-1)%26; [label insertString:[NSString stringWithFormat:@"%C",(unichar)('A'+digit)] atIndex:0]; value=(value-1)/26; }
                NSMutableDictionary *item=[matches[i] mutableCopy]; item[@"label"]=label; matches[i]=item;
            }
            view.quickSelectMatches=matches; view.quickSelectPrefix=nil; view.quickSelectActive=matches.count>0; [view setNeedsDisplay:YES];
        });
    });
}
- (void)finishQuickSelectWithLabel:(NSString *)label option:(BOOL)option {
    NSDictionary *item=[self.quickSelectMatches filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"label == %@",label]].firstObject;
    self.quickSelectActive=NO; self.quickSelectMatches=nil; self.quickSelectPrefix=nil; [self setNeedsDisplay:YES]; if (!item) return;
    NSString *value=item[@"value"], *kind=item[@"kind"];
    if (option) {
        NSURL *url=[kind isEqualToString:@"url"] ? [NSURL URLWithString:value] : [NSURL fileURLWithPath:value];
#if defined(MICA_APP_NO_MAIN)
        if (self.testRevealURLHandler) { self.testRevealURLHandler(url); return; }
#endif
        if ([kind isEqualToString:@"path"]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
        else [NSWorkspace.sharedWorkspace openURL:url];
    } else {
#if defined(MICA_APP_NO_MAIN)
        self.testClipboardText=value;
#else
        NSPasteboard *pasteboard=NSPasteboard.generalPasteboard; [pasteboard clearContents]; [pasteboard setString:value forType:NSPasteboardTypeString];
#endif
    }
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
    // Without bracketed paste every pasted newline runs as if Return were pressed; confirm multi-line pastes.
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if (!mica_session_bracketed_paste(tab.session) && !getenv("MICA_TEST_NO_STARTUP") &&
        ([trimmed containsString:@"\n"] || [trimmed containsString:@"\r"])) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Paste multiple lines?";
        alert.informativeText = @"This program isn't expecting a paste, so each line will run as soon as it is pasted.";
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Paste"];
        if ([alert runModal] != NSAlertSecondButtonReturn) return;
    }
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
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:layoutPath error:nil];
        unsigned long long layoutSize = [attributes[NSFileSize] unsignedLongLongValue];
        NSString *contents = layoutSize <= 64 * 1024
            ? [NSString stringWithContentsOfFile:layoutPath encoding:NSUTF8StringEncoding error:nil] : nil;
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
            if (tabs.count >= 64) { *stop = YES; return; }
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
    if (self.rows.count > 64) {
        [self showError:@"A project layout can contain at most 64 tabs."];
        return;
    }
    NSMutableString *contents = [NSMutableString stringWithFormat:@"# Mica layout v1\n# Mica project: %@\n", name];
    [self.originalLayoutContents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if ([line hasPrefix:@"#"] && ![line hasPrefix:@"# Mica layout v"] &&
            ![line hasPrefix:@"# Mica project: "])
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
    if ([contents lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 64 * 1024) {
        [self showError:@"A project layout cannot exceed 64 KiB."];
        return;
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

@implementation MicaSSHProfilesController
- (instancetype)initWithOwner:(MicaAppDelegate *)owner {
    self = [super initWithWindow:nil];
    if (!self) return nil;
    self.appDelegate = owner;
    self.rows = [NSMutableArray array];
    id storedObject = [owner.micaDefaults objectForKey:@"MicaSSHProfiles"];
    NSArray *stored = [storedObject isKindOfClass:NSDictionary.class] && [storedObject[@"version"] integerValue] == 1
        ? ([storedObject[@"profiles"] isKindOfClass:NSArray.class] ? storedObject[@"profiles"] : @[])
        : ([storedObject isKindOfClass:NSArray.class] ? storedObject : @[]);
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (id candidate in [stored isKindOfClass:NSArray.class] ? stored : @[]) {
        NSDictionary *profile = MicaSSHProfileNormalize(candidate, NULL);
        if (profile && ![identifiers containsObject:profile[@"id"]]) {
            [self.rows addObject:[profile mutableCopy]];
            [identifiers addObject:profile[@"id"]];
        }
        if (self.rows.count >= MicaSSHProfileMaximumCount) break;
    }

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 450)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"SSH Connections";
    window.releasedWhenClosed = NO;
    self.window = window;
    NSView *content = window.contentView;

    NSTextField *description = [NSTextField labelWithString:
        @"Profiles use macOS OpenSSH and your existing ~/.ssh/config, keys, agent, and VPN. Mica does not store credentials."];
    description.maximumNumberOfLines = 2;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    NSArray<NSString *> *titles = @[@"Name", @"SSH destination", @"Remote starting folder (optional)"];
    NSArray<NSString *> *identifiersForColumn = @[@"name", @"destination", @"remoteDirectory"];
    NSArray<NSNumber *> *widths = @[@160, @220, @340];
    for (NSUInteger index = 0; index < identifiersForColumn.count; index++) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifiersForColumn[index]];
        column.title = titles[index];
        column.width = widths[index].doubleValue;
        column.editable = YES;
        [self.tableView addTableColumn:column];
    }
    scroll.documentView = self.tableView;
    NSButton *addButton = [NSButton buttonWithTitle:@"Add Profile" target:self action:@selector(addProfile:)];
    NSButton *removeButton = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(removeProfile:)];
    NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    NSButton *saveButton = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
    NSButton *connectButton = [NSButton buttonWithTitle:@"Connect" target:self action:@selector(connectSelected:)];
    saveButton.keyEquivalent = @"\r";
    cancelButton.keyEquivalent = @"\033";
    for (NSView *view in @[description, scroll, addButton, removeButton, cancelButton, saveButton, connectButton]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [description.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [description.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [description.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [scroll.topAnchor constraintEqualToAnchor:description.bottomAnchor constant:12],
        [scroll.bottomAnchor constraintEqualToAnchor:addButton.topAnchor constant:-12],
        [addButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [addButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [removeButton.leadingAnchor constraintEqualToAnchor:addButton.trailingAnchor constant:8],
        [removeButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor],
        [connectButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [connectButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor],
        [saveButton.trailingAnchor constraintEqualToAnchor:connectButton.leadingAnchor constant:-8],
        [saveButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor],
        [cancelButton.trailingAnchor constraintEqualToAnchor:saveButton.leadingAnchor constant:-8],
        [cancelButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor],
    ]];
    [self.tableView reloadData];
    return self;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return (NSInteger)self.rows.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    return self.rows[(NSUInteger)row][column.identifier] ?: @"";
}
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    if (row >= 0 && row < (NSInteger)self.rows.count)
        self.rows[(NSUInteger)row][column.identifier] = [value isKindOfClass:NSString.class] ? value : @"";
}
- (void)addProfile:(id)sender {
    (void)sender;
    if (self.rows.count >= MicaSSHProfileMaximumCount) {
        [self showError:@"Mica supports up to 64 SSH profiles."];
        return;
    }
    [self.rows addObject:[@{@"id":NSUUID.UUID.UUIDString, @"name":@"New Connection",
        @"destination":@"", @"remoteDirectory":@""} mutableCopy]];
    [self.tableView reloadData];
    NSInteger row = (NSInteger)self.rows.count - 1;
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self.tableView editColumn:0 row:row withEvent:nil select:YES];
}
- (void)removeProfile:(id)sender {
    (void)sender;
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.rows.count) return;
    [self.rows removeObjectAtIndex:(NSUInteger)row];
    [self.tableView reloadData];
}
- (void)cancel:(id)sender {
    (void)sender;
    [self.appDelegate.window endSheet:self.window returnCode:NSModalResponseCancel];
    [self.window orderOut:nil];
}
- (NSArray<NSDictionary<NSString *, NSString *> *> *)validatedProfiles {
    [self.tableView.window makeFirstResponder:self.tableView];
    if (self.rows.count > MicaSSHProfileMaximumCount) {
        [self showError:@"Mica supports up to 64 SSH profiles."];
        return nil;
    }
    NSMutableArray *profiles = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set], *names = [NSMutableSet set];
    for (NSUInteger index = 0; index < self.rows.count; index++) {
        NSError *error = nil;
        NSDictionary *profile = MicaSSHProfileNormalize(self.rows[index], &error);
        NSString *foldedName = [profile[@"name"] lowercaseString];
        if (!profile || [ids containsObject:profile[@"id"]] || [names containsObject:foldedName]) {
            NSString *message = profile ? @"Profile names and identifiers must be unique." : error.localizedDescription;
            [self showError:[NSString stringWithFormat:@"Profile %lu: %@", (unsigned long)(index + 1), message ?: @"Invalid profile."]];
            return nil;
        }
        [ids addObject:profile[@"id"]];
        [names addObject:foldedName];
        [profiles addObject:profile];
    }
    return profiles;
}
- (void)save:(id)sender {
    (void)sender;
    NSArray *profiles = [self validatedProfiles];
    if (!profiles) return;
    [self.appDelegate.micaDefaults setObject:@{@"version":@1, @"profiles":profiles} forKey:@"MicaSSHProfiles"];
    [self.appDelegate.window endSheet:self.window returnCode:NSModalResponseOK];
    [self.window orderOut:nil];
}
- (void)connectSelected:(id)sender {
    (void)sender;
    NSInteger selected = self.tableView.selectedRow;
    if (selected < 0 || selected >= (NSInteger)self.rows.count) {
        [self showError:@"Select an SSH profile to connect."];
        return;
    }
    NSArray *profiles = [self validatedProfiles];
    if (!profiles) return;
    NSDictionary *profile = profiles[(NSUInteger)selected];
    [self.appDelegate.micaDefaults setObject:@{@"version":@1, @"profiles":profiles} forKey:@"MicaSSHProfiles"];
    [self.appDelegate.window endSheet:self.window returnCode:NSModalResponseOK];
    [self.window orderOut:nil];
    [self.appDelegate openSSHProfile:profile];
}
- (void)showError:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"SSH profiles could not be saved";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
@end

@implementation MicaPaletteSearchField
- (void)keyDown:(NSEvent *)event {
    NSString *key = event.charactersIgnoringModifiers;
    if (event.keyCode == 53) { [self.paletteOwner toggleCommandPalette:nil]; return; }
    if (event.keyCode == 126) { [self.paletteOwner moveCommandPaletteSelection:-1]; return; }
    if (event.keyCode == 125) { [self.paletteOwner moveCommandPaletteSelection:1]; return; }
    if (event.keyCode == 36 || event.keyCode == 76) { [self.paletteOwner runCommandPaletteSelection:nil]; return; }
    (void)key;
    [super keyDown:event];
}
@end
@implementation MicaPaletteRowView
- (NSString *)accessibilityLabel { return self.paletteAccessibilityLabel; }
@end
@implementation MicaPaletteTableView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) { [self.paletteOwner toggleCommandPalette:nil]; return; }
    if (event.keyCode == 36 || event.keyCode == 76) { [self.paletteOwner runCommandPaletteSelection:nil]; return; }
    [super keyDown:event];
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

static BOOL MicaPomodoroLabelIsValid(id value) {
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] > 80) return NO;
    NSCharacterSet *controls = NSCharacterSet.controlCharacterSet;
    for (NSUInteger i = 0; i < [(NSString *)value length]; i++)
        if ([controls characterIsMember:[(NSString *)value characterAtIndex:i]]) return NO;
    return YES;
}

- (void)savePomodoroState {
    MicaAppDelegate *root = MicaControllers().firstObject;
    if (root && root != self) {
        root.pomodoro = self.pomodoro; root.pomodoroLabel = self.pomodoroLabel;
        root.focusDurationMinutes = self.focusDurationMinutes; root.breakDurationMinutes = self.breakDurationMinutes;
        root.autoStartFocus = self.autoStartFocus; root.autoStartBreaks = self.autoStartBreaks;
        root.pomodoroCycleFocusMinutes = self.pomodoroCycleFocusMinutes;
        root.pomodoroCycleBreakMinutes = self.pomodoroCycleBreakMinutes;
        [root savePomodoroState]; return;
    }
    NSUserDefaults *defaults = [self micaDefaults];
    if (mica_pomodoro_is_running(&_pomodoro))
        [defaults setDouble:NSDate.date.timeIntervalSince1970 + mica_pomodoro_remaining(&_pomodoro, MicaContinuousTimeSeconds()) forKey:@"MicaPomodoroEndsAt"];
    else [defaults removeObjectForKey:@"MicaPomodoroEndsAt"];
    [defaults setInteger:self.focusDurationMinutes forKey:@"MicaPomodoroFocusMinutes"];
    [defaults setInteger:self.breakDurationMinutes forKey:@"MicaPomodoroBreakMinutes"];
    [defaults setBool:self.autoStartFocus forKey:@"MicaPomodoroAutoStartFocus"];
    [defaults setBool:self.autoStartBreaks forKey:@"MicaPomodoroAutoStartBreaks"];
    [defaults setObject:self.pomodoroLabel ?: @"" forKey:@"MicaPomodoroLabel"];
    if (mica_pomodoro_is_running(&_pomodoro))
        [defaults setInteger:(NSInteger)self.pomodoro.phase forKey:@"MicaPomodoroPhase"];
    else [defaults removeObjectForKey:@"MicaPomodoroPhase"];
}

- (BOOL)savePomodoroDurationsFocusMinutes:(NSInteger)focusMinutes breakMinutes:(NSInteger)breakMinutes {
    return [self savePomodoroSettingsFocusMinutes:focusMinutes breakMinutes:breakMinutes
        autoStartFocus:self.autoStartFocus autoStartBreaks:self.autoStartBreaks];
}

- (BOOL)savePomodoroSettingsFocusMinutes:(NSInteger)focusMinutes breakMinutes:(NSInteger)breakMinutes
    autoStartFocus:(BOOL)autoStartFocus autoStartBreaks:(BOOL)autoStartBreaks {
    if (focusMinutes < 1 || focusMinutes > kMaximumFocusMinutes || breakMinutes < 1 || breakMinutes > kMaximumBreakMinutes) return NO;
    self.focusDurationMinutes = focusMinutes; self.breakDurationMinutes = breakMinutes;
    self.autoStartFocus = autoStartFocus; self.autoStartBreaks = autoStartBreaks;
    [self savePomodoroState]; return YES;
}

- (void)refreshPomodoroState {
    MicaAppDelegate *root = MicaControllers().firstObject ?: self;
    for (MicaAppDelegate *controller in MicaControllers()) {
        controller.pomodoro = root.pomodoro;
        controller.pomodoroLabel = root.pomodoroLabel;
        controller.focusDurationMinutes = root.focusDurationMinutes;
        controller.breakDurationMinutes = root.breakDurationMinutes;
        controller.autoStartFocus = root.autoStartFocus;
        controller.autoStartBreaks = root.autoStartBreaks;
        controller.pomodoroCycleFocusMinutes = root.pomodoroCycleFocusMinutes;
        controller.pomodoroCycleBreakMinutes = root.pomodoroCycleBreakMinutes;
        [controller.terminalView setNeedsDisplay:YES];
    }
    [root updateFocusMenuLabel];
    [root updatePomodoroTimer];
}

- (void)configurePomodoro {
    NSUserDefaults *defaults = [self micaDefaults];
    self.focusDurationMinutes = [defaults integerForKey:@"MicaPomodoroFocusMinutes"];
    self.breakDurationMinutes = [defaults integerForKey:@"MicaPomodoroBreakMinutes"];
    if (self.focusDurationMinutes < 1 || self.focusDurationMinutes > kMaximumFocusMinutes) self.focusDurationMinutes = kDefaultFocusMinutes;
    if (self.breakDurationMinutes < 1 || self.breakDurationMinutes > kMaximumBreakMinutes) self.breakDurationMinutes = kDefaultBreakMinutes;
    self.autoStartFocus = [defaults objectForKey:@"MicaPomodoroAutoStartFocus"] ? [defaults boolForKey:@"MicaPomodoroAutoStartFocus"] : YES;
    self.autoStartBreaks = [defaults objectForKey:@"MicaPomodoroAutoStartBreaks"] ? [defaults boolForKey:@"MicaPomodoroAutoStartBreaks"] : YES;
    self.pomodoroLabel = MicaPomodoroLabelIsValid([defaults stringForKey:@"MicaPomodoroLabel"]) ? [defaults stringForKey:@"MicaPomodoroLabel"] : @"";
    self.pomodoroCycleFocusMinutes = self.focusDurationMinutes;
    self.pomodoroCycleBreakMinutes = self.breakDurationMinutes;
    double endsAt = [defaults doubleForKey:@"MicaPomodoroEndsAt"];
    _pomodoro.phase = endsAt > 0 ? (MicaPomodoroPhase)[defaults integerForKey:@"MicaPomodoroPhase"] : MICA_POMODORO_IDLE;
    double left = endsAt - NSDate.date.timeIntervalSince1970;
    BOOL expiredOnRelaunch = NO;
    if (_pomodoro.phase == MICA_POMODORO_FOCUS || _pomodoro.phase == MICA_POMODORO_BREAK) {
        if (left <= 0) {
            expiredOnRelaunch = YES;
            _pomodoro.phase = _pomodoro.phase == MICA_POMODORO_FOCUS ? MICA_POMODORO_PAUSED_BREAK : MICA_POMODORO_PAUSED_FOCUS;
            _pomodoro.paused_remaining = _pomodoro.phase == MICA_POMODORO_PAUSED_BREAK ? self.pomodoroCycleBreakMinutes * 60.0 : self.pomodoroCycleFocusMinutes * 60.0;
            if (_pomodoro.phase == MICA_POMODORO_PAUSED_BREAK) _pomodoro.completed_focuses = 1;
            _pomodoro.deadline = 0;
            [self savePomodoroState];
        } else _pomodoro.deadline = MicaContinuousTimeSeconds() + left;
    }
    [self refreshPomodoroState];
    if (expiredOnRelaunch && !NSApp.isActive && self.attentionRequest == 0)
        self.attentionRequest = [NSApp requestUserAttention:NSInformationalRequest];
    if (gMicaStatusItem) [self updateMenuBarTimer];
}

- (void)startPomodoro:(id)sender {
    (void)sender;
    double now = MicaContinuousTimeSeconds();
    if (mica_pomodoro_is_paused(&_pomodoro)) mica_pomodoro_toggle_pause(&_pomodoro, now);
    else if (_pomodoro.phase == MICA_POMODORO_IDLE) {
        if (!self.pomodoroLabel.length) self.pomodoroLabel = self.projectName ?: @"";
        self.pomodoroCycleFocusMinutes = self.focusDurationMinutes;
        self.pomodoroCycleBreakMinutes = self.breakDurationMinutes;
        mica_pomodoro_start(&_pomodoro, now, self.pomodoroCycleFocusMinutes * 60.0);
    }
    [self savePomodoroState]; [self refreshPomodoroState];
#if !defined(MICA_APP_NO_MAIN)
    [self requestPomodoroNotifications];
#endif
}

- (void)takePomodoroBreak:(id)sender {
    (void)sender;
    double now = MicaContinuousTimeSeconds();
    _pomodoro.phase = MICA_POMODORO_BREAK;
    _pomodoro.paused_remaining = 0;
    _pomodoro.deadline = now + MAX(1, self.breakDurationMinutes) * 60.0;
    self.pomodoroLabel = @"";
    [self savePomodoroState]; [self refreshPomodoroState];
}

- (void)editPomodoroLabel:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Label Focus Session";
    alert.informativeText = @"Add a plain text label (up to 80 characters).";
    [alert addButtonWithTitle:@"Save"]; [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = self.pomodoroLabel ?: @""; alert.accessoryView = field;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    if (!MicaPomodoroLabelIsValid(field.stringValue ?: @"")) { NSBeep(); return; }
    self.pomodoroLabel = field.stringValue ?: @""; [self savePomodoroState]; [self refreshPomodoroState];
}

- (void)togglePomodoroPause:(id)sender {
    (void)sender;
    if (!mica_pomodoro_toggle_pause(&_pomodoro, MicaContinuousTimeSeconds())) { [self startPomodoro:nil]; return; }
    [self savePomodoroState]; [self refreshPomodoroState];
}

- (void)resetPomodoro:(id)sender {
    (void)sender; mica_pomodoro_reset(&_pomodoro); self.pomodoroLabel = @"";
    [self savePomodoroState]; [self refreshPomodoroState];
#if !defined(MICA_APP_NO_MAIN)
    [UNUserNotificationCenter.currentNotificationCenter removeAllPendingNotificationRequests];
#endif
}

- (void)skipPomodoroPhase:(id)sender {
    (void)sender; if (_pomodoro.phase == MICA_POMODORO_IDLE) return;
    MicaPomodoroPhase phase = self.pomodoro.phase; double now = MicaContinuousTimeSeconds();
    if (mica_pomodoro_is_paused(&_pomodoro)) {
        _pomodoro.phase = phase == MICA_POMODORO_PAUSED_FOCUS ? MICA_POMODORO_FOCUS : MICA_POMODORO_BREAK;
        _pomodoro.paused_remaining = 0;
    }
    _pomodoro.deadline = now;
    BOOL changed = mica_pomodoro_advance(&_pomodoro, now, MAX(1, self.pomodoroCycleFocusMinutes) * 60.0,
        MAX(1, self.pomodoroCycleBreakMinutes) * 60.0);
    if (!changed) return;
    if (phase == MICA_POMODORO_BREAK || phase == MICA_POMODORO_PAUSED_BREAK) self.pomodoroLabel = @"";
    [self savePomodoroState]; [self refreshPomodoroState];
}

- (void)updatePomodoroTimer {
    if (MicaControllers().count && MicaControllers().firstObject != self) {
        [self.pomodoroTimer invalidate]; self.pomodoroTimer = nil; return;
    }
    if (mica_pomodoro_is_running(&_pomodoro)) {
        if (!self.pomodoroTimer) {
            self.pomodoroTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(pomodoroTimerFired:) userInfo:nil repeats:YES];
            self.pomodoroTimer.tolerance = 0.2;
            [[NSRunLoop mainRunLoop] addTimer:self.pomodoroTimer forMode:NSRunLoopCommonModes];
        }
    } else { [self.pomodoroTimer invalidate]; self.pomodoroTimer = nil; }
}

- (void)pomodoroTimerFired:(NSTimer *)timer {
    (void)timer; MicaAppDelegate *owner = MicaControllers().firstObject ?: self;
    MicaPomodoroPhase previousPhase = owner.pomodoro.phase;
    BOOL changed = mica_pomodoro_advance_with_options(&owner->_pomodoro, MicaContinuousTimeSeconds(),
        owner.pomodoroCycleFocusMinutes * 60.0, owner.pomodoroCycleBreakMinutes * 60.0,
        owner.autoStartBreaks, owner.autoStartFocus);
    if (changed) {
        // The process timer is owned by the first registered window; its active tab
        // supplies context, or tab ID zero represents a process-level timer event.
        MicaTab *timerTab = owner.activeTab;
        [MicaAttention() postTabID:timerTab.identifier kind:MicaAttentionTimerEnd
            title:@"Focus timer phase ended" body:@"Your timer phase has ended." muted:NO];
        NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
        if (previousPhase == MICA_POMODORO_FOCUS) {
            NSString *day = [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle];
            NSUserDefaults *defaults = [owner micaDefaults];
            NSInteger count = [[defaults stringForKey:@"MicaDailyFocusDay"] isEqualToString:day] ? [defaults integerForKey:@"MicaDailyFocusCount"] : 0;
            [defaults setObject:day forKey:@"MicaDailyFocusDay"];
            [defaults setInteger:count + 1 forKey:@"MicaDailyFocusCount"];
        }
        if (owner.pomodoro.phase == MICA_POMODORO_PAUSED_BREAK || owner.pomodoro.phase == MICA_POMODORO_BREAK) owner.pomodoroLabel = @"";
        [owner savePomodoroState]; [owner refreshPomodoroState];
        if (!NSApp.isActive && owner.attentionRequest == 0) owner.attentionRequest = [NSApp requestUserAttention:NSInformationalRequest];
    }
    [owner updateMenuBarTimer];
    for (MicaAppDelegate *controller in MicaControllers()) [controller.terminalView setNeedsDisplayInRect:NSMakeRect(0, 0, controller.terminalView.bounds.size.width, kStatusHeight)];
}

- (void)updateAgentRSSTimer {
    MicaAppDelegate *root = MicaControllers().firstObject ?: self;
    if (root != self) {
        [self.agentRSSTimer invalidate]; self.agentRSSTimer = nil; self.agentRSSMonitor = nil;
        [root updateAgentRSSTimer];
        return;
    }
    BOOL needed = self.agentRSSStatusMenuOpen || (gMicaStatusItem && gMicaStatusItem.menuOpen);
    for (MicaAppDelegate *controller in MicaControllers())
        if (controller.sidebarVisible) { needed = YES; break; }
    if (!needed) {
        [self.agentRSSTimer invalidate]; self.agentRSSTimer = nil; self.agentRSSMonitor = nil;
        return;
    }
    if (!self.agentRSSMonitor) self.agentRSSMonitor = [MicaAgentRSSMonitor new];
    self.agentRSSMonitor.thresholdBytes = MicaAgentRSSWarningBytes([self micaDefaults]);
    if (!self.agentRSSTimer) {
        self.agentRSSTimer = [NSTimer timerWithTimeInterval:5.0 target:self
            selector:@selector(agentRSSTimerFired:) userInfo:nil repeats:YES];
        self.agentRSSTimer.tolerance = 1.0;
        [[NSRunLoop mainRunLoop] addTimer:self.agentRSSTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)agentRSSTimerFired:(NSTimer *)timer {
    (void)timer;
    MicaAppDelegate *root = MicaControllers().firstObject ?: self;
    if (root != self) { [root agentRSSTimerFired:timer]; return; }
    BOOL needed = self.agentRSSStatusMenuOpen || (gMicaStatusItem && gMicaStatusItem.menuOpen);
    for (MicaAppDelegate *controller in MicaControllers())
        if (controller.sidebarVisible) { needed = YES; break; }
    if (!needed) { [self updateAgentRSSTimer]; return; }

    NSMutableArray<MicaTab *> *agentTabs = [NSMutableArray array];
    for (MicaAppDelegate *controller in MicaControllers()) for (MicaTab *tab in controller.tabs) {
        BOOL supported = [tab.agentKind isEqualToString:@"claude"] || [tab.agentKind isEqualToString:@"codex"] ||
            [tab.processAgentKind isEqualToString:@"claude"] || [tab.processAgentKind isEqualToString:@"codex"];
        if (supported) [agentTabs addObject:tab];
        else if (tab.agentRSSBytes) { tab.agentRSSBytes = 0; [controller.windowContentView.sidebarView refreshRows]; }
    }
    if (!agentTabs.count) return;
    MicaAgentRSSMonitor *monitor = self.agentRSSMonitor;
    if (!monitor) return;
    monitor.thresholdBytes = MicaAgentRSSWarningBytes([self micaDefaults]);
    NSDictionary<NSNumber *, NSNumber *> *samples = [monitor sampleTabs:agentTabs];
    for (MicaAppDelegate *controller in MicaControllers()) {
        BOOL changed = NO;
        for (MicaTab *tab in controller.tabs) {
            NSNumber *sample = samples[@(tab.identifier)];
            if (sample && tab.agentRSSBytes != sample.unsignedLongLongValue) {
                tab.agentRSSBytes = sample.unsignedLongLongValue;
                changed = YES;
            }
        }
        if (changed) [controller.windowContentView.sidebarView refreshRows];
    }
    uint64_t threshold = monitor.thresholdBytes;
    if (!threshold) return;
    for (NSNumber *tabID in [monitor crossingsForSamples:samples]) {
        for (MicaAppDelegate *controller in MicaControllers()) for (MicaTab *tab in controller.tabs) {
            if (tab.identifier != tabID.unsignedLongLongValue) continue;
            double gigabytes = (double)tab.agentRSSBytes / (1024.0 * 1024.0 * 1024.0);
            NSString *title = [NSString stringWithFormat:@"%@ is using %.1f GB", tab.name ?: @"Agent", gigabytes];
            BOOL posted = [MicaAttention() postTabID:tab.identifier kind:MicaAttentionHighMemory
                title:title body:@"The agent process group exceeded your memory warning level." muted:NO];
            if (posted) NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
        }
    }
}

- (MicaAppDelegate *)menuBarTimerOwner {
    if (NSApp.keyWindow) for (MicaAppDelegate *controller in MicaControllers())
        if (controller.window == NSApp.keyWindow) return controller;
    return MicaControllers().firstObject;
}

- (void)applyMenuBarTimerPreference {
    BOOL enabled = [[self micaDefaults] boolForKey:@"MicaMenuBarTimer"];
#if defined(MICA_APP_NO_MAIN)
    if (gMicaTimerStatusItemLifecycleHook) {
        if (enabled != gMicaTimerStatusItemEnabledForTests &&
            gMicaTimerStatusItemLifecycleHook(enabled)) gMicaTimerStatusItemEnabledForTests = enabled;
        return;
    }
#endif
    if (enabled && !gMicaStatusItem) {
        gMicaStatusItem = [MicaStatusItem new];
        __weak typeof(self) weakSelf = self;
        [gMicaStatusItem enableWithMenuBuilder:^NSMenu *{
            MicaAppDelegate *owner = [weakSelf menuBarTimerOwner];
            return owner ? [owner menuBarTimerMenu] : [[NSMenu alloc] initWithTitle:@"Mica"];
        }];
        gMicaStatusItem.menuOpenChanged = ^(BOOL open) {
            MicaAppDelegate *root = MicaControllers().firstObject ?: weakSelf;
            root.agentRSSStatusMenuOpen = open;
            [root updateAgentRSSTimer];
        };
        [self updateMenuBarTimer];
    } else if (!enabled && gMicaStatusItem) {
        [gMicaStatusItem disable];
        gMicaStatusItem = nil;
    }
}

- (void)prefMenuBarTimerChanged:(NSButton *)sender {
    [[self micaDefaults] setBool:sender.state == NSControlStateValueOn forKey:@"MicaMenuBarTimer"];
    [self applyMenuBarTimerPreference];
}

- (void)prefStatusTimerChanged:(NSButton *)sender {
    [[self micaDefaults] setBool:sender.state == NSControlStateValueOn forKey:@"MicaShowStatusTimer"];
    for (MicaAppDelegate *controller in MicaControllers()) [controller.terminalView setNeedsDisplay:YES];
}

- (void)prefDiagnosticsChanged:(NSButton *)sender {
    BOOL enabled = sender.state == NSControlStateValueOn;
    [[self micaDefaults] setBool:enabled forKey:@"MicaDiagnosticsEnabled"];
    MicaDiagnosticsSetEnabled(enabled);
}

- (void)prefAgentRSSWarningChanged:(NSPopUpButton *)sender {
    static const NSInteger values[] = {0, 2, 4, 8, 16};
    NSInteger index = MAX(0, MIN((NSInteger)(sizeof(values) / sizeof(values[0])) - 1, sender.indexOfSelectedItem));
    [[self micaDefaults] setInteger:values[index] forKey:@"MicaAgentRSSWarningGB"];
    [self updateAgentRSSTimer];
}

- (void)updateMenuBarTimer {
    MicaAppDelegate *owner = [self menuBarTimerOwner];
    if (!gMicaStatusItem || !owner) return;
    NSDictionary *presentation = [owner menuBarTimerPresentationAtTime:MicaContinuousTimeSeconds()];
    MicaPomodoroPhase phase = owner.pomodoro.phase;
    NSString *title = phase == MICA_POMODORO_IDLE ? @"•" : [presentation[@"title"] substringFromIndex:[presentation[@"title"] rangeOfString:@" "].location + 1];
    [gMicaStatusItem updateTitle:title accessibilityLabel:presentation[@"accessibilityLabel"]];
}

- (NSMenu *)menuBarTimerMenu {
    NSDictionary *presentation = [self menuBarTimerPresentationAtTime:MicaContinuousTimeSeconds()];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Mica"];
    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:presentation[@"title"] action:nil keyEquivalent:@""];
    status.enabled = NO;
    [menu addItem:status];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *toggleItem = [menu addItemWithTitle:presentation[@"toggle"] action:@selector(togglePomodoroPause:) keyEquivalent:@""];
    toggleItem.target = self;
    NSMenuItem *skip = [menu addItemWithTitle:presentation[@"endTitle"] action:@selector(skipPomodoroPhase:) keyEquivalent:@""];
    skip.target = self;
    skip.enabled = [presentation[@"endEnabled"] boolValue];
    // Extension point: agents-waiting and quota rows belong here in a later cycle.
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *show = [menu addItemWithTitle:@"Show Mica" action:@selector(showMicaFromStatusItem:) keyEquivalent:@""];
    show.target = self;
    NSMenuItem *settings = [menu addItemWithTitle:@"Settings…" action:@selector(openPreferences:) keyEquivalent:@","];
    settings.target = self;
    return menu;
}

- (void)showMicaFromStatusItem:(id)sender {
    (void)sender;
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

- (NSDictionary<NSString *, id> *)menuBarTimerPresentationAtTime:(double)now {
    MicaPomodoro timer = self.pomodoro;
    BOOL focus = timer.phase == MICA_POMODORO_IDLE || timer.phase == MICA_POMODORO_FOCUS ||
        timer.phase == MICA_POMODORO_PAUSED_FOCUS;
    BOOL paused = mica_pomodoro_is_paused(&timer);
    NSInteger minutes = focus ? self.focusDurationMinutes : self.breakDurationMinutes;
    double seconds = timer.phase == MICA_POMODORO_IDLE ? MAX(1, minutes) * 60.0 : mica_pomodoro_remaining(&timer, now);
    NSString *phase = timer.phase == MICA_POMODORO_IDLE ? @"Ready" :
        paused ? (focus ? @"Paused focus" : @"Paused break") : (focus ? @"Focus" : @"Break");
    NSInteger wholeSeconds = (NSInteger)seconds;
    NSString *title = [NSString stringWithFormat:@"%@ %02ld:%02ld", phase, (long)(wholeSeconds / 60), (long)(wholeSeconds % 60)];
    NSString *toggle = timer.phase == MICA_POMODORO_IDLE ? @"Start Focus" : (paused ? @"Resume Timer" : @"Pause Timer");
    return @{@"title": title,
        @"accessibilityLabel": [NSString stringWithFormat:@"%@, %02ld minutes %02ld seconds remaining", phase,
            (long)(wholeSeconds / 60), (long)(wholeSeconds % 60)],
        @"toggle": toggle,
        @"endEnabled": @(timer.phase != MICA_POMODORO_IDLE),
        @"endTitle": focus ? @"End Focus & Start Break" : @"End Break & Start Focus"};
}

- (void)requestPomodoroNotifications {
#if !defined(MICA_APP_NO_MAIN)
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    center.delegate = self;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert
        completionHandler:^(BOOL granted, NSError *error) {
            (void)granted;
            if (error) MicaDiagnosticsLog(@"pomodoro", [NSString stringWithFormat:@"notification permission failed: %@", error]);
        }];
#endif
}

- (NSView *)pomodoroSettingsAccessory {
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 142)];
    NSTextField *focusLabel = [NSTextField labelWithString:@"Focus (minutes)"];
    NSTextField *breakLabel = [NSTextField labelWithString:@"Break (minutes)"];
    NSTextField *focusField = [NSTextField textFieldWithString:@(self.focusDurationMinutes).stringValue];
    NSTextField *breakField = [NSTextField textFieldWithString:@(self.breakDurationMinutes).stringValue];
    focusField.frame = NSMakeRect(225, 114, 65, 24); breakField.frame = NSMakeRect(225, 82, 65, 24);
    focusLabel.frame = NSMakeRect(0, 114, 210, 24); breakLabel.frame = NSMakeRect(0, 82, 210, 24);
    NSButton *autoBreak = [NSButton checkboxWithTitle:@"Auto-start break after focus" target:nil action:nil];
    NSButton *autoFocus = [NSButton checkboxWithTitle:@"Auto-start focus after break" target:nil action:nil];
    autoBreak.frame = NSMakeRect(0, 48, 290, 24);
    autoFocus.frame = NSMakeRect(0, 16, 290, 24);
    autoBreak.state = self.autoStartBreaks ? NSControlStateValueOn : NSControlStateValueOff;
    autoFocus.state = self.autoStartFocus ? NSControlStateValueOn : NSControlStateValueOff;
    [accessory addSubview:focusLabel]; [accessory addSubview:focusField];
    [accessory addSubview:breakLabel]; [accessory addSubview:breakField];
    [accessory addSubview:autoBreak]; [accessory addSubview:autoFocus];
    return accessory;
}

- (BOOL)savePomodoroSettingsFromAccessory:(NSView *)accessory {
    NSTextField *focusField = nil, *breakField = nil;
    NSButton *autoBreak = nil, *autoFocus = nil;
    for (NSView *view in accessory.subviews) {
        if (![view isKindOfClass:NSControl.class]) continue;
        NSControl *control = (NSControl *)view;
        if ([control isKindOfClass:NSButton.class]) {
            NSButton *button = (NSButton *)control;
            if ([button.title isEqualToString:@"Auto-start break after focus"]) autoBreak = button;
            if ([button.title isEqualToString:@"Auto-start focus after break"]) autoFocus = button;
        } else if ([control isKindOfClass:NSTextField.class]) {
            NSTextField *field = (NSTextField *)control;
            if (!field.isEditable) continue;
            if (!focusField) focusField = field;
            else breakField = field;
        }
    }
    if (!focusField || !breakField || !autoBreak || !autoFocus) return NO;
    NSInteger focus = MicaMinutesFromText(focusField.stringValue, 0, kMaximumFocusMinutes);
    NSInteger pause = MicaMinutesFromText(breakField.stringValue, 0, kMaximumBreakMinutes);
    return [self savePomodoroSettingsFocusMinutes:focus breakMinutes:pause
        autoStartFocus:autoFocus.state == NSControlStateValueOn
        autoStartBreaks:autoBreak.state == NSControlStateValueOn];
}

- (void)openPomodoroSettings:(id)sender {
    (void)sender;
    [self refreshPomodoroState];
    NSView *accessory = [self pomodoroSettingsAccessory];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Computer-wide Focus Timer";
    alert.informativeText = @"Every Mica window shares this timer. Changes apply to the next focus or break interval.";
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        if (![self savePomodoroSettingsFromAccessory:accessory]) {
            NSAlert *error = [NSAlert new]; error.messageText = @"Enter valid timer lengths";
            error.informativeText = [NSString stringWithFormat:@"Focus: 1–%ld minutes. Break: 1–%ld minutes.",
                (long)kMaximumFocusMinutes, (long)kMaximumBreakMinutes];
            [error addButtonWithTitle:@"OK"]; [error beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }];
}

// A macOS notification carrying the words an agent sent. At most one per tab every ten seconds.
- (NSMenu *)notificationMenuForTab:(MicaTab *)tab {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:tab.name ?: @"Tab"];
    NSMenuItem *mute = [[NSMenuItem alloc] initWithTitle:@"Mute notifications"
        action:@selector(toggleMuteNotificationsForTab:) keyEquivalent:@""];
    mute.target = self;
    mute.representedObject = @(tab.identifier);
    mute.state = tab.muteNotifications ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:mute];
    return menu;
}

- (NSString *)agentNotificationTitleForTab:(MicaTab *)tab waiting:(BOOL)waiting {
    NSString *agent = MicaAgentNameForTab(tab);
    if (!agent.length) agent = MicaAgentNameForText(tab.completionLabel) ?: (tab.completionLabel.length ? tab.completionLabel : @"Agent");
    return [NSString stringWithFormat:@"%@ %@", agent, waiting ? @"needs input" : @"finished"];
}

- (void)toggleMuteNotificationsForTab:(id)sender {
    id represented = [sender isKindOfClass:NSMenuItem.class] ? [(NSMenuItem *)sender representedObject] : nil;
    MicaTab *tab = nil;
    if ([represented isKindOfClass:NSNumber.class]) {
        uint64_t tabID = [represented unsignedLongLongValue];
        for (MicaTab *candidate in self.tabs) if (candidate.identifier == tabID) { tab = candidate; break; }
    } else if (!represented) tab = self.activeTab;
    if (![tab isKindOfClass:MicaTab.class]) return;
    tab.muteNotifications = !tab.muteNotifications;
    [MicaAttention() setMuted:tab.muteNotifications tabID:tab.identifier];
    NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
    [self saveSessionState];
}

- (void)deliverAttentionEvent:(NSDictionary *)event {
    uint64_t tabID = [event[@"tabID"] unsignedLongLongValue];
    if (!event) return;
#if defined(MICA_APP_NO_MAIN)
    if (!tabID) {
        if (self.testAgentNotificationHandler) self.testAgentNotificationHandler(event[@"title"] ?: @"Mica", event[@"body"] ?: @"", nil);
    }
    for (MicaAppDelegate *controller in MicaControllers()) for (MicaTab *tab in controller.tabs)
        if (tab.identifier == tabID && controller.testAgentNotificationHandler)
            controller.testAgentNotificationHandler(event[@"title"] ?: @"Mica", event[@"body"] ?: @"", tab);
#else
    MicaAppDelegate *tabController = nil;
    MicaTab *tab = nil;
    for (MicaAppDelegate *controller in MicaControllers()) for (MicaTab *candidate in controller.tabs)
        if (candidate.identifier == tabID) { tabController = controller; tab = candidate; break; }
    if (tabID && (!tab || !MicaShouldDeliverAttention(NSApp.isActive,
        tabController.window == NSApp.keyWindow && tabController.activeTab == tab))) return;
    static BOOL authorizationRequested;
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    if (!authorizationRequested) {
        authorizationRequested = YES;
        [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted, NSError *error) {
            (void)granted; (void)error;
        }];
    }
    NSInteger kind = [event[@"kind"] integerValue];
    UNMutableNotificationContent *content = MicaNotificationContentForAttention(event);
    NSString *identifier = [NSString stringWithFormat:@"mica.attention.%llu.%ld", tabID, (long)kind];
    [center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil]
        withCompletionHandler:nil];
#endif
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    (void)center;
    NSDictionary *info = response.notification.request.content.userInfo;
    NSNumber *tabID = [info[@"tabID"] isKindOfClass:NSNumber.class] ? info[@"tabID"] : nil;
    if (tabID.unsignedLongLongValue) {
        for (MicaAppDelegate *controller in MicaControllers()) {
            NSUInteger index = [controller.tabs indexOfObjectPassingTest:^BOOL(MicaTab *tab, NSUInteger idx, BOOL *stop) {
                (void)idx; (void)stop; return tab.identifier == tabID.unsignedLongLongValue;
            }];
            if (index == NSNotFound) continue;
            [NSApp activateIgnoringOtherApps:YES];
            [controller.window makeKeyAndOrderFront:nil];
            [controller selectTabAtIndex:(NSInteger)index];
            [MicaAttention() clearTabID:tabID.unsignedLongLongValue];
            NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
            break;
        }
    }
    completionHandler();
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center;
    if ([notification.request.identifier hasPrefix:@"mica.attention."])
        completionHandler(UNNotificationPresentationOptionBanner);
    else
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
    if (!gAppliedIconProject || ![gAppliedIconProject isEqualToString:self.projectName ?: @""]) {
        gAppliedIconProject = self.projectName ?: @"";
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
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;   // the app delegate outlives every window
    // Launched through a project launcher (mica:// URL)? Those URLs arrived before launch finished.
    NSMutableArray<NSURL *> *pending = MicaPendingOpenURLs();
    NSMutableArray<NSArray<NSString *> *> *pendingArguments = [NSMutableArray array];
    for (NSURL *url in pending) {
        NSArray<NSString *> *arguments = MicaArgumentsForOpenURL(url, MicaDefaultLayoutsDirectory());
        if (arguments) [pendingArguments addObject:arguments];
    }
    [pending removeAllObjects];
    BOOL launchedFromProjectLayout = pendingArguments.count > 0;
    NSArray<NSDictionary *> *savedWindows = (NSProcessInfo.processInfo.arguments.count <= 1 && !getenv("MICA_TEST_NO_STARTUP"))
        ? [self readSessionState] : @[];
    NSArray<NSString *> *firstArguments = pendingArguments.firstObject;
    NSUInteger nextSavedWindow = 0;
    if (!firstArguments && savedWindows.count && [savedWindows.firstObject[@"layout"] isKindOfClass:NSString.class]) {
        NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"mica", @"--layout", savedWindows.firstObject[@"layout"], nil];
        if ([savedWindows.firstObject[@"projectName"] isKindOfClass:NSString.class])
            [arguments addObjectsFromArray:@[@"--project-name", savedWindows.firstObject[@"projectName"]]];
        firstArguments = arguments;
    }
    if (!firstArguments && savedWindows.count) self.savedTabsForWindow = savedWindows.firstObject[@"tabs"];
    [self startWindowWithArguments:firstArguments];
    if (!launchedFromProjectLayout && savedWindows.count) nextSavedWindow = 1;
    for (NSUInteger index = nextSavedWindow; index < savedWindows.count; index++) {
        NSDictionary *saved = savedWindows[index];
        NSString *savedLayout = saved[@"layout"];
        BOOL alreadyOpen = NO;
        for (NSArray<NSString *> *arguments in pendingArguments) {
            NSUInteger layoutIndex = [arguments indexOfObject:@"--layout"];
            if (layoutIndex != NSNotFound && layoutIndex + 1 < arguments.count &&
                [arguments[layoutIndex + 1] isEqualToString:savedLayout]) { alreadyOpen = YES; break; }
        }
        if (savedLayout && !alreadyOpen) {
            NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"mica", @"--layout", savedLayout, nil];
            if ([saved[@"projectName"] isKindOfClass:NSString.class])
                [arguments addObjectsFromArray:@[@"--project-name", saved[@"projectName"]]];
            MicaAppDelegate *restored = [MicaAppDelegate new];
            [restored startWindowWithArguments:arguments];
        } else if (!savedLayout) {
            MicaAppDelegate *restored = [MicaAppDelegate new];
            restored.savedTabsForWindow = saved[@"tabs"];
            [restored startWindowWithArguments:@[@"mica", @"--new-window"]];
        }
    }
    for (NSUInteger index = 1; index < pendingArguments.count; index++)
        [self openProjectWindowWithArguments:pendingArguments[index]];
}

// Builds this controller's window, tabs, voice controller and timers. `arguments` are launch-style
// (--layout, --project-name); nil means the process's own command line.
- (void)startWindowWithArguments:(NSArray<NSString *> *)arguments {
    if (![MicaControllers() containsObject:self]) [MicaControllers() addObject:self];
    static dispatch_once_t attentionDeliveryOnce;
    dispatch_once(&attentionDeliveryOnce, ^{ MicaAttention().delivery = ^(NSDictionary *event) {
        MicaAppDelegate *delegate = MicaControllers().firstObject;
        [delegate deliverAttentionEvent:event];
    }; });
    if (!getenv("MICA_TEST_NO_STARTUP")) {
        MicaHookServer *server = MicaHookServer.sharedServer;
        if ([server startAtPath:nil]) {
            server.delivery = ^(MicaHookEvent event) { MicaDeliverHook(event); };
            setenv("MICA_HOOK_SOCK", server.socketPath.fileSystemRepresentation, 1);
        }
    }
    self.tabs = [NSMutableArray array];
    self.activeIndex = 0;
    self.focusDurationMinutes = kDefaultFocusMinutes;
    self.breakDurationMinutes = kDefaultBreakMinutes;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 1100, 700)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.projectName = nil;
    self.window.title = @"Mica Terminal";
    // ARC owns the window; AppKit must not also release it when it closes (that double release crashed).
    self.window.releasedWhenClosed = NO;
    // One merged title bar: the tab strip sits beside the traffic lights instead of under a second bar.
    self.window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    self.window.titlebarAppearsTransparent = YES;
    self.window.titleVisibility = NSWindowTitleHidden;
    // Opaque on purpose: a translucent window or a vibrancy title bar costs about 8 MB of extra window memory.
    self.window.backgroundColor = NSColor.windowBackgroundColor;
    self.window.minSize = NSMakeSize(600, 300);
    self.window.delegate = self;
    self.windowContentView = [[MicaWindowContentView alloc] initWithFrame:self.window.contentView.bounds];
    self.windowContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.windowContentView.owner = self;
    self.terminalView = [[MicaTerminalView alloc] initWithFrame:self.windowContentView.bounds];
    self.terminalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.terminalView.owner = self;
    self.terminalView.terminalFont = MicaTerminalFont(kFontSizeDefault);
    self.windowContentView.terminalView = self.terminalView;
    [self.windowContentView addSubview:self.terminalView];
    [self.window setContentView:self.windowContentView];
    NSURL *voiceHelperURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/mica-voice"];
    self.voiceController = [[MicaVoiceController alloc] initWithHelperURL:voiceHelperURL defaults:[self micaDefaults]];
    self.voiceController.delegate = self;
    // Rebuild Core ML's compiled model cache in the background after an update so the first dictation is fast.
    static BOOL prewarmScheduled;
    if (!getenv("MICA_TEST_NO_STARTUP") && !prewarmScheduled) {
        prewarmScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self.voiceController prewarmSpeechModelIfNeeded];
        });
    }
    [self installMenus];
    self.uiMode = MicaUIModeNormal;
    if (arguments) [self loadLaunchConfigurationFromArguments:arguments bundleInfo:NSBundle.mainBundle.infoDictionary];
    else [self loadLaunchConfiguration];
    if (!getenv("MICA_TEST_NO_STARTUP") || gMicaDefaultsOverride) {
        gMicaCursorStyle = [NSUserDefaults.standardUserDefaults integerForKey:@"MicaCursorStyle"];
        NSMenu *viewMenu = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
        for (NSMenuItem *entry in viewMenu.itemArray)
            if (entry.action == @selector(setCursorStyle:)) entry.state = entry.tag == gMicaCursorStyle ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (!getenv("MICA_TEST_NO_STARTUP")) {
        [self loadStoredThemePreference];
        [self applyStoredShortcutPreference];
        [self applyStoredScrollbackPreference];
        [self applyMenuBarTimerPreference];
        [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:NSKeyValueObservingOptionNew context:NULL];
        self.observesSystemAppearance = YES;
    } else {
        self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }
    self.dictationToggleMode = [[self micaDefaults] boolForKey:@"MicaDictationToggleMode"];
    // A second window opened on top of another gets the classic cascade offset instead of hiding it.
    for (MicaAppDelegate *other in MicaControllers()) {
        if (other == self || !other.window) continue;
        NSRect a = other.window.frame, b = self.window.frame;
        if (fabs(a.origin.x - b.origin.x) < 2 && fabs(a.origin.y - b.origin.y) < 2)
            [self.window setFrameOrigin:NSMakePoint(b.origin.x + 28, b.origin.y - 28)];
    }
    // Show the window only after the project name restored its saved frame, so it never jumps.
    if (!getenv("MICA_TEST_NO_STARTUP")) [self.window makeKeyAndOrderFront:nil];   // tests keep windows off screen
    [self.window makeFirstResponder:self.terminalView];
    [self installSessionSources];
    [self updateAgentRSSTimer];
}

- (void)installMenus {
    if (!gMenuBuilt || !NSApp.mainMenu) {
        [self buildMenus];
        gControllerMenuItems = [NSMutableArray array];
        gViewMenuItems = [NSMutableArray array];
        __block __weak void (^collect)(NSMenu *) = nil;
        void (^collector)(NSMenu *) = ^(NSMenu *menu) {
            for (NSMenuItem *item in menu.itemArray) {
                if (item.target == self) [gControllerMenuItems addObject:item];
                else if (self.terminalView && item.target == self.terminalView) [gViewMenuItems addObject:item];
                if (item.submenu) collect(item.submenu);
            }
        };
        collect = collector;
        collector(NSApp.mainMenu);
        gMenuBuilt = YES;
    }
    [self takeMenuOwnership];
}

// One menu bar serves every window: its window-specific items act on whichever window is key.
- (void)takeMenuOwnership {
    for (NSMenuItem *item in gControllerMenuItems) item.target = self;
    for (NSMenuItem *item in gViewMenuItems) item.target = self.terminalView;
    if (gMicaStatusItem) [self updateMenuBarTimer];
}

- (void)collectPaletteItemsFromMenu:(NSMenu *)menu into:(NSMutableArray<NSDictionary *> *)rows {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) { [self collectPaletteItemsFromMenu:item.submenu into:rows]; continue; }
        if (!item.action || item.isSeparatorItem || item.action == @selector(toggleCommandPalette:)) continue;
        NSString *shortcut = @"";
        NSEventModifierFlags modifiers = item.keyEquivalentModifierMask;
        if (modifiers & NSEventModifierFlagControl) shortcut = [shortcut stringByAppendingString:@"⌃"];
        if (modifiers & NSEventModifierFlagOption) shortcut = [shortcut stringByAppendingString:@"⌥"];
        if (modifiers & NSEventModifierFlagShift) shortcut = [shortcut stringByAppendingString:@"⇧"];
        if (modifiers & NSEventModifierFlagCommand) shortcut = [shortcut stringByAppendingString:@"⌘"];
        if (item.keyEquivalent.length) shortcut = [shortcut stringByAppendingString:item.keyEquivalent.uppercaseString];
        [rows addObject:@{@"title": item.title, @"detail": shortcut, @"item": item, @"kind": @"action"}];
    }
}

- (NSArray<NSDictionary *> *)paletteRows {
    NSMutableArray *rows = [NSMutableArray array];
    [self collectPaletteItemsFromMenu:NSApp.mainMenu into:rows];
    for (MicaTab *tab in self.tabs) {
        [rows addObject:@{@"title":[NSString stringWithFormat:@"%@ notifications for %@", tab.muteNotifications ? @"Unmute" : @"Mute", tab.name ?: @"Terminal"],
                          @"detail":@"Per-tab notification setting", @"tabID":@(tab.identifier),
                          @"kind":@"mute"}];
    }
    NSArray *tabs = [self.tabs sortedArrayUsingComparator:^NSComparisonResult(MicaTab *a, MicaTab *b) {
        if (a == self.activeTab) return NSOrderedAscending;
        if (b == self.activeTab) return NSOrderedDescending;
        if (a.lastSelectedAt > b.lastSelectedAt) return NSOrderedAscending;
        if (a.lastSelectedAt < b.lastSelectedAt) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (MicaTab *tab in tabs) {
        MicaTabActivityState activity = [self.terminalView activityStateForTab:tab];
        NSString *state = activity == MicaTabActivityStateWaiting ? @"Needs input" :
            activity == MicaTabActivityStateRunning ? @"Running" : @"Idle";
        NSString *detail = [NSString stringWithFormat:@"%@  ·  %@  ·  %@",
            tab.cwd.lastPathComponent ?: @"", tab.gitBranch.length ? tab.gitBranch : @"no branch", state];
        [rows addObject:@{@"title": tab.name.length ? tab.name : @"Terminal", @"detail": detail,
                          @"tabID": @(tab.identifier), @"kind": @"tab", @"accessibility":
                          [NSString stringWithFormat:@"Go to tab %@, folder %@, branch %@, agent state %@",
                           tab.name ?: @"Terminal", tab.cwd.lastPathComponent ?: @"", tab.gitBranch ?: @"none", state]}];
    }
    return rows;
}

- (void)toggleCommandPalette:(id)sender {
    (void)sender;
    if (self.commandPalettePanel) {
        [self.commandPalettePanel orderOut:nil];
        self.commandPalettePanel = nil;
        self.commandPaletteSearch = nil;
        self.commandPaletteTable = nil;
        [self.window makeFirstResponder:self.terminalView];
        return;
    }
    self.commandPaletteRows = [self paletteRows];
    NSRect frame = NSMakeRect(0, 0, 620, 390);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Command Palette";
    panel.releasedWhenClosed = NO;
    panel.opaque = YES;
    panel.backgroundColor = NSColor.windowBackgroundColor;
    panel.appearance = self.window.appearance ?: [NSAppearance appearanceNamed:gMicaLightTheme ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    panel.level = NSFloatingWindowLevel;
    panel.hidesOnDeactivate = YES;
    MicaPaletteSearchField *search = [[MicaPaletteSearchField alloc] initWithFrame:NSMakeRect(16, 350, 588, 24)];
    search.paletteOwner = self;
    search.placeholderString = @"Search actions and tabs…";
    search.accessibilityLabel = @"Search actions and tabs";
    search.target = self;
    search.action = @selector(filterCommandPalette:);
    MicaPaletteTableView *table = [[MicaPaletteTableView alloc] initWithFrame:NSMakeRect(0, 0, 588, 330)];
    table.paletteOwner = self;
    NSTableColumn *name = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    name.title = @"Action or tab"; name.width = 400;
    NSTableColumn *detail = [[NSTableColumn alloc] initWithIdentifier:@"detail"];
    detail.title = @"Shortcut / context"; detail.width = 180;
    [table addTableColumn:name]; [table addTableColumn:detail];
    table.headerView = nil; table.dataSource = (id)self; table.delegate = (id)self;
    table.backgroundColor = NSColor.windowBackgroundColor;
    table.usesAlternatingRowBackgroundColors = YES;
    table.accessibilityLabel = @"Command palette results";
    table.target = self; table.doubleAction = @selector(runCommandPaletteSelection:);
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 16, 588, 312)];
    scroll.hasVerticalScroller = YES; scroll.drawsBackground = YES; scroll.backgroundColor = NSColor.windowBackgroundColor; scroll.documentView = table;
    NSView *content = [[NSView alloc] initWithFrame:frame];
    content.wantsLayer = YES;
    content.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    [content addSubview:search]; [content addSubview:scroll]; panel.contentView = content;
    self.commandPalettePanel = panel; self.commandPaletteSearch = search; self.commandPaletteTable = table;
    NSRect screen = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
    [panel setFrameOrigin:NSMakePoint(NSMidX(screen) - frame.size.width / 2, NSMaxY(screen) - frame.size.height - 100)];
    [panel makeKeyAndOrderFront:nil]; [panel makeFirstResponder:search];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return (NSInteger)self.commandPaletteRows.count; }
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.commandPaletteRows.count) return [NSTableRowView new];
    MicaPaletteRowView *view = [MicaPaletteRowView new];
    NSDictionary *entry = self.commandPaletteRows[(NSUInteger)row];
    view.paletteAccessibilityLabel = entry[@"accessibility"] ?: [NSString stringWithFormat:@"%@ %@", entry[@"title"], entry[@"detail"]];
    return view;
}
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.commandPaletteRows.count) return @"";
    NSDictionary *entry = self.commandPaletteRows[(NSUInteger)row];
    return [column.identifier isEqualToString:@"name"] ? entry[@"title"] : entry[@"detail"];
}
- (void)controlTextDidChange:(NSNotification *)notification { if (notification.object == self.commandPaletteSearch) [self filterCommandPalette:nil]; }
- (void)filterCommandPalette:(id)sender {
    (void)sender;
    NSString *query = self.commandPaletteSearch.stringValue.lowercaseString;
    NSArray *all = [self paletteRows];
    if (!query.length) self.commandPaletteRows = all;
    else self.commandPaletteRows = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, NSDictionary *bindings) {
        (void)bindings; NSString *text = [[NSString stringWithFormat:@"%@ %@", entry[@"title"], entry[@"detail"]] lowercaseString];
        NSArray<NSString *> *tokens = [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL allTokens = YES;
        for (NSString *token in tokens) if (token.length && [text rangeOfString:token].location == NSNotFound) { allTokens = NO; break; }
        if (allTokens) return YES;
        NSString *compact = [query stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSUInteger position = 0;
        for (NSUInteger i = 0; i < compact.length; i++) {
            NSString *character = [compact substringWithRange:NSMakeRange(i, 1)];
            if (position >= text.length) return NO;
            NSRange found = [text rangeOfString:character options:0 range:NSMakeRange(position, text.length-position)];
            if (found.location == NSNotFound) return NO;
            position = NSMaxRange(found);
        }
        return compact.length > 0;
    }]];
    if (query.length) {
        // Exact title matches, then title prefixes, then the rest, each in menu order.
        NSMutableArray *exact = [NSMutableArray array], *prefix = [NSMutableArray array], *rest = [NSMutableArray array];
        for (NSDictionary *entry in self.commandPaletteRows) {
            NSString *title = [entry[@"title"] lowercaseString];
            NSMutableArray *bucket = [title isEqualToString:query] ? exact : ([title hasPrefix:query] ? prefix : rest);
            [bucket addObject:entry];
        }
        self.commandPaletteRows = [[exact arrayByAddingObjectsFromArray:prefix] arrayByAddingObjectsFromArray:rest];
    }
    [self.commandPaletteTable reloadData];
    if (self.commandPaletteRows.count) [self.commandPaletteTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}
- (void)moveCommandPaletteSelection:(NSInteger)delta {
    NSInteger count = (NSInteger)self.commandPaletteRows.count; if (!count) return;
    NSInteger row = self.commandPaletteTable.selectedRow;
    row = (row + delta + count) % count;
    [self.commandPaletteTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self.commandPaletteTable scrollRowToVisible:row];
}
- (void)runCommandPaletteSelection:(id)sender {
    (void)sender; NSInteger row = self.commandPaletteTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.commandPaletteRows.count) return;
    NSDictionary *entry = self.commandPaletteRows[(NSUInteger)row];
    [self.commandPalettePanel orderOut:nil];
    if ([entry[@"kind"] isEqualToString:@"tab"]) {
        uint64_t tabID = [entry[@"tabID"] unsignedLongLongValue];
        for (NSUInteger index = 0; index < self.tabs.count; index++)
            if (self.tabs[index].identifier == tabID) { [self selectTabAtIndex:(NSInteger)index]; break; }
    }
    else if ([entry[@"kind"] isEqualToString:@"mute"]) {
        uint64_t tabID = [entry[@"tabID"] unsignedLongLongValue];
        for (MicaTab *tab in self.tabs) if (tab.identifier == tabID) {
            tab.muteNotifications = !tab.muteNotifications;
            [self saveSessionState];
            break;
        }
    }
    else {
        NSMenuItem *item = entry[@"item"];
        if (![self validateMenuItem:item]) { self.commandPalettePanel = nil; return; }
        id target = nil;
        if ([item.target isKindOfClass:MicaTerminalView.class]) target = self.terminalView;
        else if ([item.target isKindOfClass:MicaAppDelegate.class]) target = self;
        else if (item.target && [item.target respondsToSelector:item.action]) target = item.target;
        if (!target && [self.terminalView respondsToSelector:item.action]) target = self.terminalView;
        if (!target && [self.window respondsToSelector:item.action]) target = self.window;
        if (!target && [self respondsToSelector:item.action]) target = self;
        if (!target && [NSApp respondsToSelector:item.action]) target = NSApp;
        if (![target respondsToSelector:item.action]) { self.commandPalettePanel = nil; return; }
        [NSApp sendAction:item.action to:target from:item];
    }
    self.commandPalettePanel = nil; self.commandPaletteSearch = nil; self.commandPaletteTable = nil;
    [self.window makeFirstResponder:self.terminalView];
}

- (void)refreshProcessAgentForTab:(MicaTab *)tab {
    if (!tab.session) { tab.processAgentKind = nil; return; }
    char commands[8192];
    mica_session_descendant_commands(tab.session, commands, sizeof(commands));
    switch (mica_agent_kind_from_commands(commands)) {
        case 1: tab.processAgentKind = @"claude"; break;
        case 2: tab.processAgentKind = @"codex"; break;
        default: tab.processAgentKind = nil; break;
    }
}

- (void)handleHookEvent:(MicaHookEvent)event forTab:(MicaTab *)tab {
    NSString *eventName = [NSString stringWithUTF8String:event.event] ?: @"";
    NSString *agent = [NSString stringWithUTF8String:event.agent] ?: @"";
    NSString *sessionID = [NSString stringWithUTF8String:event.session_id] ?: @"";
    NSString *notificationType = [NSString stringWithUTF8String:event.notification_type] ?: @"";
    NSString *message = [NSString stringWithUTF8String:event.message] ?: @"";
    NSString *lastMessage = [NSString stringWithUTF8String:event.last_assistant_message] ?: @"";
    NSString *cwd = [NSString stringWithUTF8String:event.cwd] ?: @"";
    NSString *tool = [NSString stringWithUTF8String:event.tool_name] ?: @"";
    tab.lastHookEvent = @{ @"event":eventName, @"agent":agent, @"session_id":sessionID, @"cwd":cwd,
        @"notification_type":notificationType, @"message":message, @"last_assistant_message":lastMessage, @"tool_name":tool };
    tab.receivedAgentHook = YES;
    if (agent.length) tab.agentKind = agent;
    [self refreshProcessAgentForTab:tab];
    if (sessionID.length) tab.agentSessionID = sessionID;
    NSString *next = MicaAgentStateForHookEvent(eventName, notificationType, MicaAgentStateForTab(tab));
    if ([eventName isEqualToString:@"SessionEnd"]) { tab.agentKind = @"none"; tab.agentSessionID = nil; }
    if ([eventName isEqualToString:@"Stop"] || [eventName isEqualToString:@"notify"])
        if (lastMessage.length || message.length) { NSString *value = lastMessage.length ? lastMessage : message; tab.agentLastMessage = value.length > 200 ? [value substringToIndex:200] : value; }
    if (next.length) {
        tab.agentState = next; tab.agentStateSource = @"hook"; tab.agentUpdatedAt = NSDate.date;
        tab.agentActivity = next; tab.agentActivityDetail = tab.agentLastMessage;
        MicaAttentionKind kind;
        BOOL hasAttention = YES;
        if ([next isEqualToString:@"waitingPermission"]) kind = MicaAttentionWaitingPermission;
        else if ([next isEqualToString:@"waitingInput"]) kind = MicaAttentionWaitingInput;
        else if ([next isEqualToString:@"done"]) kind = MicaAttentionDone;
        else if ([next isEqualToString:@"error"]) kind = MicaAttentionError;
        else {
            hasAttention = NO;
            [MicaAttention() clearTabID:tab.identifier];
            NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
        }
        if (hasAttention) {
            [MicaAttention() setMuted:tab.muteNotifications tabID:tab.identifier];
            [MicaAttention() postTabID:tab.identifier kind:kind title:[self agentNotificationTitleForTab:tab waiting:(kind == MicaAttentionWaitingPermission || kind == MicaAttentionWaitingInput)] body:tab.agentLastMessage ?: @"" muted:NO];
            NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
        }
        [self.terminalView setNeedsDisplay:YES];
    }
}

- (void)setupAgentHooks:(id)sender { (void)sender; [MicaHookInstall presentFromWindow:self.window]; }

- (void)buildMenus {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Mica"];
    NSMenuItem *appRoot = [[NSMenuItem alloc] initWithTitle:@"Mica" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Mica"];
    AddMenuItem(appMenu, @"About Mica", @selector(orderFrontStandardAboutPanel:), @"", 0);
    AddMenuItem(appMenu, @"New Window", @selector(newInstance:), @"n",
                NSEventModifierFlagCommand).target = self;
    AddMenuItem(appMenu, @"New Project Launcher…", @selector(newProjectLauncher:), @"", 0).target = self;
    AddMenuItem(appMenu, @"Set Up Agent Hooks…", @selector(setupAgentHooks:), @"", 0).target = self;
    [appMenu addItem:NSMenuItem.separatorItem];
    // Standard macOS place for Settings (⌘,): appearance, plus links to the project and timer settings.
    AddMenuItem(appMenu, @"Settings…", @selector(openSettings:), @",", NSEventModifierFlagCommand).target = self;
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
    AddMenuItem(focusMenu, @"Start Focus", @selector(startPomodoro:), @"", 0).target = self;
    AddMenuItem(focusMenu, @"Pause/Resume Focus", @selector(togglePomodoroPause:), @"", 0).target = self;
    AddMenuItem(focusMenu, @"Skip Phase", @selector(skipPomodoroPhase:), @"", 0).target = self;
    AddMenuItem(focusMenu, @"Take Break", @selector(takePomodoroBreak:), @"", 0).target = self;
    NSString *todayKey = [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle];
    NSUserDefaults *focusDefaults = [self micaDefaults];
    NSString *storedDay = [focusDefaults stringForKey:@"MicaDailyFocusDay"];
    NSInteger dailyCount = [storedDay isEqualToString:todayKey] ? [focusDefaults integerForKey:@"MicaDailyFocusCount"] : 0;
    NSMenuItem *dailyCountItem = AddMenuItem(focusMenu, [NSString stringWithFormat:@"Completed today: %ld", (long)dailyCount], nil, @"", 0);
    dailyCountItem.enabled = NO;
    NSMenuItem *currentLabel = AddMenuItem(focusMenu,
        self.pomodoroLabel.length ? [NSString stringWithFormat:@"Session: %@", self.pomodoroLabel] : @"Session: (unlabeled)", nil, @"", 0);
    currentLabel.enabled = NO;
    currentLabel.tag = 9137;
    AddMenuItem(focusMenu, @"Label…", @selector(editPomodoroLabel:), @"", 0).target = self;
    AddMenuItem(focusMenu, @"Reset Timer", @selector(resetPomodoro:), @"", 0).target = self;
    [focusMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(focusMenu, @"Timer Settings…", @selector(openPomodoroSettings:), @"", 0).target = self;
    focusRoot.submenu = focusMenu;
    [main addItem:focusRoot];
    NSMenuItem *projectRoot = [[NSMenuItem alloc] initWithTitle:@"Project" action:nil keyEquivalent:@""];
    NSMenu *projectMenu = [[NSMenu alloc] initWithTitle:@"Project"];
    AddMenuItem(projectMenu, @"Project Settings…", @selector(openProjectSettings:), @"", 0).target = self;
    projectRoot.submenu = projectMenu;
    [main addItem:projectRoot];
    NSMenuItem *sessionsRoot = [[NSMenuItem alloc] initWithTitle:@"Session" action:nil keyEquivalent:@""];
    NSMenu *sessionMenu = [[NSMenu alloc] initWithTitle:@"Session"];
    AddMenuItem(sessionMenu, @"New Shell Tab", @selector(newShell:), @"t", NSEventModifierFlagCommand).target = self;
    AddMenuItem(sessionMenu, @"New Worktree Tab…", @selector(newWorktreeTab:), @"", 0).target = self;
    AddMenuItem(sessionMenu, @"SSH Connections…", @selector(openSSHProfiles:), @"", 0).target = self;
    AddMenuItem(sessionMenu, @"Choose Tab…", @selector(toggleTabPicker), @"", 0).target = self;
    AddMenuItem(sessionMenu, @"Jump to Next Waiting Tab", @selector(jumpToNextWaitingTab:), @"j",
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
    AddMenuItem(editMenu, @"Select Last Command Output", @selector(selectLastCommandOutput:), @"", 0).target = self.terminalView;
    AddMenuItem(editMenu, @"Copy Last Command Output", @selector(copyLastCommandOutput:), @"", 0).target = self.terminalView;
    AddMenuItem(editMenu, @"Quick Select…", @selector(toggleQuickSelect:), @"u", NSEventModifierFlagCommand | NSEventModifierFlagShift).target = self.terminalView;
    AddMenuItem(editMenu, @"Paste", @selector(paste:), @"v", NSEventModifierFlagCommand);
    AddMenuItem(editMenu, @"Undo Last Dictation", @selector(undoLastDictation:), @"", 0).target = self;
    NSMenuItem *vocabularyToggle = AddMenuItem(editMenu, @"Improve Dictation with Project Vocabulary", @selector(toggleVocabularyPreference:), @"", 0);
    vocabularyToggle.target = self;
    vocabularyToggle.state = (![[self micaDefaults] objectForKey:@"MicaDictationVocabularyEnabled"] ||
        [[self micaDefaults] boolForKey:@"MicaDictationVocabularyEnabled"]) ? NSControlStateValueOn : NSControlStateValueOff;
    AddMenuItem(editMenu, @"Edit Vocabulary…", @selector(editVocabulary:), @"", 0).target = self;
    AddMenuItem(editMenu, @"Edit Snippets…", @selector(editSnippets:), @"", 0).target = self;
    AddMenuItem(editMenu, @"Find in Scrollback…", @selector(findInScrollback:), @"f", NSEventModifierFlagCommand).target = self.terminalView;
    AddMenuItem(editMenu, @"Find Next", @selector(findNextMatch:), @"g", NSEventModifierFlagCommand).target = self.terminalView;
    AddMenuItem(editMenu, @"Find Previous", @selector(findPreviousMatch:), @"g",
                NSEventModifierFlagCommand | NSEventModifierFlagShift).target = self.terminalView;
    AddMenuItem(editMenu, @"Clear Scrollback", @selector(clearScrollbackMenu:), @"k", NSEventModifierFlagCommand).target = self.terminalView;
    AddMenuItem(editMenu, @"Fold Selected Lines", @selector(foldSelectedLines:), @"f",
                NSEventModifierFlagCommand | NSEventModifierFlagOption).target = self.terminalView;
    editRoot.submenu = editMenu;
    [main addItem:editRoot];
    NSMenuItem *viewRoot = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    AddMenuItem(viewMenu, @"Show Sidebar", @selector(toggleSidebar:), @"", 0).target = self;
    [viewMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(viewMenu, @"Light Terminal Theme", @selector(toggleLightTheme:), @"l",
                NSEventModifierFlagCommand | NSEventModifierFlagOption).target = self;
    [viewMenu addItem:NSMenuItem.separatorItem];
    NSString *cursorTitles[] = { @"Block Cursor", @"Bar Cursor", @"Underline Cursor" };
    for (NSInteger style = 0; style < 3; style++) {
        NSMenuItem *cursorItem = AddMenuItem(viewMenu, cursorTitles[style], @selector(setCursorStyle:), @"", 0);
        cursorItem.target = self;
        cursorItem.tag = style;
        cursorItem.state = style == gMicaCursorStyle ? NSControlStateValueOn : NSControlStateValueOff;
    }
    viewRoot.submenu = viewMenu;
    [main addItem:viewRoot];
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
    AddMenuItem(helpMenu, @"Command Palette…", @selector(toggleCommandPalette:), @"p",
                NSEventModifierFlagCommand | NSEventModifierFlagShift).target = self;
    AddMenuItem(helpMenu, @"Keyboard Shortcuts…", @selector(showKeyboardShortcuts:), @"/",
                NSEventModifierFlagCommand).target = self;
    AddMenuItem(helpMenu, @"Releases and Updates", @selector(openReleasesPage:), @"", 0).target = self;
    AddMenuItem(helpMenu, @"Report an Issue", @selector(openIssuesPage:), @"", 0).target = self;
    [helpMenu addItem:NSMenuItem.separatorItem];
    AddMenuItem(helpMenu, @"Open Diagnostic Logs", @selector(openDiagnosticLogs:), @"", 0).target = self;
    helpRoot.submenu = helpMenu;
    [main addItem:helpRoot];
    NSApp.helpMenu = helpMenu;
    [NSApp setMainMenu:main];
}

- (void)updateFocusMenuLabel {
    for (NSMenuItem *root in NSApp.mainMenu.itemArray) {
        if (![root.title isEqualToString:@"Focus"]) continue;
        for (NSMenuItem *item in root.submenu.itemArray) if (item.tag == 9137)
            item.title = self.pomodoroLabel.length ? [NSString stringWithFormat:@"Session: %@", self.pomodoroLabel] : @"Session: (unlabeled)";
    }
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
        @"⌘⇧P  Command palette and tab switcher",
        @"⌘⇧S  Browse scrollback",
        @"⌘⇧[ / ⌘⇧]  Previous / next tab",
        @"Drag a tab  Reorder tabs",
        @"⌘+ / ⌘− / ⌘0  Increase / decrease / reset font size",
        @"⌘F / ⌘G / ⇧⌘G  Find in scrollback, next, previous",
        @"⌘N  New window",
        @"⌘K  Clear scrollback",
        @"⌘C  Copy selection; with no selection, send Ctrl-C to the program",
        @"⌥⌘L  Toggle the light terminal theme",
        @"⌥⌘F  Fold selected lines",
        @"⌘-click  Open a link or web address",
        @"Hold left ⌥  Dictate; release to finish",
        @"Esc  Cancel dictation or return to live terminal"
    ] componentsJoinedByString:@"\n"];
    [alert addButtonWithTitle:@"Done"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)setUiMode:(MicaUIMode)mode {
    if (_uiMode == mode) return;
    _uiMode = mode;
    // Modes are drawn in the status strip only; announce them so VoiceOver users know where they are.
    NSString *announcement = mode == MicaUIModeTab ? @"Tab picker. Use arrow keys to switch tabs, Escape to leave."
        : mode == MicaUIModeScroll ? @"Scrollback. Use arrow keys or Page Up and Down, Escape to return to the live terminal."
        : @"Live terminal";
    if (self.terminalView)
        NSAccessibilityPostNotificationWithUserInfo(self.terminalView, NSAccessibilityAnnouncementRequestedNotification,
            @{ NSAccessibilityAnnouncementKey: announcement });
}

- (void)openSettings:(id)sender {
    [self openPreferences:sender];
}

- (void)openReleasesPage:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/megasoft1978/mica-terminal/releases"]];
}

- (void)openIssuesPage:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/megasoft1978/mica-terminal/issues"]];
}

- (void)openDiagnosticLogs:(id)sender {
    (void)sender;
    if (!MicaDiagnosticsIsEnabled()) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Diagnostic logging is off";
        alert.informativeText = @"Enable it in Settings → Advanced to create diagnostic logs.";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSURL *directory = MicaDiagnosticsLogDirectory();
    if (!directory) {
        MicaDiagnosticsLog(@"diagnostics", @"could not locate the diagnostic log folder");
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Couldn't find the log folder";
        alert.informativeText = @"Mica writes diagnostic logs to ~/Library/Logs/Mica. The folder hasn't been created yet.";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:directory];
}

- (void)openProjectSettings:(id)sender {
    (void)sender;
    if (!self.projectLayoutPath.length) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"This window isn't tied to a project";
        alert.informativeText = @"Open Mica from a project launcher (see “Create a project launcher” in the README) to give it saved tabs and folders you can edit here.";
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

- (void)openSSHProfiles:(id)sender {
    (void)sender;
    MicaSSHProfilesController *controller = [[MicaSSHProfilesController alloc] initWithOwner:self];
    self.sshProfilesController = controller;
    [self.window beginSheet:controller.window completionHandler:^(NSModalResponse returnCode) {
        (void)returnCode;
        self.sshProfilesController = nil;
    }];
}

- (void)openSSHProfile:(NSDictionary<NSString *,NSString *> *)profile {
    NSDictionary *normalized = MicaSSHProfileNormalize(profile, NULL);
    NSString *command = normalized ? MicaSSHProfileCommand(normalized) : nil;
    if (!command.length) return;
    NSString *tabName = normalized[@"name"];
    NSUInteger tabsBefore = self.tabs.count;
    [self newTabWithName:tabName command:command];
    if (self.tabs.count != tabsBefore + 1) return;
    MicaTab *tab = self.activeTab;
    tab.remoteProfile = normalized;
    tab.gitBranch = nil;
    tab.gitBranchLookupPath = tab.cwd;
    tab.vocabularyFileTerms = @[];
    tab.gitVocabularyTerms = @[];
    tab.recentVisibleText = @"";
}

- (void)connectSSHProfile:(id)sender {
    if (![sender isKindOfClass:NSMenuItem.class]) return;
    id profile = [(NSMenuItem *)sender representedObject];
    if ([profile isKindOfClass:NSDictionary.class]) [self openSSHProfile:profile];
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
    self.explicitLayoutLaunch = self.projectLayoutPath.length > 0;
    self.projectName = projectName.length ? projectName : nil;
    [self updateWindowTitle];
    [self configurePomodoro];
    NSArray<NSDictionary *> *tabSpecs = configuration[@"tabs"];
    BOOL restoringSession = NO;
    if (self.savedTabsForWindow.count) tabSpecs = self.savedTabsForWindow;
    else if (!self.explicitLayoutLaunch && (!getenv("MICA_TEST_NO_STARTUP") || gMicaSessionStateURLOverride)) {
        NSArray *saved = [self readSessionState];
        if (saved.count) { tabSpecs = saved.firstObject[@"tabs"]; restoringSession = YES; }
    }
    MicaDiagnosticsLog(@"launch", [NSString stringWithFormat:@"configuration layout=%d tabs=%lu",
        [configuration[@"layoutLoaded"] boolValue],
        (unsigned long)tabSpecs.count]);
    for (NSDictionary *spec in tabSpecs) {
        NSString *command = [spec[@"command"] length] ? spec[@"command"] : nil;
        NSString *resumeCommand = restoringSession ? MicaResumeCommand(spec[@"agentKind"], spec[@"agentSessionID"]) : nil;
        BOOL resumeEnabled = [[self micaDefaults] boolForKey:@"MicaResumeAgentsOnRestore"];
        if (resumeCommand) command = resumeCommand;
        // Older layouts used a built-in Git view. Keep them useful by turning
        // that entry into the regular lazygit shell command.
        if ([command isEqualToString:@"mica-git"]) command = @"lazygit";
        NSString *cwd = spec[@"cwd"];
        BOOL isDirectory = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:cwd isDirectory:&isDirectory] || !isDirectory)
            cwd = NSHomeDirectory();
        [self addTabWithName:spec[@"name"] cwd:cwd command:command
                   prefilled:resumeCommand ? !resumeEnabled : ([spec[@"prefilled"] boolValue] || (restoringSession && command.length > 0))];
        if (self.tabs.count && [spec[@"muteNotifications"] isKindOfClass:NSNumber.class])
            self.tabs.lastObject.muteNotifications = [spec[@"muteNotifications"] boolValue];
    }
    if (self.tabs.count == 0) {
        NSString *cwd = configuration[@"cwd"] ?: NSFileManager.defaultManager.currentDirectoryPath;
        if (!self.explicitLayoutLaunch && (!getenv("MICA_TEST_NO_STARTUP") || gMicaSessionStateURLOverride)) {
            NSArray *saved = [self readSessionState];
            NSString *savedCwd = [saved.firstObject[@"tabs"] firstObject][@"cwd"];
            if (savedCwd.length) cwd = savedCwd;
        }
        [self addTabWithName:@"Shell" cwd:cwd command:nil prefilled:NO];
    }
    [self updateWindowTitle];
    [self.terminalView setNeedsDisplay:YES];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(undoLastDictation:)) {
        item.toolTip = self.dictationUndoValid ? nil : @"Undo is available only until you type again";
        return self.dictationUndoValid;
    }
    if (item.action == @selector(skipPomodoroPhase:)) {
        [self refreshPomodoroState];
        MicaPomodoroPhase phase = self.pomodoro.phase;
        BOOL focus = phase == MICA_POMODORO_FOCUS || phase == MICA_POMODORO_PAUSED_FOCUS;
        item.title = phase == MICA_POMODORO_IDLE ? @"End Current Phase" :
            (focus ? @"End Focus & Start Break" : @"End Break & Start Focus");
        return phase != MICA_POMODORO_IDLE;
    }
    return YES;
}

- (NSUserDefaults *)micaDefaults { return gMicaDefaultsOverride ?: NSUserDefaults.standardUserDefaults; }

- (void)loadStoredThemePreference {
    NSString *themeMode = [[self micaDefaults] stringForKey:@"MicaThemeMode"];
    gMicaFollowSystemTheme = [themeMode isEqualToString:@"system"];
    BOOL light = gMicaFollowSystemTheme ? [self systemAppearanceIsLight] :
        ([themeMode isEqualToString:@"light"] || (!themeMode && [[self micaDefaults] boolForKey:@"MicaLightTheme"]));
    [self setLightTheme:light];
}

- (NSURL *)sessionStateURL {
    if (gMicaSessionStateURLOverride) return gMicaSessionStateURLOverride;
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"Mica" isDirectory:YES]
        URLByAppendingPathComponent:@"sessions.json"];
}

- (NSArray<NSDictionary *> *)readSessionState {
    NSData *data = [NSData dataWithContentsOfURL:[self sessionStateURL] options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || data.length > 64 * 1024) return @[];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"windows"] isKindOfClass:NSArray.class]) return @[];
    NSArray *windows = json[@"windows"];
    if (windows.count > 32) return @[];
    NSMutableArray<NSDictionary *> *validWindows = [NSMutableArray array];
    for (id window in windows) {
        if (![window isKindOfClass:NSDictionary.class] || ![window[@"tabs"] isKindOfClass:NSArray.class] ||
            [window[@"tabs"] count] == 0) continue;
        NSString *layout = window[@"layout"];
        id projectName = window[@"projectName"];
        NSString *layoutRoot = [[MicaDefaultLayoutsDirectory() stringByResolvingSymlinksInPath]
            stringByAppendingString:@"/"];
        if (projectName && (![projectName isKindOfClass:NSString.class] || [projectName length] > 100 ||
            [projectName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)) continue;
        if (layout && (![layout isKindOfClass:NSString.class] || !layout.isAbsolutePath ||
            layout.length > PATH_MAX ||
            ![layout.pathExtension isEqualToString:@"mica"] ||
            ![[layout stringByResolvingSymlinksInPath] hasPrefix:layoutRoot])) continue;
        NSMutableArray<NSDictionary *> *validTabs = [NSMutableArray array];
        for (id tab in window[@"tabs"]) {
            if (![tab isKindOfClass:NSDictionary.class] || ![tab[@"name"] isKindOfClass:NSString.class] ||
                ![tab[@"cwd"] isKindOfClass:NSString.class] ||
                (tab[@"muteNotifications"] &&
                    (![tab[@"muteNotifications"] isKindOfClass:NSNumber.class] ||
                     CFGetTypeID((__bridge CFTypeRef)tab[@"muteNotifications"]) != CFBooleanGetTypeID())) ||
                (tab[@"command"] && (![tab[@"command"] isKindOfClass:NSString.class] ||
                    [tab[@"command"] length] > 4096))) continue;
            NSString *name = tab[@"name"], *cwd = tab[@"cwd"];
            struct stat cwdInfo;
            int cwdStatus = lstat(cwd.fileSystemRepresentation, &cwdInfo);
            if ((cwdStatus == 0 && (S_ISLNK(cwdInfo.st_mode) || !S_ISDIR(cwdInfo.st_mode))) ||
                (cwdStatus != 0 && errno != ENOENT)) continue;
            if (name.length == 0 || name.length > 64 || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
                cwd.length == 0 || cwd.length > PATH_MAX || !cwd.isAbsolutePath ||
                [[cwd pathComponents] containsObject:@".."]) continue;
            if (validTabs.count < 64) {
                NSMutableDictionary *cleanTab = [tab mutableCopy];
                NSString *resumeCommand = MicaResumeCommand(tab[@"agentKind"], tab[@"agentSessionID"]);
                [cleanTab removeObjectForKey:@"agentKind"];
                [cleanTab removeObjectForKey:@"agentSessionID"];
                if (resumeCommand) {
                    cleanTab[@"agentKind"] = tab[@"agentKind"];
                    cleanTab[@"agentSessionID"] = tab[@"agentSessionID"];
                }
                [validTabs addObject:cleanTab];
            }
        }
        if (validTabs.count) {
            NSMutableDictionary *clean = [window mutableCopy];
            clean[@"tabs"] = validTabs;
            [validWindows addObject:clean];
        }
    }
    return validWindows;
}

- (void)saveSessionState {
    if (getenv("MICA_TEST_NO_STARTUP") && !gMicaSessionStateURLOverride) return;
    NSMutableArray *windows = [NSMutableArray array];
    for (MicaAppDelegate *controller in MicaControllers()) {
        NSMutableArray *tabs = [NSMutableArray array];
        for (MicaTab *tab in controller.tabs) {
            NSString *name = tab.name.length && tab.name.length <= 64 &&
                [tab.name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound
                ? tab.name : @"Terminal";
            if (tabs.count >= 64) break;
            NSString *cwd = tab.cwd ?: NSHomeDirectory();
            BOOL isDirectory = NO;
            if (!cwd.isAbsolutePath || cwd.length > PATH_MAX ||
                [[cwd pathComponents] containsObject:@".."] ||
                ![NSFileManager.defaultManager fileExistsAtPath:cwd isDirectory:&isDirectory] || !isDirectory)
                cwd = NSHomeDirectory();
            else {
                char resolvedPath[PATH_MAX];
                if (realpath(cwd.fileSystemRepresentation, resolvedPath)) cwd = @(resolvedPath);
            }
            NSMutableDictionary *savedTab = [@{@"name":name, @"cwd":cwd,
                @"muteNotifications":@(tab.muteNotifications)} mutableCopy];
            if (tab.command.length && tab.command.length <= 4096) savedTab[@"command"] = tab.command;
            if (MicaResumeCommand(tab.agentKind, tab.agentSessionID)) {
                savedTab[@"agentKind"] = tab.agentKind;
                savedTab[@"agentSessionID"] = tab.agentSessionID;
            }
            [tabs addObject:savedTab];
        }
        if (tabs.count) {
            NSMutableDictionary *savedWindow = [@{@"tabs":tabs} mutableCopy];
            if (controller.explicitLayoutLaunch && controller.projectLayoutPath.length &&
                [[controller.projectLayoutPath stringByResolvingSymlinksInPath] hasPrefix:
                    [[MicaDefaultLayoutsDirectory() stringByResolvingSymlinksInPath] stringByAppendingString:@"/"]]) {
                savedWindow[@"layout"] = [controller.projectLayoutPath stringByResolvingSymlinksInPath];
                if (controller.projectName.length) savedWindow[@"projectName"] = controller.projectName;
            }
            [windows addObject:savedWindow];
        }
    }
    NSURL *url = [self sessionStateURL];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    chmod(url.URLByDeletingLastPathComponent.fileSystemRepresentation, 0700);
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"windows":windows}
        options:NSJSONWritingSortedKeys error:nil];
    if (data.length && data.length <= 64 * 1024 && [data writeToURL:url options:NSDataWritingAtomic error:nil])
        chmod(url.fileSystemRepresentation, 0600);
}

- (void)addTabWithName:(NSString *)name cwd:(NSString *)cwd command:(NSString *)command prefilled:(BOOL)prefilled {
    MicaTab *previous = self.activeTab;
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    [self.terminalView clearSelection];
    MicaTab *tab = [[MicaTab alloc] init];
    tab.identifier = gMicaNextTabIdentifier++;
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
        MicaDiagnosticsLog(@"pty", @"session start failed");
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Couldn't start a shell";
        alert.informativeText = [NSString stringWithFormat:@"Mica couldn't start a terminal session in %@. Check that the folder exists and Mica may access it (System Settings › Privacy & Security › Files and Folders).", tab.cwd];
        [alert runModal];
        return;
    }
    const char *rawHookToken = mica_session_hook_token(tab.session);
    if (rawHookToken && rawHookToken[0]) tab.hookToken = [NSString stringWithUTF8String:rawHookToken];
    if (gMicaLightTheme) mica_session_set_light_theme(tab.session, true);
    [self installSourceForTab:tab];
    MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"session started pid=%d command_prefilled=%d",
        (int)mica_session_pid(tab.session), command.length > 0]);
    if (tab.session) {
        tab.commandCompletionCount = mica_session_command_completion_count(tab.session);
        tab.tracksCompletion = command.length > 0;
        tab.completionLabel = command.length ? command.pathComponents.lastObject : @"Process";
    }
    tab.revision = UINT64_MAX;
    [self.tabs addObject:tab];
    self.activeIndex = (NSInteger)self.tabs.count - 1;
    [self refreshVocabularyForTab:tab];
    if (tab.session && NSApp.isActive) mica_session_focus(tab.session, true);
    [self updateWindowTitle];
    [self resizeActiveSession];
    [self.terminalView setNeedsDisplay:YES];
}

- (void)refreshVocabularyForTab:(MicaTab *)tab {
    if (!tab.cwd.length) return;
    NSString *tabPath=tab.cwd;
    tab.vocabularyFileTerms=MicaVocabularyTermsFromFile([NSURL fileURLWithPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mica/vocabulary.txt"]]);
    if (![tab.gitBranchLookupPath isEqualToString:tabPath]) {
        tab.gitBranchLookupPath=tabPath;
        tab.gitBranch=nil;
        __weak MicaTab *branchTab=tab; __weak typeof(self) branchSelf=self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            NSString *branch=MicaGitBranchForDirectory(tabPath);
            dispatch_async(dispatch_get_main_queue(), ^{
                MicaTab *strongTab=branchTab; MicaAppDelegate *strongSelf=branchSelf;
                if (strongTab && strongSelf && !strongTab.remoteProfile && [strongSelf.tabs containsObject:strongTab] && [strongTab.cwd isEqualToString:tabPath]) {
                    strongTab.gitBranch=branch;
                    [strongSelf.terminalView setNeedsDisplayInRect:NSMakeRect(0,0,strongSelf.terminalView.bounds.size.width,kStatusHeight)];
                    [strongSelf.windowContentView.sidebarView refreshRows];
                }
            });
        });
    }
    __weak MicaTab *weakTab=tab; __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSArray *terms=MicaVocabularyTermsFromGitFiles(tabPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            MicaTab *strongTab=weakTab; MicaAppDelegate *strongSelf=weakSelf;
            if (strongTab && strongSelf && !strongTab.remoteProfile && [strongSelf.tabs containsObject:strongTab] && [strongTab.cwd isEqualToString:tabPath]) strongTab.gitVocabularyTerms=terms;
        });
    });
}

- (NSString *)visibleTextForTab:(MicaTab *)tab {
    if (!tab.session) return @"";
    NSMutableString *text=[NSMutableString string];
    int rows=mica_session_rows(tab.session), cols=mica_session_cols(tab.session);
    for (int row=0;row<rows;row++) {
        for (int col=0;col<cols;col++) {
            MicaCell cell;
            if (mica_session_get_cell(tab.session,row,col,&cell) && cell.chars[0]>=0x20 && cell.chars[0]<=0x7f)
                [text appendFormat:@"%C",(unichar)cell.chars[0]];
        }
        [text appendString:@"\n"];
    }
    return text;
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

// The folder that holds .git for `directory`, or nil outside a repository.
static NSString *MicaGitRootForDirectory(NSString *directory) {
    NSString *current = directory.stringByStandardizingPath;
    for (int depth = 0; depth < 40 && current.length > 1; depth++, current = current.stringByDeletingLastPathComponent)
        if ([NSFileManager.defaultManager fileExistsAtPath:[current stringByAppendingPathComponent:@".git"]]) return current;
    return nil;
}

// Only branch names git itself would accept without surprises; nothing that could be read as an option.
static BOOL MicaValidBranchName(NSString *name) {
    if (!name.length || name.length > 100 || [name hasPrefix:@"-"] || [name hasPrefix:@"/"] || [name hasSuffix:@"/"] ||
        [name hasSuffix:@".lock"] || [name containsString:@".."] || [name containsString:@"//"]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// Gives an agent its own checkout: `git worktree add -b <branch>` next to the repository, then opens a tab there.
- (void)newWorktreeTab:(id)sender {
    (void)sender;
    NSString *root = MicaGitRootForDirectory(self.activeTab.cwd ?: NSHomeDirectory());
    NSAlert *alert = [NSAlert new];
    if (!root) {
        alert.messageText = @"This tab isn't in a git repository";
        alert.informativeText = @"Open a tab inside a repository first, then choose New Worktree Tab again.";
        [alert runModal];
        return;
    }
    alert.messageText = @"New Worktree Tab";
    alert.informativeText = [NSString stringWithFormat:@"Creates a new branch and a separate checkout next to “%@”, so an agent can work without touching your current files.", root.lastPathComponent];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    field.placeholderString = @"Branch name, for example agent/fix-login";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *branch = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSAlert *problem = [NSAlert new];
    problem.messageText = @"Couldn't create the worktree";
    if (!MicaValidBranchName(branch)) {
        problem.informativeText = @"Use letters, numbers and . _ - / only, without leading dashes or “..”.";
        [problem runModal];
        return;
    }
    NSString *slug = [branch stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSString *destination = [[root stringByDeletingLastPathComponent] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@-%@", root.lastPathComponent, slug]];
    if ([NSFileManager.defaultManager fileExistsAtPath:destination]) {
        problem.informativeText = [NSString stringWithFormat:@"%@ already exists.", destination];
        [problem runModal];
        return;
    }
    NSURL *git = MicaGitExecutableURL();
    if (!git) {
        problem.informativeText = @"git wasn't found. Install the Xcode command line tools.";
        [problem runModal];
        return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = git;
    task.arguments = @[@"-C", root, @"worktree", @"add", @"-b", branch, destination];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            MicaAppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (finished.terminationStatus == 0) {
                [strongSelf addTabWithName:branch cwd:destination command:nil prefilled:NO];
            } else {
                problem.informativeText = text.length ? text : @"git reported an error.";
                [problem runModal];
            }
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        problem.informativeText = error.localizedDescription ?: @"git could not be started.";
        [problem runModal];
    }
}

// Creates a Desktop project launcher by running the bundled installer script without prompts.
- (void)newProjectLauncher:(id)sender {
    (void)sender;
    NSURL *bundle = NSBundle.mainBundle.bundleURL;
    NSURL *installedRelease = [NSURL fileURLWithPath:@"/Applications/Mica.app" isDirectory:YES];
    if ([NSFileManager.defaultManager fileExistsAtPath:installedRelease.path]) bundle = installedRelease;
    NSURL *script = [bundle URLByAppendingPathComponent:@"Contents/Resources/Scripts/install-desktop-apps.py"];
    NSURL *iconTool = [bundle URLByAppendingPathComponent:@"Contents/Helpers/mica-project-icon"];
    if (![NSFileManager.defaultManager fileExistsAtPath:script.path] || ![NSFileManager.defaultManager fileExistsAtPath:iconTool.path]) {
        NSAlert *missing = [NSAlert new];
        missing.messageText = @"Launcher tools are missing";
        missing.informativeText = @"This copy of Mica doesn't include the launcher installer. Build it from source with make app, or run make new-instance.";
        [missing runModal];
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"New Project Launcher";
    alert.informativeText = @"Creates a Mica app on your Desktop that opens this project in its own window.";
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 92)];
    NSString *(^label)(NSString *) = ^NSString *(NSString *text) { return text; };
    (void)label;
    NSArray<NSString *> *titles = @[@"Name", @"Folder", @"Startup command (optional)"];
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        CGFloat y = 92 - 30 * (i + 1);
        NSTextField *caption = [NSTextField labelWithString:titles[i]];
        caption.frame = NSMakeRect(0, y + 4, 130, 18);
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(134, y, 226, 24)];
        [form addSubview:caption];
        [form addSubview:field];
        [fields addObject:field];
    }
    NSString *activeFolder = self.activeTab.cwd.length ? self.activeTab.cwd : NSHomeDirectory();
    fields[0].stringValue = activeFolder.lastPathComponent ?: @"";
    fields[1].stringValue = activeFolder;
    alert.accessoryView = form;
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = fields[0];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *name = [fields[0].stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *folder = [fields[1].stringValue stringByExpandingTildeInPath];
    BOOL isDirectory = NO;
    if (!name.length || ![NSFileManager.defaultManager fileExistsAtPath:folder isDirectory:&isDirectory] || !isDirectory) {
        NSAlert *bad = [NSAlert new];
        bad.messageText = @"Couldn't create the launcher";
        bad.informativeText = name.length ? @"That folder doesn't exist." : @"Give the project a name.";
        [bad runModal];
        return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    task.arguments = @[script.path, @"--new-instance", @"--name", name, @"--folder", folder,
                       @"--command", fields[2].stringValue ?: @"", @"--base-app", bundle.path,
                       @"--project-icon-tool", iconTool.path];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            MicaAppDelegate *strongSelf = weakSelf;
            NSAlert *result = [NSAlert new];
            if (finished.terminationStatus == 0) {
                result.messageText = @"Launcher created";
                result.informativeText = @"Look for it on your Desktop.";
            } else {
                result.messageText = @"Couldn't create the launcher";
                result.informativeText = text.length ? text : @"The installer failed. Is Python 3 (Xcode Command Line Tools) installed?";
            }
            if (strongSelf.window) [result beginSheetModalForWindow:strongSelf.window completionHandler:nil];
            else [result runModal];
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSAlert *failed = [NSAlert new];
        failed.messageText = @"Couldn't run the launcher installer";
        failed.informativeText = error.localizedDescription ?: @"Python 3 is required.";
        [failed runModal];
    }
}

// New Window: another shell window inside this same process (no second copy of the app in memory).
- (void)newInstance:(id)sender {
    (void)sender;
    [self openProjectWindowWithArguments:@[@"mica", @"--new-window"]];
}

// Opens a project window inside this process. A window already showing the same layout is brought to the
// front instead of being duplicated.
- (void)openProjectWindowWithArguments:(NSArray<NSString *> *)arguments {
    NSUInteger layoutIndex = [arguments indexOfObject:@"--layout"];
    NSString *layout = layoutIndex != NSNotFound && layoutIndex + 1 < arguments.count ? arguments[layoutIndex + 1] : nil;
    if (layout.length) {
        for (MicaAppDelegate *controller in MicaControllers()) {
            if ([controller.projectLayoutPath isEqualToString:layout] && controller.window) {
                [controller.window makeKeyAndOrderFront:nil];
                [NSApp activateIgnoringOtherApps:YES];
                return;
            }
        }
    }
    MicaAppDelegate *controller = [[MicaAppDelegate alloc] init];
    [controller startWindowWithArguments:arguments];
    [NSApp activateIgnoringOtherApps:YES];
    MicaDiagnosticsLog(@"launch", [NSString stringWithFormat:@"opened another window in this process (windows=%lu)",
        (unsigned long)MicaControllers().count]);
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    for (NSURL *url in urls) {
        if (!MicaControllers().count) { [MicaPendingOpenURLs() addObject:url]; continue; }   // still launching
        NSArray<NSString *> *arguments = MicaArgumentsForOpenURL(url, MicaDefaultLayoutsDirectory());
        if (arguments) [self openProjectWindowWithArguments:arguments];
        else MicaDiagnosticsLog(@"launch", @"ignored a mica:// URL that is not a layout inside the layouts folder");
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
            [self refreshVocabularyForTab:tab];
        }
    }
    // Capture once at dictation start instead of maintaining a rolling screen buffer.
    tab.recentVisibleText = [self visibleTextForTab:tab];
    tab.recentVisibleCapturedAt = [NSDate date];
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
    // State transitions reserve or release the preview band and resize the PTY grid.
    NSInteger state = (NSInteger)controller.state;
    if (state != self.lastVoiceState) {
        self.lastVoiceState = state;
        [self resizeActiveSession];
        [self.terminalView setNeedsDisplay:YES];
        // The preview is drawn in the terminal view, so announce state changes to VoiceOver.
        if (controller.statusText.length)
            NSAccessibilityPostNotificationWithUserInfo(self.terminalView, NSAccessibilityAnnouncementRequestedNotification,
                @{ NSAccessibilityAnnouncementKey: controller.statusText,
                   NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium) });
    } else {
        [self.terminalView setNeedsDisplayInRect:[self.terminalView dictationPreviewRect]];
    }
}

- (BOOL)voiceController:(MicaVoiceController *)controller
      didFinishTranscript:(NSString *)transcript {
    (void)controller;
    MicaTab *target = self.voiceTargetTab;
    if (!target || ![self.tabs containsObject:target] || !target.session ||
        !mica_session_is_running(target.session)) return NO;
    BOOL improve = ![[self micaDefaults] objectForKey:@"MicaDictationVocabularyEnabled"] ||
        [[self micaDefaults] boolForKey:@"MicaDictationVocabularyEnabled"];
    NSString *visibleText = target.recentVisibleText.length ? target.recentVisibleText : [self visibleTextForTab:target];
    NSDate *capturedAt = target.recentVisibleCapturedAt ?: [NSDate date];
    NSArray *recentTerms = MicaVocabularyTermsFromRecentText(visibleText, capturedAt, [NSDate date]);
    NSArray *terms = MicaVocabularyMerge(@[target.vocabularyFileTerms ?: @[],
        self.projectName ? @[self.projectName] : @[], target.gitBranch ? @[target.gitBranch] : @[],
        target.gitVocabularyTerms ?: @[], recentTerms]);
    NSString *corrected = improve ? MicaCorrectTranscript(transcript, terms) : transcript;
    NSURL *snippetsURL = self.dictationSnippetsURLOverride ?: [NSURL fileURLWithPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mica/snippets.txt"]];
    NSString *insertedText = MicaApplyDictationSnippet(corrected, MicaDictationSnippetsFromFile(snippetsURL));
    NSData *bytes = [insertedText dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes.length) return NO;
    mica_session_paste(target.session, bytes.bytes, bytes.length);
    self.lastDictationText = insertedText;
    self.lastDictationRawText = transcript;
    self.lastDictationTab = target;
    self.dictationUndoValid = [transcript rangeOfCharacterFromSet:
        NSCharacterSet.newlineCharacterSet].location == NSNotFound;
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
    MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"tab closed pid=%d",
        previous.session ? mica_session_pid(previous.session) : -1]);
    if (previous == self.voiceTargetTab) [self cancelDictation];
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    [MicaAttention() clearTabID:previous.identifier];
    NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
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

- (void)jumpToNextWaitingTab:(id)sender {
    (void)sender;
    NSArray<NSNumber *> *waiting = [MicaAttention() waitingTabIDs];
    if (!waiting.count) return;
    MicaAppDelegate *keyController = self;
    for (MicaAppDelegate *controller in MicaControllers())
        if (controller.window == NSApp.keyWindow) { keyController = controller; break; }
    uint64_t currentID = keyController.activeTab.identifier;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < waiting.count; i++) if (waiting[i].unsignedLongLongValue == currentID) { start = i + 1; break; }
    for (NSUInteger offset = 0; offset < waiting.count; offset++) {
        uint64_t targetID = waiting[(start + offset) % waiting.count].unsignedLongLongValue;
        for (MicaAppDelegate *controller in MicaControllers()) {
            for (NSUInteger index = 0; index < controller.tabs.count; index++) {
                if (controller.tabs[index].identifier != targetID) continue;
                [NSApp activateIgnoringOtherApps:YES];
                [controller.window makeKeyAndOrderFront:nil];
                if (controller != self || (NSInteger)index != controller.activeIndex) [controller selectTabAtIndex:(NSInteger)index];
                [MicaAttention() clearTabID:targetID];
                NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
                return;
            }
        }
    }
}

- (void)selectTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.tabs.count || index == self.activeIndex) return;
    [self.terminalView.inputContext discardMarkedText];
    [self.terminalView unmarkText];
    MicaTab *previous = self.activeTab;
    if (previous.session && NSApp.isActive) mica_session_focus(previous.session, false);
    if (self.uiMode != MicaUIModeTab) self.uiMode = MicaUIModeNormal;
    [self.terminalView clearSelection];
    self.activeIndex = index;
    MicaTab *tab = self.activeTab;
    [self refreshProcessAgentForTab:tab];
    [self requestWorkingDirectoryForTab:tab];
    tab.lastSelectedAt = NSProcessInfo.processInfo.systemUptime;
    tab.needsAttention = NO;
    if (self.window.isKeyWindow) {
        [MicaAttention() clearTabID:tab.identifier];
        NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
    }
    if (tab.session && NSApp.isActive) mica_session_focus(tab.session, true);
    [self updateWindowTitle];
    [self.windowContentView.sidebarView refreshRows];
    [self resizeActiveSession];
}

- (void)toggleSidebar:(id)sender {
    (void)sender;
    self.sidebarVisible = !self.sidebarVisible;
    self.windowContentView.sidebarVisible = self.sidebarVisible;
    NSMenu *viewMenu = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
    NSMenuItem *item = nil;
    for (NSMenuItem *candidate in viewMenu.itemArray)
        if (candidate.action == @selector(toggleSidebar:)) { item = candidate; break; }
    item.title = self.sidebarVisible ? @"Hide Sidebar" : @"Show Sidebar";
    item.state = self.sidebarVisible ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateAgentRSSTimer];
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

// OSC 52: a program asked to set the clipboard. Decisions belong to the requesting tab; never read the clipboard back.
- (void)handleClipboardWrite:(NSString *)text fromTab:(MicaTab *)tab {
    if (!text.length || tab.clipboardDecision == 2) return;
    tab.pendingClipboardText = text;
    if (self.clipboardPromptShowing || tab != self.activeTab) return;
    self.clipboardPromptShowing = YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Allow this program to copy to your clipboard?";
    // Output can forge the command name, so the prompt never trusts it; show what would be copied instead.
    NSMutableString *preview = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length && preview.length < 200; i++) {
        unichar c = [text characterAtIndex:i];
        [preview appendString:(c < 0x20 && c != '\t') || c == 0x7f ? @"·" : [NSString stringWithCharacters:&c length:1]];
    }
    alert.informativeText = [NSString stringWithFormat:@"A program in this terminal wants to place %lu characters on the clipboard, starting with:\n\n%@%@",
        (unsigned long)text.length, preview, text.length > preview.length ? @"…" : @""];
    NSButton *denyAlways = [alert addButtonWithTitle:@"Deny in This Tab"];
    NSButton *once = [alert addButtonWithTitle:@"Copy Once"];
    once.keyEquivalent = @"";
    denyAlways.keyEquivalent = @""; // Default, so Return never grants clipboard access.
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        MicaAppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.clipboardPromptShowing = NO;
        NSString *pending = tab.pendingClipboardText;
        tab.pendingClipboardText = nil;
        if (response == NSAlertFirstButtonReturn) { tab.clipboardDecision = 2; return; }
        if (response == NSAlertSecondButtonReturn && pending.length) {
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:pending forType:NSPasteboardTypeString];
        }
    }];
}

- (void)setLightTheme:(BOOL)light {
    gMicaLightTheme = light;
    NSMutableArray<MicaAppDelegate *> *windows = [MicaControllers() mutableCopy];
    if (![windows containsObject:self]) [windows addObject:self];
    for (MicaAppDelegate *controller in windows) {
        for (MicaTab *tab in controller.tabs)
            if (tab.session) mica_session_set_light_theme(tab.session, light);
        // System mode lets AppKit's semantic chrome colors follow the OS appearance.
        controller.window.appearance = gMicaFollowSystemTheme ? nil :
            [NSAppearance appearanceNamed:light ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
        controller.preferencesWindow.appearance = controller.window.appearance;
        [controller.terminalView setNeedsDisplay:YES];
    }
    NSMenuItem *item = [[NSApp.mainMenu itemWithTitle:@"View"].submenu itemWithTitle:@"Light Terminal Theme"];
    item.state = light ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)systemAppearanceIsLight {
    NSAppearance *appearance = NSApp.effectiveAppearance ?: NSAppearance.currentAppearance;
    NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [best isEqualToString:NSAppearanceNameAqua];
}

- (void)applySystemAppearanceIfNeeded {
    if (gMicaFollowSystemTheme) [self setLightTheme:[self systemAppearanceIsLight]];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    (void)change;
    (void)context;
    if (object == NSApp && [keyPath isEqualToString:@"effectiveAppearance"]) {
        [self applySystemAppearanceIfNeeded];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)applyCursorStyle:(NSInteger)style {
    gMicaCursorStyle = MIN(MAX(style, 0), 2);
    if (!getenv("MICA_TEST_NO_STARTUP")) [NSUserDefaults.standardUserDefaults setInteger:gMicaCursorStyle forKey:@"MicaCursorStyle"];
    NSMenu *viewMenu = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
    for (NSMenuItem *entry in viewMenu.itemArray)
        if (entry.action == @selector(setCursorStyle:)) entry.state = entry.tag == gMicaCursorStyle ? NSControlStateValueOn : NSControlStateValueOff;
    [self.terminalView setNeedsDisplay:YES];
}

- (void)setCursorStyle:(id)sender {
    if ([sender isKindOfClass:NSMenuItem.class]) [self applyCursorStyle:((NSMenuItem *)sender).tag];
}

// One place for the look of the terminal: theme, cursor and text size, plus the project and timer settings.
- (void)prefThemeChanged:(NSPopUpButton *)sender {
    NSInteger selection = sender.indexOfSelectedItem;
    gMicaFollowSystemTheme = selection == 2;
    if (!getenv("MICA_TEST_NO_STARTUP") || gMicaDefaultsOverride) {
        NSString *mode = gMicaFollowSystemTheme ? @"system" : (selection == 1 ? @"light" : @"dark");
        [[self micaDefaults] setObject:mode forKey:@"MicaThemeMode"];
        [[self micaDefaults] setBool:selection == 1 forKey:@"MicaLightTheme"];
    }
    [self setLightTheme:gMicaFollowSystemTheme ? [self systemAppearanceIsLight] : selection == 1];
}
- (void)prefCursorChanged:(NSPopUpButton *)sender { [self applyCursorStyle:sender.indexOfSelectedItem]; }
- (void)prefFontSizeChanged:(NSStepper *)sender {
    self.terminalView.terminalFont = MicaTerminalFont(sender.doubleValue);
    [self resizeActiveSession];
    [self refreshPreferencesSizeLabel];
}

- (void)refreshPreferencesSizeLabel {
    NSTextField *value = (NSTextField *)[self.preferencesWindow.contentView viewWithTag:104];
    value.stringValue = [NSString stringWithFormat:@"%.0f pt", self.terminalView.terminalFont.pointSize];
}

// Scrollback allowance in lines at 80 columns. Measured footprint per busy tab: about 5 MB / 16 MB / 40 MB / 160 MB.
// 0 means the built-in allowance (2 MiB of cells, about 650 lines), which keeps a busy tab small.
static const NSInteger kScrollbackChoices[] = { 0, 2000, 5000, 20000 };

- (NSInteger)storedScrollbackLines {
    NSInteger lines = [[self micaDefaults] integerForKey:@"MicaScrollbackLines"];
    return lines > 0 ? lines : 0;
}

- (void)applyStoredScrollbackPreference {
    NSInteger lines = [self storedScrollbackLines];
    mica_set_history_limit_lines(lines > 0 ? (size_t)lines : MICA_HISTORY_LIMIT_BYTES / (80u * sizeof(VTermScreenCell)));
}

- (void)prefScrollbackChanged:(NSPopUpButton *)sender {
    NSInteger index = MAX(0, MIN(3, sender.indexOfSelectedItem));
    [[self micaDefaults] setInteger:kScrollbackChoices[index] forKey:@"MicaScrollbackLines"];
    [self applyStoredScrollbackPreference];
}

+ (NSInteger)scrollbackIndexForLines:(NSInteger)lines {
    return lines <= 0 ? 0 : (lines <= 2000 ? 1 : (lines <= 5000 ? 2 : 3));
}

- (void)applyStoredShortcutPreference {
    MicaSetGlobalShortcutEnabled([[self micaDefaults] boolForKey:@"MicaGlobalShortcut"]);
}

- (void)prefShortcutChanged:(NSButton *)sender {
    BOOL enable = sender.state == NSControlStateValueOn;
    if (MicaSetGlobalShortcutEnabled(enable)) {
        [[self micaDefaults] setBool:enable forKey:@"MicaGlobalShortcut"];
    } else {
        sender.state = enable ? NSControlStateValueOff : NSControlStateValueOn;   // the system refused; stay as before
    }
}

- (void)prefDictationModeChanged:(NSPopUpButton *)sender {
    self.dictationToggleMode = sender.indexOfSelectedItem == 1;
    [[self micaDefaults] setBool:self.dictationToggleMode forKey:@"MicaDictationToggleMode"];
}

- (void)prefVocabularyChanged:(NSButton *)sender {
    [[self micaDefaults] setBool:sender.state == NSControlStateValueOn forKey:@"MicaDictationVocabularyEnabled"];
}

- (void)prefResumeAgentsChanged:(NSButton *)sender {
    [[self micaDefaults] setBool:sender.state == NSControlStateValueOn forKey:@"MicaResumeAgentsOnRestore"];
}

- (void)editVocabulary:(id)sender {
    (void)sender;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mica/vocabulary.txt"];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        [@"# One term per line; spoken form => Canonical spelling\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:path.stringByDeletingLastPathComponent];
}

- (void)editSnippets:(id)sender {
    (void)sender;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mica/snippets.txt"];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        [@"# One spoken phrase per line: phrase => expansion\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:path.stringByDeletingLastPathComponent];
}

- (void)toggleVocabularyPreference:(id)sender {
    BOOL enabled = ![[self micaDefaults] objectForKey:@"MicaDictationVocabularyEnabled"] ||
        [[self micaDefaults] boolForKey:@"MicaDictationVocabularyEnabled"];
    enabled = !enabled;
    [[self micaDefaults] setBool:enabled forKey:@"MicaDictationVocabularyEnabled"];
    if ([sender isKindOfClass:NSMenuItem.class]) ((NSMenuItem *)sender).state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *button = (NSButton *)[self.preferencesWindow.contentView viewWithTag:108];
    if ([button isKindOfClass:NSButton.class]) button.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)undoLastDictation:(id)sender {
    (void)sender;
    MicaTab *tab = self.lastDictationTab;
    if (!self.dictationUndoValid || !tab.session || ![self.tabs containsObject:tab]) return;
    __block NSUInteger count = 0;
    [self.lastDictationText enumerateSubstringsInRange:NSMakeRange(0, self.lastDictationText.length)
        options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(__unused NSString *part, __unused NSRange range,
            __unused NSRange enclosing, __unused BOOL *stop) { count++; }];
    for (NSUInteger i = 0; i < count; i++) mica_session_key(tab.session, VTERM_KEY_BACKSPACE, VTERM_MOD_NONE);
    self.dictationUndoValid = NO;
    NSData *raw = [self.lastDictationRawText dataUsingEncoding:NSUTF8StringEncoding];
    if (raw.length) mica_session_paste(tab.session, raw.bytes, raw.length);
    self.lastDictationText = nil;
    self.lastDictationRawText = nil;
    self.lastDictationTab = nil;
    [self.terminalView setNeedsDisplay:YES];
}

- (void)openPreferences:(id)sender {
    (void)sender;
    if (self.preferencesWindow) {
        // Values may have changed through shortcuts (⌘+ ⌘− ⌘0, ⌥⌘L) or the View menu since it was last shown.
        [(NSPopUpButton *)[self.preferencesWindow.contentView viewWithTag:102]
            selectItemAtIndex:gMicaFollowSystemTheme ? 2 : (gMicaLightTheme ? 1 : 0)];
        [(NSPopUpButton *)[self.preferencesWindow.contentView viewWithTag:103] selectItemAtIndex:gMicaCursorStyle];
        ((NSStepper *)[self.preferencesWindow.contentView viewWithTag:101]).doubleValue = self.terminalView.terminalFont.pointSize;
        ((NSButton *)[self.preferencesWindow.contentView viewWithTag:105]).state =
            [[self micaDefaults] boolForKey:@"MicaGlobalShortcut"] ? NSControlStateValueOn : NSControlStateValueOff;
        ((NSButton *)[self.preferencesWindow.contentView viewWithTag:109]).state =
            [[self micaDefaults] boolForKey:@"MicaMenuBarTimer"] ? NSControlStateValueOn : NSControlStateValueOff;
        ((NSButton *)[self.preferencesWindow.contentView viewWithTag:110]).state =
            [[self micaDefaults] boolForKey:@"MicaDiagnosticsEnabled"] ? NSControlStateValueOn : NSControlStateValueOff;
        ((NSButton *)[self.preferencesWindow.contentView viewWithTag:112]).state =
            [[self micaDefaults] boolForKey:@"MicaResumeAgentsOnRestore"] ? NSControlStateValueOn : NSControlStateValueOff;
        NSPopUpButton *memoryWarning = (NSPopUpButton *)[self.preferencesWindow.contentView viewWithTag:114];
        NSInteger warningGB = MicaAgentRSSWarningGB([self micaDefaults]);
        [memoryWarning selectItemAtIndex:warningGB == 0 ? 0 : warningGB == 2 ? 1 : warningGB == 4 ? 2 : warningGB == 8 ? 3 : 4];
        ((NSButton *)[self.preferencesWindow.contentView viewWithTag:108]).state =
            (![[self micaDefaults] objectForKey:@"MicaDictationVocabularyEnabled"] ||
             [[self micaDefaults] boolForKey:@"MicaDictationVocabularyEnabled"]) ? NSControlStateValueOn : NSControlStateValueOff;
        {
        [(NSPopUpButton *)[self.preferencesWindow.contentView viewWithTag:106]
                selectItemAtIndex:[MicaAppDelegate scrollbackIndexForLines:[self storedScrollbackLines]]];
            [(NSPopUpButton *)[self.preferencesWindow.contentView viewWithTag:107]
                selectItemAtIndex:self.dictationToggleMode ? 1 : 0];
        }
        [self refreshPreferencesSizeLabel];
        self.preferencesWindow.appearance = gMicaFollowSystemTheme ? nil :
            [NSAppearance appearanceNamed:gMicaLightTheme ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
        [self.preferencesWindow makeKeyAndOrderFront:nil];
        return;
    }
    self.dictationToggleMode = [[self micaDefaults] boolForKey:@"MicaDictationToggleMode"];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 550)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Mica Settings";
    window.releasedWhenClosed = NO;
    window.appearance = gMicaFollowSystemTheme ? nil :
        [NSAppearance appearanceNamed:gMicaLightTheme ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
    NSAppearance *settingsAppearance = window.appearance ?: NSApp.effectiveAppearance;
    __block NSColor *settingsBackground;
    [settingsAppearance performAsCurrentDrawingAppearance:^{ settingsBackground = NSColor.windowBackgroundColor; }];
    window.backgroundColor = settingsBackground;
    NSView *content = window.contentView;
    NSTextField *generalTitle = [NSTextField labelWithString:@"General"];
    generalTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    generalTitle.frame = NSMakeRect(20, 500, 100, 18);
    [content addSubview:generalTitle];
    NSTextField *advancedTitle = [NSTextField labelWithString:@"Advanced"];
    advancedTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    advancedTitle.frame = NSMakeRect(20, 420, 100, 18);
    [content addSubview:advancedTitle];
    NSButton *diagnostics = [NSButton checkboxWithTitle:@"Enable diagnostic logging" target:self action:@selector(prefDiagnosticsChanged:)];
    diagnostics.tag = 110;
    diagnostics.state = [[self micaDefaults] boolForKey:@"MicaDiagnosticsEnabled"] ? NSControlStateValueOn : NSControlStateValueOff;
    diagnostics.frame = NSMakeRect(122, 417, 280, 20);
    [content addSubview:diagnostics];
    NSButton *resumeAgents = [NSButton checkboxWithTitle:@"Resume agents when restoring windows" target:self action:@selector(prefResumeAgentsChanged:)];
    resumeAgents.tag = 112;
    resumeAgents.frame = NSMakeRect(122, 470, 320, 20);
    resumeAgents.state = [[self micaDefaults] boolForKey:@"MicaResumeAgentsOnRestore"] ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:resumeAgents];
    NSTextField *memoryWarningCaption = [NSTextField labelWithString:@"Agent memory warning"];
    memoryWarningCaption.alignment = NSTextAlignmentRight;
    memoryWarningCaption.frame = NSMakeRect(8, 442, 104, 18);
    [content addSubview:memoryWarningCaption];
    NSPopUpButton *memoryWarning = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(122, 437, 160, 26) pullsDown:NO];
    [memoryWarning addItemsWithTitles:@[@"Never", @"2 GB", @"4 GB", @"8 GB", @"16 GB"]];
    NSInteger warningGB = MicaAgentRSSWarningGB([self micaDefaults]);
    [memoryWarning selectItemAtIndex:warningGB == 0 ? 0 : warningGB == 2 ? 1 : warningGB == 4 ? 2 : warningGB == 8 ? 3 : 4];
    memoryWarning.tag = 114;
    memoryWarning.target = self; memoryWarning.action = @selector(prefAgentRSSWarningChanged:);
    [content addSubview:memoryWarning];
    content.wantsLayer = YES;
    content.layer.backgroundColor = settingsBackground.CGColor;
    NSArray<NSString *> *labels = @[@"Theme", @"Cursor", @"Text size"];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSTextField *caption = [NSTextField labelWithString:labels[i]];
        caption.alignment = NSTextAlignmentRight;
        caption.frame = NSMakeRect(20, 330 - 40 * i, 90, 18);
        [content addSubview:caption];
    }
    NSPopUpButton *theme = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(122, 325, 200, 26) pullsDown:NO];
    [theme addItemsWithTitles:@[@"Dark", @"Light", @"System"]];
    [theme selectItemAtIndex:gMicaFollowSystemTheme ? 2 : (gMicaLightTheme ? 1 : 0)];
    theme.tag = 102;
    theme.target = self; theme.action = @selector(prefThemeChanged:);
    [content addSubview:theme];
    NSPopUpButton *cursor = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(122, 285, 200, 26) pullsDown:NO];
    [cursor addItemsWithTitles:@[@"Block", @"Bar", @"Underline"]];
    [cursor selectItemAtIndex:gMicaCursorStyle];
    cursor.tag = 103;
    cursor.target = self; cursor.action = @selector(prefCursorChanged:);
    [content addSubview:cursor];
    NSTextField *sizeValue = [NSTextField labelWithString:@""];
    sizeValue.tag = 104;
    sizeValue.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    sizeValue.frame = NSMakeRect(122, 250, 44, 18);
    [content addSubview:sizeValue];
    NSStepper *stepper = [[NSStepper alloc] initWithFrame:NSMakeRect(168, 245, 19, 27)];
    stepper.minValue = 8; stepper.maxValue = 28; stepper.increment = 1;
    stepper.doubleValue = self.terminalView.terminalFont.pointSize;
    stepper.tag = 101;
    stepper.target = self; stepper.action = @selector(prefFontSizeChanged:);
    [content addSubview:stepper];
    NSTextField *sizeHint = [NSTextField labelWithString:@"Also ⌘+  ⌘−  ⌘0 in a terminal."];
    sizeHint.textColor = MicaSecondaryLabelColor(1.0);
    sizeHint.font = [NSFont systemFontOfSize:11];
    sizeHint.frame = NSMakeRect(122, 226, 320, 14);
    [content addSubview:sizeHint];
    NSTextField *scrollbackCaption = [NSTextField labelWithString:@"Scrollback"];
    scrollbackCaption.alignment = NSTextAlignmentRight;
    scrollbackCaption.frame = NSMakeRect(20, 194, 90, 18);
    [content addSubview:scrollbackCaption];
    NSPopUpButton *scrollback = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(122, 189, 200, 26) pullsDown:NO];
    [scrollback addItemsWithTitles:@[@"650 lines · about 5 MB", @"2,000 lines · about 16 MB", @"5,000 lines · about 40 MB", @"20,000 lines · about 160 MB"]];
    [scrollback selectItemAtIndex:[MicaAppDelegate scrollbackIndexForLines:[self storedScrollbackLines]]];
    scrollback.tag = 106;
    scrollback.frame = NSMakeRect(122, 189, 260, 26);
    scrollback.target = self; scrollback.action = @selector(prefScrollbackChanged:);
    [content addSubview:scrollback];
    NSButton *shortcut = [NSButton checkboxWithTitle:@"Show Mica with a global shortcut (⌃⌥Space)" target:self
                                              action:@selector(prefShortcutChanged:)];
    NSButton *menuBarTimer = [NSButton checkboxWithTitle:@"Show focus timer in the menu bar" target:self
                                                   action:@selector(prefMenuBarTimerChanged:)];
    menuBarTimer.frame = NSMakeRect(120, 84, 320, 20);
    menuBarTimer.tag = 109;
    menuBarTimer.state = [[self micaDefaults] boolForKey:@"MicaMenuBarTimer"] ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:menuBarTimer];
    NSButton *statusTimer = [NSButton checkboxWithTitle:@"Show timer in status bar" target:self action:@selector(prefStatusTimerChanged:)];
    statusTimer.frame = NSMakeRect(120, 36, 280, 20);
    statusTimer.tag = 110;
    statusTimer.state = (![[self micaDefaults] objectForKey:@"MicaShowStatusTimer"] || [[self micaDefaults] boolForKey:@"MicaShowStatusTimer"])
        ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:statusTimer];
    NSButton *vocabulary = [NSButton checkboxWithTitle:@"Improve dictation with project vocabulary" target:self action:@selector(prefVocabularyChanged:)];
    vocabulary.frame = NSMakeRect(120, 158, 330, 20);
    vocabulary.state = (![[self micaDefaults] objectForKey:@"MicaDictationVocabularyEnabled"] ||
        [[self micaDefaults] boolForKey:@"MicaDictationVocabularyEnabled"]) ? NSControlStateValueOn : NSControlStateValueOff;
    vocabulary.tag = 108; [content addSubview:vocabulary];
    NSButton *editVocabulary = [NSButton buttonWithTitle:@"Edit Vocabulary…" target:self action:@selector(editVocabulary:)];
    editVocabulary.frame = NSMakeRect(120, 128, 170, 24); [content addSubview:editVocabulary];
    shortcut.frame = NSMakeRect(120, 107, 320, 20);
    shortcut.tag = 105;
    shortcut.state = [[self micaDefaults] boolForKey:@"MicaGlobalShortcut"] ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:shortcut];
    NSTextField *dictationCaption = [NSTextField labelWithString:@"Dictation"];
    dictationCaption.alignment = NSTextAlignmentRight;
    dictationCaption.frame = NSMakeRect(20, 62, 90, 18);
    [content addSubview:dictationCaption];
    NSPopUpButton *dictationMode = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(122, 57, 200, 26) pullsDown:NO];
    [dictationMode addItemsWithTitles:@[@"Hold", @"Toggle"]];
    [dictationMode selectItemAtIndex:self.dictationToggleMode ? 1 : 0];
    dictationMode.tag = 107; dictationMode.target = self; dictationMode.action = @selector(prefDictationModeChanged:);
    [content addSubview:dictationMode];
    NSBox *rule = [[NSBox alloc] initWithFrame:NSMakeRect(20, 42, 420, 1)];
    rule.boxType = NSBoxSeparator;
    [content addSubview:rule];
    NSButton *project = [NSButton buttonWithTitle:@"Project Settings…" target:self action:@selector(openProjectSettings:)];
    project.frame = NSMakeRect(20, 28, 200, 30);
    project.enabled = self.projectLayoutPath.length > 0;
    NSButton *timer = [NSButton buttonWithTitle:@"Timer Settings…" target:self action:@selector(openPomodoroSettings:)];
    timer.frame = NSMakeRect(240, 28, 200, 30);
    [content addSubview:project];
    [content addSubview:timer];
    self.preferencesWindow = window;
    [self refreshPreferencesSizeLabel];
    [window center];
    [window makeKeyAndOrderFront:nil];
}


- (void)toggleLightTheme:(id)sender {
    (void)sender;
    BOOL light = !gMicaLightTheme;
    [self setLightTheme:light];
    if (!getenv("MICA_TEST_NO_STARTUP") || gMicaDefaultsOverride) [[self micaDefaults] setBool:light forKey:@"MicaLightTheme"];
}

- (void)installSessionSources { for (MicaTab *tab in self.tabs) [self installSourceForTab:tab]; }
- (void)installSourceForTab:(MicaTab *)tab {
    int fd = mica_session_fd(tab.session);
    if (fd < 0 || tab.ioSource) return;
    tab.ioSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(tab.ioSource, ^{
        MicaAppDelegate *self = weakSelf;
        if (!self || !tab.session) return;
        self.dispatchPollTab = tab;
        [self pollSessions:nil];
        self.dispatchPollTab = nil;
    });
    dispatch_source_set_cancel_handler(tab.ioSource, ^{});
    dispatch_resume(tab.ioSource);
}

- (void)restartPollTimerWithInterval:(NSTimeInterval)interval {
    if (self.pollTimer && fabs(self.pollTimer.timeInterval - interval) < 0.001) return;
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(pollSessions:) userInfo:nil repeats:YES];
    self.pollTimer.tolerance = interval / 3.0;
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)requestWorkingDirectoryForTab:(MicaTab *)tab {
    if (!tab.session || tab.cwdLookupPending) return;
    tab.cwdLookupPending = YES;
    pid_t pid = mica_session_pid(tab.session);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cwd = MicaWorkingDirectoryForPID(pid);
        dispatch_async(dispatch_get_main_queue(), ^{
            MicaAppDelegate *strongSelf = weakSelf;
            tab.cwdLookupPending = NO;
            if (!strongSelf || !cwd.length || !tab.session ||
                mica_session_pid(tab.session) != pid || [cwd isEqualToString:tab.cwd]) return;
            tab.cwd = cwd;
            [strongSelf refreshVocabularyForTab:tab];
            [strongSelf.terminalView setNeedsDisplayInRect:NSMakeRect(0, 0,
                strongSelf.terminalView.bounds.size.width, kStatusHeight)];
            [strongSelf.windowContentView.sidebarView refreshRows];
        });
    });
}

- (void)pollSessions:(NSTimer *)timer {
    (void)timer;
    BOOL redraw = NO;
    // Process footprint is useful only while its status-strip readout is visible.
    {
        NSTimeInterval nowForMemory = NSProcessInfo.processInfo.systemUptime;
        pid_t helperPID = [self.voiceController helperProcessIdentifier];
        BOOL statusVisible = self.window.isVisible && !self.terminalView.hidden && self.terminalView.window != nil;
        if (statusVisible && nowForMemory - self.memoryCheckedAt >= 2.0) {
            self.memoryCheckedAt = nowForMemory;
            uint64_t appBytes = MicaFootprintBytes(getpid()), helperBytes = MicaFootprintBytes(helperPID);
            NSString *label = MicaMemoryLabel(appBytes, helperBytes);
            if (helperPID)
                MicaDiagnosticsLog(@"memory", [NSString stringWithFormat:@"app=%.1f MB helper=%.1f MB total=%.1f MB",
                    appBytes / 1048576.0, helperBytes / 1048576.0, (appBytes + helperBytes) / 1048576.0]);
            if (![label isEqualToString:self.memoryLabel]) {
                self.memoryLabel = label;
                [self.terminalView setNeedsDisplayInRect:NSMakeRect(0, 0, self.terminalView.bounds.size.width, kStatusHeight)];
            }
        }
    }
    // Idle backoff: after ~5 s without output, poll at 50 ms instead of 15 ms.
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    MicaVoiceController *voice = self.voiceController;
    if (voice.state == MicaVoiceControllerStateListening && voice.transcript.length == 0 &&
        now - self.lastVoiceAnimationAt >= 0.10) {
        self.lastVoiceAnimationAt = now;
        [self.terminalView setNeedsDisplayInRect:[self.terminalView dictationPreviewRect]];
    }
    NSTimeInterval pollStartedAt = now;
    if (self.lastPollTimerTickAt > 0 && now - self.lastPollTimerTickAt >= 0.150 &&
        now - self.lastSlowPollLogAt >= 1.0) {
        MicaDiagnosticsLog(@"performance", [NSString stringWithFormat:
            @"poll-timer-gap duration_ms=%.1f tabs=%lu", (now - self.lastPollTimerTickAt) * 1000.0,
            (unsigned long)self.tabs.count]);
        self.lastSlowPollLogAt = now;
    }
    self.lastPollTimerTickAt = now;
    [self updatePomodoroTimer];
    BOOL activityScanPerformed = NO;
    for (MicaTab *tab in self.tabs) {
        if (self.dispatchPollTab && tab != self.dispatchPollTab) continue;
        if (!tab.session) continue;
        mica_session_poll(tab.session, 0);
        MicaSessionOutputMetrics outputMetrics = {0};
        BOOL receivedOutput = mica_session_take_output_metrics(tab.session, &outputMetrics);
        if (receivedOutput) tab.lastOutputReadAt = NSProcessInfo.processInfo.systemUptime;
        if (receivedOutput) {
            char *clipboardText = mica_session_take_clipboard_write(tab.session);
            if (clipboardText) {
                [self handleClipboardWrite:[NSString stringWithUTF8String:clipboardText] fromTab:tab];
                free(clipboardText);
            }
        }
        MicaDirtyRows dirtyRows = {0};
        // Hold repaints while a program is mid-frame (mode 2026); the rows stay queued until it finishes.
        BOOL syncHeld = mica_session_sync_output_active(tab.session);
        BOOL hasDirtyRows = syncHeld ? NO : mica_session_take_dirty_rows(tab.session, &dirtyRows);
        if (syncHeld) tab.syncHeld = YES;
        else if (tab.syncHeld) {
            // The frame ended (or timed out) without a revision change; repaint whatever was held back.
            tab.syncHeld = NO;
            if (tab == self.activeTab) [self.terminalView setNeedsDisplay:YES];
        }
        if (tab == self.activeTab && tab.pendingClipboardText.length && tab.clipboardDecision == 0 && !self.clipboardPromptShowing)
            [self handleClipboardWrite:tab.pendingClipboardText fromTab:tab];
        const char *rawTitle = mica_session_title(tab.session);
        NSString *terminalTitle = rawTitle[0]
            ? [[NSString alloc] initWithBytes:rawTitle length:strlen(rawTitle) encoding:NSUTF8StringEncoding]
            : nil;
        if (MicaStringChanged(terminalTitle, tab.terminalTitle)) {
            tab.terminalTitle = terminalTitle;
            [self requestWorkingDirectoryForTab:tab];
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
            // Command start/finish is a rare transition, not a per-tick cost. The shell's preexec runs before
            // the program execs, so look again shortly after to see the real process tree.
            [self refreshProcessAgentForTab:tab];
            if (currentCommand.length) {
                __weak MicaAppDelegate *weakSelf = self;
                __weak MicaTab *weakTab = tab;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (weakSelf && weakTab) [weakSelf refreshProcessAgentForTab:weakTab];
                });
            }
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
            char *agentWords = mica_session_take_notification(tab.session);
            if (tab != self.activeTab || !NSApp.isActive) {
                tab.needsAttention = YES;
                if (!NSApp.isActive && self.attentionRequest == 0)
                    self.attentionRequest = [NSApp requestUserAttention:NSInformationalRequest];
                // Away from Mica: say what the program asked, and bring you back to that tab when clicked.
                if (agentWords && !NSApp.isActive) {
                    NSString *detail = nil;
                    NSString *activity = MicaAgentActivityForSession(tab.session, &detail);
                    BOOL waitingPermission = [MicaAgentStateForTab(tab) isEqualToString:@"waitingPermission"] ||
                        [activity isEqualToString:@"Needs permission"];
                    BOOL waitingInput = [MicaAgentStateForTab(tab) isEqualToString:@"waitingInput"] ||
                        [activity isEqualToString:@"Needs input"];
                    BOOL waiting = waitingPermission || waitingInput;
                    NSString *title = waiting ? [self agentNotificationTitleForTab:tab waiting:YES] :
                        [NSString stringWithFormat:@"%@ update", MicaAgentNameForTab(tab) ?: @"Agent"];
                    MicaAttentionKind kind = waitingPermission ? MicaAttentionWaitingPermission :
                        (waitingInput ? MicaAttentionWaitingInput : MicaAttentionError);
                    [MicaAttention() setMuted:tab.muteNotifications tabID:tab.identifier];
                    [MicaAttention() postTabID:tab.identifier kind:kind title:title
                        body:[NSString stringWithUTF8String:agentWords] muted:NO];
                    NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
                }
                redraw = YES;
            }
            free(agentWords);
        }
        uint64_t completionCount = mica_session_command_completion_count(tab.session);
        if (completionCount != tab.cwdLookupCompletionCount) {
            tab.cwdLookupCompletionCount = completionCount;
            [self requestWorkingDirectoryForTab:tab];
        }
        if (tab.tracksCompletion && completionCount > tab.commandCompletionCount) {
            tab.commandCompletionCount = completionCount;
            tab.tracksCompletion = NO;
            tab.completedCommand = YES;
            tab.completionStatus = mica_session_command_exit_status(tab.session);
            if (tab != self.activeTab || !NSApp.isActive) {
                tab.needsAttention = YES;
                NSString *label = tab.completionLabel.length ? tab.completionLabel : @"Command";
                NSString *result = tab.completionStatus == 0 ? @"finished" : [NSString stringWithFormat:@"failed (%d)", tab.completionStatus];
                [MicaAttention() setMuted:tab.muteNotifications tabID:tab.identifier];
                [MicaAttention() postTabID:tab.identifier kind:MicaAttentionDone
                    title:[self agentNotificationTitleForTab:tab waiting:NO]
                    body:[NSString stringWithFormat:@"%@ %@", label, result] muted:NO];
                NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
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
            BOOL typedAgentCommand = MicaAgentNameForText(currentCommand) != nil || MicaAgentNameForText(tab.command) != nil;
            if (!tab.receivedAgentHook && (tab.processAgentKind.length || typedAgentCommand) &&
                !activityScanPerformed && now - tab.lastActivityScanAt >= 0.50) {
                tab.lastActivityScanAt = now;
                activityScanPerformed = YES;
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
    NSMutableArray<MicaTab *> *exitedTabs = [NSMutableArray array];
    for (MicaTab *tab in self.tabs)
        if (tab.session && !mica_session_is_running(tab.session)) [exitedTabs addObject:tab];
    for (MicaTab *tab in exitedTabs) {
        NSUInteger index = [self.tabs indexOfObjectIdenticalTo:tab];
        if (index == NSNotFound) continue;
        MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"session exited status=%d",
            mica_session_exit_status(tab.session)]);
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
    // Reduce Motion: keep the activity indicator still (it still changes state and colour, it just stops spinning).
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) animatesTab = NO;
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
    [self.windowContentView.sidebarView refreshRows];
    if (redraw) [self.terminalView setNeedsDisplay:YES];
    NSTimeInterval pollEndedAt = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval pollDuration = pollEndedAt - pollStartedAt;
    if (pollDuration >= 0.075 && pollEndedAt - self.lastSlowPollLogAt >= 1.0) {
        self.lastSlowPollLogAt = pollEndedAt;
        MicaDiagnosticsLog(@"performance", [NSString stringWithFormat:
            @"slow-session-poll duration_ms=%.1f tabs=%lu active_pid=%d",
            pollDuration * 1000.0, (unsigned long)self.tabs.count,
            self.activeTab.session ? mica_session_pid(self.activeTab.session) : -1]);
    }
    // Time based UI work shares one window timer, and sleeps when no visible
    // countdown, animation, or dictation indicator needs another frame.
    BOOL hasCommandClock = NO;
    for (MicaTab *tab in self.tabs) if (tab.currentCommand.length) { hasCommandClock = YES; break; }
    BOOL needsTimer = animatesTab || hasCommandClock ||
        mica_pomodoro_is_running(&_pomodoro) ||
        (self.voiceController.state == MicaVoiceControllerStateListening && self.voiceController.transcript.length == 0) ||
        (self.window.isVisible && !self.terminalView.hidden && self.terminalView.window != nil);
    BOOL oneSecondTimer = hasCommandClock || mica_pomodoro_is_running(&_pomodoro) ||
        (self.voiceController.state == MicaVoiceControllerStateListening && self.voiceController.transcript.length == 0);
    if (needsTimer) [self restartPollTimerWithInterval:animatesTab ? 0.12 : oneSecondTimer ? 1.0 : 2.0];
    else if (!needsTimer && self.pollTimer) { [self.pollTimer invalidate]; self.pollTimer = nil; }
}

- (BOOL)confirmEndingRunningCommandsFor:(NSString *)action {
    if (getenv("MICA_TEST_NO_STARTUP")) return YES;
    NSMutableArray<NSString *> *running = [NSMutableArray array];
    // Closing a window asks about its own tabs; quitting asks about every window in the process.
    NSArray<MicaAppDelegate *> *scope = ([action hasPrefix:@"Quit"] && MicaControllers().count) ? [MicaControllers() copy] : @[self];
    for (MicaAppDelegate *controller in scope) {
        for (MicaTab *tab in controller.tabs) {
            // An exited shell can leave a stale command label behind; only live sessions count.
            if (!tab.currentCommand.length || !tab.session || !mica_session_is_running(tab.session)) continue;
            [running addObject:tab.currentCommand.lastPathComponent.length
                ? tab.currentCommand.lastPathComponent : tab.currentCommand];
        }
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
    [self saveSessionState];
    self.terminationCleanupStarted = YES;
    MicaDiagnosticsLog(@"app", @"application termination requested");
    NSMutableArray<NSValue *> *sessions = [NSMutableArray array];
    NSArray<MicaAppDelegate *> *windows = MicaControllers().count ? [MicaControllers() copy] : @[self];
    for (MicaAppDelegate *controller in windows) [sessions addObjectsFromArray:[controller detachSessionsForTermination]];
    MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"queued all sessions count=%lu",
        (unsigned long)sessions.count]);
    if (!self.terminationCleanupGroup) self.terminationCleanupGroup = dispatch_group_create();
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
    // The C teardown bounds its child waits. Wait for every cleanup, including
    // windows closed just before Quit, rather than abandoning their descendants.
    return NSTerminateLater;
}
// Stops this window's timers and voice controller and hands back its sessions for destruction.
- (NSArray<NSValue *> *)detachSessionsForTermination {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.voiceController cancel];
    NSMutableArray<NSValue *> *sessions = [NSMutableArray arrayWithCapacity:self.tabs.count];
    for (MicaTab *tab in self.tabs) {
        if (!tab.session) continue;
        MicaDiagnosticsLog(@"pty", [NSString stringWithFormat:@"queued session cleanup pid=%d",
            mica_session_pid(tab.session)]);
        [sessions addObject:[NSValue valueWithPointer:tab.session]];
        tab.session = NULL;
    }
    return sessions;
}

// A window closed while others stay open: release its shells and timers now.
- (void)teardownWindow {
    for (MicaTab *tab in self.tabs) [MicaAttention() clearTabID:tab.identifier];
    NSApp.dockTile.badgeLabel = MicaAttention().dockBadge;
    NSArray<NSValue *> *sessions = [self detachSessionsForTermination];
    self.window.delegate = nil;
    [self.terminalView setOwner:nil];
    MicaAppDelegate *applicationController = [NSApp.delegate isKindOfClass:MicaAppDelegate.class]
        ? (MicaAppDelegate *)NSApp.delegate : self;
    if (!applicationController.terminationCleanupGroup)
        applicationController.terminationCleanupGroup = dispatch_group_create();
    dispatch_group_t cleanupGroup = applicationController.terminationCleanupGroup;
    dispatch_group_enter(cleanupGroup);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            for (NSValue *value in sessions) mica_session_destroy(value.pointerValue);
        }
        dispatch_group_leave(cleanupGroup);
    });
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (self.observesSystemAppearance) {
        [NSApp removeObserver:self forKeyPath:@"effectiveAppearance"];
        self.observesSystemAppearance = NO;
    }
    NSMutableArray<MicaAppDelegate *> *controllers = MicaControllers();
    if (![controllers containsObject:self] || controllers.count <= 1) return;   // last window: quitting cleans up
    if (self == controllers.firstObject) {
        [self.agentRSSTimer invalidate]; self.agentRSSTimer = nil;
        self.agentRSSMonitor = nil;
    }
    [self teardownWindow];
    [controllers removeObject:self];
    if (controllers.firstObject) {
        [controllers.firstObject refreshPomodoroState];
        [controllers.firstObject updateAgentRSSTimer];
    }
    [self saveSessionState];
    for (MicaAppDelegate *other in controllers) if (other.window) { [other takeMenuOwnership]; break; }
    MicaDiagnosticsLog(@"launch", [NSString stringWithFormat:@"closed a window (windows left=%lu)", (unsigned long)controllers.count]);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self saveSessionState];
    MicaDiagnosticsLog(@"app", @"application is terminating");
    [MicaHookServer.sharedServer stop];
    unsetenv("MICA_HOOK_SOCK");
}
- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    for (MicaAppDelegate *controller in MicaControllers().count ? [MicaControllers() copy] : @[self]) {
        [controller.terminalView cancelLeftOptionTracking];
        MicaTab *tab = controller.activeTab;
        if (tab.session) mica_session_focus(tab.session, false);
    }
}
- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    for (MicaAppDelegate *controller in MicaControllers().count ? [MicaControllers() copy] : @[self]) {
        if (controller.attentionRequest != 0) {
            [NSApp cancelUserAttentionRequest:controller.attentionRequest];
            controller.attentionRequest = 0;
        }
        // Only the key window's shell reports focus; the others stay "unfocused" until they are selected.
        MicaTab *tab = controller.activeTab;
        if (tab.session && (controller.window.isKeyWindow || MicaControllers().count <= 1)) mica_session_focus(tab.session, true);
        if (controller.window.isKeyWindow || MicaControllers().count <= 1) tab.needsAttention = NO;
        [controller.terminalView setNeedsDisplay:YES];
    }
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    [self takeMenuOwnership];
    [self refreshProcessAgentForTab:self.activeTab];
    [self updateWindowTitle];   // the Dock icon follows the key window's project
    [self.terminalView setNeedsDisplay:YES];
    [self pollSessions:nil];    // resume visible status readouts and time-based UI work
}

- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification;
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
        // A dead speech helper must surface as a write error, not kill every terminal with SIGPIPE.
signal(SIGPIPE, SIG_IGN);
NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        MicaAppDelegate *delegate = [[MicaAppDelegate alloc] init];
        app.delegate = delegate;
        MicaDiagnosticsSetEnabled([[delegate micaDefaults] boolForKey:@"MicaDiagnosticsEnabled"]);
        MicaDiagnosticsLog(@"startup", [NSString stringWithFormat:@"Mica %@ revision %@ launching pid=%d parent_pid=%d bundle=%@",
            @MICA_VERSION, @MICA_REVISION, getpid(), getppid(), NSBundle.mainBundle.bundleIdentifier ?: @"unknown"]);
        [app run];
    }
    return 0;
}
#endif
