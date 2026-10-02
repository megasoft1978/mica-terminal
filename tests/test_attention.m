#import <Foundation/Foundation.h>
#import "mica_attention.h"

int main(void) {
    @autoreleasepool {
        MicaAttentionInbox *inbox = [MicaAttentionInbox new];
        __block NSTimeInterval now = 10;
        inbox.clock = ^{ return now; };
        __block NSUInteger delivered = 0;
        inbox.delivery = ^(NSDictionary *event) { (void)event; delivered++; };
        NSCAssert([inbox postTabID:1 kind:MicaAttentionWaitingInput title:@"a" body:@"one" muted:NO], @"first post");
        NSCAssert(![inbox postTabID:1 kind:MicaAttentionWaitingInput title:@"a" body:@"two" muted:NO], @"coalesce");
        NSCAssert(delivered == 1 && [inbox.events.firstObject[@"body"] isEqual:@"two"], @"coalesced event update");
        now += 2;
        NSCAssert([inbox postTabID:1 kind:MicaAttentionWaitingInput title:@"a" body:@"three" muted:NO], @"post after window");
        [inbox postTabID:1 kind:MicaAttentionWaitingPermission title:@"a" body:@"permission" muted:NO];
        NSCAssert(inbox.waitingTabIDs.count == 1, @"waiting IDs dedupe");
        [inbox setMuted:YES tabID:1];
        NSCAssert(inbox.events.count == 0 && ![inbox postTabID:1 kind:MicaAttentionDone title:@"a" body:@"done" muted:NO], @"mute clears and blocks");
        [inbox setMuted:NO tabID:1];
        __block MicaAttentionKind lastKind = MicaAttentionWaitingInput;
        inbox.delivery = ^(NSDictionary *event) { delivered++; lastKind = [event[@"kind"] integerValue]; };
        now += 2;
        NSCAssert([inbox postTabID:3 kind:MicaAttentionTimerEnd title:@"Timer" body:@"Ended" muted:NO], @"timer end post");
        NSCAssert(lastKind == MicaAttentionTimerEnd, @"timer end routed through inbox delivery");
        [inbox clearTabID:3];
        [inbox postTabID:2 kind:MicaAttentionDone title:@"b" body:@"done" muted:NO];
        NSCAssert([inbox.dockBadge isEqual:@"1"], @"dock badge");
        [inbox clearTabID:2];
        NSCAssert(inbox.dockBadge == nil, @"clear removes badge");
    }
    return 0;
}
