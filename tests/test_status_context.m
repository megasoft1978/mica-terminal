#import <Foundation/Foundation.h>
#import "mica_status_context.h"

int main(void) {
    @autoreleasepool {
        BOOL claudeApproval = [MicaStatusContextForCommand(@"claude", @"Claude Code", @"waitingPermission",
            @"Ran git status --short", MicaStatusActivityWaiting, YES, NO, 0)
            isEqualToString:@"Claude Code · Needs approval"];
        BOOL codexInput = [MicaStatusContextForCommand(@"codex", @"Codex", @"waitingInput",
            nil, MicaStatusActivityWaiting, YES, NO, 0) isEqualToString:@"Codex · Needs input"];
        BOOL rawDetailNotShown = [MicaStatusContextForCommand(@"codex", @"Codex", @"working",
            @"ts 125ms | operation queue item", MicaStatusActivityRunning, YES, NO, 0)
            isEqualToString:@"Codex · Working"];
        BOOL stablePhaseShown = [MicaStatusContextForCommand(@"claude", @"Claude Code", @"working",
            @"Testing", MicaStatusActivityRunning, YES, NO, 0) isEqualToString:@"Claude Code · Testing"];
        BOOL genericCommand = [MicaStatusContextForCommand(@"/opt/homebrew/bin/npm", nil, nil, nil,
            MicaStatusActivityRunning, NO, NO, 0) isEqualToString:@"Running · npm"];
        BOOL lazygitTUI = [MicaStatusContextForCommand(@"lazygit", nil, nil, nil,
            MicaStatusActivityIdle, NO, NO, 0) isEqualToString:@"lazygit · Open"];
        BOOL failedExit = [MicaStatusContextForCommand(@"npm", nil, nil, nil,
            MicaStatusActivityFinished, NO, YES, 2) isEqualToString:@"npm · Failed (2)"];
        BOOL finished = [MicaStatusContextForCommand(@"npm", nil, nil, nil,
            MicaStatusActivityFinished, NO, YES, 0) isEqualToString:@"npm · Finished"];
        NSCAssert(claudeApproval && codexInput && rawDetailNotShown && stablePhaseShown && genericCommand &&
            lazygitTUI && failedExit && finished, @"status context should be concise, stable and evidence based");
        puts("PASS concise command, Claude, Codex and lazygit status contexts");
    }
    return 0;
}
