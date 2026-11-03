#import "mica_focus_band.h"
#include <math.h>

@implementation MicaFocusBandState @end

@implementation MicaFocusBandPalette
+ (instancetype)darkPalette {
    MicaFocusBandPalette *p = [MicaFocusBandPalette new];
    p.background = [NSColor colorWithSRGBRed:0.092 green:0.096 blue:0.108 alpha:1];
    p.foreground = [NSColor colorWithWhite:0.95 alpha:1];
    p.secondary = [NSColor colorWithWhite:0.70 alpha:1];
    p.separator = [NSColor colorWithWhite:1 alpha:0.10];
    p.focusColor = [NSColor colorWithSRGBRed:1.0 green:0.42 blue:0.36 alpha:1];
    p.breakColor = [NSColor colorWithSRGBRed:0.36 green:0.84 blue:0.62 alpha:1];
    p.pausedColor = [NSColor colorWithSRGBRed:0.96 green:0.74 blue:0.30 alpha:1];
    p.trackColor = [NSColor colorWithWhite:1 alpha:0.10];
    return p;
}
+ (instancetype)lightPalette {
    MicaFocusBandPalette *p = [MicaFocusBandPalette new];
    p.background = [NSColor colorWithSRGBRed:0.955 green:0.958 blue:0.968 alpha:1];
    p.foreground = [NSColor colorWithWhite:0.09 alpha:1];
    p.secondary = [NSColor colorWithWhite:0.36 alpha:1];
    p.separator = [NSColor colorWithWhite:0 alpha:0.12];
    p.focusColor = [NSColor colorWithSRGBRed:0.82 green:0.20 blue:0.16 alpha:1];
    p.breakColor = [NSColor colorWithSRGBRed:0.06 green:0.50 blue:0.34 alpha:1];
    p.pausedColor = [NSColor colorWithSRGBRed:0.70 green:0.44 blue:0.02 alpha:1];
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

// Borderless pill/circle button with a hover fill (no timers; tracking area only).
@interface MicaPillButton : NSButton
@property(nonatomic, strong) NSColor *restFill, *hoverFill;
@end
@implementation MicaPillButton {
    NSTrackingArea *_area;
    BOOL _hover;
}
- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.bordered = NO; self.wantsLayer = YES;
    self.focusRingType = NSFocusRingTypeNone;
    return self;
}
- (void)syncFill {
    NSColor *c = _hover ? (self.hoverFill ?: self.restFill) : self.restFill;
    self.layer.backgroundColor = c ? c.CGColor : NULL;
}
- (void)setRestFill:(NSColor *)c { _restFill = c; [self syncFill]; }
- (void)setHoverFill:(NSColor *)c { _hoverFill = c; [self syncFill]; }
- (void)layout {
    [super layout];
    self.layer.cornerRadius = self.bounds.size.height / 2;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_area) [self removeTrackingArea:_area];
    _area = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)e { _hover = YES; [self syncFill]; }
- (void)mouseExited:(NSEvent *)e { _hover = NO; [self syncFill]; }
@end

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
    int _phaseSeen;
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
    NSButton *b = [[MicaPillButton alloc] initWithFrame:NSMakeRect(0, 0, kButton, kButton)];
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
    b.target = self; b.action = action;
    return b;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    _phaseSeen = -1;
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityGroupRole;
    _phaseField = MicaBandField([NSFont systemFontOfSize:10 weight:NSFontWeightHeavy]);
    _countdownField = MicaBandField([NSFont monospacedDigitSystemFontOfSize:26 weight:NSFontWeightSemibold]);
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
    _todayButton = [[MicaPillButton alloc] initWithFrame:NSZeroRect];
    _todayButton.target = self; _todayButton.action = @selector(pressedToday:);
    _todayButton.toolTip = @"Today's focus time by project";
    _todayButton.accessibilityLabel = @"Today's focus sessions";
    _startButton = [[MicaPillButton alloc] initWithFrame:NSZeroRect];
    _startButton.target = self; _startButton.action = @selector(pressedStart:);
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

static const NSInteger kMaxGoalDots = 8;

// Plain-text form of the chip (layout gating, tests, fallback beyond kMaxGoalDots).
- (NSString *)todayTitle {
    MicaFocusBandState *s = _state;
    NSString *dur = s.todayTotalSeconds >= 1 ? [MicaFocusBandView formatDuration:s.todayTotalSeconds] : nil;
    if (s.phase == MICA_POMODORO_IDLE) return dur ? [NSString stringWithFormat:@"Today %@", dur] : @"";
    NSString *count = s.goalToday > 0 ? [NSString stringWithFormat:@"%ld/%ld today", (long)s.completedToday, (long)s.goalToday]
                                      : [NSString stringWithFormat:@"%ld today", (long)s.completedToday];
    return dur ? [NSString stringWithFormat:@"%@ \u00b7 %@", count, dur] : count;
}

- (NSAttributedString *)todayAttributedTitle {
    MicaFocusBandState *s = _state;
    NSFont *font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    NSDictionary *textAttrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: _palette.secondary};
    BOOL dots = s.phase != MICA_POMODORO_IDLE && s.goalToday > 0 && s.goalToday <= kMaxGoalDots;
    if (!dots) return [[NSAttributedString alloc] initWithString:[self todayTitle] attributes:textAttrs];
    NSInteger filled = MAX(0, MIN(s.completedToday, s.goalToday));
    NSColor *accent = [self phaseColor];
    NSDictionary *dotAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:8], NSForegroundColorAttributeName: accent,
                               NSKernAttributeName: @1.5, NSBaselineOffsetAttributeName: @1};
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSMutableString *glyphs = [NSMutableString string];
    for (NSInteger i = 0; i < s.goalToday; i++) [glyphs appendString:i < filled ? @"\u25CF" : @"\u25CB"];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:glyphs attributes:dotAttrs]];
    if (s.todayTotalSeconds >= 1)
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:
            [@"  " stringByAppendingString:[MicaFocusBandView formatDuration:s.todayTotalSeconds]] attributes:textAttrs]];
    return out;
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
    BOOL phaseChanged = _phaseSeen != (int)s.phase;
    _phaseSeen = (int)s.phase;
    if (structural && phaseChanged && self.window && self.layer) {
        // One short fade on phase change only (AppKit animator, no timers).
        for (NSView *v in @[_phaseField, _countdownField]) v.alphaValue = 0.25;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.3;
            self->_phaseField.animator.alphaValue = 1;
            self->_countdownField.animator.alphaValue = 1;
        }];
    }
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

    _todayButton.attributedTitle = [self todayAttributedTitle];
    if (idle) _todayButton.accessibilityLabel = @"Today's total focus time";
    else {
        NSString *count = s.goalToday > 0 ? [NSString stringWithFormat:@"%ld of %ld sessions today", (long)s.completedToday, (long)s.goalToday]
                                          : [NSString stringWithFormat:@"%ld sessions today", (long)s.completedToday];
        _todayButton.accessibilityLabel = s.todayTotalSeconds >= 1
            ? [NSString stringWithFormat:@"%@, %@", count, [MicaFocusBandView formatDuration:s.todayTotalSeconds]] : count;
    }

    NSMutableAttributedString *phase = [[NSMutableAttributedString alloc] initWithString:@"●  "
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:8], NSForegroundColorAttributeName: accent,
                     NSBaselineOffsetAttributeName: @1.5}];
    [phase appendAttributedString:[[NSAttributedString alloc] initWithString:[self phaseName] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightHeavy],
        NSForegroundColorAttributeName: accent, NSKernAttributeName: @1.2}]];
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
    ((MicaPillButton *)_startButton).restFill = [p.focusColor colorWithAlphaComponent:0.14];
    ((MicaPillButton *)_startButton).hoverFill = [p.focusColor colorWithAlphaComponent:0.26];
    ((MicaPillButton *)_todayButton).restFill = [p.secondary colorWithAlphaComponent:0.12];
    ((MicaPillButton *)_todayButton).hoverFill = [p.secondary colorWithAlphaComponent:0.22];

    NSString *pauseSymbol = paused ? @"play.fill" : @"pause.fill";
    NSString *pauseName = paused ? @"Resume" : @"Pause";
    _pauseButton.image = [NSImage imageWithSystemSymbolName:pauseSymbol accessibilityDescription:nil];
    _pauseButton.toolTip = pauseName; _pauseButton.accessibilityLabel = pauseName;
    for (NSButton *b in @[_pauseButton, _skipButton, _resetButton]) {
        b.contentTintColor = p.secondary;
        ((MicaPillButton *)b).restFill = nil;
        ((MicaPillButton *)b).hoverFill = [p.secondary colorWithAlphaComponent:0.18];
    }
    // Primary control carries the phase tint.
    _pauseButton.contentTintColor = accent;
    ((MicaPillButton *)_pauseButton).restFill = [accent colorWithAlphaComponent:0.16];
    ((MicaPillButton *)_pauseButton).hoverFill = [accent colorWithAlphaComponent:0.30];
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
    return NSMakeRect(kPad, 41, MAX(0, self.bounds.size.width - 2 * kPad), 5);
}

- (void)drawRect:(NSRect)dirty {
    if (!_palette) return;
    NSRect b = self.bounds;
    [_palette.background setFill];
    NSRectFill(b);
    if (_state.phase != MICA_POMODORO_IDLE) {
        // Subtle phase-tinted wash, strongest at the left where the phase caption sits.
        NSColor *c = [self phaseColor];
        NSGradient *wash = [[NSGradient alloc] initWithStartingColor:[c colorWithAlphaComponent:0.10]
                                                         endingColor:[c colorWithAlphaComponent:0.02]];
        [wash drawInRect:b angle:0];
    }
    [_palette.separator setFill];
    NSRectFill(NSMakeRect(0, b.size.height - 1, b.size.width, 1));
    NSRect track = [self progressTrackRect];
    if (NSIsEmptyRect(track)) return;
    CGFloat r = track.size.height / 2;
    [_palette.trackColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:r yRadius:r] fill];
    CGFloat w = floor(track.size.width * _progress);
    if (w <= 0) return;
    NSColor *accent = [self phaseColor];
    NSRect fill = NSMakeRect(track.origin.x, track.origin.y, MAX(w, track.size.height), track.size.height);
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[accent colorWithAlphaComponent:0.55] endingColor:accent];
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:r yRadius:r] addClip];
    [g drawInRect:fill angle:0];
    [NSGraphicsContext restoreGraphicsState];
    // Glowing leading edge.
    NSPoint tip = NSMakePoint(NSMaxX(fill) - r, NSMidY(fill));
    NSGradient *glow = [[NSGradient alloc] initWithColors:@[[accent colorWithAlphaComponent:0.55], [accent colorWithAlphaComponent:0]]];
    [glow drawFromCenter:tip radius:0 toCenter:tip radius:9 options:0];
    [[NSColor.whiteColor colorWithAlphaComponent:0.85] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(tip.x - 1.5, tip.y - 1.5, 3, 3)] fill];
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
