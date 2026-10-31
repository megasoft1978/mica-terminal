#import "mica_focus_band.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); exit(1); } } while (0)

@interface FBDelegate : NSObject <MicaFocusBandDelegate>
@property int start, pause, skip, reset;
@property(copy) NSString *edited;
@end
@implementation FBDelegate
- (void)focusBandStart:(MicaFocusBandView *)b { self.start++; }
- (void)focusBandTogglePause:(MicaFocusBandView *)b { self.pause++; }
- (void)focusBandSkip:(MicaFocusBandView *)b { self.skip++; }
- (void)focusBandReset:(MicaFocusBandView *)b { self.reset++; }
- (void)focusBand:(MicaFocusBandView *)b didEditLabel:(NSString *)l { self.edited = l; }
@end

static MicaFocusBandState *State(MicaPomodoroPhase phase, double remaining, double total, NSString *label) {
    MicaFocusBandState *s = [MicaFocusBandState new];
    s.phase = phase; s.remainingSeconds = remaining; s.totalSeconds = total; s.label = label;
    s.completedToday = 3; s.goalToday = 4; s.todayTotalSeconds = 9600; s.startHint = @"⌥⌘P";
    s.projectRows = @[
        @{@"project": @"csc", @"branch": @"main", @"seconds": @3900, @"sessions": @2},
        @{@"project": @"mica", @"seconds": @5700, @"sessions": @1}];
    return s;
}

static MicaFocusBandView *Band(CGFloat width, MicaFocusBandState *s) {
    MicaFocusBandView *v = [[MicaFocusBandView alloc] initWithFrame:NSMakeRect(0, 0, width, [MicaFocusBandView heightForPhase:s.phase])];
    [v applyState:s palette:[MicaFocusBandPalette darkPalette]];
    [v layoutSubtreeIfNeeded];
    return v;
}

static void CheckNoOverlap(MicaFocusBandView *v) {
    NSMutableArray *visible = [NSMutableArray array];
    for (NSView *sub in v.subviews) if (!sub.hidden) [visible addObject:sub];
    for (NSView *sub in visible) {
        CHECK(NSMinX(sub.frame) >= 0 && NSMaxX(sub.frame) <= v.bounds.size.width + 0.01);
        CHECK(NSMinY(sub.frame) >= 0 && NSMaxY(sub.frame) <= v.bounds.size.height + 0.01);
    }
    for (NSUInteger i = 0; i < visible.count; i++)
        for (NSUInteger j = i + 1; j < visible.count; j++) {
            NSRect a = [visible[i] frame], b = [visible[j] frame];
            CHECK(NSIsEmptyRect(NSIntersectionRect(a, b)));
        }
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *longLabel = @"csc · main — CSC-133 fix the very long label that cannot possibly fit in a narrow window";

        CHECK([MicaFocusBandView heightForPhase:MICA_POMODORO_IDLE] == 24);
        CHECK([MicaFocusBandView heightForPhase:MICA_POMODORO_FOCUS] == 52);
        CHECK([MicaFocusBandView heightForPhase:MICA_POMODORO_BREAK] == 52);
        CHECK([MicaFocusBandView heightForPhase:MICA_POMODORO_PAUSED_FOCUS] == 52);

        CHECK([[MicaFocusBandView formatCountdown:2538] isEqualToString:@"42:18"]);
        CHECK([[MicaFocusBandView formatCountdown:0] isEqualToString:@"00:00"]);
        CHECK([[MicaFocusBandView formatCountdown:59.2] isEqualToString:@"01:00"]);
        CHECK([[MicaFocusBandView formatCountdown:3600] isEqualToString:@"1:00:00"]);
        CHECK([[MicaFocusBandView formatCountdown:3725] isEqualToString:@"1:02:05"]);
        CHECK([[MicaFocusBandView formatDuration:3900] isEqualToString:@"1h 05m"]);
        CHECK([[MicaFocusBandView formatDuration:2520] isEqualToString:@"42m"]);

        // Layout at both widths, active and idle, no overlap; label truncates when narrow.
        MicaPomodoroPhase phases[] = {MICA_POMODORO_IDLE, MICA_POMODORO_FOCUS, MICA_POMODORO_BREAK, MICA_POMODORO_PAUSED_FOCUS};
        for (int i = 0; i < 4; i++)
            for (NSNumber *w in @[@480, @2000, @360]) {
                MicaFocusBandView *v = Band(w.doubleValue, State(phases[i], 2538, 3000, longLabel));
                CheckNoOverlap(v);
            }
        MicaFocusBandView *narrow = Band(480, State(MICA_POMODORO_FOCUS, 2538, 3000, longLabel));
        MicaFocusBandView *wide = Band(2000, State(MICA_POMODORO_FOCUS, 2538, 3000, longLabel));
        CHECK(!narrow.todayButton.hidden);
        CGFloat labelNeeded = ceil([narrow.labelField.attributedStringValue size].width);
        CHECK(narrow.labelField.frame.size.width < labelNeeded);
        CHECK(narrow.labelField.lineBreakMode == NSLineBreakByTruncatingTail);
        CHECK([narrow.labelField.toolTip isEqualToString:longLabel]);
        CHECK(wide.labelField.frame.size.width > narrow.labelField.frame.size.width);
        CHECK(NSMaxX(wide.labelField.frame) < NSMinX(wide.todayButton.frame));
        MicaFocusBandView *tiny = Band(360, State(MICA_POMODORO_FOCUS, 2538, 3000, longLabel));
        CHECK(tiny.todayButton.hidden);

        // Texts and progress.
        MicaFocusBandView *v = Band(800, State(MICA_POMODORO_FOCUS, 2538, 3000, @"csc · main"));
        CHECK([v.countdownField.stringValue isEqualToString:@"42:18"]);
        CHECK([v.phaseField.stringValue containsString:@"FOCUS"]);
        CHECK([v.todayButton.attributedTitle.string isEqualToString:@"3/4 today"]);
        CHECK(fabs(v.progressFraction - (1 - 2538.0 / 3000)) < 1e-9);
        CHECK([v.pauseButton.toolTip isEqualToString:@"Pause"]);
        MicaFocusBandState *brk = State(MICA_POMODORO_BREAK, 300, 300, @"");
        [v applyState:brk palette:[MicaFocusBandPalette darkPalette]];
        CHECK([v.phaseField.stringValue containsString:@"BREAK"]);
        CHECK(v.progressFraction == 0);
        MicaFocusBandState *h = State(MICA_POMODORO_FOCUS, 4000, 4000, @"x");
        h.remainingSeconds = 3725;
        [v applyState:h palette:[MicaFocusBandPalette darkPalette]];
        CHECK([v.countdownField.stringValue isEqualToString:@"1:02:05"]);

        // Cheap per-second update: no relayout when only the countdown changes.
        MicaFocusBandState *tick = State(MICA_POMODORO_FOCUS, 2538, 3000, @"csc · main");
        [v applyState:tick palette:[MicaFocusBandPalette darkPalette]];
        [v layoutSubtreeIfNeeded];
        tick.remainingSeconds = 2537;
        [v applyState:tick palette:[MicaFocusBandPalette darkPalette]];
        CHECK(!v.needsLayout);
        CHECK([v.countdownField.stringValue isEqualToString:@"42:17"]);

        // Paused shows Resume and PAUSED.
        MicaFocusBandView *p = Band(800, State(MICA_POMODORO_PAUSED_FOCUS, 1000, 3000, @"a"));
        CHECK([p.phaseField.stringValue containsString:@"PAUSED"]);
        CHECK([p.pauseButton.toolTip isEqualToString:@"Resume"]);
        CHECK([p.pauseButton.accessibilityLabel isEqualToString:@"Resume"]);

        // Delegate actions.
        FBDelegate *d = [FBDelegate new];
        v.delegate = d;
        [v applyState:State(MICA_POMODORO_FOCUS, 2538, 3000, @"csc · main") palette:[MicaFocusBandPalette darkPalette]];
        [v.pauseButton performClick:nil]; [v.skipButton performClick:nil]; [v.resetButton performClick:nil];
        CHECK(d.pause == 1 && d.skip == 1 && d.reset == 1 && d.start == 0);
        CHECK([v.skipButton.accessibilityLabel isEqualToString:@"Skip"]);
        CHECK([v.resetButton.accessibilityLabel isEqualToString:@"Reset"]);
        MicaFocusBandView *idle = Band(800, State(MICA_POMODORO_IDLE, 0, 0, @""));
        idle.delegate = d;
        [idle.startButton performClick:nil];
        CHECK(d.start == 1);
        CHECK(!idle.startButton.hidden && idle.pauseButton.hidden && idle.countdownField.hidden);
        CHECK([idle.hintField.stringValue isEqualToString:@"⌥⌘P"]);
        CHECK([idle.todayButton.attributedTitle.string isEqualToString:@"Today 2h 40m"]);
        MicaFocusBandState *none = State(MICA_POMODORO_IDLE, 0, 0, @"");
        none.todayTotalSeconds = 0;
        [idle applyState:none palette:[MicaFocusBandPalette darkPalette]];
        [idle layoutSubtreeIfNeeded];
        CHECK(idle.todayButton.hidden);

        // Label edit commits via delegate; unchanged value does not.
        v.labelField.stringValue = @"  new label ";
        [NSNotificationCenter.defaultCenter postNotificationName:NSControlTextDidEndEditingNotification object:v.labelField];
        CHECK([d.edited isEqualToString:@"new label"]);
        d.edited = nil;
        v.labelField.stringValue = @"csc · main";
        [NSNotificationCenter.defaultCenter postNotificationName:NSControlTextDidEndEditingNotification object:v.labelField];
        CHECK(d.edited == nil);

        // Accessibility.
        MicaFocusBandView *a = Band(800, State(MICA_POMODORO_FOCUS, 2538, 3000, @"csc · main"));
        CHECK(a.isAccessibilityElement);
        CHECK([a.accessibilityRole isEqualToString:NSAccessibilityGroupRole]);
        CHECK([a.accessibilityLabel isEqualToString:@"Focus timer, FOCUS, 42 minutes 18 seconds remaining, csc · main, 3 of 4 today"]);
        MicaFocusBandView *a2 = Band(800, State(MICA_POMODORO_PAUSED_BREAK, 3601, 3601, @""));
        CHECK([a2.accessibilityLabel isEqualToString:@"Focus timer, PAUSED, 1 hour 0 minutes 1 second remaining, 3 of 4 today"]);
        CHECK([Band(800, State(MICA_POMODORO_IDLE, 0, 0, @"")).accessibilityLabel hasPrefix:@"Focus timer, idle"]);

        // Today button label: idle wins even without a goal; non-idle branches are exclusive.
        MicaFocusBandState *idleNoGoal = State(MICA_POMODORO_IDLE, 0, 0, @"");
        idleNoGoal.goalToday = 0; idleNoGoal.todayTotalSeconds = 9600;
        MicaFocusBandView *ig = Band(800, idleNoGoal);
        CHECK([ig.todayButton.accessibilityLabel isEqualToString:@"Today's total focus time"]);
        MicaFocusBandState *focusNoGoal = State(MICA_POMODORO_FOCUS, 2538, 3000, @"csc · main");
        focusNoGoal.goalToday = 0;
        CHECK([Band(800, focusNoGoal).todayButton.accessibilityLabel isEqualToString:@"3 focus sessions today"]);
        CHECK([Band(800, State(MICA_POMODORO_FOCUS, 2538, 3000, @"csc · main")).todayButton.accessibilityLabel isEqualToString:@"3 of 4 focus sessions today"]);

        // Popover rows and empty state.
        NSArray *rows = [a popoverRowsForTesting];
        CHECK(rows.count == 3);
        CHECK([rows[0] isEqualToArray:(@[@"csc · main", @"1h 05m", @"2 sessions"])]);
        CHECK([rows[1] isEqualToArray:(@[@"mica", @"1h 35m", @"1 session"])]);
        CHECK([rows[2] isEqualToArray:(@[@"Total", @"2h 40m", @"3 sessions"])]);
        CHECK([a popoverContentViewForTesting].subviews.count > 0);
        MicaFocusBandState *e = State(MICA_POMODORO_FOCUS, 100, 3000, @"");
        e.projectRows = @[];
        MicaFocusBandView *ev = Band(800, e);
        CHECK([[ev popoverRowsForTesting] isEqualToArray:@[@[@"No focus sessions yet today"]]]);
        CHECK([ev popoverContentViewForTesting].subviews.count > 0);

        puts("focus band tests passed");
    }
    return 0;
}
