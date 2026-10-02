#import "mica_attention.h"

@interface MicaAttentionInbox ()
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *pending;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *mutedTabs;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *lastPost;
@end

@implementation MicaAttentionInbox
- (instancetype)init {
    if ((self = [super init])) {
        _pending = [NSMutableDictionary dictionary]; _mutedTabs = [NSMutableDictionary dictionary];
        _lastPost = [NSMutableDictionary dictionary];
        _clock = ^NSTimeInterval { return NSProcessInfo.processInfo.systemUptime; };
    }
    return self;
}
- (NSString *)key:(uint64_t)tabID kind:(MicaAttentionKind)kind { return [NSString stringWithFormat:@"%llu:%ld", tabID, (long)kind]; }
- (BOOL)postTabID:(uint64_t)tabID kind:(MicaAttentionKind)kind title:(NSString *)title body:(NSString *)body muted:(BOOL)muted {
    if (!tabID || muted || [self isMutedTabID:tabID]) return NO;
    NSString *key = [self key:tabID kind:kind]; NSTimeInterval now = self.clock ? self.clock() : 0;
    NSNumber *last = self.lastPost[key];
    if (last && now >= last.doubleValue && now - last.doubleValue < 2.0) return NO;
    self.lastPost[key] = @(now);
    NSDictionary *event = @{@"tabID":@(tabID), @"kind":@(kind), @"title":title ?: @"Mica", @"body":body ?: @""};
    self.pending[key] = event;
    if (self.delivery) self.delivery(event);
    return YES;
}
- (void)clearTabID:(uint64_t)tabID {
    NSString *prefix = [NSString stringWithFormat:@"%llu:", tabID];
    for (NSString *key in self.pending.allKeys) if ([key hasPrefix:prefix]) [self.pending removeObjectForKey:key];
}
- (void)setMuted:(BOOL)muted tabID:(uint64_t)tabID { if (muted) self.mutedTabs[@(tabID)] = @YES; else [self.mutedTabs removeObjectForKey:@(tabID)]; }
- (BOOL)isMutedTabID:(uint64_t)tabID { return [self.mutedTabs[@(tabID)] boolValue]; }
- (NSArray<NSDictionary *> *)events { return self.pending.allValues; }
- (NSArray<NSNumber *> *)waitingTabIDs {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *event in self.pending.allValues) {
        NSInteger kind = [event[@"kind"] integerValue];
        if (kind == MicaAttentionWaitingPermission || kind == MicaAttentionWaitingInput) [ids addObject:event[@"tabID"]];
    }
    return ids;
}
- (NSString *)dockBadge { return self.pending.count ? [NSString stringWithFormat:@"%lu", (unsigned long)self.pending.count] : nil; }
@end
