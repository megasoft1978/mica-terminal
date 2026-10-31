#import "mica_focus_hold.h"

static const NSUInteger kMicaFocusHoldCap = 128;

typedef NS_ENUM(NSInteger, MicaFocusCategory) { MicaFocusNone = 0, MicaFocusFinished = 1, MicaFocusError = 2, MicaFocusWaiting = 3 };

static MicaFocusCategory CategoryForKind(MicaAttentionKind kind) {
    switch (kind) {
    case MicaAttentionDone: return MicaFocusFinished;
    case MicaAttentionError: return MicaFocusError;
    case MicaAttentionWaitingInput:
    case MicaAttentionWaitingPermission: return MicaFocusWaiting;
    default: return MicaFocusNone;
    }
}

@interface MicaFocusHoldEntry ()
@property(nonatomic) uint64_t tabID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) MicaFocusCategory category;
@end
@implementation MicaFocusHoldEntry
@end

@interface MicaFocusHoldSummary ()
- (instancetype)initWithFinished:(NSArray *)finished waiting:(NSArray *)waiting errors:(NSArray *)errors;
@end
@implementation MicaFocusHoldSummary
- (instancetype)initWithFinished:(NSArray *)finished waiting:(NSArray *)waiting errors:(NSArray *)errors {
    if ((self = [super init])) { _finished = [finished copy]; _waiting = [waiting copy]; _errors = [errors copy]; }
    return self;
}
- (BOOL)isEmpty { return !_finished.count && !_waiting.count && !_errors.count; }
- (NSString *)text {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (_finished.count) [parts addObject:[NSString stringWithFormat:@"%lu finished", (unsigned long)_finished.count]];
    if (_waiting.count) [parts addObject:[NSString stringWithFormat:@"%lu waiting", (unsigned long)_waiting.count]];
    if (_errors.count) [parts addObject:[NSString stringWithFormat:@"%lu error%@", (unsigned long)_errors.count, _errors.count == 1 ? @"" : @"s"]];
    return [parts componentsJoinedByString:@" · "];
}
@end

@interface MicaFocusHold ()
@property(nonatomic) NSMutableArray<MicaFocusHoldEntry *> *entries; // first-seen order
@end

@implementation MicaFocusHold
- (instancetype)init {
    if ((self = [super init])) _entries = [NSMutableArray array];
    return self;
}
- (void)setPhase:(MicaPomodoroPhase)phase {
    _holding = (phase == MICA_POMODORO_FOCUS);
}
- (BOOL)shouldHoldKind:(MicaAttentionKind)kind {
    if (!_holding) return NO;
    return kind == MicaAttentionDone || kind == MicaAttentionWaitingInput || kind == MicaAttentionError;
}
- (void)queueKind:(MicaAttentionKind)kind tabID:(uint64_t)tabID title:(NSString *)title {
    MicaFocusCategory category = CategoryForKind(kind);
    if (category == MicaFocusNone) return;
    for (MicaFocusHoldEntry *entry in _entries) {
        if (entry.tabID != tabID) continue;
        if (category > entry.category) entry.category = category;
        entry.title = title ?: @"";
        return;
    }
    MicaFocusHoldEntry *entry = [MicaFocusHoldEntry new];
    entry.tabID = tabID; entry.title = title ?: @""; entry.category = category;
    [_entries addObject:entry];
    if (_entries.count > kMicaFocusHoldCap) [_entries removeObjectAtIndex:0];
}
- (MicaFocusHoldSummary *)releaseSummary {
    NSMutableArray *finished = [NSMutableArray array], *waiting = [NSMutableArray array], *errors = [NSMutableArray array];
    for (MicaFocusHoldEntry *entry in _entries) {
        [(entry.category == MicaFocusWaiting ? waiting : entry.category == MicaFocusError ? errors : finished) addObject:entry];
    }
    [_entries removeAllObjects];
    return [[MicaFocusHoldSummary alloc] initWithFinished:finished waiting:waiting errors:errors];
}
- (void)forgetTabID:(uint64_t)tabID {
    for (NSUInteger i = 0; i < _entries.count; i++)
        if (_entries[i].tabID == tabID) { [_entries removeObjectAtIndex:i]; return; }
}
@end
