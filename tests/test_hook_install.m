#import <Foundation/Foundation.h>
#import "mica_hook_install.h"
#import <sys/stat.h>

static void check(BOOL value, NSString *message) { if (!value) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
int main(void) {
 @autoreleasepool {
  NSString *home=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSString *claude=[home stringByAppendingPathComponent:@".claude/settings.json"], *codex=[home stringByAppendingPathComponent:@".codex/hooks.json"];
  NSError *e=nil; NSDictionary *preview=[MicaHookInstall previewForHome:home error:&e]; check(preview!=nil,@"empty preview");
  check([MicaHookInstall applyForHome:home remove:NO error:&e],@"empty install");
  [@"{\"before\":true}" writeToFile:claude atomically:YES encoding:NSUTF8StringEncoding error:nil];
  check([MicaHookInstall applyForHome:home remove:NO error:&e],@"install over existing");
  check([[NSFileManager defaultManager] fileExistsAtPath:[claude stringByAppendingString:@".mica-backup"]],@"backup created");
  NSData *installed=[NSData dataWithContentsOfFile:claude]; id root=[NSJSONSerialization JSONObjectWithData:installed options:0 error:nil]; check([root[@"hooks"][@"UserPromptSubmit"] count]==1,@"Claude events installed");
  check([MicaHookInstall applyForHome:home remove:NO error:&e],@"idempotent install");
  NSString *other=@"{\"model\":\"keep\",\"hooks\":{\"Stop\":[{\"matcher\":\"x\",\"hooks\":[{\"type\":\"command\",\"command\":\"other\"}]}]}}";
  [other writeToFile:claude atomically:YES encoding:NSUTF8StringEncoding error:nil];
  check([MicaHookInstall applyForHome:home remove:NO error:&e],@"merge existing");
  root=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:claude] options:0 error:nil];
  check([root[@"model"] isEqual:@"keep"] && [root[@"hooks"][@"Stop"] count]==2,@"existing keys and hooks retained");
  check([MicaHookInstall applyForHome:home remove:YES error:&e],@"remove");
  root=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:claude] options:0 error:nil];
  check([root[@"model"] isEqual:@"keep"] && [root[@"hooks"][@"Stop"] count]==1,@"remove retains unrelated semantic content");
  [@"{" writeToFile:claude atomically:YES encoding:NSUTF8StringEncoding error:nil]; e=nil;
  check([MicaHookInstall previewForHome:home error:&e]==nil && e!=nil,@"invalid JSON refused");
  check([claude hasPrefix:home] && [codex hasPrefix:home],@"all installer paths stay under temporary HOME");
  (void)codex;
  [[NSFileManager defaultManager] removeItemAtPath:home error:nil];
 }
 puts("hook installer temporary HOME merge, idempotence, remove, backup, invalid JSON passed"); return 0;
}
