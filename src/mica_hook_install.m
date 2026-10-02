#import "mica_hook_install.h"
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>

// Schema checked 2026-10-02: https://code.claude.com/docs/en/hooks
// and https://developers.openai.com/codex/hooks ; notify is documented as
// array<string> at https://developers.openai.com/codex/config-reference/.
static NSString *const MicaHookMarker = @"mica-hook";

@implementation MicaHookInstall

+ (NSString *)helperPath {
    NSString *path = NSBundle.mainBundle.bundleURL.path;
    if (![path hasSuffix:@".app"]) path = @"/Applications/Mica.app";
    return [path stringByAppendingPathComponent:@"Contents/Helpers/mica-hook"];
}

+ (BOOL)backup:(NSString *)path error:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    NSString *backup = [path stringByAppendingString:@".mica-backup"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:backup]) {
        NSDateFormatter *fmt = [NSDateFormatter new]; fmt.dateFormat = @"yyyyMMdd-HHmmss";
        backup = [path stringByAppendingFormat:@".%@-%@.mica-backup", [fmt stringFromDate:NSDate.date], NSUUID.UUID.UUIDString];
    }
    return [[NSFileManager defaultManager] copyItemAtPath:path toPath:backup error:error];
}

+ (BOOL)write:(NSData *)data path:(NSString *)path error:(NSError **)error {
    NSString *dir = path.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error];
    mode_t mode = 0600; struct stat st; if (stat(path.fileSystemRepresentation, &st) == 0) mode = st.st_mode & 07777;
    NSString *tmp = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".mica-%@.tmp", NSUUID.UUID.UUIDString]];
    if (![data writeToFile:tmp options:NSDataWritingAtomic error:error]) return NO;
    chmod(tmp.fileSystemRepresentation, mode);
    if (![self backup:path error:error]) { [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil]; return NO; }
    if (rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil]; return NO;
    }
    return YES;
}

+ (id)jsonAt:(NSString *)path missing:(id)fallback error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path]; if (!data) return fallback;
    id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error];
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    return value;
}

+ (NSDictionary *)previewForHome:(NSString *)home error:(NSError **)error {
    NSString *claude = [home stringByAppendingPathComponent:@".claude/settings.json"];
    NSString *codex = [home stringByAppendingPathComponent:@".codex/hooks.json"];
    id c = [self jsonAt:claude missing:@{} error:error]; if (!c) return nil;
    id x = [self jsonAt:codex missing:@{} error:error]; if (!x) return nil;
    NSArray *events = @[@"Notification", @"Stop", @"PermissionRequest", @"SessionStart", @"SessionEnd", @"UserPromptSubmit"];
    NSMutableDictionary *nextC = [c mutableCopy]; NSMutableDictionary *hooks = [nextC[@"hooks"] isKindOfClass:NSDictionary.class] ? [nextC[@"hooks"] mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *event in events) {
        NSMutableArray *groups = [hooks[event] isKindOfClass:NSArray.class] ? [hooks[event] mutableCopy] : [NSMutableArray array];
        BOOL exists = NO; for (NSDictionary *g in groups) for (NSDictionary *h in g[@"hooks"]) if ([h[@"command"] containsString:MicaHookMarker]) exists = YES;
        if (!exists) [groups addObject:@{@"hooks":@[@{@"type":@"command", @"command":[NSString stringWithFormat:@"%@ %@", self.helperPath,event]}]}];
        hooks[event] = groups;
    }
    nextC[@"hooks"] = hooks;
    NSMutableDictionary *nextX = [x mutableCopy]; NSMutableDictionary *xh = [nextX[@"hooks"] isKindOfClass:NSDictionary.class] ? [nextX[@"hooks"] mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *event in @[@"SessionStart", @"Stop", @"SessionEnd"]) {
        NSMutableArray *groups = [xh[event] isKindOfClass:NSArray.class] ? [xh[event] mutableCopy] : [NSMutableArray array];
        NSString *command = [NSString stringWithFormat:@"%@ %@", self.helperPath,event]; BOOL exists=NO;
        for (NSDictionary *g in groups) for (NSDictionary *h in g[@"hooks"]) if ([h[@"command"] containsString:MicaHookMarker]) exists=YES;
        if (!exists) [groups addObject:@{@"hooks":@[@{@"type":@"command",@"command":command}]}]; xh[event]=groups;
    }
    nextX[@"hooks"] = xh;
    NSData *cd = [NSJSONSerialization dataWithJSONObject:nextC options:NSJSONWritingPrettyPrinted error:error]; if (!cd) return nil;
    NSData *xd = [NSJSONSerialization dataWithJSONObject:nextX options:NSJSONWritingPrettyPrinted error:error]; if (!xd) return nil;
    return @{@"claudePath":claude,@"claudePreview":[[NSString alloc] initWithData:cd encoding:NSUTF8StringEncoding],@"codexPath":codex,@"codexPreview":[[NSString alloc] initWithData:xd encoding:NSUTF8StringEncoding],@"note":@"Existing Codex config.toml notify is preserved; TOML notify is not changed by this installer."};
}

+ (BOOL)applyForHome:(NSString *)home remove:(BOOL)remove error:(NSError **)error {
    NSDictionary *p = [self previewForHome:home error:error]; if (!p) return NO;
    for (NSString *key in @[@"claudePath", @"codexPath"]) {
        NSString *path=p[key]; NSData *raw=[NSData dataWithContentsOfFile:path]; if (!raw && remove) continue;
        if (remove) {
            id root=[self jsonAt:path missing:@{} error:error]; if (!root) return NO;
            NSMutableDictionary *out=[root mutableCopy]; NSMutableDictionary *hooks=[out[@"hooks"] mutableCopy];
            for (NSString *event in [hooks.allKeys copy]) {
                NSMutableArray *groups=[NSMutableArray array];
                for (NSDictionary *group in hooks[event]) {
                    NSMutableArray *handlers=[NSMutableArray array]; for (NSDictionary *h in group[@"hooks"]) if (![h[@"command"] containsString:MicaHookMarker]) [handlers addObject:h];
                    if (handlers.count) { NSMutableDictionary *g=[group mutableCopy];g[@"hooks"]=handlers;[groups addObject:g]; }
                }
                if (groups.count) hooks[event]=groups; else [hooks removeObjectForKey:event];
            }
            if (hooks.count) out[@"hooks"]=hooks; else [out removeObjectForKey:@"hooks"];
            NSData *d=[NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:error]; if (!d) return NO;
            if (raw && ![self write:d path:path error:error]) return NO;
        } else {
            NSString *preview=p[[key isEqualToString:@"claudePath"]?@"claudePreview":@"codexPreview"];
            if (![self write:[preview dataUsingEncoding:NSUTF8StringEncoding] path:path error:error]) return NO;
        }
    }
    return YES;
}

+ (void)presentFromWindow:(NSWindow *)window {
    NSError *error=nil; NSDictionary *p=[self previewForHome:NSHomeDirectory() error:&error];
    NSAlert *alert=[NSAlert new]; alert.messageText=@"Set Up Agent Hooks";
    alert.informativeText=p ? [NSString stringWithFormat:@"Install changes these files. Existing keys and hooks are preserved.\n\n%@\n\n%@\n\nCodex note: %@",p[@"claudePath"],p[@"codexPath"],p[@"note"]] : [NSString stringWithFormat:@"Cannot preview hook changes: %@",error.localizedDescription];
    NSTextView *text=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,620,300)]; text.editable=NO; text.font=[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    if (p) text.string=[NSString stringWithFormat:@"--- %@ (complete resulting JSON) ---\n%@\n\n--- %@ (complete resulting JSON) ---\n%@",p[@"claudePath"],p[@"claudePreview"],p[@"codexPath"],p[@"codexPreview"]];
    else text.string=alert.informativeText;
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,620,300)]; scroll.hasVerticalScroller=YES; scroll.documentView=text; alert.accessoryView=scroll;
    [alert addButtonWithTitle:@"Install"]; [alert addButtonWithTitle:@"Remove"]; [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        if (result!=NSAlertFirstButtonReturn && result!=NSAlertSecondButtonReturn) return;
        NSError *writeError=nil; BOOL ok=[self applyForHome:NSHomeDirectory() remove:(result==NSAlertSecondButtonReturn) error:&writeError];
        if (!ok) { NSAlert *e=[NSAlert new]; e.messageText=@"Agent hooks were not changed"; e.informativeText=writeError.localizedDescription ?: @"Unknown error"; [e beginSheetModalForWindow:window completionHandler:nil]; }
    }];
}
@end
