#import "mica_resume.h"

NSString *MicaResumeCommand(NSString *kind, NSString *sessionID) {
    if (![kind isKindOfClass:NSString.class]) return nil;
    if (![kind isEqualToString:@"claude"] && ![kind isEqualToString:@"codex"]) return nil;
    if (![sessionID isKindOfClass:NSString.class] || sessionID.length < 8 || sessionID.length > 80) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    if ([sessionID rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    // First char must be alphanumeric so an id can never parse as a CLI option ("-x", "--help").
    unichar first = [sessionID characterAtIndex:0];
    if (!((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z') || (first >= '0' && first <= '9'))) return nil;
    if ([kind isEqualToString:@"claude"]) return [NSString stringWithFormat:@"claude --resume %@", sessionID];
    return [NSString stringWithFormat:@"codex resume %@", sessionID];
}

NSArray<NSString *> *MicaSanitizedAgentFlags(NSString *kind, NSArray *flags) {
    if (![kind isKindOfClass:NSString.class] || ![flags isKindOfClass:NSArray.class]) return @[];
    BOOL claude = [kind isEqualToString:@"claude"], codex = [kind isEqualToString:@"codex"];
    if (!claude && !codex) return @[];
    NSDictionary *codexValues = @{@"--sandbox": @[@"read-only", @"workspace-write", @"danger-full-access"],
                                  @"--ask-for-approval": @[@"untrusted", @"on-failure", @"on-request", @"never"]};
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSUInteger i = 0; i < flags.count && i < 16; i++) {
        NSString *flag = flags[i];
        if (![flag isKindOfClass:NSString.class]) continue;
        if (claude && [flag isEqualToString:@"--dangerously-skip-permissions"]) {
            if (![clean containsObject:flag]) [clean addObject:flag];
        } else if (codex && [flag isEqualToString:@"--dangerously-bypass-approvals-and-sandbox"]) {
            if (![clean containsObject:flag]) [clean addObject:flag];
        } else if (codex && codexValues[flag] && i + 1 < flags.count) {
            NSString *value = flags[i + 1];
            if ([value isKindOfClass:NSString.class] && [codexValues[flag] containsObject:value] && ![clean containsObject:flag]) {
                [clean addObject:flag];
                [clean addObject:value];
                i++;
            }
        }
    }
    return clean;
}

NSString *MicaSanitizedConfigDir(NSString *configDir, NSString *home) {
    if (![configDir isKindOfClass:NSString.class] || !configDir.isAbsolutePath || configDir.length > 1024) return nil;
    if ([configDir rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    if ([[configDir pathComponents] containsObject:@".."]) return nil;
    NSString *standard = configDir.stringByStandardizingPath;
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:standard isDirectory:&isDirectory] || !isDirectory) return nil;
    if (home.length && [standard isEqualToString:[home.stringByStandardizingPath stringByAppendingPathComponent:@".claude"]]) return nil;
    return standard;
}

NSString *MicaResumeCommandWithLaunch(NSString *kind, NSString *sessionID, NSString *configDir, NSArray *flags, NSString *home) {
    if (!MicaResumeCommand(kind, sessionID)) return nil;
    NSArray<NSString *> *safeFlags = MicaSanitizedAgentFlags(kind, flags);
    NSString *flagText = [safeFlags componentsJoinedByString:@" "];
    if ([kind isEqualToString:@"claude"]) {
        NSString *dir = MicaSanitizedConfigDir(configDir, home);
        NSString *prefix = dir ? [NSString stringWithFormat:@"CLAUDE_CONFIG_DIR='%@' ",
            [dir stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]] : @"";
        return [NSString stringWithFormat:@"%@claude %@--resume %@", prefix,
            flagText.length ? [flagText stringByAppendingString:@" "] : @"", sessionID];
    }
    return [NSString stringWithFormat:@"codex resume %@%@", sessionID, flagText.length ? [@" " stringByAppendingString:flagText] : @""];
}
