#import "mica_project_history.h"

static NSString * const MicaProjectHistoryDefaultsKey = @"MicaRecentProjects";
static NSUInteger const MicaProjectHistoryMaximumCount = 10;

static NSString *CanonicalProjectPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return nil;

    NSString *expanded = [path stringByExpandingTildeInPath];
    if (![expanded isAbsolutePath]) return nil;

    NSString *canonical = [[expanded stringByStandardizingPath] stringByResolvingSymlinksInPath];
    return canonical.length ? canonical : nil;
}

@interface MicaProjectHistory ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, copy, readwrite) NSArray<NSDictionary<NSString *, NSString *> *> *projects;
@end

@implementation MicaProjectHistory

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (!self) return nil;

    _defaults = defaults;
    id stored = [defaults objectForKey:MicaProjectHistoryDefaultsKey];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *loaded = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];

    if ([stored isKindOfClass:NSArray.class]) {
        for (id candidate in (NSArray *)stored) {
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            id rawPath = candidate[@"path"];
            id rawName = candidate[@"name"];
            if (![rawPath isKindOfClass:NSString.class] || ![rawName isKindOfClass:NSString.class]) continue;
            NSString *path = CanonicalProjectPath(rawPath);
            NSString *name = rawName;
            if (!path || name.length == 0 || [seenPaths containsObject:path]) continue;
            [seenPaths addObject:path];
            [loaded addObject:@{@"path": path, @"name": name}];
            if (loaded.count == MicaProjectHistoryMaximumCount) break;
        }
    }

    _projects = [loaded copy];
    return self;
}

- (void)recordLayoutPath:(NSString *)path name:(NSString *)name {
    NSString *canonicalPath = CanonicalProjectPath(path);
    if (!canonicalPath || ![name isKindOfClass:NSString.class] || name.length == 0) return;

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *updated = [NSMutableArray arrayWithCapacity:MicaProjectHistoryMaximumCount];
    [updated addObject:@{@"path": canonicalPath, @"name": name}];
    for (NSDictionary<NSString *, NSString *> *project in self.projects) {
        if ([project[@"path"] isEqualToString:canonicalPath]) continue;
        [updated addObject:project];
        if (updated.count == MicaProjectHistoryMaximumCount) break;
    }

    self.projects = [updated copy];
    [self.defaults setObject:self.projects forKey:MicaProjectHistoryDefaultsKey];
}

- (void)clear {
    self.projects = @[];
    [self.defaults removeObjectForKey:MicaProjectHistoryDefaultsKey];
}

@end
