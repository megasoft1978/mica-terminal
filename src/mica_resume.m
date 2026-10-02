#import "mica_resume.h"

NSString *MicaResumeCommand(NSString *kind, NSString *sessionID) {
    if (![kind isKindOfClass:NSString.class]) return nil;
    if (![kind isEqualToString:@"claude"] && ![kind isEqualToString:@"codex"]) return nil;
    if (![sessionID isKindOfClass:NSString.class] || sessionID.length < 8 || sessionID.length > 80) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    if ([sessionID rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    if ([kind isEqualToString:@"claude"]) return [NSString stringWithFormat:@"claude --resume %@", sessionID];
    return [NSString stringWithFormat:@"codex resume %@", sessionID];
}
