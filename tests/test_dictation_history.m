#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import "mica_dictation_history.h"

@interface MicaDictationHistory (Testing)
- (instancetype)initWithRootURL:(NSURL *)rootURL maximumBytes:(unsigned long long)maximumBytes
    recordOverhead:(unsigned long long)recordOverhead;
@property(nonatomic) unsigned long long maximumArchiveBytes;
@end

static int failures;
static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

static NSDictionary *ReadMetadata(NSURL *recordURL) {
    NSData *data = [NSData dataWithContentsOfURL:[recordURL URLByAppendingPathComponent:@"metadata.json"]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static unsigned long long ArchiveFileBytes(NSURL *rootURL) {
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager enumeratorAtURL:rootURL
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey, NSURLIsSymbolicLinkKey]
        options:0 errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) { return YES; }];
    unsigned long long total = 0;
    for (NSURL *url in enumerator) {
        NSNumber *regular = nil, *symbolic = nil, *size = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (regular.boolValue && !symbolic.boolValue) total += size.unsignedLongLongValue;
    }
    return total;
}

static void Flush(MicaDictationHistory *store) {
    __block BOOL completed = NO;
    [store flushWithCompletion:^{ completed = YES; }];
    while (!completed) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

int main(void) {
    @autoreleasepool {
        NSURL *baseURL = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
        NSURL *rootURL = [baseURL URLByAppendingPathComponent:[NSString stringWithFormat:@"mica-history-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
        MicaDictationHistory *store = [[MicaDictationHistory alloc] initWithRootURL:rootURL];
        NSUUID *recordID = [store beginRecordWithMetadata:@{@"provenance": @{@"project": @"Mica Test", @"branch": @"feature/dictation"}}];
        Check(recordID != nil, @"starts a record in the injected test root");
        if (!recordID) return 1;

        AVAudioFormat *microphoneFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
            sampleRate:48000 channels:1 interleaved:NO];
        AVAudioPCMBuffer *microphone = [[AVAudioPCMBuffer alloc] initWithPCMFormat:microphoneFormat frameCapacity:480];
        microphone.frameLength = 480;
        for (AVAudioFrameCount i = 0; i < microphone.frameLength; i++) microphone.floatChannelData[0][i] = (float)i / 480.0f;
        [store appendMicrophoneBuffer:microphone recordID:recordID];

        float samples[1600];
        for (NSUInteger i = 0; i < 1600; i++) samples[i] = (float)i / 1600.0f;
        [store appendModelInputSamples:[NSData dataWithBytes:samples length:sizeof(samples)] recordID:recordID];
        [store finishRecordID:recordID withMetadata:@{@"transcript_hypothesis": @"Open src/mica_app.m", @"provenance": @{@"model": @"parakeet-ultra"}}];
        Flush(store);

        NSURL *recordURL = [rootURL URLByAppendingPathComponent:recordID.UUIDString isDirectory:YES];
        NSDictionary *metadata = ReadMetadata(recordURL);
        Check([[NSFileManager.defaultManager contentsOfDirectoryAtURL:rootURL includingPropertiesForKeys:nil options:0 error:nil] count] == 1,
              @"publishes only the finished UUID record directory");
        Check([metadata[@"status"] isEqual:@"complete"] && [metadata[@"transcript_hypothesis"] isEqual:@"Open src/mica_app.m"],
              @"stores the exact helper hypothesis and completed state");
        Check([metadata[@"provenance"][@"project"] isEqual:@"Mica Test"] && [metadata[@"provenance"][@"model"] isEqual:@"parakeet-ultra"],
              @"merges initial and final provenance");

        NSURL *waveURL = [recordURL URLByAppendingPathComponent:@"model-input.wav"];
        AVAudioFile *wave = [[AVAudioFile alloc] initForReading:waveURL error:nil];
        AVAudioPCMBuffer *waveBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:wave.processingFormat frameCapacity:1600];
        BOOL waveRead = wave && [wave readIntoBuffer:waveBuffer error:nil];
        Check(waveRead && wave.processingFormat.sampleRate == 16000 && wave.processingFormat.channelCount == 1 &&
              wave.processingFormat.commonFormat == AVAudioPCMFormatFloat32 && waveBuffer.frameLength == 1600,
              @"writes the exact model input as mono 16 kHz Float32 WAV");
        Check(waveRead && fabsf(waveBuffer.floatChannelData[0][1234] - samples[1234]) < 0.00001f,
              @"preserves synthetic model-input samples exactly");

        AVAudioFile *caf = [[AVAudioFile alloc] initForReading:[recordURL URLByAppendingPathComponent:@"microphone.caf"] error:nil];
        AVAudioPCMBuffer *cafBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:caf.processingFormat frameCapacity:480];
        BOOL cafRead = caf && [caf readIntoBuffer:cafBuffer error:nil];
        Check(cafRead && caf.processingFormat.sampleRate == 48000 && cafBuffer.frameLength == 480,
              @"stores captured microphone audio in its native CAF format");
        Check(cafRead && fabsf(cafBuffer.floatChannelData[0][123] - microphone.floatChannelData[0][123]) < 0.00001f,
              @"preserves captured PCM samples");

        [store updateRecordID:recordID withMetadata:@{@"human_reference": @"Open the Mica app source", @"rating": @5}];
        Flush(store);
        metadata = ReadMetadata(recordURL);
        Check([metadata[@"human_reference"][@"text"] isEqual:@"Open the Mica app source"] &&
              [metadata[@"human_reference"][@"source"] isEqual:@"user"], @"stores user reference separately from model hypothesis");
        Check([metadata[@"annotations"][@"rating"] isEqual:@5], @"stores per-record annotations separately");

        NSUUID *cancelledID = [store beginRecordWithMetadata:@{}];
        [store appendModelInputSamples:[NSData dataWithBytes:samples length:sizeof(samples)] recordID:cancelledID];
        [store cancelRecordID:cancelledID];
        Flush(store);
        Check(![NSFileManager.defaultManager fileExistsAtPath:[rootURL URLByAppendingPathComponent:cancelledID.UUIDString].path],
              @"does not publish a cancelled record");

        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:rootURL.path error:nil];
        NSNumber *rootPermissions = attributes[NSFilePosixPermissions];
        Check((rootPermissions.unsignedShortValue & 0777) == 0700, @"restricts archive root permissions");
        NSDictionary *recordAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:recordURL.path error:nil];
        NSDictionary *metadataAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:[recordURL URLByAppendingPathComponent:@"metadata.json"].path error:nil];
        NSNumber *recordPermissions = recordAttributes[NSFilePosixPermissions];
        NSNumber *metadataPermissions = metadataAttributes[NSFilePosixPermissions];
        Check((recordPermissions.unsignedShortValue & 0777) == 0700 &&
              (metadataPermissions.unsignedShortValue & 0777) == 0600,
              @"restricts record and metadata file permissions");

        [NSFileManager.defaultManager removeItemAtURL:rootURL error:nil];

        NSURL *disabledRoot = [baseURL URLByAppendingPathComponent:[NSString stringWithFormat:@"mica-history-disabled-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:disabledRoot withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *disabledMarker = [disabledRoot URLByAppendingPathComponent:@".disabled"];
        [NSData.data writeToURL:disabledMarker atomically:YES];
        MicaDictationHistory *disabledStore = [[MicaDictationHistory alloc] initWithRootURL:disabledRoot];
        Check([disabledStore beginRecordWithMetadata:@{}] == nil, @"honors the private archive-disable sentinel");
        Check([NSFileManager.defaultManager fileExistsAtPath:disabledMarker.path], @"preserves the archive-disable sentinel");
        [NSFileManager.defaultManager removeItemAtURL:disabledMarker error:nil];
        NSUUID *reenabledID = [disabledStore beginRecordWithMetadata:@{}];
        Check(reenabledID != nil, @"allows archiving after the disable sentinel is removed in the same process");
        if (reenabledID) [disabledStore cancelRecordID:reenabledID];
        Flush(disabledStore);
        [NSFileManager.defaultManager removeItemAtURL:disabledRoot error:nil];

        NSURL *cancelRoot = [baseURL URLByAppendingPathComponent:[NSString stringWithFormat:@"mica-history-cancel-capacity-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
        MicaDictationHistory *cancelStore = [[MicaDictationHistory alloc] initWithRootURL:cancelRoot
            maximumBytes:80 * 1024 recordOverhead:64 * 1024];
        NSUUID *reservedID = [cancelStore beginRecordWithMetadata:@{}];
        float reservedSamples[1024] = {0};
        [cancelStore appendModelInputSamples:[NSData dataWithBytes:reservedSamples length:sizeof(reservedSamples)] recordID:reservedID];
        [cancelStore cancelRecordID:reservedID];
        Flush(cancelStore);
        NSUUID *afterCancelID = [cancelStore beginRecordWithMetadata:@{}];
        Check(afterCancelID != nil, @"releases active audio reservations when a record is cancelled");
        if (afterCancelID) [cancelStore cancelRecordID:afterCancelID];
        Flush(cancelStore);
        [NSFileManager.defaultManager removeItemAtURL:cancelRoot error:nil];

        NSURL *capacityRoot = [baseURL URLByAppendingPathComponent:[NSString stringWithFormat:@"mica-history-capacity-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
        MicaDictationHistory *capacityStore = [[MicaDictationHistory alloc] initWithRootURL:capacityRoot
            maximumBytes:1024 * 1024 recordOverhead:64 * 1024];
        NSUUID *storedID = [capacityStore beginRecordWithMetadata:@{@"provenance": @{@"test": @YES}}];
        float retainedSamples[1600] = {0};
        [capacityStore appendModelInputSamples:[NSData dataWithBytes:retainedSamples length:sizeof(retainedSamples)] recordID:storedID];
        [capacityStore finishRecordID:storedID withMetadata:@{@"transcript_hypothesis": @"capacity fixture"}];
        Flush(capacityStore);
        unsigned long long existingBytes = ArchiveFileBytes(capacityRoot);
        capacityStore.maximumArchiveBytes = existingBytes + 64 * 1024 - 1;
        Check([capacityStore beginRecordWithMetadata:@{}] == nil, @"pauses archival when existing records plus reserved overhead reach the cap");
        [NSFileManager.defaultManager removeItemAtURL:[capacityRoot URLByAppendingPathComponent:storedID.UUIDString isDirectory:YES] error:nil];
        NSUUID *afterClearID = [capacityStore beginRecordWithMetadata:@{}];
        Check(afterClearID != nil, @"refreshes disk usage and resumes after clearing records in the same store");
        if (afterClearID) [capacityStore cancelRecordID:afterClearID];
        Flush(capacityStore);
        [NSFileManager.defaultManager removeItemAtURL:capacityRoot error:nil];

        NSURL *concurrentRoot = [baseURL URLByAppendingPathComponent:[NSString stringWithFormat:@"mica-history-concurrent-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
        MicaDictationHistory *concurrentStore = [[MicaDictationHistory alloc] initWithRootURL:concurrentRoot
            maximumBytes:140 * 1024 recordOverhead:64 * 1024];
        NSUUID *concurrentA = [concurrentStore beginRecordWithMetadata:@{}];
        NSUUID *concurrentB = [concurrentStore beginRecordWithMetadata:@{}];
        float concurrentSamples[1024] = {0};
        [concurrentStore appendModelInputSamples:[NSData dataWithBytes:concurrentSamples length:sizeof(concurrentSamples)] recordID:concurrentA];
        [concurrentStore appendModelInputSamples:[NSData dataWithBytes:concurrentSamples length:sizeof(concurrentSamples)] recordID:concurrentB];
        [concurrentStore finishRecordID:concurrentA withMetadata:@{@"transcript_hypothesis": @"record A"}];
        [concurrentStore finishRecordID:concurrentB withMetadata:@{@"transcript_hypothesis": @"record B"}];
        Flush(concurrentStore);
        Check([NSFileManager.defaultManager fileExistsAtPath:[concurrentRoot URLByAppendingPathComponent:concurrentA.UUIDString].path] &&
              [NSFileManager.defaultManager fileExistsAtPath:[concurrentRoot URLByAppendingPathComponent:concurrentB.UUIDString].path],
              @"publishes both concurrent records without folding active reservations into finalized bytes");
        NSUUID *afterConcurrentID = [concurrentStore beginRecordWithMetadata:@{}];
        Check(afterConcurrentID != nil, @"does not double-count a concurrent record reservation after both records finish");
        if (afterConcurrentID) [concurrentStore cancelRecordID:afterConcurrentID];
        Flush(concurrentStore);
        [NSFileManager.defaultManager removeItemAtURL:concurrentRoot error:nil];

        NSURL *oversizedRoot = [baseURL URLByAppendingPathComponent:[NSString stringWithFormat:@"mica-history-oversized-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
        MicaDictationHistory *oversizedStore = [[MicaDictationHistory alloc] initWithRootURL:oversizedRoot maximumBytes:1 recordOverhead:0];
        NSUUID *oversizedID = [oversizedStore beginRecordWithMetadata:@{}];
        [oversizedStore finishRecordID:oversizedID withMetadata:@{@"transcript_hypothesis": @"preserve completed capture"}];
        Flush(oversizedStore);
        NSURL *oversizedURL = [oversizedRoot URLByAppendingPathComponent:oversizedID.UUIDString isDirectory:YES];
        NSDictionary *oversizedMetadata = ReadMetadata(oversizedURL);
        Check([NSFileManager.defaultManager fileExistsAtPath:oversizedURL.path] &&
              [oversizedMetadata[@"status"] isEqual:@"storage_limit"] &&
              [oversizedMetadata[@"annotations"][@"archival_stop_reason"] isEqual:@"storage_limit"],
              @"retains a completed record and marks it when final actual size crosses the cap");
        Check([oversizedStore beginRecordWithMetadata:@{}] == nil, @"pauses new archives while retained records occupy over-cap storage");
        [NSFileManager.defaultManager removeItemAtURL:oversizedRoot error:nil];
    }
    if (failures) return 1;
    puts("Dictation history tests passed");
    return 0;
}
