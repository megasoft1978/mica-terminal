#import <Foundation/Foundation.h>
#import "mica_hook_install.h"
#import <sys/stat.h>

static void check(BOOL ok, NSString *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
static NSString *home(void) { return [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]; }
static NSString *config(NSString *h) { return [h stringByAppendingPathComponent:@".codex/config.toml"]; }
static void put(NSString *path, NSData *data) { [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]; check([data writeToFile:path atomically:YES],@"write fixture"); }
static NSData *bytesAt(NSString *path) { return [NSData dataWithContentsOfFile:path]; }
static void clean(NSString *h) { [[NSFileManager defaultManager] removeItemAtPath:h error:nil]; }

int main(void) {
 @autoreleasepool {
  NSError *e=nil; NSString *h=home(), *p=config(h);
  NSDictionary *preview=[MicaHookInstall previewForHome:h env:@{} error:&e]; check(preview!=nil,@"empty home preview");
  check([MicaHookInstall applyForHome:h env:@{} remove:NO error:&e],@"empty home install");
  NSString *line=preview[@"codexLine"]; NSString *installed=[[NSString alloc] initWithData:bytesAt(p) encoding:NSUTF8StringEncoding];
  check([installed containsString:line] && [[NSFileManager defaultManager] fileExistsAtPath:p],@"empty home config created with notify");
  struct stat st; check(stat(p.fileSystemRepresentation,&st)==0 && (st.st_mode&0777)==0600,@"new config mode 0600"); clean(h);

  h=home(); p=config(h); NSString *tables=@"# keep\n[model]\nname = \"x\"\n"; put(p,[tables dataUsingEncoding:NSUTF8StringEncoding]);
  check([MicaHookInstall applyForHome:h env:@{} remove:NO error:&e],@"tables only install"); installed=[[NSString alloc] initWithData:bytesAt(p) encoding:NSUTF8StringEncoding];
  check([installed hasPrefix:[NSString stringWithFormat:@"# keep\n%@\n[model]",line]],@"notify inserted before first table");
  NSArray *files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:p.stringByDeletingLastPathComponent error:nil]; BOOL backup=NO;
  for(NSString *f in files) if([f hasPrefix:@"config.toml.mica-backup-"]) backup=YES;
  check(backup,@"timestamped backup created"); clean(h);

  h=home(); p=config(h); NSString *own=@"notify = [\"my-notifier\"]\n[table]\nx=1\n"; put(p,[own dataUsingEncoding:NSUTF8StringEncoding]); NSData *before=bytesAt(p);
  preview=[MicaHookInstall previewForHome:h env:@{} error:&e]; check([preview[@"codexUnchanged"] boolValue],@"foreign notify marked unchanged");
  check([preview[@"codexPreview"] isEqual:@"Codex already has a notify command; Mica left it unchanged"],@"own notify preview note");
  check([MicaHookInstall applyForHome:h env:@{} remove:NO error:&e] && [bytesAt(p) isEqual:before],@"own notify left byte-identical"); clean(h);

  h=home(); p=config(h); NSString *mica=[NSString stringWithFormat:@"# before\n%@\n[keep]\na = 1\n",line]; put(p,[mica dataUsingEncoding:NSUTF8StringEncoding]); before=bytesAt(p);
  check([MicaHookInstall applyForHome:h env:@{} remove:NO error:&e] && [bytesAt(p) isEqual:before],@"existing Mica line idempotent");
  check([MicaHookInstall applyForHome:h env:@{} remove:YES error:&e],@"remove Mica line");
  check([[NSString alloc] initWithData:bytesAt(p) encoding:NSUTF8StringEncoding] && [bytesAt(p) isEqual:[@"# before\n[keep]\na = 1\n" dataUsingEncoding:NSUTF8StringEncoding]],@"remove preserves other bytes"); clean(h);

  h=home(); p=config(h); const unsigned char invalid[]={0xff,0xfe}; put(p,[NSData dataWithBytes:invalid length:sizeof(invalid)]); before=bytesAt(p); e=nil;
  check(![MicaHookInstall applyForHome:h env:@{} remove:NO error:&e] && e && [bytesAt(p) isEqual:before],@"invalid UTF-8 refused without mutation"); clean(h);
  h=home(); p=config(h); NSMutableData *large=[NSMutableData dataWithLength:262145]; put(p,large); before=bytesAt(p); e=nil;
  check(![MicaHookInstall applyForHome:h env:@{} remove:NO error:&e] && [bytesAt(p) isEqual:before],@"oversized config refused"); clean(h);
  NSString *root=home(); h=[root stringByAppendingPathComponent:@"home"];
  NSString *external=[root stringByAppendingPathComponent:@"external"];
  NSString *normal=[h stringByAppendingPathComponent:@".claude"];
  NSString *work=[h stringByAppendingPathComponent:@".claude-work"];
  NSString *foo=[h stringByAppendingPathComponent:@".claude-foo"];
  [[NSFileManager defaultManager] createDirectoryAtPath:foo withIntermediateDirectories:YES attributes:nil error:nil];
  NSData *fixture=[@"{\"other\":42,\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"other-hook\"}]}]}}" dataUsingEncoding:NSUTF8StringEncoding];
  for (NSString *dir in @[external, normal, work]) put([dir stringByAppendingPathComponent:@"settings.json"],fixture);
  NSDictionary *env=@{@"CLAUDE_CONFIG_DIR":external};
  NSArray *dirs=[MicaHookInstall claudeConfigDirsForHome:h env:env];
  check([dirs isEqual:@[external,normal,work]],@"override, default and existing work directories ordered; empty foo excluded");
  check([[MicaHookInstall claudeConfigDirsForHome:h env:@{@"CLAUDE_CONFIG_DIR":normal}] isEqual:@[normal,work]],@"default override deduplicated");
  NSString *missing=[root stringByAppendingPathComponent:@"missing-config"];
  NSDictionary *missingEnv=@{@"CLAUDE_CONFIG_DIR":missing};
  check([[MicaHookInstall claudeConfigDirsForHome:h env:missingEnv] isEqual:@[normal,work]],@"nonexistent override not targeted");
  check([MicaHookInstall applyForHome:h env:missingEnv remove:NO error:&e] && ![[NSFileManager defaultManager] fileExistsAtPath:missing],@"nonexistent override not created by install");
  preview=[MicaHookInstall previewForHome:h env:env error:&e];
  check([preview[@"claudeTargets"] count]==3 && [preview[@"claudePath"] isEqual:[external stringByAppendingPathComponent:@"settings.json"]] && [preview[@"claudePreview"] isEqual:preview[@"claudeTargets"][0][@"preview"]],@"preview exposes all targets and compatibility keys");
  check([MicaHookInstall applyForHome:h env:env remove:NO error:&e],@"install all Claude targets");
  for (NSString *dir in dirs) {
      NSDictionary *json=[NSJSONSerialization JSONObjectWithData:bytesAt([dir stringByAppendingPathComponent:@"settings.json"]) options:0 error:&e];
      check([json[@"other"] isEqual:@42] && [json[@"hooks"][@"Stop"] count]==2,@"install preserves other key and hook");
  }
  check([MicaHookInstall applyForHome:h env:env remove:YES error:&e],@"remove from all Claude targets");
  for (NSString *dir in dirs) {
      NSDictionary *json=[NSJSONSerialization JSONObjectWithData:bytesAt([dir stringByAppendingPathComponent:@"settings.json"]) options:0 error:&e];
      check([json[@"other"] isEqual:@42] && [json[@"hooks"][@"Stop"] count]==1 && [json[@"hooks"][@"Stop"][0][@"hooks"][0][@"command"] isEqual:@"other-hook"],@"remove preserves other key and hook");
  }
  clean(root);
  puts("hook installer Codex TOML temporary HOME cases passed");
 }
 return 0;
}
