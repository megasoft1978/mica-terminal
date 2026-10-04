#import <Foundation/Foundation.h>
#import "mica_agent_rss.h"
#import "mica.h"
#include <unistd.h>

@interface MicaRSSProbeTab : NSObject
@property(nonatomic) uint64_t identifier;
@property(nonatomic) MicaSession *session;
@property(nonatomic, copy) NSString *agentKind;
@property(nonatomic, copy) NSString *processAgentKind;
@end
@implementation MicaRSSProbeTab @end

int main(void) {
    @autoreleasepool {
        MicaAgentRSSMonitor *monitor = [MicaAgentRSSMonitor new];
        monitor.thresholdBytes = 100;
        NSDictionary *high = @{@1:@100};
        BOOL first = [[monitor crossingsForSamples:high] isEqual:@[@1]];
        BOOL held = [monitor crossingsForSamples:high].count == 0;
        [monitor crossingsForSamples:@{@1:@89}];
        BOOL rearmed = [[monitor crossingsForSamples:high] isEqual:@[@1]];
        monitor.thresholdBytes = 200;
        BOOL thresholdChangeRearms = [[monitor crossingsForSamples:@{@1:@200}] isEqual:@[@1]];
        monitor.thresholdBytes = 0;
        BOOL neverDisablesWarnings = [monitor crossingsForSamples:@{@1:@999}].count == 0;

        MicaSession *session = mica_session_create("/tmp", "sleep 30", 24, 80);
        if (!session) return 2;
        uint64_t treeRSS = 0;
        for (int attempt = 0; attempt < 100 && treeRSS == 0; attempt++) {
            treeRSS = mica_session_tree_rss(session);
            if (treeRSS == 0) usleep(10000);
        }
        BOOL processTreeAPI = mica_session_root_pid(session) == mica_session_pid(session) &&
            treeRSS > 0 && mica_process_tree_rss(-1) == 0;
        MicaRSSProbeTab *claude = [MicaRSSProbeTab new];
        claude.identifier = 7; claude.session = session; claude.agentKind = @"claude";
        MicaRSSProbeTab *codex = [MicaRSSProbeTab new];
        codex.identifier = 8; codex.session = session; codex.processAgentKind = @"codex";
        MicaRSSProbeTab *shell = [MicaRSSProbeTab new];
        shell.identifier = 9; shell.session = session;
        __block NSUInteger calls = 0;
        __block pid_t sampledPID = -1;
        monitor.sampler = ^uint64_t(pid_t pid) { calls++; sampledPID = pid; return 1234; };
        NSDictionary *samples = [monitor sampleTabs:@[claude, codex, shell]];
        BOOL onlyAgentsSampled = samples.count == 2 && [samples[@7] unsignedLongLongValue] == 1234 &&
            [samples[@8] unsignedLongLongValue] == 1234 && !samples[@9] && calls == 2 &&
            sampledPID == mica_session_pid(session);
        mica_session_destroy(session);
        if (!first || !held || !rearmed || !thresholdChangeRearms || !neverDisablesWarnings || !onlyAgentsSampled || !processTreeAPI) return 1;
        puts("PASS agent RSS process-tree sampling, supported-agent filter, crossing hysteresis, threshold reset and Never");
    }
    return 0;
}
