#import "mica_hook_install.h"
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>

// Codex config-reference checked 2026-10-02:
// https://developers.openai.com/docs/config-file/config-reference ; user-level
// notify is a top-level array of argv strings (agent-turn-complete event).
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

+ (NSString *)codexLine { return [NSString stringWithFormat:@"notify = [\"%@\", \"codex-notify\"]  # mica-hook", self.helperPath]; }

+ (BOOL)backupCodex:(NSString *)path error:(NSError **)error {
    NSDateFormatter *fmt=[NSDateFormatter new]; fmt.dateFormat=@"yyyyMMddHHmmss";
    NSString *backup=[path stringByAppendingFormat:@".mica-backup-%@",[fmt stringFromDate:NSDate.date]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:backup]) {
        if (error) *error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError userInfo:@{NSLocalizedDescriptionKey:@"A Codex config backup already exists for this second."}];
        return NO;
    }
    return [[NSFileManager defaultManager] copyItemAtPath:path toPath:backup error:error];
}

+ (BOOL)editCodexAtPath:(NSString *)path remove:(BOOL)remove error:(NSError **)error {
    NSData *data=[NSData dataWithContentsOfFile:path];
    if (!data && [[NSFileManager defaultManager] fileExistsAtPath:path]) { if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil]; return NO; }
    if (data.length>262144) { if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadTooLargeError userInfo:@{NSLocalizedDescriptionKey:@"Codex config.toml exceeds 256 KiB."}]; return NO; }
    NSString *contents=data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    if (!contents) { if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInapplicableStringEncodingError userInfo:@{NSLocalizedDescriptionKey:@"Codex config.toml is not valid UTF-8."}]; return NO; }
    NSArray *lines=[contents componentsSeparatedByString:@"\n"]; NSUInteger header=lines.count;
    NSRegularExpression *table=[NSRegularExpression regularExpressionWithPattern:@"^\\s*\\[\\[?.+\\]\\]?\\s*(?:#.*)?$" options:0 error:nil];
    for (NSUInteger i=0;i<lines.count;i++) if ([table numberOfMatchesInString:lines[i] options:0 range:NSMakeRange(0,[lines[i] length])]) { header=i; break; }
    NSRegularExpression *key=[NSRegularExpression regularExpressionWithPattern:@"^\\s*notify\\s*=" options:0 error:nil];
    BOOL found=NO, mica=NO;
    for (NSUInteger i=0;i<header;i++) if ([key numberOfMatchesInString:lines[i] options:0 range:NSMakeRange(0,[lines[i] length])]) { found=YES; if ([lines[i] containsString:@"# mica-hook"]) mica=YES; }
    NSString *next=contents;
    if (remove) {
        NSMutableArray *kept=[NSMutableArray array]; BOOL changed=NO;
        for (NSString *line in lines) { if ([line containsString:@"# mica-hook"]) { changed=YES; continue; } [kept addObject:line]; }
        if (!changed) return YES;
        next=[kept componentsJoinedByString:@"\n"];
    } else {
        if (found && !mica) return YES;
        if (mica) return YES;
        NSString *line=self.codexLine;
        if (header==lines.count) {
            if (contents.length && ![contents hasSuffix:@"\n"]) next=[contents stringByAppendingFormat:@"\n%@\n",line];
            else next=[contents stringByAppendingFormat:@"%@\n",line];
        } else {
            NSMutableArray *prefix=[[lines subarrayWithRange:NSMakeRange(0,header)] mutableCopy];
            [prefix addObject:line]; [prefix addObjectsFromArray:[lines subarrayWithRange:NSMakeRange(header,lines.count-header)]]; next=[prefix componentsJoinedByString:@"\n"];
        }
    }
    NSData *out=[next dataUsingEncoding:NSUTF8StringEncoding];
    NSString *dir=path.stringByDeletingLastPathComponent;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if (data && ![self backupCodex:path error:error]) return NO;
    NSString *tmp=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@".mica-codex-%@.tmp",NSUUID.UUID.UUIDString]];
    if (![out writeToFile:tmp options:0 error:error]) return NO;
    mode_t mode=0600; struct stat st; if (data && stat(path.fileSystemRepresentation,&st)==0) mode=st.st_mode&07777;
    chmod(tmp.fileSystemRepresentation,mode);
    if (rename(tmp.fileSystemRepresentation,path.fileSystemRepresentation)!=0) { if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil]; return NO; }
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
    NSString *codex = [home stringByAppendingPathComponent:@".codex/config.toml"];
    id c = [self jsonAt:claude missing:@{} error:error]; if (!c) return nil;
    NSArray *events = @[@"Notification", @"Stop", @"PermissionRequest", @"SessionStart", @"SessionEnd", @"UserPromptSubmit"];
    NSMutableDictionary *nextC = [c mutableCopy]; NSMutableDictionary *hooks = [nextC[@"hooks"] isKindOfClass:NSDictionary.class] ? [nextC[@"hooks"] mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *event in events) {
        NSMutableArray *groups = [hooks[event] isKindOfClass:NSArray.class] ? [hooks[event] mutableCopy] : [NSMutableArray array];
        BOOL exists = NO; for (NSDictionary *g in groups) for (NSDictionary *h in g[@"hooks"]) if ([h[@"command"] containsString:MicaHookMarker]) exists = YES;
        if (!exists) [groups addObject:@{@"hooks":@[@{@"type":@"command", @"command":[NSString stringWithFormat:@"%@ %@", self.helperPath,event]}]}];
        hooks[event] = groups;
    }
    nextC[@"hooks"] = hooks;
    NSData *cd = [NSJSONSerialization dataWithJSONObject:nextC options:NSJSONWritingPrettyPrinted error:error]; if (!cd) return nil;
    NSData *xd=[NSData dataWithContentsOfFile:codex]; NSString *xt=xd ? [[NSString alloc] initWithData:xd encoding:NSUTF8StringEncoding] : @"";
    if (xd.length>262144 || (xd && !xt)) { if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadInapplicableStringEncodingError userInfo:@{NSLocalizedDescriptionKey:@"Codex config.toml is invalid UTF-8 or exceeds 256 KiB."}]; return nil; }
    NSArray *xl=[(xt ?: @"") componentsSeparatedByString:@"\n"]; NSUInteger top=xl.count; NSRegularExpression *table=[NSRegularExpression regularExpressionWithPattern:@"^\\s*\\[\\[?.+\\]\\]?\\s*(?:#.*)?$" options:0 error:nil]; for(NSUInteger i=0;i<xl.count;i++) if([table numberOfMatchesInString:xl[i] options:0 range:NSMakeRange(0,[xl[i] length])]){top=i;break;}
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^\\s*notify\\s*=" options:0 error:nil]; BOOL own=NO,mica=NO;
    for(NSUInteger i=0;i<top;i++) if([re numberOfMatchesInString:xl[i] options:0 range:NSMakeRange(0,[xl[i] length])]) {own=YES;if([xl[i] containsString:@"# mica-hook"])mica=YES;}
    NSString *note=own&&!mica ? @"Codex already has a notify command; Mica left it unchanged" : mica ? @"Codex Mica notify is already installed" : self.codexLine;
    return @{@"claudePath":claude,@"claudePreview":[[NSString alloc] initWithData:cd encoding:NSUTF8StringEncoding],@"codexPath":codex,@"codexPreview":note,@"codexLine":self.codexLine,@"codexUnchanged":@(own&&!mica)};
}

+ (BOOL)applyForHome:(NSString *)home remove:(BOOL)remove error:(NSError **)error {
    NSDictionary *p = [self previewForHome:home error:error]; if (!p) return NO;
    for (NSString *key in @[@"claudePath"]) {
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
    return [self editCodexAtPath:p[@"codexPath"] remove:remove error:error];
}

+ (void)presentFromWindow:(NSWindow *)window {
    NSError *error=nil; NSDictionary *p=[self previewForHome:NSHomeDirectory() error:&error];
    NSAlert *alert=[NSAlert new]; alert.messageText=@"Set Up Agent Hooks";
    alert.informativeText=p ? [NSString stringWithFormat:@"Install changes these files. Existing keys and hooks are preserved.\n\n%@\n\n%@\n\nCodex: %@",p[@"claudePath"],p[@"codexPath"],p[@"codexPreview"]] : [NSString stringWithFormat:@"Cannot preview hook changes: %@",error.localizedDescription];
    NSTextView *text=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,620,300)]; text.editable=NO; text.font=[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    if (p) text.string=[NSString stringWithFormat:@"--- %@ (complete resulting JSON) ---\n%@\n\n--- %@ (Codex config.toml) ---\n%@\n",p[@"claudePath"],p[@"claudePreview"],p[@"codexPath"],p[@"codexPreview"]];
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
