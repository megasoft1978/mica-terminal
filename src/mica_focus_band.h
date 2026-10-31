#import <Cocoa/Cocoa.h>
#include "mica_pomodoro.h"

// Full-width focus timer band shown under the tab bar.

@interface MicaFocusBandState : NSObject
@property(nonatomic) MicaPomodoroPhase phase;
@property(nonatomic) double remainingSeconds;
@property(nonatomic) double totalSeconds;
@property(nonatomic, copy) NSString *label;
@property(nonatomic) NSInteger completedToday;
@property(nonatomic) NSInteger goalToday;          // 0 = no goal
@property(nonatomic) double todayTotalSeconds;
// Each row: @{@"project": NSString, @"branch": NSString (optional),
//             @"seconds": NSNumber, @"sessions": NSNumber}
@property(nonatomic, copy) NSArray<NSDictionary *> *projectRows;
@property(nonatomic, copy) NSString *startHint;    // e.g. @"⌥⌘P"
@end

@interface MicaFocusBandPalette : NSObject
@property(nonatomic, strong) NSColor *background, *foreground, *secondary, *separator;
@property(nonatomic, strong) NSColor *focusColor, *breakColor, *pausedColor, *trackColor;
+ (instancetype)darkPalette;
+ (instancetype)lightPalette;
@end

@class MicaFocusBandView;
@protocol MicaFocusBandDelegate <NSObject>
- (void)focusBandStart:(MicaFocusBandView *)band;
- (void)focusBandTogglePause:(MicaFocusBandView *)band;
- (void)focusBandSkip:(MicaFocusBandView *)band;
- (void)focusBandReset:(MicaFocusBandView *)band;
- (void)focusBand:(MicaFocusBandView *)band didEditLabel:(NSString *)label;
@end

@interface MicaFocusBandView : NSView
@property(nonatomic, weak) id<MicaFocusBandDelegate> delegate;

+ (CGFloat)heightForPhase:(MicaPomodoroPhase)phase;
+ (NSString *)formatCountdown:(double)seconds;   // mm:ss, h:mm:ss from 1h
+ (NSString *)formatDuration:(double)seconds;    // "1h 05m", "42m"

// Cheap to call every second; relayouts only when structure changes.
- (void)applyState:(MicaFocusBandState *)state palette:(MicaFocusBandPalette *)palette;

// Accessors (tests / integration).
@property(nonatomic, readonly) NSTextField *phaseField, *countdownField, *labelField, *hintField;
@property(nonatomic, readonly) NSButton *pauseButton, *skipButton, *resetButton, *todayButton, *startButton;
@property(nonatomic, readonly) double progressFraction;
- (NSArray<NSArray<NSString *> *> *)popoverRowsForTesting;
- (NSView *)popoverContentViewForTesting;
@end
