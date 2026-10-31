#import "mica_agent_discover.h"
#import "mica_resume.h"

#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <limits.h>
#include <sys/sysctl.h>

static NSString *RealPath(NSString *path) {
    if (!path.length) return @"";
    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved)) return [NSString stringWithUTF8String:resolved];
    return path.stringByStandardizingPath;
}

static NSString *ValidID(NSString *kind, NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;
    return MicaResumeCommand(kind, identifier) ? identifier : nil;
}

@implementation MicaAgentDiscover

+ (NSArray<NSString *> *)claudeConfigDirsForHome:(NSString *)home env:(NSDictionary *)env {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *dir) {
        if (!dir.length) return;
        NSString *key = dir.stringByStandardizingPath;
        if ([seen containsObject:key]) return;
        [seen addObject:key];
        [dirs addObject:key];
    };
    id override = env[@"CLAUDE_CONFIG_DIR"];
    if ([override isKindOfClass:NSString.class]) add(override);
    if (!home.length) return dirs;
    add([home stringByAppendingPathComponent:@".claude"]);
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:home error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (![name hasPrefix:@".claude-"]) continue;
        NSString *full = [home stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] && isDir) add(full);
    }
    return dirs;
}

+ (NSString *)claudeSessionIDFromFile:(NSString *)path cwd:(NSString *)cwd {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data.length || data.length > 1 << 20) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    NSString *identifier = ValidID(@"claude", object[@"sessionId"]);
    if (!identifier) return nil;
    id fileCwd = object[@"cwd"];
    if ([fileCwd isKindOfClass:NSString.class] && [fileCwd length] && cwd.length &&
        ![RealPath(fileCwd) isEqualToString:RealPath(cwd)]) return nil;
    return identifier;
}

+ (NSString *)codexSessionIDFromRolloutPath:(NSString *)path {
    NSString *name = path.lastPathComponent;
    if (![name hasPrefix:@"rollout-"] || ![name hasSuffix:@".jsonl"]) return nil;
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.jsonl$" options:0 error:nil];
    });
    NSTextCheckingResult *match = [regex firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    if (!match) return nil;
    return ValidID(@"codex", [name substringWithRange:[match rangeAtIndex:1]]);
}

+ (NSString *)codexSessionsRootForHome:(NSString *)home env:(NSDictionary *)env {
    id override = env[@"CODEX_HOME"];
    NSString *base = [override isKindOfClass:NSString.class] && [override length] ? override : [home stringByAppendingPathComponent:@".codex"];
    return [base.stringByStandardizingPath stringByAppendingPathComponent:@"sessions"];
}

static NSString *RolloutCwd(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    NSMutableData *line = [NSMutableData data];
    BOOL done = NO;
    @try {
        while (!done && line.length < (1 << 20)) {
            NSData *chunk = [handle readDataOfLength:65536];
            if (!chunk.length) break;
            NSRange nl = [chunk rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, chunk.length)];
            if (nl.location != NSNotFound) { chunk = [chunk subdataWithRange:NSMakeRange(0, nl.location)]; done = YES; }
            [line appendData:chunk];
        }
    } @catch (NSException *e) { return nil; }
    [handle closeFile];
    if (!done) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"type"] isEqual:@"session_meta"]) return nil;
    id payload = object[@"payload"];
    id cwd = [payload isKindOfClass:NSDictionary.class] ? payload[@"cwd"] : nil;
    return [cwd isKindOfClass:NSString.class] ? cwd : nil;
}

+ (NSString *)codexFallbackSessionIDInRoots:(NSArray<NSString *> *)roots cwd:(NSString *)cwd processStart:(NSTimeInterval)start {
    return [self codexFallbackSessionIDInRoots:roots cwd:cwd processStart:start excludeIDs:nil];
}

+ (NSString *)codexFallbackSessionIDInRoots:(NSArray<NSString *> *)roots cwd:(NSString *)cwd processStart:(NSTimeInterval)start
                                 excludeIDs:(NSSet<NSString *> *)exclude {
    if (!cwd.length) return nil;
    NSString *wanted = RealPath(cwd);
    NSMutableSet<NSString *> *candidates = [NSMutableSet set];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger inspected = 0, listed = 0;   // caps keep a save-time pass cheap on huge session dirs
    for (NSString *root in roots) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil]) {
            if (inspected >= 100 || listed >= 400) break;
            listed++;
            NSString *identifier = [self codexSessionIDFromRolloutPath:name];
            if (!identifier || [exclude containsObject:identifier]) continue;
            NSString *full = [root stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            NSDate *modified = attrs[NSFileModificationDate], *created = attrs[NSFileCreationDate];
            if (!modified || modified.timeIntervalSince1970 < start) continue;
            if (!created || created.timeIntervalSince1970 < start - 2.0 || created.timeIntervalSince1970 > start + 60.0) continue;
            inspected++;
            NSString *fileCwd = RolloutCwd(full);
            if (fileCwd && [RealPath(fileCwd) isEqualToString:wanted]) [candidates addObject:identifier];
        }
    }
    return candidates.count == 1 ? candidates.anyObject : nil;
}

static NSArray<NSString *> *OpenVnodePaths(pid_t pid) {
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0 || bytes > 1 << 20) return @[];
    struct proc_fdinfo *fds = malloc((size_t)bytes);
    if (!fds) return @[];
    bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    NSMutableArray *paths = [NSMutableArray array];
    int count = bytes > 0 ? bytes / (int)sizeof(struct proc_fdinfo) : 0;
    for (int i = 0; i < count; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
        struct vnode_fdinfowithpath info;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof(info)) != (int)sizeof(info)) continue;
        NSString *path = [NSString stringWithUTF8String:info.pvip.vip_path];
        if (path.length) [paths addObject:path];
    }
    free(fds);
    return paths;
}

static BOOL IsCodexish(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    return strcasestr(strrchr(path, '/') ? strrchr(path, '/') + 1 : path, "codex") != NULL;
}

+ (NSDictionary *)discoverForPids:(NSArray<NSNumber *> *)pids cwd:(NSString *)cwd home:(NSString *)home env:(NSDictionary *)env {
    return [self discoverForPids:pids cwd:cwd home:home env:env excludeIDs:nil];
}

+ (NSDictionary *)discoverForPids:(NSArray<NSNumber *> *)pids cwd:(NSString *)cwd home:(NSString *)home env:(NSDictionary *)env
                       excludeIDs:(NSSet<NSString *> *)exclude {
    if (!pids.count || !home.length) return nil;
    for (NSString *dir in [self claudeConfigDirsForHome:home env:env]) {
        for (NSNumber *pid in pids) {
            NSString *file = [dir stringByAppendingFormat:@"/sessions/%d.json", pid.intValue];
            NSString *identifier = [self claudeSessionIDFromFile:file cwd:cwd];
            if (identifier) return [self resultForKind:@"claude" sessionID:identifier configDir:dir pids:pids home:home env:env];
        }
    }
    NSString *root = [self codexSessionsRootForHome:home env:env];
    NSArray<NSString *> *prefixes = @[[root stringByAppendingString:@"/"], [RealPath(root) stringByAppendingString:@"/"]];
    for (NSNumber *pid in pids) {
        for (NSString *path in OpenVnodePaths(pid.intValue)) {
            BOOL inside = NO;
            for (NSString *prefix in prefixes) if ([path hasPrefix:prefix]) inside = YES;
            if (!inside) continue;
            NSString *identifier = [self codexSessionIDFromRolloutPath:path];
            if (identifier) return [self resultForKind:@"codex" sessionID:identifier configDir:nil pids:pids home:home env:env];
        }
    }
    NSMutableSet<NSString *> *roots = [NSMutableSet set];
    NSMutableArray<NSString *> *rootList = [NSMutableArray array];
    NSTimeInterval earliest = 0;
    BOOL any = NO;
    for (NSNumber *pid in pids) {
        if (!IsCodexish(pid.intValue)) continue;
        struct proc_bsdinfo info;
        if (proc_pidinfo(pid.intValue, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != (int)sizeof(info)) continue;
        NSTimeInterval start = (NSTimeInterval)info.pbi_start_tvsec + info.pbi_start_tvusec / 1e6;
        if (!any || start < earliest) earliest = start;
        any = YES;
    }
    if (!any) return nil;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    for (NSDate *day in @[[NSDate dateWithTimeIntervalSince1970:earliest], NSDate.date, [NSDate dateWithTimeIntervalSinceNow:-86400]]) {
        NSDateComponents *c = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:day];
        NSString *dir = [root stringByAppendingFormat:@"/%04ld/%02ld/%02ld", (long)c.year, (long)c.month, (long)c.day];
        if ([roots containsObject:dir]) continue;
        [roots addObject:dir];
        [rootList addObject:dir];
    }
    NSString *identifier = [self codexFallbackSessionIDInRoots:rootList cwd:cwd processStart:earliest excludeIDs:exclude];
    return identifier ? [self resultForKind:@"codex" sessionID:identifier configDir:nil pids:pids home:home env:env] : nil;
}

+ (NSDictionary *)resolveResumeForPids:(NSArray<NSNumber *> *)pids cwd:(NSString *)cwd command:(NSString *)command
                                  home:(NSString *)home env:(NSDictionary *)env
                           currentKind:(NSString *)kind currentID:(NSString *)identifier
                              fromHook:(BOOL)hooked resolvedID:(NSString *)resolvedID excludeIDs:(NSSet<NSString *> *)exclude {
    NSDictionary *none = @{@"action": @"none"};
    BOOL haveID = identifier.length > 0;
    if (hooked && haveID) {
        if ([resolvedID isEqualToString:identifier]) return none;
        if (![kind isEqualToString:@"claude"] && ![kind isEqualToString:@"codex"]) return none;
        NSDictionary *info = [self launchInfoForKind:kind sessionID:identifier pids:pids command:command home:home env:env];
        NSMutableDictionary *out = [@{@"action": @"set", @"kind": kind, @"sessionID": identifier,
                                      @"launchResolved": @(pids.count > 0)} mutableCopy];
        if (info[@"configDir"]) out[@"configDir"] = info[@"configDir"];
        if (info[@"flags"]) out[@"flags"] = info[@"flags"];
        return out;
    }
    NSDictionary *hit = [self discoverForPids:pids cwd:cwd ?: home home:home env:env excludeIDs:exclude];
    if (!hit) {
        BOOL agentKind = [kind isEqualToString:@"claude"] || [kind isEqualToString:@"codex"];
        return (agentKind || haveID) && !pids.count ? @{@"action": @"clear"} : none;
    }
    if ([hit[@"sessionID"] isEqualToString:identifier] && [hit[@"kind"] isEqualToString:kind] && [resolvedID isEqualToString:identifier]) return none;
    NSDictionary *info = [self launchInfoForKind:hit[@"kind"] sessionID:hit[@"sessionID"] pids:pids command:command home:home env:env];
    NSMutableDictionary *out = [@{@"action": @"set", @"kind": hit[@"kind"], @"sessionID": hit[@"sessionID"], @"launchResolved": @YES} mutableCopy];
    NSString *dir = hit[@"configDir"] ?: info[@"configDir"];
    if (dir) out[@"configDir"] = dir;
    if (info[@"flags"]) out[@"flags"] = info[@"flags"];
    return out;
}

+ (NSDictionary *)resultForKind:(NSString *)kind sessionID:(NSString *)identifier configDir:(NSString *)dir
                           pids:(NSArray<NSNumber *> *)pids home:(NSString *)home env:(NSDictionary *)env {
    NSMutableDictionary *result = [@{@"kind": kind, @"sessionID": identifier} mutableCopy];
    NSString *safeDir = MicaSanitizedConfigDir(dir, home);
    if (safeDir) result[@"configDir"] = safeDir;
    NSArray *flags = [self flagsFromPids:pids kind:kind];
    if (flags.count) result[@"flags"] = flags;
    return result;
}

+ (NSArray<NSString *> *)flagsFromPids:(NSArray<NSNumber *> *)pids kind:(NSString *)kind {
    for (NSNumber *pid in pids) {
        NSArray *flags = [self agentFlagsForKind:kind tokens:[self processArgsForPid:pid.intValue][@"argv"]];
        if (flags.count) return flags;
    }
    return @[];
}

+ (NSDictionary *)parseProcArgs:(NSData *)data {
    if (data.length < sizeof(int) + 2) return nil;
    int argc = 0;
    memcpy(&argc, data.bytes, sizeof(int));
    if (argc < 0 || argc > 4096) return nil;
    const char *bytes = data.bytes;
    size_t length = data.length, i = sizeof(int);
    while (i < length && bytes[i] != 0) i++;          // executable path
    while (i < length && bytes[i] == 0) i++;          // padding
    NSMutableArray<NSString *> *argv = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary dictionary];
    int seen = 0;
    while (i < length) {
        size_t start = i;
        while (i < length && bytes[i] != 0) i++;
        if (i >= length && i == start) break;
        NSString *item = [[NSString alloc] initWithBytes:bytes + start length:i - start encoding:NSUTF8StringEncoding];
        i++;
        if (!item) { if (seen < argc) seen++; continue; }
        if (seen < argc) { [argv addObject:item]; seen++; continue; }
        NSRange eq = [item rangeOfString:@"="];
        if (eq.location != NSNotFound && eq.location > 0) env[[item substringToIndex:eq.location]] = [item substringFromIndex:eq.location + 1];
    }
    return @{@"argv": argv, @"env": env};
}

+ (NSDictionary *)processArgsForPid:(pid_t)pid {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0 || size > 1 << 20) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (sysctl(mib, 3, data.mutableBytes, &size, NULL, 0) != 0) return nil;
    data.length = size;
    return [self parseProcArgs:data];
}

+ (NSArray<NSString *> *)agentFlagsForKind:(NSString *)kind tokens:(NSArray<NSString *> *)tokens {
    if (![tokens isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *normal = [NSMutableArray array];
    for (id token in tokens) {
        if (![token isKindOfClass:NSString.class]) continue;
        NSRange eq = [token rangeOfString:@"="];
        if ([token hasPrefix:@"--"] && eq.location != NSNotFound) {
            [normal addObject:[token substringToIndex:eq.location]];
            [normal addObject:[token substringFromIndex:eq.location + 1]];
        } else [normal addObject:token];
    }
    return MicaSanitizedAgentFlags(kind, normal);
}

+ (NSDictionary *)launchInfoFromCommand:(NSString *)command kind:(NSString *)kind home:(NSString *)home {
    if (![command isKindOfClass:NSString.class] || !command.length || command.length > 4096) return @{};
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSString *configDir = nil;
    for (NSString *raw in [command componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (!raw.length) continue;
        NSString *token = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'\""]];
        if ([token hasPrefix:@"CLAUDE_CONFIG_DIR="]) {
            NSString *value = [[token substringFromIndex:@"CLAUDE_CONFIG_DIR=".length]
                stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'\""]];
            if ([value hasPrefix:@"~/"] && home.length) value = [home stringByAppendingString:[value substringFromIndex:1]];
            configDir = MicaSanitizedConfigDir(value, home);
        } else [tokens addObject:token];
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSArray *flags = [self agentFlagsForKind:kind tokens:tokens];
    if (flags.count) info[@"flags"] = flags;
    if (configDir && [kind isEqualToString:@"claude"]) info[@"configDir"] = configDir;
    return info;
}

+ (NSString *)claudeConfigDirForSessionID:(NSString *)sessionID home:(NSString *)home env:(NSDictionary *)env {
    if (!ValidID(@"claude", sessionID)) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in [self claudeConfigDirsForHome:home env:env]) {
        NSString *projects = [dir stringByAppendingPathComponent:@"projects"];
        for (NSString *name in [fm contentsOfDirectoryAtPath:projects error:nil]) {
            NSString *file = [[projects stringByAppendingPathComponent:name] stringByAppendingFormat:@"/%@.jsonl", sessionID];
            if ([fm fileExistsAtPath:file]) return dir;
        }
    }
    return nil;
}

+ (NSDictionary *)launchInfoForKind:(NSString *)kind sessionID:(NSString *)sessionID pids:(NSArray<NSNumber *> *)pids
                           command:(NSString *)command home:(NSString *)home env:(NSDictionary *)env {
    NSMutableDictionary *info = [[self launchInfoFromCommand:command kind:kind home:home] mutableCopy];
    if (!info[@"flags"]) {
        NSArray *flags = [self flagsFromPids:pids kind:kind];
        if (flags.count) info[@"flags"] = flags;
    }
    if ([kind isEqualToString:@"claude"] && !info[@"configDir"]) {
        for (NSNumber *pid in pids) {
            NSDictionary *args = [self processArgsForPid:pid.intValue];
            NSString *argvText = [args[@"argv"] componentsJoinedByString:@" "].lowercaseString;
            NSString *dir = MicaSanitizedConfigDir(args[@"env"][@"CLAUDE_CONFIG_DIR"], home);
            if (dir && [argvText containsString:@"claude"]) { info[@"configDir"] = dir; break; }
        }
        if (!info[@"configDir"]) {
            NSString *dir = MicaSanitizedConfigDir([self claudeConfigDirForSessionID:sessionID home:home env:env], home);
            if (dir) info[@"configDir"] = dir;
        }
    }
    return info;
}

@end
