#import "../src/mica_voice_controller.h"
#import "../src/mica_dictation_history.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

@interface MicaVoiceController (MicaVoiceHistoryTestHooks)
- (void)beginHistoryRecordWithInputFormat:(AVAudioFormat *)inputFormat;
- (void)archiveMicrophoneBuffer:(AVAudioPCMBuffer *)buffer recordID:(NSUUID *)recordID generation:(unsigned)generation;
- (void)launchHelperWithArguments:(NSArray<NSString *> *)arguments
                        inputData:(NSData *)inputData
                   keepsInputOpen:(BOOL)keepsInputOpen;
- (void)writeAudioPayload:(NSData *)payload frames:(unsigned int)frames toWriter:(NSFileHandle *)writer
               generation:(unsigned)generation recordID:(NSUUID *)recordID;
- (void)finishAudioStreamWithWriter:(NSFileHandle *)writer;
@end

static void MicaVoiceHistoryCheck(BOOL condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}

static NSDictionary *MicaVoiceHistoryReadMetadata(NSURL *directory) {
    NSData *data = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"metadata.json"]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL MicaVoiceHistoryWaitFor(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}

int main(void) {
    @autoreleasepool {
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"mica-voice-history-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
        NSURL *helperURL = [root URLByAppendingPathComponent:@"fake-helper"];
        NSError *error = nil;
        MicaVoiceHistoryCheck([NSFileManager.defaultManager createDirectoryAtURL:root
            withIntermediateDirectories:YES attributes:nil error:&error], "create temporary history directory");

        NSString *helper = @"#!/bin/sh\nprintf '%s\\n' '{\"type\":\"metadata\",\"engine\":\"Fixture\",\"model_version\":\"unit\",\"streaming_config\":{\"chunk_seconds\":5}}'\nprintf '%s\\n' '{\"type\":\"ready\"}'\ncat >/dev/null\nif [ \"$1\" = \"fail\" ]; then printf '%s\\n' '{\"type\":\"error\",\"message\":\"synthetic decoder failure\"}'; exit 1; fi\nprintf '%s\\n' '{\"type\":\"result\",\"text\":\"  raw fixture result  \"}'\n";
        MicaVoiceHistoryCheck([helper writeToURL:helperURL atomically:YES encoding:NSUTF8StringEncoding error:&error],
            "write fake local helper");
        chmod(helperURL.fileSystemRepresentation, 0700);

        MicaDictationHistory *store = [[MicaDictationHistory alloc] initWithRootURL:root];
        MicaVoiceController *controller = [[MicaVoiceController alloc] initWithHelperURL:helperURL
            defaults:[[NSUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString] historyStore:store];
        AVAudioFormat *microphoneFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
            sampleRate:44100 channels:2 interleaved:NO];
        [controller beginHistoryRecordWithInputFormat:microphoneFormat];
        NSUUID *recordID = controller.recordingID;
        MicaVoiceHistoryCheck(recordID != nil, "controller starts an archive record");

        AVAudioPCMBuffer *native = [[AVAudioPCMBuffer alloc] initWithPCMFormat:microphoneFormat frameCapacity:4];
        native.frameLength = 4;
        const float left[] = {0.1f, -0.2f, 0.3f, -0.4f};
        const float right[] = {-0.5f, 0.6f, -0.7f, 0.8f};
        memcpy(native.floatChannelData[0], left, sizeof(left));
        memcpy(native.floatChannelData[1], right, sizeof(right));
        [controller archiveMicrophoneBuffer:native recordID:recordID generation:0];
        memset(native.floatChannelData[0], 0, sizeof(left));
        memset(native.floatChannelData[1], 0, sizeof(right));

        [controller launchHelperWithArguments:@[@"stream"] inputData:nil keepsInputOpen:YES];
        NSFileHandle *writer = [controller valueForKey:@"audioWriter"];
        MicaVoiceHistoryCheck(writer != nil, "fake local helper has an input stream");
        const float modelSamples[] = {0.125f, -0.25f, 0.5f, -1.0f};
        NSData *modelPayload = [NSData dataWithBytes:modelSamples length:sizeof(modelSamples)];
        [controller writeAudioPayload:modelPayload frames:4 toWriter:writer generation:0 recordID:recordID];
        [controller finishAudioStreamWithWriter:writer];

        MicaVoiceHistoryCheck(MicaVoiceHistoryWaitFor(^BOOL{ return [controller valueForKey:@"process"] == nil; }, 5),
            "fake helper completed without microphone or model access");
        NSURL *recordDirectory = [root URLByAppendingPathComponent:recordID.UUIDString isDirectory:YES];
        MicaVoiceHistoryCheck(MicaVoiceHistoryWaitFor(^BOOL{
            return [NSFileManager.defaultManager fileExistsAtPath:recordDirectory.path];
        }, 3), "controller finalized the record after queued audio writes drained");
        __block BOOL flushed = NO;
        [store flushWithCompletion:^{ flushed = YES; }];
        MicaVoiceHistoryCheck(MicaVoiceHistoryWaitFor(^BOOL{ return flushed; }, 3), "archive queue flushed");

        NSDictionary *metadata = MicaVoiceHistoryReadMetadata(recordDirectory);
        MicaVoiceHistoryCheck([metadata[@"status"] isEqual:@"complete"], "successful helper archived as complete");
        MicaVoiceHistoryCheck([metadata[@"transcript_hypothesis"] isEqual:@"  raw fixture result  "],
            "archive preserves the exact untrimmed helper result");
        NSDictionary *provenance = metadata[@"provenance"];
        NSDictionary *speechEngine = provenance[@"speech_engine"];
        MicaVoiceHistoryCheck([speechEngine[@"engine"] isEqual:@"Fixture"] &&
            [speechEngine[@"model_version"] isEqual:@"unit"] &&
            [speechEngine[@"streaming_config"][@"chunk_seconds"] isEqual:@5],
            "archive retains helper engine, model, and streaming configuration");

        NSURL *microphoneURL = [recordDirectory URLByAppendingPathComponent:@"microphone.caf"];
        AVAudioFile *microphoneFile = [[AVAudioFile alloc] initForReading:microphoneURL error:&error];
        AVAudioPCMBuffer *microphoneRead = [[AVAudioPCMBuffer alloc] initWithPCMFormat:microphoneFile.processingFormat frameCapacity:4];
        MicaVoiceHistoryCheck(microphoneFile && [microphoneFile readIntoBuffer:microphoneRead error:&error] &&
            microphoneRead.frameLength == 4 && fabsf(microphoneRead.floatChannelData[0][2] - 0.3f) < 0.0001f &&
            fabsf(microphoneRead.floatChannelData[1][1] - 0.6f) < 0.0001f,
            "native microphone samples were deep-copied before the source buffer changed");

        NSURL *modelURL = [recordDirectory URLByAppendingPathComponent:@"model-input.wav"];
        AVAudioFile *modelFile = [[AVAudioFile alloc] initForReading:modelURL error:&error];
        AVAudioPCMBuffer *modelRead = [[AVAudioPCMBuffer alloc] initWithPCMFormat:modelFile.processingFormat frameCapacity:4];
        MicaVoiceHistoryCheck(modelFile && [modelFile readIntoBuffer:modelRead error:&error] &&
            modelRead.frameLength == 4 && fabsf(modelRead.floatChannelData[0][2] - modelSamples[2]) < 0.0001f,
            "archived model input matches the exact float32 samples sent to the helper");

        [controller updateHistoryForRecordingID:recordID metadata:@{@"paste_succeeded": @YES}];
        flushed = NO;
        [store flushWithCompletion:^{ flushed = YES; }];
        MicaVoiceHistoryCheck(MicaVoiceHistoryWaitFor(^BOOL{ return flushed; }, 3), "provenance update flushed");
        metadata = MicaVoiceHistoryReadMetadata(recordDirectory);
        MicaVoiceHistoryCheck([metadata[@"annotations"][@"paste_succeeded"] isEqual:@YES],
            "app can associate insertion outcome with the stable recording ID");

        [controller setValue:[NSMutableDictionary dictionary] forKey:@"helperMetadata"];
        [controller beginHistoryRecordWithInputFormat:microphoneFormat];
        NSUUID *failedRecordID = controller.recordingID;
        [controller launchHelperWithArguments:@[@"fail"] inputData:nil keepsInputOpen:YES];
        NSFileHandle *failedWriter = [controller valueForKey:@"audioWriter"];
        MicaVoiceHistoryCheck(failedWriter != nil, "failure fixture helper has an input stream");
        [controller finishAudioStreamWithWriter:failedWriter];
        NSURL *failedDirectory = [root URLByAppendingPathComponent:failedRecordID.UUIDString isDirectory:YES];
        MicaVoiceHistoryCheck(MicaVoiceHistoryWaitFor(^BOOL{
            return [controller valueForKey:@"process"] == nil &&
                [NSFileManager.defaultManager fileExistsAtPath:failedDirectory.path];
        }, 5), "failed helper record finalized");
        flushed = NO;
        [store flushWithCompletion:^{ flushed = YES; }];
        MicaVoiceHistoryCheck(MicaVoiceHistoryWaitFor(^BOOL{ return flushed; }, 3), "failed record flush");
        NSDictionary *failedMetadata = MicaVoiceHistoryReadMetadata(failedDirectory);
        MicaVoiceHistoryCheck([failedMetadata[@"status"] isEqual:@"failed"] &&
            [failedMetadata[@"provenance"][@"failure_reason"] containsString:@"synthetic decoder failure"],
            "helper error status and reason are archived");

        [controller beginHistoryRecordWithInputFormat:microphoneFormat];
        NSUUID *cancelledRecordID = controller.recordingID;
        [controller cancel];
        flushed = NO;
        [store flushWithCompletion:^{ flushed = YES; }];
        MicaVoiceHistoryCheck(MicaVoiceHistoryWaitFor(^BOOL{ return flushed; }, 3), "cancelled record cleanup flushed");
        NSURL *cancelledDirectory = [root URLByAppendingPathComponent:cancelledRecordID.UUIDString isDirectory:YES];
        NSURL *cancelledTemporaryDirectory = [root URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.tmp", cancelledRecordID.UUIDString] isDirectory:YES];
        MicaVoiceHistoryCheck(![NSFileManager.defaultManager fileExistsAtPath:cancelledDirectory.path] &&
            ![NSFileManager.defaultManager fileExistsAtPath:cancelledTemporaryDirectory.path],
            "cancel removes the incomplete archive deterministically");

        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        puts("PASS: controller archives synthetic native/model PCM, helper metadata/raw result, failure status, provenance, and cancellation cleanup");
    }
    return 0;
}
