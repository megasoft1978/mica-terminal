#import "mica_agent_rss.h"
#import "mica.h"
#import <objc/message.h>

@interface MicaAgentRSSMonitor ()
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *armed;
@end

@implementation MicaAgentRSSMonitor
- (instancetype)init {
    if ((self = [super init])) {
        _armed = [NSMutableDictionary dictionary];
        _thresholdBytes = 4ULL * 1024 * 1024 * 1024;
        _sampler = ^uint64_t(pid_t pid) { return mica_process_tree_rss(pid); };
    }
    return self;
}
- (NSDictionary<NSNumber *,NSNumber *> *)sampleTabs:(NSArray *)tabs {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (id tab in tabs) {
        NSNumber *identifier = [tab valueForKey:@"identifier"];
        if (!identifier) continue;
        NSString *kind = [tab valueForKey:@"agentKind"];
        NSString *processKind = [tab valueForKey:@"processAgentKind"];
        BOOL supported = [kind isEqualToString:@"claude"] || [kind isEqualToString:@"codex"] ||
            [processKind isEqualToString:@"claude"] || [processKind isEqualToString:@"codex"];
        if (!supported) continue;
        MicaSession *session = NULL;
        SEL sessionSelector = NSSelectorFromString(@"session");
        if ([tab respondsToSelector:sessionSelector]) {
            MicaSession *(*getSession)(id, SEL) = (MicaSession *(*)(id, SEL))objc_msgSend;
            session = getSession(tab, sessionSelector);
        }
        uint64_t rss = session ? (self.sampler ? self.sampler(mica_session_root_pid(session)) : mica_session_tree_rss(session)) : 0;
        values[identifier] = @(rss);
    }
    NSSet *present = [NSSet setWithArray:values.allKeys];
    for (NSNumber *tabID in self.armed.allKeys)
        if (![present containsObject:tabID]) [self.armed removeObjectForKey:tabID];
    return [values copy];
}
- (void)setThresholdBytes:(uint64_t)thresholdBytes {
    if (_thresholdBytes == thresholdBytes) return;
    _thresholdBytes = thresholdBytes;
    [self.armed removeAllObjects];
}
- (NSArray<NSNumber *> *)crossingsForSamples:(NSDictionary<NSNumber *,NSNumber *> *)samples {
    NSMutableArray *crossings = [NSMutableArray array];
    uint64_t threshold = self.thresholdBytes;
    uint64_t rearm = threshold - threshold / 10;
    [samples enumerateKeysAndObjectsUsingBlock:^(NSNumber *tabID, NSNumber *value, BOOL *stop) {
        (void)stop;
        uint64_t rss = value.unsignedLongLongValue;
        BOOL armed = self.armed[tabID] ? self.armed[tabID].boolValue : YES;
        if (armed && threshold && rss >= threshold) {
            [crossings addObject:tabID]; self.armed[tabID] = @NO;
        } else if (!armed && rss < rearm) self.armed[tabID] = @YES;
    }];
    [crossings sortUsingSelector:@selector(compare:)];
    return crossings;
}
@end
