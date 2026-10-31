#import <Foundation/Foundation.h>
#import "../src/mica_resume.h"
#include <unistd.h>

int main(void) {
    @autoreleasepool {
        NSArray *valid = @[@"abcdefgh", @"abc_DEF-123.xyz", [@"a" stringByPaddingToLength:80 withString:@"a" startingAtIndex:0]];
        for (NSString *value in valid) if (!MicaResumeCommand(@"claude", value)) return 1;
        NSString *tooShort = @"short";
        NSString *tooLong = [@"a" stringByPaddingToLength:81 withString:@"a" startingAtIndex:0];
        NSArray *hostile = @[@"abc defgh", @"abcdefgh;", @"$(touch)", @"abc\"defgh", @"abc\ndefgh", @"abcdefghé", @"--help-me", @"-abcdefgh", @".abcdefgh", @"_abcdefgh", tooShort, tooLong];
        for (NSString *value in hostile) if (MicaResumeCommand(@"claude", value)) return 2;
        if (![[MicaResumeCommand(@"codex", @"abcdefgh") description] isEqualToString:@"codex resume abcdefgh"]) return 3;
        if (MicaResumeCommand(@"other", @"abcdefgh")) return 4;
        // launch reproduction
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mica-resume-%d", getpid()]];
        NSString *home = [tmp stringByAppendingPathComponent:@"home"];
        NSString *work = [home stringByAppendingPathComponent:@".claude-work"];
        NSString *quoted = [home stringByAppendingPathComponent:@"it's"];
        for (NSString *dir in @[work, quoted, [home stringByAppendingPathComponent:@".claude"]])
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSArray *skip = @[@"--dangerously-skip-permissions"];
        NSString *expect = [NSString stringWithFormat:@"CLAUDE_CONFIG_DIR='%@' claude --dangerously-skip-permissions --resume abcdefgh", work];
        if (![MicaResumeCommandWithLaunch(@"claude", @"abcdefgh", work, skip, home) isEqualToString:expect]) return 10;
        if (![MicaResumeCommandWithLaunch(@"claude", @"abcdefgh", [home stringByAppendingPathComponent:@".claude"], skip, home)
              isEqualToString:@"claude --dangerously-skip-permissions --resume abcdefgh"]) return 11;
        if (![MicaResumeCommandWithLaunch(@"claude", @"abcdefgh", [tmp stringByAppendingPathComponent:@"missing"], nil, home)
              isEqualToString:@"claude --resume abcdefgh"]) return 12;
        if (![MicaResumeCommandWithLaunch(@"claude", @"abcdefgh", @"relative", nil, home) isEqualToString:@"claude --resume abcdefgh"]) return 13;
        if (![MicaResumeCommandWithLaunch(@"claude", @"abcdefgh", quoted, nil, home) containsString:@"it'\\''s' claude"]) return 14;
        NSArray *codexFlags = @[@"--sandbox", @"danger-full-access", @"--ask-for-approval", @"never", @"--evil", @"$(x)"];
        if (![MicaResumeCommandWithLaunch(@"codex", @"abcdefgh", work, codexFlags, home)
              isEqualToString:@"codex resume abcdefgh --sandbox danger-full-access --ask-for-approval never"]) return 15;
        if (MicaSanitizedAgentFlags(@"claude", @[@"--sandbox", @"never"]).count != 0) return 16;
        if (MicaSanitizedAgentFlags(@"codex", @[@"--sandbox", @"rm -rf"]).count != 0) return 17;
        if (![[MicaSanitizedAgentFlags(@"codex", @[@"--dangerously-bypass-approvals-and-sandbox"]) firstObject] isEqual:@"--dangerously-bypass-approvals-and-sandbox"]) return 18;
        if (MicaResumeCommandWithLaunch(@"codex", @"bad id", nil, nil, home)) return 19;
        if (MicaResumeCommandWithLaunch(@"claude", @"--help-me", nil, nil, home)) return 20;
        if (MicaResumeCommandWithLaunch(@"codex", @".hidden-id", nil, nil, home)) return 21;
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    }
    return 0;
}
