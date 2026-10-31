#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Hookless discovery of the Claude Code / Codex session id behind a tab's process tree.
// Foundation only; the environment is injected so tests never touch the real user config.
@interface MicaAgentDiscover : NSObject

// Returns @{@"kind": @"claude"|@"codex", @"sessionID": ..., optional @"configDir" (claude), @"flags" (allowlisted)} or nil.
// Every id passes MicaResumeCommand.
+ (nullable NSDictionary *)discoverForPids:(NSArray<NSNumber *> *)pids cwd:(NSString *)cwd home:(NSString *)home env:(NSDictionary *)env;

// Launch info (configDir/flags) for an already known session id: flags from the process argv/tab command,
// Claude config dir from the process environment, else the config dir holding projects/*/<id>.jsonl.
+ (NSDictionary *)launchInfoForKind:(NSString *)kind sessionID:(NSString *)sessionID pids:(NSArray<NSNumber *> *)pids
                           command:(nullable NSString *)command home:(NSString *)home env:(NSDictionary *)env;
+ (nullable NSString *)claudeConfigDirForSessionID:(NSString *)sessionID home:(NSString *)home env:(NSDictionary *)env;
// KERN_PROCARGS2 buffer -> @{@"argv": [..], @"env": {..}}; nil if malformed.
+ (nullable NSDictionary *)parseProcArgs:(NSData *)data;
+ (nullable NSDictionary *)processArgsForPid:(pid_t)pid;
// Tokens (argv or a typed command line) -> allowlisted flags.
+ (NSArray<NSString *> *)agentFlagsForKind:(NSString *)kind tokens:(NSArray<NSString *> *)tokens;
+ (NSDictionary *)launchInfoFromCommand:(NSString *)command kind:(NSString *)kind home:(NSString *)home;

// Pure helpers (no live agent needed).
+ (NSArray<NSString *> *)claudeConfigDirsForHome:(NSString *)home env:(NSDictionary *)env;
+ (nullable NSString *)claudeSessionIDFromFile:(NSString *)path cwd:(nullable NSString *)cwd;
+ (nullable NSString *)codexSessionIDFromRolloutPath:(NSString *)path;
+ (NSString *)codexSessionsRootForHome:(NSString *)home env:(NSDictionary *)env;
// Exactly-one-candidate chooser: rollout files under `roots` (directories, non-recursive) with mtime >= start
// whose first-line session_meta cwd equals `cwd`.
+ (nullable NSString *)codexFallbackSessionIDInRoots:(NSArray<NSString *> *)roots cwd:(NSString *)cwd processStart:(NSTimeInterval)start;
// Same, but the rollout's creation date must be within [start-2s, start+60s] and ids in `exclude` (owned by other tabs) are dropped
// before the exactly-one check.
+ (nullable NSString *)codexFallbackSessionIDInRoots:(NSArray<NSString *> *)roots cwd:(NSString *)cwd processStart:(NSTimeInterval)start
                                          excludeIDs:(nullable NSSet<NSString *> *)exclude;
+ (nullable NSDictionary *)discoverForPids:(NSArray<NSNumber *> *)pids cwd:(NSString *)cwd home:(NSString *)home env:(NSDictionary *)env
                                excludeIDs:(nullable NSSet<NSString *> *)exclude;

// Whole per-tab merge, so the AppKit frontend only gathers inputs and applies the result.
// Returns @{@"action": @"none"} | @{@"action": @"clear"} |
//   @{@"action": @"set", @"kind", @"sessionID", optional @"configDir", optional @"flags", @"launchResolved": @YES/@NO}.
// Hook-supplied ids are never replaced or cleared; discovered ids are re-discovered each pass and replaced when they change,
// and cleared once no descendant pids remain.
+ (NSDictionary *)resolveResumeForPids:(NSArray<NSNumber *> *)pids cwd:(NSString *)cwd command:(nullable NSString *)command
                                  home:(NSString *)home env:(NSDictionary *)env
                           currentKind:(nullable NSString *)kind currentID:(nullable NSString *)identifier
                            fromHook:(BOOL)hooked resolvedID:(nullable NSString *)resolvedID excludeIDs:(nullable NSSet<NSString *> *)exclude;

@end

NS_ASSUME_NONNULL_END
