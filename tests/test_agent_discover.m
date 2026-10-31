#import <Foundation/Foundation.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>
#include <limits.h>
#include <fcntl.h>
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
            NSString *bin = [home stringByAppendingPathComponent:@"bin"];
            [NSFileManager.defaultManager createDirectoryAtPath:bin withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *claudeStub = [bin stringByAppendingPathComponent:@"claude"];
            NSString *otherStub = [bin stringByAppendingPathComponent:@"notagent"];
            // Stubs are tiny compiled programs that just sleep (/bin/sh copies re-exec bash, copied system binaries lose their signature).
            NSString *src = [bin stringByAppendingPathComponent:@"stub.c"];
            Write(src, @"#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n");
            for (NSString *stub in @[claudeStub, otherStub]) {
                pid_t cc = fork();
                if (cc == 0) { execl("/usr/bin/clang", "clang", src.UTF8String, "-o", stub.UTF8String, (char *)NULL); _exit(127); }
                waitpid(cc, NULL, 0);
            }
            // spawn(exe, name, dirEnv, extra): exec stub with argv [name, -c, idle, extra]
            pid_t (^spawn)(NSString *, NSString *, NSString *, NSString *) = ^pid_t(NSString *exe, NSString *name, NSString *dirEnv, NSString *extra) {
                pid_t p = fork();
                if (p == 0) {
                    int nul = open("/dev/null", O_RDWR); dup2(nul, 0); dup2(nul, 1); dup2(nul, 2);
                    if (dirEnv) setenv("CLAUDE_CONFIG_DIR", dirEnv.UTF8String, 1); else unsetenv("CLAUDE_CONFIG_DIR");
                    execl(exe.UTF8String, name.UTF8String, "-c", "idle", extra.UTF8String, (char *)NULL);
                    _exit(127);
                }
                return p;
            };
            void (^wait)(pid_t) = ^(pid_t p) { for (int i = 0; i < 100; i++) { if ([[MicaAgentDiscover processArgsForPid:p][@"argv"] count] >= 4) break; usleep(20000); } usleep(150000); };   // let the exec settle (proc_pidpath can lag argv)
            void (^reap)(pid_t) = ^(pid_t p) { kill(p, SIGKILL); waitpid(p, NULL, 0); };

            NSString *(^RP)(NSString *) = ^NSString *(NSString *path) { char r[PATH_MAX]; return realpath(path.fileSystemRepresentation, r) ? [NSString stringWithUTF8String:r] : path; };
            pid_t ag[7];
            // the agent's own CLAUDE_CONFIG_DIR decides where its session file is read: unset -> ~/.claude only
            NSString *agentEnv[7] = {nil, [tmp stringByAppendingPathComponent:@"custom"], [home stringByAppendingPathComponent:@".claude-alt"], nil, nil, nil, [home stringByAppendingPathComponent:@".claude-work"]};
            for (int i = 0; i < 7; i++) ag[i] = spawn(claudeStub, @"claude", agentEnv[i], @"plain");
            for (int i = 0; i < 7; i++) wait(ag[i]);

        // uuid extraction
        CHECK([[MicaAgentDiscover codexSessionIDFromRolloutPath:[NSString stringWithFormat:@"/x/rollout-2026-10-29T22-31-18-%@.jsonl", uuid]] isEqualToString:uuid]);
        CHECK(![MicaAgentDiscover codexSessionIDFromRolloutPath:@"/x/rollout-2026-bad.jsonl"]);
        CHECK(![MicaAgentDiscover codexSessionIDFromRolloutPath:[NSString stringWithFormat:@"/x/other-%@.jsonl", uuid]]);
        CHECK(![MicaAgentDiscover codexSessionIDFromRolloutPath:[NSString stringWithFormat:@"/x/rollout-%@.json", uuid]]);

        // claude: default dir, env override, cwd mismatch, extra .claude-* dir, invalid id
        Write([home stringByAppendingFormat:@"/.claude/sessions/%d.json", ag[0]],
              [NSString stringWithFormat:@"{\"pid\":111,\"sessionId\":\"aaaaaaaa-1111\",\"cwd\":\"%@\"}", work]);
        NSDictionary *r = [MicaAgentDiscover discoverForPids:@[@(ag[0])] cwd:work home:home env:@{}];
        CHECK([r[@"kind"] isEqual:@"claude"] && [r[@"sessionID"] isEqual:@"aaaaaaaa-1111"]);
        CHECK(![MicaAgentDiscover discoverForPids:@[@(ag[0])] cwd:@"/somewhere/else" home:home env:@{}]);
        CHECK(![MicaAgentDiscover discoverForPids:@[@(ag[1])] cwd:work home:home env:@{}]);
        NSString *custom = [tmp stringByAppendingPathComponent:@"custom"];
        Write([custom stringByAppendingFormat:@"/sessions/%d.json", ag[1]], @"{\"sessionId\":\"bbbbbbbb-2222\"}");
        r = [MicaAgentDiscover discoverForPids:@[@(ag[1])] cwd:work home:home env:@{@"CLAUDE_CONFIG_DIR": custom}];
        CHECK([r[@"sessionID"] isEqual:@"bbbbbbbb-2222"]);
        Write([home stringByAppendingFormat:@"/.claude-alt/sessions/%d.json", ag[2]], @"{\"sessionId\":\"cccccccc-3333\"}");
        r = [MicaAgentDiscover discoverForPids:@[@(ag[2])] cwd:work home:home env:@{}];
        CHECK([r[@"sessionID"] isEqual:@"cccccccc-3333"]);
        NSArray *dirs = [MicaAgentDiscover claudeConfigDirsForHome:home env:@{@"CLAUDE_CONFIG_DIR": [home stringByAppendingPathComponent:@".claude"]}];
        CHECK(dirs.count == 2);
        Write([home stringByAppendingFormat:@"/.claude/sessions/%d.json", ag[3]], @"{\"sessionId\":\"bad id;rm\"}");
        CHECK(![MicaAgentDiscover discoverForPids:@[@(ag[3])] cwd:work home:home env:@{}]);
        Write([home stringByAppendingFormat:@"/.claude/sessions/%d.json", ag[4]], @"not json");
        CHECK(![MicaAgentDiscover discoverForPids:@[@(ag[4])] cwd:work home:home env:@{}]);

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
            NSString *sf = [home stringByAppendingFormat:@"/.claude/sessions/%d.json", ag[5]];
            Write(sf, [NSString stringWithFormat:@"{\"sessionId\":\"%@\",\"cwd\":\"%@\"}", rid1, work]);
            NSDictionary *res = [MicaAgentDiscover resolveResumeForPids:@[@(ag[5])] cwd:work command:nil home:home env:@{}
                currentKind:nil currentID:nil fromHook:NO resolvedID:nil excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"set"] && [res[@"sessionID"] isEqual:rid1] && [res[@"launchResolved"] boolValue]);
            res = [MicaAgentDiscover resolveResumeForPids:@[@(ag[5])] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:rid1 fromHook:NO resolvedID:rid1 excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"none"]);
            Write(sf, [NSString stringWithFormat:@"{\"sessionId\":\"%@\",\"cwd\":\"%@\"}", rid2, work]);
            res = [MicaAgentDiscover resolveResumeForPids:@[@(ag[5])] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:rid1 fromHook:NO resolvedID:rid1 excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"set"] && [res[@"sessionID"] isEqual:rid2]);
            res = [MicaAgentDiscover resolveResumeForPids:@[] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:rid2 fromHook:NO resolvedID:rid2 excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"clear"]);
            res = [MicaAgentDiscover resolveResumeForPids:@[] cwd:work command:nil home:home env:@{}
                currentKind:@"claude" currentID:@"hookhook-id" fromHook:YES resolvedID:nil excludeIDs:nil];
            CHECK([res[@"action"] isEqual:@"set"] && [res[@"sessionID"] isEqual:@"hookhook-id"] && ![res[@"launchResolved"] boolValue]);
            res = [MicaAgentDiscover resolveResumeForPids:@[@(ag[5])] cwd:work command:nil home:home env:@{}
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
        CHECK(launch[@"configDir"] == nil);   // projects-scan hits are not trusted for launch info
        launch = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:cid pids:@[] command:nil home:home env:@{@"CLAUDE_CONFIG_DIR": workDir}];
        CHECK([launch[@"configDir"] isEqualToString:RP(workDir)]);   // Mica's own env dir holding the session
        launch = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:cid pids:@[]
            command:@"CLAUDE_CONFIG_DIR=~/.claude-work claude --dangerously-skip-permissions" home:home env:@{}];
        CHECK([launch[@"flags"] isEqual:@[@"--dangerously-skip-permissions"]]);
        // sessions/<pid>.json hit carries its config dir
        Write([workDir stringByAppendingFormat:@"/sessions/%d.json", ag[6]], [NSString stringWithFormat:@"{\"sessionId\":\"%@\",\"cwd\":\"%@\"}", cid, work]);
        NSDictionary *hit = [MicaAgentDiscover discoverForPids:@[@(ag[6])] cwd:work home:home env:@{}];
        CHECK([hit[@"kind"] isEqual:@"claude"] && [hit[@"configDir"] isEqualToString:RP(workDir)]);

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

        // Security: flags/config dir only from the verified agent pid
        {
            NSString *sid = @"abababab-1111-2222-3333-444444444444";
            NSString *legit = [home stringByAppendingPathComponent:@".claude-legit"];
            NSString *outside = [tmp stringByAppendingPathComponent:@"outside"];       // not under home
            NSString *nosess = [home stringByAppendingPathComponent:@".claude-nosess"]; // under home, no session
            [NSFileManager.defaultManager createDirectoryAtPath:nosess withIntermediateDirectories:YES attributes:nil error:nil];
            // 1. agent pid without flags + non-agent child with bypass flags -> no flags
            pid_t agent = spawn(claudeStub, @"claude", legit, @"plain");
            pid_t evil = spawn(otherStub, @"sh", nil, @"--dangerously-skip-permissions");
            wait(agent); wait(evil);
            Write([legit stringByAppendingFormat:@"/sessions/%d.json", agent], [NSString stringWithFormat:@"{\"sessionId\":\"%@\",\"cwd\":\"%@\"}", sid, work]);
            NSDictionary *d = nil;
            for (int i = 0; i < 50 && !d; i++) { d = [MicaAgentDiscover discoverForPids:@[@(evil), @(agent)] cwd:work home:home env:@{@"CLAUDE_CONFIG_DIR": legit}]; if (!d) usleep(20000); }
            CHECK([d[@"sessionID"] isEqual:sid]);
            CHECK(d[@"flags"] == nil);
            CHECK([d[@"configDir"] isEqualToString:RP(legit)]);   // legit temp dir under home containing the session
            NSDictionary *li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(evil), @(agent)] command:nil home:home env:@{}];
            CHECK(li[@"flags"] == nil);
            CHECK([li[@"configDir"] isEqualToString:RP(legit)]);  // from the verified agent's own env
            reap(agent); reap(evil);

            // 2. agent pid carrying flags -> taken (both paths)
            agent = spawn(claudeStub, @"claude", legit, @"--dangerously-skip-permissions");
            wait(agent);
            Write([legit stringByAppendingFormat:@"/sessions/%d.json", agent], [NSString stringWithFormat:@"{\"sessionId\":\"%@\"}", sid]);
            d = [MicaAgentDiscover discoverForPids:@[@(agent)] cwd:work home:home env:@{@"CLAUDE_CONFIG_DIR": legit}];
            CHECK([d[@"flags"] isEqual:@[@"--dangerously-skip-permissions"]]);
            li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(agent)] command:nil home:home env:@{}];
            CHECK([li[@"flags"] isEqual:@[@"--dangerously-skip-permissions"]]);
            reap(agent);

            // 3. pid owning the session file but executable not claude -> no flags, no env dir
            pid_t imposter = spawn(otherStub, @"sh", legit, @"--dangerously-skip-permissions");
            wait(imposter);
            Write([legit stringByAppendingFormat:@"/sessions/%d.json", imposter], [NSString stringWithFormat:@"{\"sessionId\":\"%@\"}", sid]);
            d = [MicaAgentDiscover discoverForPids:@[@(imposter)] cwd:work home:home env:@{@"CLAUDE_CONFIG_DIR": legit}];
            CHECK(d[@"flags"] == nil);
            li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(imposter)] command:nil home:home env:@{}];
            CHECK(li[@"flags"] == nil);
            reap(imposter);

            // 3b. same-user child forges ~/.claude-evil/sessions/<its pid>.json -> no configDir from discover or launch info
            NSString *evilDir = [home stringByAppendingPathComponent:@".claude-evil"];
            imposter = spawn(otherStub, @"sh", evilDir, @"plain");
            wait(imposter);
            Write([evilDir stringByAppendingFormat:@"/sessions/%d.json", imposter], [NSString stringWithFormat:@"{\"sessionId\":\"%@\"}", sid]);
            d = [MicaAgentDiscover discoverForPids:@[@(imposter)] cwd:work home:home env:@{}];
            CHECK(d == nil || d[@"configDir"] == nil);
            li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(imposter)] command:nil home:home env:@{}];
            CHECK(li[@"configDir"] == nil);
            reap(imposter);

            // 3c. a group-writable config dir is rejected even for the verified agent
            NSString *gw = [home stringByAppendingPathComponent:@".claude-gw"];
            agent = spawn(claudeStub, @"claude", gw, @"plain");
            wait(agent);
            Write([gw stringByAppendingFormat:@"/sessions/%d.json", agent], [NSString stringWithFormat:@"{\"sessionId\":\"%@\"}", sid]);
            chmod(gw.fileSystemRepresentation, 0775);
            li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(agent)] command:nil home:home env:@{}];
            CHECK(li[@"configDir"] == nil);
            chmod(gw.fileSystemRepresentation, 0755);
            li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(agent)] command:nil home:home env:@{}];
            CHECK([li[@"configDir"] isEqualToString:RP(gw)]);
            reap(agent);

            // 3d. decoy ~/.claude-aaa/sessions/<pid>.json never wins over the agent's own env dir; unset env -> no configDir
            NSString *realDir = [home stringByAppendingPathComponent:@".claude-zzz"], *decoy = [home stringByAppendingPathComponent:@".claude-aaa"];
            agent = spawn(claudeStub, @"claude", realDir, @"plain");
            pid_t noenv = spawn(claudeStub, @"claude", nil, @"plain");
            wait(agent); wait(noenv);
            NSString *body = [NSString stringWithFormat:@"{\"sessionId\":\"%@\"}", sid];
            Write([realDir stringByAppendingFormat:@"/sessions/%d.json", agent], body);
            Write([decoy stringByAppendingFormat:@"/sessions/%d.json", agent], body);
            Write([decoy stringByAppendingFormat:@"/sessions/%d.json", noenv], body);
            d = [MicaAgentDiscover discoverForPids:@[@(agent)] cwd:work home:home env:@{}];
            CHECK([d[@"configDir"] isEqualToString:RP(realDir)]);
            li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(agent)] command:nil home:home env:@{}];
            CHECK([li[@"configDir"] isEqualToString:RP(realDir)]);
            d = [MicaAgentDiscover discoverForPids:@[@(noenv)] cwd:work home:home env:@{}];
            CHECK(d == nil || d[@"configDir"] == nil);
            li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(noenv)] command:nil home:home env:@{}];
            CHECK(li[@"configDir"] == nil);
            reap(agent); reap(noenv);

            // 4. env dir outside home / without the session -> rejected
            Write([outside stringByAppendingFormat:@"/projects/-x/%@.jsonl", sid], @"{}\n");
            Write([outside stringByAppendingString:@"/sessions/1.json"], [NSString stringWithFormat:@"{\"sessionId\":\"%@\"}", sid]);
            NSString *sid2 = @"cdcdcdcd-1111-2222-3333-444444444444";
            Write([home stringByAppendingFormat:@"/.claude/projects/-y/%@.jsonl", sid2], @"{}\n");
            for (NSString *bad in @[outside, nosess]) {
                agent = spawn(claudeStub, @"claude", bad, @"plain");
                wait(agent);
                Write([bad stringByAppendingFormat:@"/sessions/%d.json", agent], [NSString stringWithFormat:@"{\"sessionId\":\"%@\"}", sid2]);
                if (bad == nosess) [NSFileManager.defaultManager removeItemAtPath:[bad stringByAppendingFormat:@"/sessions/%d.json", agent] error:nil];
                li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid2 pids:@[@(agent)] command:nil home:home env:@{}];
                CHECK(li[@"configDir"] == nil);
                reap(agent);
            }
            agent = spawn(claudeStub, @"claude", outside, @"plain");
            wait(agent);
            Write([outside stringByAppendingFormat:@"/sessions/%d.json", agent], [NSString stringWithFormat:@"{\"sessionId\":\"%@\"}", sid]);
            li = [MicaAgentDiscover launchInfoForKind:@"claude" sessionID:sid pids:@[@(agent)] command:nil home:home env:@{}];
            CHECK(li[@"configDir"] == nil);                    // session is there, but outside home
            d = [MicaAgentDiscover discoverForPids:@[@(agent)] cwd:work home:home env:@{@"CLAUDE_CONFIG_DIR": outside}];
            CHECK([d[@"sessionID"] isEqual:sid] && d[@"configDir"] == nil);
            reap(agent);
        }

        for (int i = 0; i < 7; i++) { kill(ag[i], SIGKILL); waitpid(ag[i], NULL, 0); }
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    puts("agent discover tests passed");
    return 0;
}
