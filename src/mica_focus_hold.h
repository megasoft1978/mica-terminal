#import <Foundation/Foundation.h>
#import "mica_attention.h"
#include "mica_pomodoro.h"

NS_ASSUME_NONNULL_BEGIN

// Holds agent attention events during a focus-timer FOCUS phase and summarizes them afterwards.
//
// Kind mapping (MicaAttentionKind -> category):
//   MicaAttentionDone              -> finished
//   MicaAttentionWaitingInput      -> waiting
//   MicaAttentionWaitingPermission -> waiting (never held; only categorized if queued explicitly)
//   MicaAttentionError             -> errors
//   MicaAttentionTimerEnd, MicaAttentionHighMemory -> not an agent state: never held, ignored by queueKind.
//
// Dedupe per tab: one entry per tab, keeping the highest priority seen (waiting > error > finished);
// an equal or lower priority event only refreshes the title, a higher one upgrades the category. The entry
// keeps its first-seen position. Callers should forgetTabID: when a tab returns to a non-attention state
// (running) so a resolved wait does not linger. Cap: 128 distinct tabs, the oldest (first-seen) is dropped.
//
// Integration lives in the app layer: see mica_app.m for the call sites (setPhase, shouldHoldKind, releaseSummary).
@interface MicaFocusHoldEntry : NSObject
@property(nonatomic, readonly) uint64_t tabID;
@property(nonatomic, readonly, copy) NSString *title;
@end

@interface MicaFocusHoldSummary : NSObject
@property(nonatomic, readonly) NSArray<MicaFocusHoldEntry *> *finished;
@property(nonatomic, readonly) NSArray<MicaFocusHoldEntry *> *waiting;
@property(nonatomic, readonly) NSArray<MicaFocusHoldEntry *> *errors;
@property(nonatomic, readonly) BOOL isEmpty;
// Short text, e.g. "2 finished · 1 waiting · 1 error" (errors: "1 error", "2 errors"); "" when empty.
@property(nonatomic, readonly, copy) NSString *text;
@end

@interface MicaFocusHold : NSObject
@property(nonatomic, readonly) BOOL holding;
// holding is YES only for MICA_POMODORO_FOCUS. PAUSED_FOCUS, break, idle and all other phases are NO,
// so notifications are never held while the timer is paused, expired, or not running a focus session.
- (void)setPhase:(MicaPomodoroPhase)phase;
- (BOOL)shouldHoldKind:(MicaAttentionKind)kind;
- (void)queueKind:(MicaAttentionKind)kind tabID:(uint64_t)tabID title:(NSString *)title;
- (MicaFocusHoldSummary *)releaseSummary;
- (void)forgetTabID:(uint64_t)tabID;
@end

NS_ASSUME_NONNULL_END
