#import <Foundation/Foundation.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#import "../src/mica_agent_discover.h"

static int failures = 0;
#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #__VA_ARGS__); failures++; } } while (0)

static void Write(NSString *path, NSString *text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static NSString *Meta(NSString *cwd) {
    return [NSString stringWithFormat:@"{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"%@\",\"id\":\"x\"}}\n{\"type\":\"event\"}\n", cwd];
}

int main(void) {
    @autoreleasepool {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mica-discover-%d", getpid()]];
        NSString *home = [tmp stringByAppendingPathComponent:@"home"];
        NSString *work = [tmp stringByAppendingPathComponent:@"work"];
        [NSFileManager.defaultManager createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *uuid = @"01a18993-0d73-7343-ab3c-761cbe2e54f0";

        // uuid extraction
        CHECK([[MicaAgentDiscover codexSessionIDFromRolloutPath:[NSString stringWithFormat:@"/x/rollout-2026-10-29T22-31-18-%@.jsonl", uuid]] isEqualToString:uuid]);
        CHECK(![MicaAgentDiscover codexSessionIDFromRolloutPath:@"/x/rollout-2026-bad.jsonl"]);
        CHECK(![MicaAgentDiscover codexSessionIDFromRolloutPath:[NSString stringWithFormat:@"/x/other-%@.jsonl", uuid]]);
        CHECK(![MicaAgentDiscover codexSessionIDFromRolloutPath:[NSString stringWithFormat:@"/x/rollout-%@.json", uuid]]);

        // claude: default dir, env override, cwd mismatch, extra .claude-* dir, invalid id
        Write([home stringByAppendingPathComponent:@".claude/sessions/111.json"],
              [NSString stringWithFormat:@"{\"pid\":111,\"sessionId\":\"aaaaaaaa-1111\",\"cwd\":\"%@\"}", work]);
        NSDictionary *r = [MicaAgentDiscover discoverForPids:@[@111] cwd:work home:home env:@{}];
        CHECK([r[@"kind"] isEqual:@"claude"] && [r[@"sessionID"] isEqual:@"aaaaaaaa-1111"]);
        CHECK(![MicaAgentDiscover discoverForPids:@[@111] cwd:@"/somewhere/else" home:home env:@{}]);
        CHECK(![MicaAgentDiscover discoverForPids:@[@222] cwd:work home:home env:@{}]);
        NSString *custom = [tmp stringByAppendingPathComponent:@"custom"];
        Write([custom stringByAppendingPathComponent:@"sessions/222.json"], @"{\"sessionId\":\"bbbbbbbb-2222\"}");
        r = [MicaAgentDiscover discoverForPids:@[@222] cwd:work home:home env:@{@"CLAUDE_CONFIG_DIR": custom}];
        CHECK([r[@"sessionID"] isEqual:@"bbbbbbbb-2222"]);
        Write([home stringByAppendingPathComponent:@".claude-alt/sessions/333.json"], @"{\"sessionId\":\"cccccccc-3333\"}");
        r = [MicaAgentDiscover discoverForPids:@[@333] cwd:work home:home env:@{}];
        CHECK([r[@"sessionID"] isEqual:@"cccccccc-3333"]);
        NSArray *dirs = [MicaAgentDiscover claudeConfigDirsForHome:home env:@{@"CLAUDE_CONFIG_DIR": [home stringByAppendingPathComponent:@".claude"]}];
        CHECK(dirs.count == 2);
        Write([home stringByAppendingPathComponent:@".claude/sessions/444.json"], @"{\"sessionId\":\"bad id;rm\"}");
        CHECK(![MicaAgentDiscover discoverForPids:@[@444] cwd:work home:home env:@{}]);
        Write([home stringByAppendingPathComponent:@".claude/sessions/555.json"], @"not json");
        CHECK(![MicaAgentDiscover discoverForPids:@[@555] cwd:work home:home env:@{}]);

        // codex fallback 0 / 1 / 2 candidates
        NSString *day = [tmp stringByAppendingPathComponent:@"day"];
        NSTimeInterval past = NSDate.date.timeIntervalSince1970 - 5;   // process start just before the rollout was created
        CHECK(![MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:past]);
        NSString *f1 = [day stringByAppendingFormat:@"/rollout-2026-10-31T10-00-00-%@.jsonl", uuid];
        Write(f1, Meta(work));
        r = (id)[MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:past];
        CHECK([(NSString *)r isEqualToString:uuid]);
        CHECK(![MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:NSDate.date.timeIntervalSince1970 + 3600]);
        CHECK(![MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:@"/other" processStart:past]);
        Write([day stringByAppendingString:@"/rollout-2026-10-31T11-00-00-01a18993-0d73-7343-ab3c-761cbe2e54f1.jsonl"], Meta(work));
        CHECK(![MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:past]);

        // creation window [start-2, start+60] and exclusion set (f1 + the second rollout both exist here)
        [NSFileManager.defaultManager removeItemAtPath:[day stringByAppendingString:@"/rollout-2026-10-31T11-00-00-01a18993-0d73-7343-ab3c-761cbe2e54f1.jsonl"] error:nil];
        CHECK([(NSString *)[MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:past excludeIDs:nil] isEqualToString:uuid]);
        CHECK(![MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:past excludeIDs:[NSSet setWithObject:uuid]]);
        CHECK([(NSString *)[MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:past excludeIDs:[NSSet setWithObject:@"other"]] isEqualToString:uuid]);
        // rollout created long after process start (> 60s) is rejected; created before start-2s is rejected
        NSTimeInterval nowT = NSDate.date.timeIntervalSince1970;
        CHECK(![MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:nowT - 120 excludeIDs:nil]);
        CHECK(![MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:nowT + 30 excludeIDs:nil]);
        // an owned id excluded lets the other tab's rollout be the only candidate
        NSString *uuid2 = @"01a18993-0d73-7343-ab3c-761cbe2e54f1";
        Write([day stringByAppendingFormat:@"/rollout-2026-10-31T11-00-00-%@.jsonl", uuid2], Meta(work));
        CHECK(![MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:past excludeIDs:nil]);
        CHECK([(NSString *)[MicaAgentDiscover codexFallbackSessionIDInRoots:@[day] cwd:work processStart:past excludeIDs:[NSSet setWithObject:uuid]] isEqualToString:uuid2]);

        // resolveResumeForPids: discovered ids are replaced on change, cleared when pids vanish; hook ids are kept
        {
            NSString *rid1 = @"rrrrrrrr-0001", *rid2 = @"rrrrrrrr-0002";
            NSString *sf = [home stringByAppendingFormat:@"/.claude/sessions/%d.json", getpid()];
            Write(sf, [NSString stringWithFormat:@"{\"sessionId\":\"%@\",\"cwd\":\"%@\"}", rid1, work]);
            NSDictionary *res = [MicaAgentDiscover resolveResumeForPids:@[@(getpid())] cwd:work command:nil home:home env:@{}
                currentKind:nil currentID:nil fromHook:NO resolvedID:nil excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"set"] && [res[@"sessionID"] isEqual:rid1] && [res[@"launchResolved"] boolValue]);
            res = [MicaAgentDiscover resolveResumeForPids:@[@(getpid())] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:rid1 fromHook:NO resolvedID:rid1 excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"none"]);
            Write(sf, [NSString stringWithFormat:@"{\"sessionId\":\"%@\",\"cwd\":\"%@\"}", rid2, work]);
            res = [MicaAgentDiscover resolveResumeForPids:@[@(getpid())] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:rid1 fromHook:NO resolvedID:rid1 excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"set"] && [res[@"sessionID"] isEqual:rid2]);
            res = [MicaAgentDiscover resolveResumeForPids:@[] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:rid2 fromHook:NO resolvedID:rid2 excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"clear"]);
            res = [MicaAgentDiscover resolveResumeForPids:@[] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:@"hookhook-id" fromHook:YES resolvedID:nil excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"set"] && [res[@"sessionID"] isEqual:@"hookhook-id"] && ![res[@"launchResolved"] boolValue]);
            res = [MicaAgentDiscover resolveResumeForPids:@[@(getpid())] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:@"hookhook-id" fromHook:YES resolvedID:@"hookhook-id" excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"none"]);
            [NSFileManager.defaultManager removeItemAtPath:sf error:nil];
        }

        // codex live-fd: stub child holding a rollout file open
        NSString *codexHome = [tmp stringByAppendingPathComponent:@"codexhome"];
        NSString *live = [codexHome stringByAppendingFormat:@"/sessions/2026/10/31/rollout-2026-10-31T12-00-00-%@.jsonl", uuid];
        Write(live, Meta(@"/unrelated"));
        pid_t child = fork();
        if (child == 0) {
            execl("/bin/sh", "sh", "-c", [NSString stringWithFormat:@"exec 3<'%@'; sleep 5", live].UTF8String, (char *)NULL);
            _exit(127);
        }
        CHECK(child > 0);
        NSDictionary *found = nil;
        for (int i = 0; i < 100 && !found; i++) {
            found = [MicaAgentDiscover discoverForPids:@[@(child)] cwd:@"/nomatch" home:home env:@{@"CODEX_HOME": codexHome}];
            if (!found) usleep(50000);
        }
        CHECK([found[@"kind"] isEqual:@"codex"] && [found[@"sessionID"] isEqual:uuid]);
        // a different codex home must not match
        CHECK(![MicaAgentDiscover discoverForPids:@[@(child)] cwd:@"/nomatch" home:home env:@{@"CODEX_HOME": [tmp stringByAppendingPathComponent:@"nothome"]}]);
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);

        // Claude config dir by session id (hook-supplied ids), and launch info
        NSString *workDir = [home stringByAppendingPathComponent:@".claude-work"];
        NSString *cid = @"11111111-2222-3333-4444-555555555555";
        Write([workDir stringByAppendingFormat:@"/projects/-tmp-x/%@.jsonl", cid], @"{}\n");
        [NSFileManager.defaultManager createDirectoryAtPath:[home stringByAppendingPathComponent:@".claude"] withIntermediateDirectories:YES attributes:nil error:nil];
        CHECK([[MicaAgentDiscover claudeConfigDirForSessionID:cid home:home env:@{}] isEqualToString:workDir.stringByStandardizingPath]);
        CHECK(![MicaAgentDiscover claudeConfigDirForSessionID:@"99999999-2222-3333-4444-555555555555" home:home env:@{}]);
        NSDictionary *launch = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:cid pids:@[] command:nil home:home env:@{}];
        CHECK([launch[@"configDir"] isEqualToString:workDir.stringByStandardizingPath]);
        launch = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:cid pids:@[]
            command:@"CLAUDE_CONFIG_DIR=~/.claude-work claude --dangerously-skip-permissions" home:home env:@{}];
        CHECK([launch[@"flags"] isEqual:@[@"--dangerously-skip-permissions"]]);
        // sessions/<pid>.json hit carries its config dir
        Write([workDir stringByAppendingFormat:@"/sessions/%d.json", getpid()], [NSString stringWithFormat:@"{\"sessionId\":\"%@\",\"cwd\":\"%@\"}", cid, work]);
        NSDictionary *hit = [MicaAgentDiscover discoverForPids:@[@(getpid())] cwd:work home:home env:@{}];
        CHECK([hit[@"kind"] isEqual:@"claude"] && [hit[@"configDir"] isEqualToString:workDir.stringByStandardizingPath]);

        // KERN_PROCARGS2 parsing + flag extraction
        NSMutableData *raw = [NSMutableData data];
        int argc = 4;
        [raw appendBytes:&argc length:sizeof(argc)];
        const char blob[] = "/usr/bin/codex\0\0\0codex\0--sandbox=danger-full-access\0--ask-for-approval\0never\0HOME=/x\0CLAUDE_CONFIG_DIR=/y\0";
        [raw appendBytes:blob length:sizeof(blob) - 1];
        NSDictionary *parsed = [MicaAgentDiscover parseProcArgs:raw];
        CHECK([parsed[@"argv"] count] == 4 && [parsed[@"env"][@"CLAUDE_CONFIG_DIR"] isEqual:@"/y"]);
        CHECK([[MicaAgentDiscover agentFlagsForKind:@"codex" tokens:parsed[@"argv"]]
            isEqual:@[@"--sandbox", @"danger-full-access", @"--ask-for-approval", @"never"]]);
        CHECK([MicaAgentDiscover agentFlagsForKind:@"claude" tokens:parsed[@"argv"]].count == 0);
        CHECK([MicaAgentDiscover processArgsForPid:getpid()][@"argv"] != nil);

        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    puts("agent discover tests passed");
    return 0;
}
