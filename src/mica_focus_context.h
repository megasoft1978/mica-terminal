#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Per-project focus time for the focus band: owns the lazily loaded MicaFocusLog, the project and branch
// captured when a focus session starts, and a debounced off-main-thread save of the log's JSON.
@interface MicaFocusRecorder : NSObject
// Where the app keeps the log: MICA_TEST_FOCUS_LOG_PATH if set, nil (memory only) under MICA_TEST_NO_STARTUP,
// else ~/Library/Application Support/Mica/focus-log.json.
+ (nullable NSString *)defaultLogPath;
// Local calendar day as yyyymmdd.
+ (NSString *)dayKeyForDate:(NSDate *)date;

// nil path keeps the log in memory only.
- (instancetype)initWithPath:(nullable NSString *)path;

// Project and branch of the tab that was active when the current focus session started.
@property(nonatomic, copy, nullable) NSString *activeProject;
@property(nonatomic, copy, nullable) NSString *activeBranch;

// Adds elapsed focus seconds under the day of `date`. Ignores values below minimumSeconds. Returns YES if recorded.
- (BOOL)recordSeconds:(double)seconds project:(NSString *)project branch:(nullable NSString *)branch
                 date:(NSDate *)date minimumSeconds:(double)minimumSeconds;

// Rows shaped for MicaFocusBandState.projectRows: @{project, branch, seconds, sessions}.
- (NSArray<NSDictionary *> *)rowsForDayKey:(NSString *)dayKey;
- (double)totalSecondsForDayKey:(NSString *)dayKey;
- (NSInteger)sessionsForDayKey:(NSString *)dayKey;

// Writes any unsaved changes now (waits for the writer queue). Called at termination and by tests.
- (void)flush;
@end

NS_ASSUME_NONNULL_END
