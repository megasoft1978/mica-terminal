#import "mica_focus_band.h"
#include <math.h>

@implementation MicaFocusBandState @end

@implementation MicaFocusBandPalette
+ (instancetype)darkPalette {
    MicaFocusBandPalette *p = [MicaFocusBandPalette new];
    p.background = [NSColor colorWithSRGBRed:0.105 green:0.108 blue:0.115 alpha:1];
    p.foreground = [NSColor colorWithWhite:0.93 alpha:1];
    p.secondary = [NSColor colorWithWhite:0.66 alpha:1];
    p.separator = [NSColor colorWithWhite:1 alpha:0.10];
    p.focusColor = [NSColor colorWithSRGBRed:1.0 green:0.45 blue:0.38 alpha:1];
    p.breakColor = [NSColor colorWithSRGBRed:0.40 green:0.82 blue:0.55 alpha:1];
    p.pausedColor = [NSColor colorWithWhite:0.60 alpha:1];
    p.trackColor = [NSColor colorWithWhite:1 alpha:0.10];
    return p;
}
+ (instancetype)lightPalette {
    MicaFocusBandPalette *p = [MicaFocusBandPalette new];
    p.background = [NSColor colorWithSRGBRed:0.945 green:0.948 blue:0.955 alpha:1];
    p.foreground = [NSColor colorWithWhite:0.10 alpha:1];
    p.secondary = [NSColor colorWithWhite:0.38 alpha:1];
    p.separator = [NSColor colorWithWhite:0 alpha:0.12];
    p.focusColor = [NSColor colorWithSRGBRed:0.80 green:0.22 blue:0.17 alpha:1];
    p.breakColor = [NSColor colorWithSRGBRed:0.08 green:0.50 blue:0.27 alpha:1];
    p.pausedColor = [NSColor colorWithWhite:0.42 alpha:1];
    p.trackColor = [NSColor colorWithWhite:0 alpha:0.10];
    return p;
}
@end

static const CGFloat kIdleHeight = 24, kActiveHeight = 52, kPad = 12, kButton = 26;
static const CGFloat kLabelMinimum = 90;

static BOOL MicaPhaseIsPaused(MicaPomodoroPhase p) {
    return p == MICA_POMODORO_PAUSED_FOCUS || p == MICA_POMODORO_PAUSED_BREAK;
}

static NSTextField *MicaBandField(NSFont *font) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.bezeled = NO; f.bordered = NO; f.drawsBackground = NO; f.editable = NO; f.selectable = NO;
    f.font = font;
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    f.usesSingleLineMode = YES;
    f.focusRingType = NSFocusRingTypeNone;
    return f;
}

@interface MicaFocusFlippedView : NSView @end
@implementation MicaFocusFlippedView - (BOOL)isFlipped { return YES; } @end

@interface MicaFocusBandView () <NSTextFieldDelegate>
@end

@implementation MicaFocusBandView {
    MicaFocusBandState *_state;
    MicaFocusBandPalette *_palette;
    NSString *_signature;
    NSTextField *_phaseField, *_countdownField, *_labelField, *_hintField;
    NSButton *_pauseButton, *_skipButton, *_resetButton, *_todayButton, *_startButton;
    NSPopover *_popover;
    double _progress;
}

@synthesize phaseField = _phaseField, countdownField = _countdownField, labelField = _labelField,
    hintField = _hintField, pauseButton = _pauseButton, skipButton = _skipButton,
    resetButton = _resetButton, todayButton = _todayButton, startButton = _startButton;

+ (CGFloat)heightForPhase:(MicaPomodoroPhase)phase {
    return phase == MICA_POMODORO_IDLE ? kIdleHeight : kActiveHeight;
}

+ (NSString *)formatCountdown:(double)seconds {
    long total = seconds <= 0 ? 0 : (long)ceil(seconds - 1e-9);
    if (total >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60];
    return [NSString stringWithFormat:@"%02ld:%02ld", total / 60, total % 60];
}

+ (NSString *)formatDuration:(double)seconds {
    long minutes = seconds <= 0 ? 0 : lround(seconds / 60.0);
    if (minutes >= 60) return [NSString stringWithFormat:@"%ldh %02ldm", minutes / 60, minutes % 60];
    return [NSString stringWithFormat:@"%ldm", minutes];
}

- (BOOL)isFlipped { return YES; }

- (NSButton *)symbolButton:(NSString *)symbol action:(SEL)action {
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, kButton, kButton)];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
    b.target = self; b.action = action;
    b.focusRingType = NSFocusRingTypeNone;
    return b;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityGroupRole;
    _phaseField = MicaBandField([NSFont systemFontOfSize:10.5 weight:NSFontWeightBold]);
    _countdownField = MicaBandField([NSFont monospacedDigitSystemFontOfSize:24 weight:NSFontWeightSemibold]);
    _labelField = MicaBandField([NSFont systemFontOfSize:12.5]);
    _labelField.editable = YES; _labelField.selectable = YES;
    _labelField.delegate = self;
    _labelField.placeholderString = @"Add a label";
    _hintField = MicaBandField([NSFont systemFontOfSize:11.5]);
    _pauseButton = [self symbolButton:@"pause.fill" action:@selector(pressedPause:)];
    _skipButton = [self symbolButton:@"forward.end.fill" action:@selector(pressedSkip:)];
    _resetButton = [self symbolButton:@"arrow.counterclockwise" action:@selector(pressedReset:)];
    _skipButton.toolTip = @"Skip to next phase"; _skipButton.accessibilityLabel = @"Skip";
    _resetButton.toolTip = @"Reset timer"; _resetButton.accessibilityLabel = @"Reset";
    _todayButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _todayButton.bordered = NO; _todayButton.target = self; _todayButton.action = @selector(pressedToday:);
    _todayButton.focusRingType = NSFocusRingTypeNone;
    _todayButton.toolTip = @"Today's focus time by project";
    _todayButton.accessibilityLabel = @"Today's focus sessions";
    _startButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _startButton.bordered = NO; _startButton.target = self; _startButton.action = @selector(pressedStart:);
    _startButton.focusRingType = NSFocusRingTypeNone;
    _startButton.wantsLayer = YES; _startButton.layer.cornerRadius = 9;
    _startButton.toolTip = @"Start a focus session"; _startButton.accessibilityLabel = @"Start focus";
    for (NSView *v in @[_phaseField, _countdownField, _labelField, _hintField, _pauseButton, _skipButton,
                        _resetButton, _todayButton, _startButton]) [self addSubview:v];
    return self;
}

- (double)progressFraction { return _progress; }

#pragma mark State

static BOOL MicaColorsEqual(NSColor *a, NSColor *b) { return a == b || [a isEqual:b]; }

- (BOOL)palette:(MicaFocusBandPalette *)a equals:(MicaFocusBandPalette *)b {
    if (a == b) return YES;
    return a && b && MicaColorsEqual(a.background, b.background) && MicaColorsEqual(a.foreground, b.foreground) &&
        MicaColorsEqual(a.secondary, b.secondary) && MicaColorsEqual(a.separator, b.separator) &&
        MicaColorsEqual(a.focusColor, b.focusColor) && MicaColorsEqual(a.breakColor, b.breakColor) &&
        MicaColorsEqual(a.pausedColor, b.pausedColor) && MicaColorsEqual(a.trackColor, b.trackColor);
}

- (NSColor *)phaseColor {
    MicaPomodoroPhase p = _state.phase;
    if (MicaPhaseIsPaused(p)) return _palette.pausedColor;
    return p == MICA_POMODORO_BREAK ? _palette.breakColor : _palette.focusColor;
}

- (NSString *)phaseName {
    MicaPomodoroPhase p = _state.phase;
    if (MicaPhaseIsPaused(p)) return @"PAUSED";
    return p == MICA_POMODORO_BREAK ? @"BREAK" : @"FOCUS";
}

- (NSString *)todayTitle {
    MicaFocusBandState *s = _state;
    if (s.phase == MICA_POMODORO_IDLE)
        return s.todayTotalSeconds >= 1 ? [NSString stringWithFormat:@"Today %@", [MicaFocusBandView formatDuration:s.todayTotalSeconds]] : @"";
    if (s.goalToday > 0) return [NSString stringWithFormat:@"%ld/%ld today", (long)s.completedToday, (long)s.goalToday];
    return [NSString stringWithFormat:@"%ld today", (long)s.completedToday];
}

- (void)applyState:(MicaFocusBandState *)s palette:(MicaFocusBandPalette *)p {
    if (!s || !p) return;
    BOOL paletteChanged = ![self palette:_palette equals:p];
    _state = s; _palette = p;
    NSString *label = s.label ?: @"";
    NSString *hint = s.startHint ?: @"";
    NSString *signature = [NSString stringWithFormat:@"%d|%@|%@|%ld|%ld|%d|%d", (int)s.phase, label, hint,
        (long)s.completedToday, (long)s.goalToday, (int)llround(s.todayTotalSeconds / 60.0), (int)s.projectRows.count];
    BOOL structural = ![signature isEqualToString:_signature];
    _signature = signature;

    double total = s.totalSeconds;
    double fraction = total > 0 ? 1.0 - s.remainingSeconds / total : 0;
    _progress = MAX(0, MIN(1, fraction));
    NSString *countdown = [MicaFocusBandView formatCountdown:s.remainingSeconds];
    if (![_countdownField.stringValue isEqualToString:countdown]) _countdownField.stringValue = countdown;

    if (structural || paletteChanged) [self applyStructure:paletteChanged];
    [self updateAccessibility];
    [self setNeedsDisplayInRect:[self progressTrackRect]];
}

- (void)applyStructure:(BOOL)paletteChanged {
    MicaFocusBandState *s = _state; MicaFocusBandPalette *p = _palette;
    BOOL idle = s.phase == MICA_POMODORO_IDLE;
    BOOL paused = MicaPhaseIsPaused(s.phase);
    NSColor *accent = [self phaseColor];

    for (NSView *v in @[_phaseField, _countdownField, _labelField, _pauseButton, _skipButton, _resetButton])
        v.hidden = idle;
    _startButton.hidden = !idle; _hintField.hidden = !idle || !s.startHint.length;

    NSString *today = [self todayTitle];
    NSFont *todayFont = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    _todayButton.attributedTitle = [[NSAttributedString alloc] initWithString:today attributes:@{
        NSFontAttributeName: todayFont, NSForegroundColorAttributeName: p.secondary}];
    if (idle) _todayButton.accessibilityLabel = @"Today's total focus time";
    else if (s.goalToday > 0) _todayButton.accessibilityLabel = [NSString stringWithFormat:@"%ld of %ld focus sessions today", (long)s.completedToday, (long)s.goalToday];
    else _todayButton.accessibilityLabel = [NSString stringWithFormat:@"%ld focus sessions today", (long)s.completedToday];

    NSMutableAttributedString *phase = [[NSMutableAttributedString alloc] initWithString:@"●  "
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:8], NSForegroundColorAttributeName: accent,
                     NSBaselineOffsetAttributeName: @1.5}];
    [phase appendAttributedString:[[NSAttributedString alloc] initWithString:[self phaseName] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: accent, NSKernAttributeName: @0.9}]];
    _phaseField.attributedStringValue = phase;
    _countdownField.textColor = paused ? p.secondary : p.foreground;
    _labelField.textColor = p.secondary;
    _labelField.toolTip = s.label.length ? s.label : @"Click to add a label";
    if (!_labelField.currentEditor && ![_labelField.stringValue isEqualToString:s.label ?: @""])
        _labelField.stringValue = s.label ?: @"";

    _hintField.stringValue = s.startHint ?: @"";
    _hintField.textColor = [p.secondary colorWithAlphaComponent:0.75];
    _startButton.attributedTitle = [[NSAttributedString alloc] initWithString:@"▶  Start focus" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: p.focusColor}];
    _startButton.layer.backgroundColor = [[p.focusColor colorWithAlphaComponent:0.14] CGColor];

    NSString *pauseSymbol = paused ? @"play.fill" : @"pause.fill";
    NSString *pauseName = paused ? @"Resume" : @"Pause";
    _pauseButton.image = [NSImage imageWithSystemSymbolName:pauseSymbol accessibilityDescription:nil];
    _pauseButton.toolTip = pauseName; _pauseButton.accessibilityLabel = pauseName;
    for (NSButton *b in @[_pauseButton, _skipButton, _resetButton]) b.contentTintColor = p.secondary;
    _pauseButton.contentTintColor = p.foreground;
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (void)updateAccessibility {
    MicaFocusBandState *s = _state;
    NSString *text;
    if (s.phase == MICA_POMODORO_IDLE) {
        text = @"Focus timer, idle";
        if (s.todayTotalSeconds >= 1) text = [text stringByAppendingFormat:@", %@ focused today", [MicaFocusBandView formatDuration:s.todayTotalSeconds]];
    } else {
        long t = (long)ceil(MAX(0, s.remainingSeconds) - 1e-9);
        NSMutableArray *time = [NSMutableArray array];
        if (t >= 3600) [time addObject:[NSString stringWithFormat:@"%ld hour%@", t / 3600, t / 3600 == 1 ? @"" : @"s"]];
        long m = (t / 60) % 60, sec = t % 60;
        if (m || t >= 3600) [time addObject:[NSString stringWithFormat:@"%ld minute%@", m, m == 1 ? @"" : @"s"]];
        if (sec || !time.count) [time addObject:[NSString stringWithFormat:@"%ld second%@", sec, sec == 1 ? @"" : @"s"]];
        text = [NSString stringWithFormat:@"Focus timer, %@, %@ remaining", [self phaseName], [time componentsJoinedByString:@" "]];
        if (s.label.length) text = [text stringByAppendingFormat:@", %@", s.label];
        if (s.goalToday > 0) text = [text stringByAppendingFormat:@", %ld of %ld today", (long)s.completedToday, (long)s.goalToday];
        else text = [text stringByAppendingFormat:@", %ld today", (long)s.completedToday];
    }
    if (![self.accessibilityLabel isEqualToString:text]) self.accessibilityLabel = text;
}

#pragma mark Layout

static CGFloat MicaFieldWidth(NSTextField *f) {
    return ceil([f.attributedStringValue size].width) + 4;
}
static CGFloat MicaFieldHeight(NSTextField *f) { return ceil(f.intrinsicContentSize.height); }

- (void)setFrameSize:(NSSize)size {
    BOOL changed = size.width != self.frame.size.width;
    [super setFrameSize:size];
    if (changed) self.needsLayout = YES;
}

- (NSRect)centered:(CGFloat)x width:(CGFloat)w height:(CGFloat)h centerY:(CGFloat)cy {
    return NSMakeRect(x, round(cy - h / 2), w, h);
}

- (void)layout {
    [super layout];
    if (!_state) return;
    CGFloat width = self.bounds.size.width;
    if (_state.phase == MICA_POMODORO_IDLE) { [self layoutIdle:width]; return; }
    CGFloat cy = 22;
    CGFloat right = width - kPad;
    // Right cluster: pause, skip, reset (right to left: reset, skip, pause).
    _resetButton.frame = [self centered:right - kButton width:kButton height:kButton centerY:cy];
    right -= kButton;
    _skipButton.frame = [self centered:right - kButton width:kButton height:kButton centerY:cy];
    right -= kButton;
    _pauseButton.frame = [self centered:right - kButton width:kButton height:kButton centerY:cy];
    right -= kButton + 8;

    CGFloat x = kPad;
    CGFloat phaseW = MicaFieldWidth(_phaseField);
    _phaseField.frame = [self centered:x width:phaseW height:MicaFieldHeight(_phaseField) centerY:cy];
    x += phaseW + 6;
    CGFloat countW = MicaFieldWidth(_countdownField);
    _countdownField.frame = [self centered:x width:countW height:MicaFieldHeight(_countdownField) centerY:cy];
    x += countW + 12;

    NSString *today = [self todayTitle];
    CGFloat todayW = today.length ? ceil([_todayButton.attributedTitle size].width) + 16 : 0;
    CGFloat labelW = right - x - (todayW ? todayW + 8 : 0);
    BOOL showToday = todayW > 0;
    if (showToday && labelW < kLabelMinimum) { showToday = NO; labelW = right - x; }
    _todayButton.hidden = !showToday;
    if (showToday) {
        _todayButton.frame = [self centered:right - todayW width:todayW height:22 centerY:cy];
    }
    labelW = MAX(0, labelW);
    _labelField.frame = [self centered:x width:labelW height:MicaFieldHeight(_labelField) centerY:cy];
}

- (void)layoutIdle:(CGFloat)width {
    CGFloat cy = kIdleHeight / 2;
    CGFloat x = kPad;
    CGFloat startW = ceil([_startButton.attributedTitle size].width) + 16;
    _startButton.frame = [self centered:x width:startW height:18 centerY:cy];
    x += startW + 10;
    NSString *today = [self todayTitle];
    CGFloat todayW = today.length ? ceil([_todayButton.attributedTitle size].width) + 16 : 0;
    CGFloat hintW = MIN(MicaFieldWidth(_hintField), MAX(0, width - x - kPad - (todayW ? todayW + 8 : 0)));
    BOOL showToday = todayW > 0 && width - x - kPad - todayW - 8 >= 0;
    if (todayW && !showToday) hintW = MIN(MicaFieldWidth(_hintField), MAX(0, width - x - kPad));
    _hintField.frame = [self centered:x width:hintW height:MicaFieldHeight(_hintField) centerY:cy];
    _todayButton.hidden = !showToday;
    if (showToday) _todayButton.frame = [self centered:width - kPad - todayW width:todayW height:20 centerY:cy];
}

#pragma mark Drawing

- (NSRect)progressTrackRect {
    if (_state.phase == MICA_POMODORO_IDLE) return NSZeroRect;
    return NSMakeRect(kPad, 42, MAX(0, self.bounds.size.width - 2 * kPad), 4);
}

- (void)drawRect:(NSRect)dirty {
    if (!_palette) return;
    [_palette.background setFill];
    NSRectFill(self.bounds);
    [_palette.separator setFill];
    NSRectFill(NSMakeRect(0, self.bounds.size.height - 1, self.bounds.size.width, 1));
    NSRect track = [self progressTrackRect];
    if (NSIsEmptyRect(track)) return;
    [_palette.trackColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
    CGFloat w = floor(track.size.width * _progress);
    if (w > 0) {
        NSRect fill = NSMakeRect(track.origin.x, track.origin.y, MAX(w, 4), track.size.height);
        [[self phaseColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2 yRadius:2] fill];
    }
}

#pragma mark Actions

- (void)pressedStart:(id)sender { [self.delegate focusBandStart:self]; }
- (void)pressedPause:(id)sender { [self.delegate focusBandTogglePause:self]; }
- (void)pressedSkip:(id)sender { [self.delegate focusBandSkip:self]; }
- (void)pressedReset:(id)sender { [self.delegate focusBandReset:self]; }

- (void)pressedToday:(id)sender {
    if (_popover.shown) { [_popover close]; return; }
    _popover = [[NSPopover alloc] init];
    _popover.behavior = NSPopoverBehaviorTransient;
    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = [self popoverContentViewForTesting];
    _popover.contentViewController = vc;
    [_popover showRelativeToRect:_todayButton.bounds ofView:_todayButton preferredEdge:NSRectEdgeMaxY];
}

#pragma mark Label editing

- (void)controlTextDidBeginEditing:(NSNotification *)n {
    _labelField.drawsBackground = YES;
    _labelField.backgroundColor = _palette.trackColor;
    _labelField.textColor = _palette.foreground;
}

- (void)controlTextDidEndEditing:(NSNotification *)n {
    if (n.object != _labelField) return;
    _labelField.drawsBackground = NO;
    _labelField.textColor = _palette.secondary;
    NSString *value = [_labelField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![value isEqualToString:_state.label ?: @""]) [self.delegate focusBand:self didEditLabel:value];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(cancelOperation:)) {
        _labelField.stringValue = _state.label ?: @"";
        [self.window makeFirstResponder:nil];
        return YES;
    }
    return NO;
}

#pragma mark Popover

- (NSArray<NSArray<NSString *> *> *)popoverRowsForTesting {
    NSArray *rows = _state.projectRows;
    if (!rows.count) return @[@[@"No focus sessions yet today"]];
    NSMutableArray *out = [NSMutableArray array];
    double total = 0; long sessions = 0;
    for (NSDictionary *r in rows) {
        NSString *project = r[@"project"] ?: @"Unknown", *branch = r[@"branch"];
        double sec = [r[@"seconds"] doubleValue]; long n = [r[@"sessions"] longValue];
        total += sec; sessions += n;
        [out addObject:@[branch.length ? [NSString stringWithFormat:@"%@ · %@", project, branch] : project,
            [MicaFocusBandView formatDuration:sec],
            [NSString stringWithFormat:@"%ld session%@", n, n == 1 ? @"" : @"s"]]];
    }
    [out addObject:@[@"Total", [MicaFocusBandView formatDuration:total],
        [NSString stringWithFormat:@"%ld session%@", sessions, sessions == 1 ? @"" : @"s"]]];
    return out;
}

- (NSView *)popoverContentViewForTesting {
    MicaFocusBandPalette *p = _palette ?: [MicaFocusBandPalette darkPalette];
    NSArray *rows = [self popoverRowsForTesting];
    BOOL empty = !_state.projectRows.count;
    const CGFloat width = 340, rowH = 22, header = 30, pad = 14;
    CGFloat height = header + (empty ? rowH + 8 : rows.count * rowH + 6) + 8;
    NSView *root = [[MicaFocusFlippedView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    root.appearance = self.effectiveAppearance;
    NSTextField *title = MicaBandField([NSFont systemFontOfSize:10.5 weight:NSFontWeightBold]);
    title.attributedStringValue = [[NSAttributedString alloc] initWithString:@"TODAY" attributes:@{
        NSFontAttributeName: title.font, NSKernAttributeName: @0.9, NSForegroundColorAttributeName: p.secondary}];
    title.frame = NSMakeRect(pad, 10, 100, 16);
    [root addSubview:title];
    NSFont *font = [NSFont systemFontOfSize:12];
    NSFont *num = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    CGFloat y = header;
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSArray *r = rows[i];
        BOOL total = !empty && i == rows.count - 1;
        if (total) {
            NSView *rule = [[NSView alloc] initWithFrame:NSMakeRect(pad, y + 1, width - 2 * pad, 1)];
            rule.wantsLayer = YES; rule.layer.backgroundColor = p.separator.CGColor;
            [root addSubview:rule]; y += 6;
        }
        NSFont *nameFont = total ? [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] : font;
        NSTextField *name = MicaBandField(nameFont);
        name.stringValue = r[0]; name.textColor = empty ? p.secondary : p.foreground;
        if (r.count == 1) { name.frame = NSMakeRect(pad, y, width - 2 * pad, rowH - 4); [root addSubview:name]; break; }
        name.frame = NSMakeRect(pad, y, 180, rowH - 4); name.toolTip = r[0];
        NSTextField *dur = MicaBandField(total ? [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold] : num);
        dur.stringValue = r[1]; dur.alignment = NSTextAlignmentRight; dur.textColor = p.foreground;
        dur.frame = NSMakeRect(pad + 184, y, 56, rowH - 4);
        NSTextField *count = MicaBandField([NSFont systemFontOfSize:11]);
        count.stringValue = r[2]; count.alignment = NSTextAlignmentRight; count.textColor = p.secondary;
        count.frame = NSMakeRect(pad + 244, y, width - 2 * pad - 244, rowH - 4);
        [root addSubview:name]; [root addSubview:dur]; [root addSubview:count];
        y += rowH;
    }
    return root;
}

@end
