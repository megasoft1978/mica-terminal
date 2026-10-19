#import <Foundation/Foundation.h>
#import "mica_project_history.h"

static int failures;
static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

static NSString *CreateLayout(NSString *directory, NSString *filename) {
    NSString *path = [directory stringByAppendingPathComponent:filename];
    [@"{}\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}

int main(void) {
    @autoreleasepool {
        NSString *suiteName = [NSString stringWithFormat:@"MicaProjectHistoryTests.%@", NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSError *error = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
        Check(error == nil, @"creates isolated temporary layout directory");

        NSString *alpha = CreateLayout(directory, @"Alpha.mica");
        NSString *beta = CreateLayout(directory, @"Beta.mica");
        MicaProjectHistory *history = [[MicaProjectHistory alloc] initWithDefaults:defaults];
        Check(history.projects.count == 0, @"starts with an empty recent-project list");

        [history recordLayoutPath:alpha name:@"Alpha"];
        NSArray<NSDictionary *> *projects = history.projects;
        Check(projects.count == 1, @"records a project");
        Check([projects.firstObject[@"path"] isEqualToString:alpha] &&
              [projects.firstObject[@"name"] isEqualToString:@"Alpha"], @"stores project path and display name");

        MicaProjectHistory *reloaded = [[MicaProjectHistory alloc] initWithDefaults:defaults];
        Check(reloaded.projects.count == 1 && [reloaded.projects.firstObject[@"path"] isEqualToString:alpha],
              @"persists projects in the supplied defaults suite");

        NSString *canonicalAlpha = [directory stringByAppendingPathComponent:@"./Alpha.mica"];
        [history recordLayoutPath:beta name:@"Beta"];
        [history recordLayoutPath:canonicalAlpha name:@"Alpha renamed"];
        projects = history.projects;
        Check(projects.count == 2 && [projects[0][@"path"] isEqualToString:alpha],
              @"canonicalizes paths and moves a duplicate to the front");
        Check([projects[0][@"name"] isEqualToString:@"Alpha renamed"], @"refreshes the name when a project is reopened");

        [defaults setObject:@"not an array" forKey:@"MicaRecentProjects"];
        MicaProjectHistory *malformedTopLevel = [[MicaProjectHistory alloc] initWithDefaults:defaults];
        Check(malformedTopLevel.projects.count == 0, @"treats malformed top-level stored data as empty");
        [defaults setObject:@[@{ @"path": alpha, @"name": @"Alpha" },
                              @{ @"path": @42, @"name": @"Bad path" },
                              @{ @"path": beta },
                              @"not a dictionary"] forKey:@"MicaRecentProjects"];
        MicaProjectHistory *malformedEntries = [[MicaProjectHistory alloc] initWithDefaults:defaults];
        Check(malformedEntries.projects.count == 1 &&
              [malformedEntries.projects.firstObject[@"path"] isEqualToString:alpha],
              @"skips malformed stored project entries");

        for (NSUInteger index = 0; index < 15; index++) {
            NSString *filename = [NSString stringWithFormat:@"Project-%lu.mica", (unsigned long)index];
            [history recordLayoutPath:CreateLayout(directory, filename)
                                 name:[NSString stringWithFormat:@"Project %lu", (unsigned long)index]];
        }
        projects = history.projects;
        Check(projects.count == 10, @"caps recent projects at ten entries");
        Check([projects.firstObject[@"name"] isEqualToString:@"Project 14"] &&
              [projects.lastObject[@"name"] isEqualToString:@"Project 5"], @"orders projects newest first and drops oldest");

        [history clear];
        Check(history.projects.count == 0, @"clears the recent-project list");
        Check([[MicaProjectHistory alloc] initWithDefaults:defaults].projects.count == 0,
              @"persists clearing to the supplied defaults suite");

        [defaults removePersistentDomainForName:suiteName];
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
    if (failures) return 1;
    puts("Project history tests passed");
    return 0;
}
