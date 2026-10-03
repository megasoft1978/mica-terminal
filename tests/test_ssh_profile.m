#import <Foundation/Foundation.h>
#import "mica_ssh_profile.h"

static int failures;
static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

static NSDictionary *Profile(NSString *destination, NSString *directory) {
    return @{@"id": @"3A4A9A50-5CB5-4FC0-B69D-B873E029F05A", @"name": @"Studio",
             @"destination": destination, @"remoteDirectory": directory};
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        NSDictionary *normalized = MicaSSHProfileNormalize(Profile(@"studio", @""), &error);
        Check(normalized != nil && [normalized[@"destination"] isEqualToString:@"studio"], @"normalizes a valid profile");
        Check([MicaSSHProfileCommand(normalized) isEqualToString:@"'ssh' '-tt' 'studio'"], @"starts an interactive ssh PTY without an unnecessary remote command");

        NSString *path = @"/Users/me/Projects/O'Brien $(touch pwned) 東京";
        NSString *command = MicaSSHProfileCommand(Profile(@"user@studio", path));
        NSString *directory = NSTemporaryDirectory();
        NSString *shimDirectory = [directory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:shimDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *shim = [shimDirectory stringByAppendingPathComponent:@"ssh"];
        NSString *argumentsPath = [shimDirectory stringByAppendingPathComponent:@"arguments"];
        [@"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$MICA_TEST_ARGV\"\n"
            writeToFile:shim atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:shim error:nil];
        NSTask *task = [NSTask new];
        task.launchPath = @"/bin/zsh";
        task.arguments = @[@"-c", command];
        NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
        environment[@"PATH"] = [NSString stringWithFormat:@"%@:/usr/bin:/bin", shimDirectory];
        environment[@"MICA_TEST_ARGV"] = argumentsPath;
        task.environment = environment;
        NSError *launchError = nil;
        BOOL launched = [task launchAndReturnError:&launchError];
        if (launched) [task waitUntilExit];
        NSString *argumentText = [NSString stringWithContentsOfFile:argumentsPath encoding:NSUTF8StringEncoding error:nil];
        NSArray<NSString *> *arguments = [argumentText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        Check(launched && task.terminationStatus == 0 && arguments.count >= 4,
              @"runs generated command through a local fake ssh program");
        Check(arguments.count >= 3 && [arguments[0] isEqualToString:@"-tt"] &&
              [arguments[1] isEqualToString:@"user@studio"], @"passes PTY and destination as distinct local arguments");
        Check(arguments.count >= 3 && [arguments[2] isEqualToString:
              [NSString stringWithFormat:@"cd -- '%@' && exec \"${SHELL:-/bin/sh}\" -l",
               [path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]],
              @"passes the safely quoted remote folder command as one SSH argument");
        
        NSArray<NSString *> *badDestinations = @[@"-oProxyCommand=evil", @"studio;touch", @"user name@studio", @"host\n-oProxyCommand=evil", @"/tmp/host"];
        for (NSString *bad in badDestinations) {
            error = nil;
            Check(MicaSSHProfileNormalize(Profile(bad, @""), &error) == nil && error != nil,
                  [NSString stringWithFormat:@"rejects unsafe destination %@", bad]);
        }
        error = nil;
        Check(MicaSSHProfileNormalize(Profile(@"studio", @"bad\ncommand"), &error) == nil,
              @"rejects control characters in a remote folder");
        NSString *tildeCommand = MicaSSHProfileCommand(Profile(@"studio", @"~/Projects/Mica"));
        Check([tildeCommand containsString:@"\"$HOME\"/"] && [tildeCommand containsString:@"Projects/Mica"],
              @"expands a leading remote-home tilde without local expansion");
        Check(MicaSSHProfileNormalize(@{@"name":@"missing fields"}, NULL) == nil, @"rejects malformed stored profiles");
        Check(MicaSSHProfileMaximumCount == 64, @"has a bounded profile count");
    }
    if (failures) return 1;
    puts("SSH profile tests passed");
    return 0;
}
