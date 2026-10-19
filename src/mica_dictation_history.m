#import "mica_dictation_history.h"

#import <math.h>
#import <limits.h>
#import <sys/stat.h>

static const unsigned long long MicaDictationHistoryMaximumBytes = 2ull * 1024ull * 1024ull * 1024ull;
static const unsigned long long MicaDictationHistoryRecordOverheadBytes = 64ull * 1024ull;

@interface MicaDictationHistoryRecord : NSObject
@property(nonatomic, strong) NSURL *directoryURL;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *metadata;
@property(nonatomic, strong, nullable) AVAudioFile *microphoneFile;
@property(nonatomic, strong, nullable) AVAudioFile *modelInputFile;
@property(nonatomic) unsigned long long reservedOverhead;
@property(nonatomic) unsigned long long reservedAudioBytes;
@property(nonatomic) BOOL audioArchivalPaused;
@end

@implementation MicaDictationHistoryRecord
@end

@interface MicaDictationHistory ()
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableDictionary<NSUUID *, MicaDictationHistoryRecord *> *records;
@property(nonatomic) unsigned long long archivedBytes;
@property(nonatomic) unsigned long long maximumArchiveBytes;
@property(nonatomic) unsigned long long recordOverheadBytes;
@property(nonatomic) BOOL archivalStopped;
@property(nonatomic) BOOL rootPrepared;
- (instancetype)initWithRootURL:(NSURL *)rootURL maximumBytes:(unsigned long long)maximumBytes
    recordOverhead:(unsigned long long)recordOverhead;
@end

@implementation MicaDictationHistory

+ (instancetype)sharedStore {
    static MicaDictationHistory *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *root = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/Mica/DictationHistory"] isDirectory:YES];
        store = [[self alloc] initWithRootURL:root];
    });
    return store;
}

- (instancetype)initWithRootURL:(NSURL *)rootURL {
    self = [super init];
    if (!self) return nil;
    _rootURL = rootURL;
    _maximumArchiveBytes = MicaDictationHistoryMaximumBytes;
    _recordOverheadBytes = MicaDictationHistoryRecordOverheadBytes;
    _queue = dispatch_queue_create("com.mica.dictation-history", DISPATCH_QUEUE_SERIAL);
    _records = [NSMutableDictionary dictionary];
    dispatch_sync(_queue, ^{
        [self prepareRootAndMeasureExistingRecords];
    });
    return self;
}

- (instancetype)initWithRootURL:(NSURL *)rootURL maximumBytes:(unsigned long long)maximumBytes
    recordOverhead:(unsigned long long)recordOverhead {
    self = [self initWithRootURL:rootURL];
    if (!self) return nil;
    self.maximumArchiveBytes = maximumBytes;
    self.recordOverheadBytes = recordOverhead;
    return self;
}

- (void)prepareRootAndMeasureExistingRecords {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if ([fileManager fileExistsAtPath:[[self.rootURL URLByAppendingPathComponent:@".disabled"] path]]) {
        return;
    }
    NSDictionary *rootAttributes = [fileManager attributesOfItemAtPath:self.rootURL.path error:nil];
    if ([rootAttributes[NSFileType] isEqual:NSFileTypeSymbolicLink]) {
        self.archivalStopped = YES;
        return;
    }
    NSError *error = nil;
    if (![fileManager createDirectoryAtURL:self.rootURL withIntermediateDirectories:YES attributes:
        @{NSFilePosixPermissions: @0700} error:&error]) {
        self.archivalStopped = YES;
        return;
    }
    chmod(self.rootURL.fileSystemRepresentation, 0700);
    NSArray<NSURL *> *existing = [fileManager contentsOfDirectoryAtURL:self.rootURL
        includingPropertiesForKeys:nil options:0 error:nil];
    NSRegularExpression *temporaryName = [NSRegularExpression regularExpressionWithPattern:
        @"^\\.[A-Fa-f0-9-]{36}\\.tmp$" options:0 error:nil];
    for (NSURL *url in existing) {
        if ([temporaryName numberOfMatchesInString:url.lastPathComponent options:0
            range:NSMakeRange(0, url.lastPathComponent.length)] != 0)
            [fileManager removeItemAtURL:url error:nil];
    }
    if (![self refreshOnDiskUsage]) return;
    self.rootPrepared = YES;
}

- (BOOL)refreshOnDiskUsage {
    NSError *error = nil;
    NSArray<NSURL *> *children = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.rootURL
        includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey] options:0 error:&error];
    if (!children) {
        self.archivalStopped = YES;
        return NO;
    }
    unsigned long long total = 0;
    for (NSURL *url in children) {
        if ([url.lastPathComponent hasPrefix:@"."]) continue;
        NSNumber *isDirectory = nil, *isSymbolicLink = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        [url getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (!isDirectory.boolValue || isSymbolicLink.boolValue) continue;
        unsigned long long directoryBytes = 0;
        if (![self fileBytesBelowDirectory:url total:&directoryBytes]) {
            self.archivalStopped = YES;
            return NO;
        }
        if (ULLONG_MAX - total < directoryBytes) total = ULLONG_MAX;
        else total += directoryBytes;
    }
    self.archivedBytes = total;
    return YES;
}

- (BOOL)fileBytesBelowDirectory:(NSURL *)directoryURL total:(unsigned long long *)total {
    __block BOOL enumerationFailed = NO;
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager enumeratorAtURL:directoryURL
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey, NSURLIsSymbolicLinkKey]
        options:0 errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
            enumerationFailed = YES;
            return YES;
        }];
    if (!enumerator) return NO;
    unsigned long long sizeTotal = 0;
    for (NSURL *url in enumerator) {
        NSNumber *regular = nil, *symbolic = nil, *size = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (!regular.boolValue || symbolic.boolValue) continue;
        unsigned long long fileSize = size.unsignedLongLongValue;
        if (ULLONG_MAX - sizeTotal < fileSize) sizeTotal = ULLONG_MAX;
        else sizeTotal += fileSize;
    }
    if (enumerationFailed) return NO;
    *total = sizeTotal;
    return YES;
}

- (NSURL *)archiveRootURL { return self.rootURL; }

- (nullable NSUUID *)beginRecordWithMetadata:(NSDictionary<NSString *,id> *)metadata {
    __block NSUUID *recordID = nil;
    dispatch_sync(self.queue, ^{
        if (self.archivalStopped || [NSFileManager.defaultManager fileExistsAtPath:
            [[self.rootURL URLByAppendingPathComponent:@".disabled"] path]]) return;
        if (!self.rootPrepared) [self prepareRootAndMeasureExistingRecords];
        if (self.archivalStopped || ![self refreshOnDiskUsage] ||
            [self wouldExceedCapacityByAddingBytes:self.recordOverheadBytes]) return;
        NSUUID *candidate = NSUUID.UUID;
        NSURL *directoryURL = [self.rootURL URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.tmp", candidate.UUIDString] isDirectory:YES];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
            self.archivalStopped = YES;
            return;
        }
        NSDictionary *directoryAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:directoryURL.path error:nil];
        if (![directoryAttributes[NSFileType] isEqual:NSFileTypeDirectory]) {
            [NSFileManager.defaultManager removeItemAtURL:directoryURL error:nil];
            return;
        }
        chmod(directoryURL.fileSystemRepresentation, 0700);
        NSDictionary *provenance = [metadata[@"provenance"] isKindOfClass:NSDictionary.class]
            ? metadata[@"provenance"] : metadata;
        NSDate *now = NSDate.date;
        NSMutableDictionary *document = [@{
            @"schema_version": @1,
            @"record_id": candidate.UUIDString,
            @"created_at": [self iso8601StringForDate:now],
            @"updated_at": [self iso8601StringForDate:now],
            @"status": @"recording",
            @"transcript_hypothesis": NSNull.null,
            @"human_reference": NSNull.null,
            @"provenance": [provenance isKindOfClass:NSDictionary.class] ? provenance : @{},
            @"annotations": @{}
        } mutableCopy];
        MicaDictationHistoryRecord *record = [MicaDictationHistoryRecord new];
        record.directoryURL = directoryURL;
        record.metadata = document;
        if (![self writeMetadataForRecord:record]) {
            [NSFileManager.defaultManager removeItemAtURL:directoryURL error:nil];
            self.archivalStopped = YES;
            return;
        }
        record.reservedOverhead = self.recordOverheadBytes;
        self.records[candidate] = record;
        recordID = candidate;
    });
    return recordID;
}

- (void)appendMicrophoneBuffer:(AVAudioPCMBuffer *)buffer recordID:(NSUUID *)recordID {
    AVAudioPCMBuffer *copy = [self copyBuffer:buffer];
    if (!copy) return;
    dispatch_async(self.queue, ^{
        MicaDictationHistoryRecord *record = self.records[recordID];
        unsigned long long payloadBytes = 0;
        const AudioBufferList *bufferList = copy.audioBufferList;
        for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) payloadBytes += bufferList->mBuffers[i].mDataByteSize;
        if (!record || ![self reserveBytes:payloadBytes record:record]) return;
        if (!record.microphoneFile) {
            NSURL *url = [record.directoryURL URLByAppendingPathComponent:@"microphone.caf"];
            NSError *error = nil;
            record.microphoneFile = [[AVAudioFile alloc] initForWriting:url settings:copy.format.settings
                commonFormat:copy.format.commonFormat interleaved:copy.format.isInterleaved error:&error];
            if (!record.microphoneFile) {
                [self stopArchivalForRecord:record];
                return;
            }
            chmod(url.fileSystemRepresentation, 0600);
        }
        NSError *error = nil;
        if (![record.microphoneFile writeFromBuffer:copy error:&error]) {
            [self stopArchivalForRecord:record];
        } else {
            record.reservedAudioBytes += payloadBytes;
        }
    });
}

- (void)appendModelInputSamples:(NSData *)samples recordID:(NSUUID *)recordID {
    if (samples.length == 0 || samples.length % sizeof(float) != 0) return;
    NSData *copy = [samples copy];
    dispatch_async(self.queue, ^{
        MicaDictationHistoryRecord *record = self.records[recordID];
        if (!record || ![self reserveBytes:copy.length record:record]) return;
        if (!record.modelInputFile) {
            NSURL *url = [record.directoryURL URLByAppendingPathComponent:@"model-input.wav"];
            AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                sampleRate:16000 channels:1 interleaved:NO];
            NSError *error = nil;
            record.modelInputFile = [[AVAudioFile alloc] initForWriting:url settings:format.settings
                commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:&error];
            if (!record.modelInputFile) {
                [self stopArchivalForRecord:record];
                return;
            }
            chmod(url.fileSystemRepresentation, 0600);
        }
        AVAudioFormat *format = record.modelInputFile.processingFormat;
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
            frameCapacity:(AVAudioFrameCount)(copy.length / sizeof(float))];
        if (!buffer || buffer.floatChannelData == NULL) {
            [self stopArchivalForRecord:record];
            return;
        }
        buffer.frameLength = (AVAudioFrameCount)(copy.length / sizeof(float));
        memcpy(buffer.floatChannelData[0], copy.bytes, copy.length);
        NSError *error = nil;
        if (![record.modelInputFile writeFromBuffer:buffer error:&error]) {
            [self stopArchivalForRecord:record];
        } else {
            record.reservedAudioBytes += copy.length;
        }
    });
}

- (void)finishRecordID:(NSUUID *)recordID withMetadata:(NSDictionary<NSString *,id> *)metadata {
    NSDictionary *values = [metadata copy] ?: @{};
    dispatch_async(self.queue, ^{
        MicaDictationHistoryRecord *record = self.records[recordID];
        if (!record) return;
        record.microphoneFile = nil;
        record.modelInputFile = nil;
        id hypothesis = values[@"transcript_hypothesis"];
        if ([hypothesis isKindOfClass:NSString.class]) record.metadata[@"transcript_hypothesis"] = hypothesis;
        NSMutableDictionary *provenance = [record.metadata[@"provenance"] mutableCopy] ?: [NSMutableDictionary dictionary];
        if ([values[@"provenance"] isKindOfClass:NSDictionary.class]) [provenance addEntriesFromDictionary:values[@"provenance"]];
        for (NSString *key in values) {
            if (![key isEqualToString:@"transcript_hypothesis"] && ![key isEqualToString:@"provenance"] &&
                ![key isEqualToString:@"human_reference"]) provenance[key] = values[key];
        }
        record.metadata[@"provenance"] = provenance;
        if ([values[@"human_reference"] isKindOfClass:NSString.class])
            [self setHumanReference:values[@"human_reference"] record:record];
        record.metadata[@"status"] = [values[@"status"] isEqual:@"failed"] ? @"failed" : @"complete";
        if (![self updateTimestampAndWrite:record]) return;
        unsigned long long recordBytes = 0;
        if (![self fileBytesBelowDirectory:record.directoryURL total:&recordBytes]) {
            self.archivalStopped = YES;
            return;
        }
        unsigned long long otherBytes = self.archivedBytes;
        for (MicaDictationHistoryRecord *activeRecord in self.records.allValues) {
            if (activeRecord == record) continue;
            unsigned long long reservation = activeRecord.reservedOverhead + activeRecord.reservedAudioBytes;
            if (ULLONG_MAX - otherBytes < reservation) {
                otherBytes = ULLONG_MAX;
                break;
            }
            otherBytes += reservation;
        }
        if (otherBytes > self.maximumArchiveBytes ||
            recordBytes > self.maximumArchiveBytes - MIN(otherBytes, self.maximumArchiveBytes)) {
            record.metadata[@"status"] = @"storage_limit";
            NSMutableDictionary *annotations = [record.metadata[@"annotations"] mutableCopy] ?: [NSMutableDictionary dictionary];
            annotations[@"archival_stopped"] = @YES;
            annotations[@"archival_stop_reason"] = @"storage_limit";
            record.metadata[@"annotations"] = annotations;
            if (![self updateTimestampAndWrite:record]) return;
            if (![self fileBytesBelowDirectory:record.directoryURL total:&recordBytes]) {
                self.archivalStopped = YES;
                return;
            }
        }
        NSURL *finalURL = [self.rootURL URLByAppendingPathComponent:recordID.UUIDString isDirectory:YES];
        NSError *moveError = nil;
        if (![NSFileManager.defaultManager moveItemAtURL:record.directoryURL toURL:finalURL error:&moveError]) {
            return;
        }
        record.directoryURL = finalURL;
        if (ULLONG_MAX - self.archivedBytes < recordBytes) self.archivedBytes = ULLONG_MAX;
        else self.archivedBytes += recordBytes;
        [self.records removeObjectForKey:recordID];
    });
}

- (void)cancelRecordID:(NSUUID *)recordID {
    dispatch_async(self.queue, ^{
        MicaDictationHistoryRecord *record = self.records[recordID];
        if (!record) return;
        record.microphoneFile = nil;
        record.modelInputFile = nil;
        [NSFileManager.defaultManager removeItemAtURL:record.directoryURL error:nil];
        [self.records removeObjectForKey:recordID];
    });
}

- (void)updateRecordID:(NSUUID *)recordID withMetadata:(NSDictionary<NSString *,id> *)metadata {
    NSDictionary *values = [metadata copy] ?: @{};
    dispatch_async(self.queue, ^{
        MicaDictationHistoryRecord *record = self.records[recordID];
        NSURL *directoryURL = record.directoryURL ?: [self.rootURL URLByAppendingPathComponent:recordID.UUIDString isDirectory:YES];
        NSMutableDictionary *document = record.metadata ?: [[self metadataForDirectory:directoryURL] mutableCopy];
        if (!document) return;
        if ([values[@"human_reference"] isKindOfClass:NSString.class]) {
            [self setHumanReference:values[@"human_reference"] document:document];
        }
        NSMutableDictionary *annotations = [document[@"annotations"] mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in values) {
            if (![key isEqualToString:@"human_reference"]) annotations[key] = values[key];
        }
        document[@"annotations"] = annotations;
        document[@"updated_at"] = [self iso8601StringForDate:NSDate.date];
        BOOL saved = record ? [self writeMetadataForRecord:record]
            : [self writeMetadata:document atURL:[directoryURL URLByAppendingPathComponent:@"metadata.json"]];
        if (!saved) self.archivalStopped = YES;
    });
}

- (void)flushWithCompletion:(void (^)(void))completion {
    dispatch_async(self.queue, ^{
        dispatch_async(dispatch_get_main_queue(), completion ?: ^{});
    });
}

- (AVAudioPCMBuffer *)copyBuffer:(AVAudioPCMBuffer *)buffer {
    if (!buffer || buffer.frameLength == 0) return nil;
    AVAudioPCMBuffer *copy = [[AVAudioPCMBuffer alloc] initWithPCMFormat:buffer.format frameCapacity:buffer.frameLength];
    if (!copy) return nil;
    copy.frameLength = buffer.frameLength;
    const AudioBufferList *source = buffer.audioBufferList;
    AudioBufferList *destination = copy.mutableAudioBufferList;
    if (source->mNumberBuffers != destination->mNumberBuffers) return nil;
    for (UInt32 i = 0; i < source->mNumberBuffers; i++) {
        if (!source->mBuffers[i].mData || !destination->mBuffers[i].mData ||
            source->mBuffers[i].mDataByteSize > destination->mBuffers[i].mDataByteSize) return nil;
        memcpy(destination->mBuffers[i].mData, source->mBuffers[i].mData, source->mBuffers[i].mDataByteSize);
        destination->mBuffers[i].mDataByteSize = source->mBuffers[i].mDataByteSize;
    }
    return copy;
}

- (BOOL)reserveBytes:(unsigned long long)count record:(MicaDictationHistoryRecord *)record {
    if (self.archivalStopped || record.audioArchivalPaused || [self wouldExceedCapacityByAddingBytes:count]) {
        if (!self.archivalStopped) [self pauseArchivalForRecord:record];
        return NO;
    }
    return YES;
}

- (void)stopArchivalForRecord:(MicaDictationHistoryRecord *)record {
    self.archivalStopped = YES;
    [self pauseArchivalForRecord:record];
}

- (void)pauseArchivalForRecord:(MicaDictationHistoryRecord *)record {
    record.audioArchivalPaused = YES;
    record.microphoneFile = nil;
    record.modelInputFile = nil;
    NSMutableDictionary *annotations = [record.metadata[@"annotations"] mutableCopy] ?: [NSMutableDictionary dictionary];
    annotations[@"archival_stopped"] = @YES;
    annotations[@"archival_stop_reason"] = self.archivalStopped ? @"archive_io_error" : @"storage_limit";
    record.metadata[@"annotations"] = annotations;
    [self updateTimestampAndWrite:record];
}

- (BOOL)wouldExceedCapacityByAddingBytes:(unsigned long long)count {
    unsigned long long total = self.archivedBytes;
    for (MicaDictationHistoryRecord *record in self.records.allValues) {
        if (ULLONG_MAX - total < record.reservedOverhead ||
            ULLONG_MAX - (total + record.reservedOverhead) < record.reservedAudioBytes) return YES;
        total += record.reservedOverhead + record.reservedAudioBytes;
    }
    if (ULLONG_MAX - total < count) return YES;
    total += count;
    return total > self.maximumArchiveBytes;
}

- (void)setHumanReference:(NSString *)text record:(MicaDictationHistoryRecord *)record {
    [self setHumanReference:text document:record.metadata];
}

- (void)setHumanReference:(NSString *)text document:(NSMutableDictionary *)document {
    document[@"human_reference"] = @{ @"text": text, @"source": @"user", @"updated_at": [self iso8601StringForDate:NSDate.date] };
}

- (BOOL)updateTimestampAndWrite:(MicaDictationHistoryRecord *)record {
    record.metadata[@"updated_at"] = [self iso8601StringForDate:NSDate.date];
    BOOL saved = [self writeMetadataForRecord:record];
    if (!saved) self.archivalStopped = YES;
    return saved;
}

- (BOOL)writeMetadataForRecord:(MicaDictationHistoryRecord *)record {
    return [self writeMetadata:record.metadata atURL:[record.directoryURL URLByAppendingPathComponent:@"metadata.json"]];
}

- (BOOL)writeMetadata:(NSDictionary *)metadata atURL:(NSURL *)url {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) return NO;
    chmod(url.fileSystemRepresentation, 0600);
    return YES;
}

- (NSDictionary *)metadataForDirectory:(NSURL *)directoryURL {
    NSData *data = [NSData dataWithContentsOfURL:[directoryURL URLByAppendingPathComponent:@"metadata.json"]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

- (NSString *)iso8601StringForDate:(NSDate *)date {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ formatter = [NSISO8601DateFormatter new]; });
    return [formatter stringFromDate:date];
}

@end
