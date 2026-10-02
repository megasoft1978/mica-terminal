#import "mica_diagnostics.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t MicaDiagnosticsLock = PTHREAD_MUTEX_INITIALIZER;
static int MicaDiagnosticsFD = -1;
static BOOL MicaDiagnosticsEnabled = NO;
static NSURL *MicaDiagnosticsDirectoryURL;
static const off_t MicaDiagnosticsMaximumBytes = 1024 * 1024;

NSURL *MicaDiagnosticsLogDirectory(void) {
    @synchronized (NSFileManager.defaultManager) {
        if (!MicaDiagnosticsDirectoryURL) {
            const char *override = getenv("MICA_DIAGNOSTICS_LOG_DIR");
            if (override && override[0] == '/') {
                MicaDiagnosticsDirectoryURL = [NSURL fileURLWithPath:
                    [NSString stringWithUTF8String:override] isDirectory:YES];
            } else {
                NSURL *library = [[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory
                    inDomains:NSUserDomainMask] firstObject];
                if (library)
                    MicaDiagnosticsDirectoryURL = [library URLByAppendingPathComponent:@"Logs/Mica" isDirectory:YES];
            }
        }
        return MicaDiagnosticsDirectoryURL;
    }
}

static void MicaDiagnosticsWriteBytes(int fd, const void *bytes, size_t length) {
    const char *cursor = bytes;
    while (length) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return;
        cursor += written;
        length -= (size_t)written;
    }
}

void MicaDiagnosticsInitialize(void) {
    pthread_mutex_lock(&MicaDiagnosticsLock);
    if (!MicaDiagnosticsEnabled) {
        pthread_mutex_unlock(&MicaDiagnosticsLock);
        return;
    }
    if (MicaDiagnosticsFD >= 0) {
        pthread_mutex_unlock(&MicaDiagnosticsLock);
        return;
    }

    NSURL *directory = MicaDiagnosticsLogDirectory();
    NSError *directoryError = nil;
    if (!directory || ![NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @0700 } error:&directoryError]) {
        pthread_mutex_unlock(&MicaDiagnosticsLock);
        return;
    }

    // Each launch writes its own log; drop ones older than a week so the folder stays small.
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-7 * 24 * 3600];
    for (NSURL *old in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
            includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil]) {
        NSDate *modified = nil;
        [old getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        // Only delete Mica's own "<bundle>-<pid>.log" files, never other files or symlinks.
        NSNumber *isRegular = nil;
        [old getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
        NSString *name = old.lastPathComponent;
        BOOL ownName = [name rangeOfString:@"^.+-[0-9]+\\.log$" options:NSRegularExpressionSearch].location != NSNotFound;
        if (ownName && isRegular.boolValue && modified && [modified compare:cutoff] == NSOrderedAscending)
            [NSFileManager.defaultManager removeItemAtURL:old error:nil];
    }

    NSString *identifier = NSBundle.mainBundle.bundleIdentifier ?: @"com.megasoft78.mica";
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@".-_"];
    NSMutableString *safeIdentifier = [NSMutableString string];
    for (NSUInteger index = 0; index < identifier.length; index++) {
        unichar character = [identifier characterAtIndex:index];
        unichar safeCharacter = [allowed characterIsMember:character] ? character : (unichar)'_';
        [safeIdentifier appendFormat:@"%C", safeCharacter];
    }
    NSString *filename = [NSString stringWithFormat:@"%@-%d.log", safeIdentifier, getpid()];
    NSURL *fileURL = [directory URLByAppendingPathComponent:filename isDirectory:NO];
    MicaDiagnosticsFD = open(fileURL.fileSystemRepresentation,
        O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR);
    if (MicaDiagnosticsFD >= 0) {
        ftruncate(MicaDiagnosticsFD, 0);
        MicaDiagnosticsDirectoryURL = directory;
    }
    pthread_mutex_unlock(&MicaDiagnosticsLock);

    if (directoryError) MicaDiagnosticsLog(@"startup", @"could not create diagnostic log directory");
}

void MicaDiagnosticsSetEnabled(BOOL enabled) {
    pthread_mutex_lock(&MicaDiagnosticsLock);
    MicaDiagnosticsEnabled = enabled;
    if (!enabled && MicaDiagnosticsFD >= 0) {
        close(MicaDiagnosticsFD);
        MicaDiagnosticsFD = -1;
    }
    pthread_mutex_unlock(&MicaDiagnosticsLock);
    if (enabled) MicaDiagnosticsInitialize();
}

BOOL MicaDiagnosticsIsEnabled(void) {
    pthread_mutex_lock(&MicaDiagnosticsLock);
    BOOL enabled = MicaDiagnosticsEnabled;
    pthread_mutex_unlock(&MicaDiagnosticsLock);
    return enabled;
}

void MicaDiagnosticsLog(NSString *category, NSString *message) {
    if (!message.length) return;
    pthread_mutex_lock(&MicaDiagnosticsLock);
    if (!MicaDiagnosticsEnabled || MicaDiagnosticsFD < 0) {
        pthread_mutex_unlock(&MicaDiagnosticsLock);
        return;
    }

    struct stat fileStatus;
    if (fstat(MicaDiagnosticsFD, &fileStatus) == 0 && fileStatus.st_size > MicaDiagnosticsMaximumBytes) {
        ftruncate(MicaDiagnosticsFD, 0);
        lseek(MicaDiagnosticsFD, 0, SEEK_SET);
    }

    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    struct tm localTime;
    localtime_r(&now.tv_sec, &localTime);
    char timestamp[40];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S", &localTime);
    NSString *singleLine = [[message stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    NSString *line = [NSString stringWithFormat:@"%s.%03ld [%@] %@\n", timestamp,
        now.tv_nsec / 1000000, category.length ? category : @"app", singleLine];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length) MicaDiagnosticsWriteBytes(MicaDiagnosticsFD, data.bytes, data.length);
    pthread_mutex_unlock(&MicaDiagnosticsLock);
}
