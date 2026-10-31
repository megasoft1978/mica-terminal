#import "mica_focus_context.h"
#include "mica_focus_log.h"
#include <stdlib.h>

@implementation MicaFocusRecorder {
    NSString *_path;
    MicaFocusLog *_log;
    BOOL _dirty, _savePending;
    dispatch_queue_t _writer;
}

+ (NSString *)defaultLogPath {
    const char *override = getenv("MICA_TEST_FOCUS_LOG_PATH");
    if (override && override[0]) return @(override);
    if (getenv("MICA_TEST_NO_STARTUP")) return nil;
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    return [[support URLByAppendingPathComponent:@"Mica/focus-log.json"] path];
}

+ (NSString *)dayKeyForDate:(NSDate *)date {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        formatter.dateFormat = @"yyyyMMdd";
    });
    formatter.timeZone = NSTimeZone.localTimeZone;
    return [formatter stringFromDate:date];
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _writer = dispatch_queue_create("mica.focus-log.writer", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc { mica_focus_log_free(_log); }

// Load once, on first use.
- (MicaFocusLog *)log {
    if (!_log) {
        _log = mica_focus_log_new();
        if (_log && _path.length) mica_focus_log_load(_log, _path.fileSystemRepresentation);
    }
    return _log;
}

- (BOOL)recordSeconds:(double)seconds project:(NSString *)project branch:(NSString *)branch
                 date:(NSDate *)date minimumSeconds:(double)minimumSeconds {
    if (!(seconds >= minimumSeconds) || seconds <= 0 || !project.length || ![self log]) return NO;
    NSString *day = [MicaFocusRecorder dayKeyForDate:date];
    if (!mica_focus_log_add([self log], day.UTF8String, project.UTF8String, (branch ?: @"").UTF8String, seconds)) return NO;
    _dirty = YES;
    [self scheduleSave];
    return YES;
}

- (NSArray<NSDictionary *> *)rowsForDayKey:(NSString *)dayKey {
    MicaFocusLogEntry entries[64];
    size_t count = mica_focus_log_entries_for_day([self log], dayKey.UTF8String, entries, 64);
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++)
        [rows addObject:@{@"project": @(entries[i].project), @"branch": @(entries[i].branch),
                          @"seconds": @(entries[i].seconds), @"sessions": @(entries[i].sessions)}];
    return rows;
}

- (double)totalSecondsForDayKey:(NSString *)dayKey {
    return mica_focus_log_total_for_day([self log], dayKey.UTF8String);
}

- (NSInteger)sessionsForDayKey:(NSString *)dayKey {
    NSInteger sessions = 0;
    for (NSDictionary *row in [self rowsForDayKey:dayKey]) sessions += [row[@"sessions"] integerValue];
    return sessions;
}

#pragma mark Saving

- (void)scheduleSave {
    if (!_path.length || _savePending) return;
    _savePending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MicaFocusRecorder *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_savePending = NO;
        [strongSelf writeSnapshot];
    });
}

// Serializes on the calling (main) thread and hands the string to the serial writer queue.
- (void)writeSnapshot {
    if (!_dirty || !_log || !_path.length) return;
    char *json = mica_focus_log_to_json(_log);
    if (!json) return;
    NSString *snapshot = @(json);
    free(json);
    _dirty = NO;
    NSString *path = _path;
    dispatch_async(_writer, ^{
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        [snapshot writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

- (void)flush {
    [self writeSnapshot];
    dispatch_sync(_writer, ^{});
}
@end
