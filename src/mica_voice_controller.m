#import "mica_voice_controller.h"
#import "mica_diagnostics.h"

#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>
#include <math.h>
#include <signal.h>
#include <string.h>

@interface MicaVoiceController ()
@property(nonatomic, strong) NSURL *helperURL;
@property(nonatomic, assign, readwrite) MicaVoiceControllerState state;
@property(nonatomic, copy, readwrite) NSString *statusText;
@property(nonatomic, copy, readwrite) NSString *transcript;
@property(nonatomic, copy, readwrite) NSString *confirmedTranscript;
@property(nonatomic, assign, readwrite) NSTimeInterval elapsedSeconds;
@property(nonatomic, assign, readwrite) double progress;
@property(nonatomic, assign, readwrite) BOOL hasProgress;
@property(nonatomic, assign, readwrite) BOOL isPushToTalk;
@property(nonatomic, copy) NSString *workingDirectory;
@property(nonatomic, strong) NSTask *process;
@property(nonatomic, strong) NSPipe *outputPipe;
@property(nonatomic, strong) NSPipe *audioPipe;
@property(nonatomic, strong) NSFileHandle *audioWriter;
@property(nonatomic, strong) AVAudioEngine *audioEngine;
@property(nonatomic, strong) AVAudioConverter *audioConverter;
@property(nonatomic, strong) AVAudioFormat *audioTargetFormat;
@property(nonatomic, strong) NSMutableData *outputBuffer;
@property(nonatomic, strong) NSTimer *elapsedTimer;
@property(nonatomic, strong) NSTimer *helperExitTimer;
@property(nonatomic, strong) NSTimer *progressRefreshTimer;
@property(nonatomic, copy) NSString *rawTranscript;
@property(nonatomic, copy) NSString *helperResult;
@property(nonatomic, copy) NSString *helperError;
@property(nonatomic, assign) BOOL outputEOF;
@property(nonatomic, assign) BOOL processTerminated;
@property(nonatomic, assign) int processExitCode;
@property(nonatomic, assign) NSTaskTerminationReason processTerminationReason;
@property(nonatomic, strong) NSDate *recordingStartedAt;
@property(nonatomic, copy) NSString *lastLoggedHelperStatus;
@property(nonatomic, assign) NSInteger lastLoggedProgressBucket;
- (void)beginForWorkingDirectory:(NSString *)workingDirectory;
- (void)helperBecameReady;
- (void)writeAudioPayload:(NSData *)payload frames:(unsigned int)frames toWriter:(NSFileHandle *)writer;
- (void)flushPreparationAudioToWriter:(NSFileHandle *)writer;
- (void)finishAudioStreamWithWriter:(NSFileHandle *)writer;
- (void)forceFinishExitedHelper:(NSTimer *)timer;
- (void)releaseOutputPipe;
- (void)finishTranscript:(NSString *)transcript;
@end

@implementation MicaVoiceController {
    dispatch_queue_t _audioWriteQueue;
    atomic_bool _acceptAudio;
    atomic_bool _discardQueuedAudio;
    atomic_bool _audioOverflowReported;
    atomic_bool _audioHelperReady;
    atomic_uint _queuedAudioFrames;
    NSFileHandle *_audioStreamWriter;
    NSMutableData *_preparationAudio;
    NSUInteger _preparationAudioFrames;
    BOOL _audioFinishRequested;
}

- (instancetype)initWithHelperURL:(NSURL *)helperURL {
    self = [super init];
    if (self) {
        _helperURL = helperURL;
        _state = MicaVoiceControllerStateIdle;
        _audioWriteQueue = dispatch_queue_create("com.megasoft78.mica.voice-audio", DISPATCH_QUEUE_SERIAL);
        atomic_init(&_acceptAudio, false);
        atomic_init(&_discardQueuedAudio, false);
        atomic_init(&_audioOverflowReported, false);
        atomic_init(&_audioHelperReady, false);
        atomic_init(&_queuedAudioFrames, 0);
    }
    return self;
}

- (void)dealloc {
    atomic_store(&_acceptAudio, false);
    atomic_store(&_discardQueuedAudio, true);
    if (self.audioEngine) {
        [self.audioEngine.inputNode removeTapOnBus:0];
        [self.audioEngine stop];
    }
    self.process.terminationHandler = nil;
    if (self.process.isRunning) [self.process terminate];
    [self releaseOutputPipe];
    NSFileHandle *writer = self.audioWriter;
    self.audioWriter = nil;
    if (writer) dispatch_async(_audioWriteQueue, ^{
        @try { [writer closeFile]; } @catch (__unused NSException *exception) { }
    });
    [self.elapsedTimer invalidate];
    [self.helperExitTimer invalidate];
    [self.progressRefreshTimer invalidate];
}

- (BOOL)isBusy {
    return self.state != MicaVoiceControllerStateIdle &&
           self.state != MicaVoiceControllerStateFailed;
}

- (void)startPushToTalkForWorkingDirectory:(NSString *)workingDirectory {
    NSAssert(NSThread.isMainThread, @"Voice actions must run on the main thread");
    if (self.isBusy) return;
    [self beginForWorkingDirectory:workingDirectory];
}

- (void)finishPushToTalk {
    NSAssert(NSThread.isMainThread, @"Voice actions must run on the main thread");
    if (!self.isPushToTalk) return;
    if (self.recordingStartedAt && (self.state == MicaVoiceControllerStatePreparing ||
        self.state == MicaVoiceControllerStateListening)) {
        [self stopListening];
    } else if (self.state == MicaVoiceControllerStatePreparing) {
        [self cancel];
    }
}

- (void)beginForWorkingDirectory:(NSString *)workingDirectory {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14) {
        [self failWithMessage:@"Dictation requires macOS 14 or later. Mica's terminal works on macOS 13 and later."];
        return;
    }

    self.isPushToTalk = YES;
    [self.helperExitTimer invalidate];
    self.helperExitTimer = nil;
    self.workingDirectory = workingDirectory.length ? workingDirectory : NSFileManager.defaultManager.currentDirectoryPath;
    MicaDiagnosticsLog(@"dictation", [NSString stringWithFormat:@"requested folder=%@", self.workingDirectory]);
    self.transcript = @"";
    self.confirmedTranscript = @"";
    self.rawTranscript = nil;
    self.helperResult = nil;
    self.helperError = nil;
    self.recordingStartedAt = nil;
    self.elapsedSeconds = 0;
    [self setState:MicaVoiceControllerStatePreparing
            status:@"Requesting microphone access…"
          progress:-1];

    AVAuthorizationStatus permission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (permission == AVAuthorizationStatusAuthorized) {
        [self launchASRHelper];
    } else if (permission == AVAuthorizationStatusNotDetermined) {
        __weak typeof(self) weakSelf = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MicaVoiceController *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.state != MicaVoiceControllerStatePreparing) return;
                if (granted) [strongSelf launchASRHelper];
                else [strongSelf failWithMessage:@"Microphone access was denied. Enable Mica in System Settings → Privacy & Security → Microphone."];
            });
        }];
    } else {
        MicaDiagnosticsLog(@"dictation", @"microphone access is disabled in macOS privacy settings");
        [self failWithMessage:@"Microphone access is off. Enable Mica in System Settings → Privacy & Security → Microphone."];
    }
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"Voice actions must run on the main thread");
    [self stopAudioCaptureSendingCancel:YES];
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    self.process.terminationHandler = nil;
    if (self.process.isRunning) [self.process terminate];
    self.process = nil;
    [self releaseOutputPipe];
    self.audioPipe = nil;
    self.audioWriter = nil;
    self.rawTranscript = nil;
    self.helperResult = nil;
    self.helperError = nil;
    self.transcript = @"";
    self.confirmedTranscript = @"";
    self.elapsedSeconds = 0;
    self.isPushToTalk = NO;
    self.recordingStartedAt = nil;
    [self setState:MicaVoiceControllerStateIdle status:@"" progress:-1];
}

- (void)launchASRHelper {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:self.helperURL.path]) {
        [self failWithMessage:@"The local speech helper is missing. Rebuild Mica to restore Dictation."];
        return;
    }
    self.transcript = @"";
    self.confirmedTranscript = @"";
    self.rawTranscript = nil;
    [self setState:MicaVoiceControllerStatePreparing
            status:@"Starting local speech recognition…"
          progress:-1];
    [self launchHelperWithArguments:@[@"stream"] inputData:nil keepsInputOpen:YES];
    if (self.process) [self startAudioCapture];
}

- (void)launchHelperWithArguments:(NSArray<NSString *> *)arguments
                        inputData:(NSData *)inputData
                   keepsInputOpen:(BOOL)keepsInputOpen {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *inputPipe = [NSPipe pipe];
    task.executableURL = self.helperURL;
    task.arguments = arguments;
    task.standardOutput = outputPipe.fileHandleForWriting;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = inputPipe.fileHandleForReading;
    self.outputBuffer = [NSMutableData data];
    self.outputEOF = NO;
    self.processTerminated = NO;
    self.processExitCode = -1;
    self.processTerminationReason = NSTaskTerminationReasonExit;
    self.helperResult = nil;
    self.helperError = nil;
    self.lastLoggedHelperStatus = nil;
    self.lastLoggedProgressBucket = -1;
    self.process = task;
    self.outputPipe = outputPipe;

    MicaDiagnosticsLog(@"dictation", [NSString stringWithFormat:@"starting local helper phase=%@ operation=%@",
        @"speech",
        arguments.firstObject ?: @"unknown"]);

    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MicaVoiceController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.process != finishedTask) return;
            strongSelf.processTerminated = YES;
            strongSelf.processExitCode = finishedTask.terminationStatus;
            strongSelf.processTerminationReason = finishedTask.terminationReason;
            MicaDiagnosticsLog(@"dictation", [NSString stringWithFormat:
                @"helper exited phase=%@ pid=%d reason=%@ status=%d",
                @"speech",
                finishedTask.processIdentifier,
                finishedTask.terminationReason == NSTaskTerminationReasonExit ? @"exit" : @"signal",
                finishedTask.terminationStatus]);
            [strongSelf completeHelperIfReady];
            if (!strongSelf.outputEOF && strongSelf.process == finishedTask) {
                [strongSelf.helperExitTimer invalidate];
                strongSelf.helperExitTimer = [NSTimer scheduledTimerWithTimeInterval:0.75
                    target:strongSelf selector:@selector(forceFinishExitedHelper:)
                    userInfo:finishedTask repeats:NO];
            }
        });
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        self.process = nil;
        [self releaseOutputPipe];
        MicaDiagnosticsLog(@"dictation", [NSString stringWithFormat:@"helper launch failed: %@",
            launchError.localizedDescription ?: @"unknown error"]);
        [self failWithMessage:[NSString stringWithFormat:@"Could not start local speech processing: %@",
                               launchError.localizedDescription ?: @"unknown error"]];
        return;
    }
    [inputPipe.fileHandleForReading closeFile];
    [outputPipe.fileHandleForWriting closeFile];

    NSFileHandle *reader = outputPipe.fileHandleForReading;
    reader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) {
            handle.readabilityHandler = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                MicaVoiceController *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.process != task) return;
                [strongSelf consumeHelperData:[NSData data] endOfFile:YES];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                MicaVoiceController *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.process != task) return;
                [strongSelf consumeHelperData:data endOfFile:NO];
            });
        }
    };

    if (keepsInputOpen) {
        self.audioPipe = inputPipe;
        self.audioWriter = inputPipe.fileHandleForWriting;
        NSFileHandle *writer = self.audioWriter;
        atomic_store(&_audioHelperReady, false);
        dispatch_async(_audioWriteQueue, ^{
            self->_audioStreamWriter = writer;
            self->_preparationAudio = [NSMutableData data];
            self->_preparationAudioFrames = 0;
            self->_audioFinishRequested = NO;
        });
    } else {
        @try {
            if (inputData.length) [inputPipe.fileHandleForWriting writeData:inputData];
            [inputPipe.fileHandleForWriting closeFile];
        } @catch (NSException *exception) {
            [self failWithMessage:[NSString stringWithFormat:@"Could not send the transcript to the local cleaner: %@", exception.reason ?: @"unknown error"]];
            if (task.isRunning) [task terminate];
        }
    }
}

- (void)consumeHelperData:(NSData *)data endOfFile:(BOOL)endOfFile {
    if (data.length) [self.outputBuffer appendData:data];
    const uint8_t *bytes = self.outputBuffer.bytes;
    NSUInteger consumed = 0;
    for (NSUInteger index = 0; index < self.outputBuffer.length; index++) {
        if (bytes[index] != '\n') continue;
        NSData *line = [self.outputBuffer subdataWithRange:NSMakeRange(consumed, index - consumed)];
        [self consumeHelperLine:line];
        consumed = index + 1;
    }
    if (consumed) [self.outputBuffer replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
    if (endOfFile) {
        if (self.outputBuffer.length) [self consumeHelperLine:self.outputBuffer];
        [self.outputBuffer setLength:0];
        self.outputEOF = YES;
        [self completeHelperIfReady];
    }
}

- (void)consumeHelperLine:(NSData *)line {
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![message isKindOfClass:NSDictionary.class]) return;
    NSString *type = [message[@"type"] isKindOfClass:NSString.class] ? message[@"type"] : @"";
    NSString *text = [message[@"text"] isKindOfClass:NSString.class] ? message[@"text"] : nil;
    NSString *messageText = [message[@"message"] isKindOfClass:NSString.class] ? message[@"message"] : nil;
    NSNumber *progress = [message[@"progress"] isKindOfClass:NSNumber.class] ? message[@"progress"] : nil;

    if ([type isEqualToString:@"status"]) {
        NSInteger bucket = progress ? (NSInteger)floor(progress.doubleValue * 10.0) : -1;
        if (![messageText isEqualToString:self.lastLoggedHelperStatus] ||
            (bucket >= 0 && bucket != self.lastLoggedProgressBucket)) {
            NSString *detail = bucket >= 0
                ? [NSString stringWithFormat:@"%@ progress=%ld%%", messageText ?: @"working", (long)(bucket * 10)]
                : (messageText ?: @"working");
            MicaDiagnosticsLog(@"dictation", detail);
            self.lastLoggedHelperStatus = messageText;
            self.lastLoggedProgressBucket = bucket;
        }
        [self setState:self.state status:messageText ?: @"Working locally…" progress:progress ? progress.doubleValue : -1];
    } else if ([type isEqualToString:@"ready"]) {
        [self helperBecameReady];
    } else if ([type isEqualToString:@"diagnostic"]) {
        if (messageText.length) MicaDiagnosticsLog(@"dictation.metrics", messageText);
    } else if ([type isEqualToString:@"transcript"]) {
        self.transcript = text ?: @"";
        self.confirmedTranscript = [message[@"confirmedText"] isKindOfClass:NSString.class]
            ? message[@"confirmedText"] : @"";
        [self notifyUpdate];
    } else if ([type isEqualToString:@"result"]) {
        self.helperResult = text ?: @"";
    } else if ([type isEqualToString:@"error"]) {
        self.helperError = messageText ?: @"Local speech processing failed.";
    }
}

- (void)completeHelperIfReady {
    if (!self.outputEOF || !self.processTerminated) return;
    NSTask *finishedTask = self.process;
    if (!finishedTask) return;
    [self.helperExitTimer invalidate];
    self.helperExitTimer = nil;
    finishedTask.terminationHandler = nil;
    self.process = nil;
    [self releaseOutputPipe];
    self.audioPipe = nil;
    self.audioWriter = nil;

    if (self.helperError.length) {
        [self failWithMessage:self.helperError];
        return;
    }
    NSString *result = [self.helperResult stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (result.length == 0) {
        [self failWithMessage:@"I didn’t catch any speech. Hold left Option and speak a little longer."];
        return;
    }
    self.rawTranscript = result;
    self.transcript = result;
    self.confirmedTranscript = result;
    [self notifyUpdate];
    [self finishTranscript:result];
}

- (void)finishTranscript:(NSString *)transcript {
    NSString *finalText = [transcript stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (finalText.length == 0) {
        [self failWithMessage:@"I didn’t catch any speech. Hold left Option and speak a little longer."];
        return;
    }
    self.transcript = finalText;
    self.confirmedTranscript = finalText;
    self.elapsedSeconds = 0;
    self.recordingStartedAt = nil;
    self.isPushToTalk = NO;
    if (![self.delegate voiceController:self didFinishTranscript:finalText]) {
        MicaDiagnosticsLog(@"dictation", @"transcript recognized but could not be inserted into its captured shell");
        [self setState:MicaVoiceControllerStateFailed
                status:@"Transcript was not inserted. Copy it from this message and paste it manually."
              progress:-1];
        return;
    }
    [self setState:MicaVoiceControllerStateIdle status:@"" progress:-1];
}

- (void)forceFinishExitedHelper:(NSTimer *)timer {
    NSTask *finishedTask = timer.userInfo;
    if (self.helperExitTimer != timer || self.process != finishedTask ||
        !self.processTerminated || self.outputEOF) return;
    self.helperExitTimer = nil;
    if (self.processExitCode != 0 && !self.helperError.length) {
        if (self.processTerminationReason == NSTaskTerminationReasonUncaughtSignal) {
            const char *signalDescription = strsignal(self.processExitCode);
            self.helperError = [NSString stringWithFormat:
                @"Local speech helper was interrupted by signal %d (%@).", self.processExitCode,
                signalDescription ? [NSString stringWithUTF8String:signalDescription] : @"unknown signal"];
        } else {
            self.helperError = [NSString stringWithFormat:
                @"Local speech helper exited unexpectedly (status %d).", self.processExitCode];
        }
    }
    [self consumeHelperData:[NSData data] endOfFile:YES];
}

- (void)startAudioCapture {
    if (self.state != MicaVoiceControllerStatePreparing) return;
    NSError *error = nil;
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *inputFormat = [input outputFormatForBus:0];
    if (inputFormat.sampleRate <= 0 || inputFormat.channelCount == 0) {
        [self failWithMessage:@"No microphone input is available. Connect a microphone and try again."];
        return;
    }
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
        sampleRate:16000 channels:1 interleaved:NO];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:targetFormat];
    if (!targetFormat || !converter) {
        [self failWithMessage:@"Mica could not prepare the microphone audio format."];
        return;
    }

    self.audioEngine = engine;
    self.audioConverter = converter;
    self.audioTargetFormat = targetFormat;
    atomic_store(&_acceptAudio, true);
    atomic_store(&_discardQueuedAudio, false);
    atomic_store(&_audioOverflowReported, false);
    atomic_store(&_queuedAudioFrames, 0);

    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:4096 format:inputFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        MicaVoiceController *strongSelf = weakSelf;
        if (!strongSelf || !atomic_load(&strongSelf->_acceptAudio)) return;
        AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(buffer.frameLength * 16000.0 / inputFormat.sampleRate) + 64;
        AVAudioPCMBuffer *converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFormat frameCapacity:capacity];
        if (!converted) return;
        __block BOOL inputConsumed = NO;
        NSError *conversionError = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:converted error:&conversionError
            withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount packets, AVAudioConverterInputStatus *outStatus) {
                (void)packets;
                if (inputConsumed) {
                    *outStatus = AVAudioConverterInputStatus_NoDataNow;
                    return nil;
                }
                inputConsumed = YES;
                *outStatus = AVAudioConverterInputStatus_HaveData;
                return buffer;
            }];
        if (status == AVAudioConverterOutputStatus_Error || conversionError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf failWithMessage:[NSString stringWithFormat:@"Could not convert microphone audio: %@",
                    conversionError.localizedDescription ?: @"unknown audio format"]];
            });
            return;
        }
        if (converted.frameLength == 0) return;

        unsigned int frameCountValue = converted.frameLength;
        unsigned int queuedFrames = atomic_fetch_add(&strongSelf->_queuedAudioFrames, frameCountValue);
        if (queuedFrames + frameCountValue > 64000) {
            atomic_fetch_sub(&strongSelf->_queuedAudioFrames, frameCountValue);
            if (!atomic_exchange(&strongSelf->_audioOverflowReported, true)) {
                atomic_store(&strongSelf->_acceptAudio, false);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf failWithMessage:@"Live speech recognition fell behind the microphone. Stop and try a shorter dictation."];
                });
            }
            return;
        }

        NSData *payload = [NSData dataWithBytes:converted.floatChannelData[0]
            length:(NSUInteger)converted.frameLength * sizeof(float)];
        dispatch_async(strongSelf->_audioWriteQueue, ^{
            if (!atomic_load(&strongSelf->_discardQueuedAudio)) {
                if (atomic_load(&strongSelf->_audioHelperReady)) {
                    [strongSelf writeAudioPayload:payload frames:frameCountValue toWriter:strongSelf->_audioStreamWriter];
                } else {
                    const NSUInteger maximumBufferedFrames = 16000u * 120u;
                    if (strongSelf->_preparationAudioFrames + frameCountValue <= maximumBufferedFrames) {
                        [strongSelf->_preparationAudio appendData:payload];
                        strongSelf->_preparationAudioFrames += frameCountValue;
                    } else if (!atomic_exchange(&strongSelf->_audioOverflowReported, true)) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [strongSelf failWithMessage:@"Speech model preparation took too long. Dictation buffers up to two minutes while the model loads; try again after setup finishes."];
                        });
                    }
                }
            }
            atomic_fetch_sub(&strongSelf->_queuedAudioFrames, frameCountValue);
        });
    }];

    [engine prepare];
    if (![engine startAndReturnError:&error]) {
        [input removeTapOnBus:0];
        atomic_store(&_acceptAudio, false);
        [self failWithMessage:[NSString stringWithFormat:@"Could not start microphone capture: %@",
            error.localizedDescription ?: @"unknown audio error"]];
        return;
    }

    self.recordingStartedAt = [NSDate date];
    self.elapsedSeconds = 0;
    if (atomic_load(&_audioHelperReady)) {
        [self setState:MicaVoiceControllerStateListening
                status:@"Listening — release left ⌥ to finish · Esc cancels"
              progress:-1];
    }
    [self.elapsedTimer invalidate];
    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
        target:self selector:@selector(updateElapsedTime:) userInfo:nil repeats:YES];
}

- (void)stopListening {
    if (!self.recordingStartedAt || (self.state != MicaVoiceControllerStateListening &&
        self.state != MicaVoiceControllerStatePreparing)) return;
    [self stopAudioCaptureSendingCancel:NO];
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    [self setState:MicaVoiceControllerStateTranscribing
            status:(atomic_load(&_audioHelperReady) ? @"Finishing the live transcript…"
                                                    : @"Finishing transcript after model setup…")
          progress:-1];
}

- (void)helperBecameReady {
    dispatch_async(_audioWriteQueue, ^{
        if (atomic_load(&self->_discardQueuedAudio)) return;
        NSFileHandle *writer = self->_audioStreamWriter;
        [self flushPreparationAudioToWriter:writer];
        if (atomic_load(&self->_discardQueuedAudio)) return;
        atomic_store(&self->_audioHelperReady, true);
        if (self->_audioFinishRequested) [self finishAudioStreamWithWriter:writer];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.state != MicaVoiceControllerStatePreparing || !self.recordingStartedAt) return;
            [self setState:MicaVoiceControllerStateListening
                    status:@"Listening — release left ⌥ to finish · Esc cancels"
                  progress:-1];
        });
    });
}

- (void)writeAudioPayload:(NSData *)payload frames:(unsigned int)frames toWriter:(NSFileHandle *)writer {
    if (!writer || !payload.length || !frames) return;
    uint32_t littleEndianCount = CFSwapInt32HostToLittle(frames);
    NSMutableData *packet = [NSMutableData dataWithBytes:&littleEndianCount length:sizeof(littleEndianCount)];
    [packet appendData:payload];
    @try {
        [writer writeData:packet];
    } @catch (NSException *exception) {
        if (atomic_load(&_discardQueuedAudio)) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self failWithMessage:[NSString stringWithFormat:@"The live transcript stream stopped: %@",
                exception.reason ?: @"speech helper closed"]];
        });
    }
}

- (void)flushPreparationAudioToWriter:(NSFileHandle *)writer {
    if (!writer || !self->_preparationAudio.length) return;
    const NSUInteger bytesPerFrame = sizeof(float);
    const NSUInteger maximumPacketFrames = 160000;
    NSData *buffer = [self->_preparationAudio copy];
    NSUInteger offset = 0;
    while (offset < buffer.length && !atomic_load(&_discardQueuedAudio)) {
        NSUInteger remainingFrames = (buffer.length - offset) / bytesPerFrame;
        NSUInteger frames = MIN(maximumPacketFrames, remainingFrames);
        NSUInteger count = frames * bytesPerFrame;
        NSData *payload = [buffer subdataWithRange:NSMakeRange(offset, count)];
        [self writeAudioPayload:payload frames:(unsigned int)frames toWriter:writer];
        offset += count;
    }
    self->_preparationAudio = nil;
    self->_preparationAudioFrames = 0;
}

- (void)finishAudioStreamWithWriter:(NSFileHandle *)writer {
    if (!writer) return;
    self->_audioFinishRequested = NO;
    atomic_store(&_audioHelperReady, false);
    uint32_t finish = 0;
    @try {
        [writer writeData:[NSData dataWithBytes:&finish length:sizeof(finish)]];
        [writer closeFile];
    } @catch (__unused NSException *exception) {
        @try { [writer closeFile]; } @catch (__unused NSException *closeException) { }
    }
    if (self->_audioStreamWriter == writer) self->_audioStreamWriter = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.audioWriter == writer) self.audioWriter = nil;
    });
}

- (void)stopAudioCaptureSendingCancel:(BOOL)cancel {
    atomic_store(&_acceptAudio, false);
    if (cancel) atomic_store(&_discardQueuedAudio, true);
    AVAudioEngine *engine = self.audioEngine;
    if (engine) {
        [engine.inputNode removeTapOnBus:0];
        [engine stop];
    }
    self.audioEngine = nil;
    self.audioConverter = nil;
    self.audioTargetFormat = nil;
    if (cancel) {
        atomic_store(&_audioHelperReady, false);
        NSFileHandle *writer = self.audioWriter;
        self.audioWriter = nil;
        dispatch_async(_audioWriteQueue, ^{
            self->_preparationAudio = nil;
            self->_preparationAudioFrames = 0;
            self->_audioFinishRequested = NO;
            if (self->_audioStreamWriter == writer) self->_audioStreamWriter = nil;
            if (writer) @try { [writer closeFile]; } @catch (__unused NSException *exception) { }
        });
        return;
    }

    dispatch_async(_audioWriteQueue, ^{
        self->_audioFinishRequested = YES;
        if (atomic_load(&self->_audioHelperReady))
            [self finishAudioStreamWithWriter:self->_audioStreamWriter];
    });
}

- (void)updateElapsedTime:(NSTimer *)timer {
    (void)timer;
    if (!self.recordingStartedAt || (self.state != MicaVoiceControllerStateListening &&
        self.state != MicaVoiceControllerStatePreparing)) return;
    self.elapsedSeconds = -self.recordingStartedAt.timeIntervalSinceNow;
    [self notifyUpdate];
}

- (void)failWithMessage:(NSString *)message {
    MicaDiagnosticsLog(@"dictation", [NSString stringWithFormat:@"failed: %@", message ?: @"unknown error"]);
    [self stopAudioCaptureSendingCancel:YES];
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    [self.helperExitTimer invalidate];
    self.helperExitTimer = nil;
    self.process.terminationHandler = nil;
    if (self.process.isRunning) [self.process terminate];
    self.process = nil;
    [self releaseOutputPipe];
    self.audioPipe = nil;
    self.audioWriter = nil;
    self.transcript = @"";
    self.confirmedTranscript = @"";
    self.rawTranscript = nil;
    self.elapsedSeconds = 0;
    [self setState:MicaVoiceControllerStateFailed status:message ?: @"Dictation failed." progress:-1];
}

- (void)releaseOutputPipe {
    NSPipe *pipe = self.outputPipe;
    if (!pipe) return;
    NSFileHandle *reader = pipe.fileHandleForReading;
    reader.readabilityHandler = nil;
    @try { [reader closeFile]; } @catch (__unused NSException *exception) { }
    self.outputPipe = nil;
}

- (void)setState:(MicaVoiceControllerState)state status:(NSString *)status progress:(double)progress {
    self.state = state;
    self.statusText = status ?: @"";
    // A zero fraction means the helper is still checking or waiting for the
    // first bytes. Keep the UI indeterminate until a positive fraction arrives.
    self.hasProgress = progress > 0;
    self.progress = MIN(1.0, MAX(0.0, progress));
    BOOL waitingForProgress = !self.hasProgress &&
        (state == MicaVoiceControllerStatePreparing ||
         state == MicaVoiceControllerStateTranscribing);
    if (waitingForProgress && !self.progressRefreshTimer) {
        __weak typeof(self) weakSelf = self;
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(__unused NSTimer *tick) {
            [weakSelf notifyUpdate];
        }];
        self.progressRefreshTimer = timer;
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    } else if (!waitingForProgress) {
        [self.progressRefreshTimer invalidate];
        self.progressRefreshTimer = nil;
    }
    [self notifyUpdate];
}

- (void)notifyUpdate {
    [self.delegate voiceControllerDidUpdate:self];
}

@end
