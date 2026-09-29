#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, MicaVoiceControllerState) {
    MicaVoiceControllerStateIdle = 0,
    MicaVoiceControllerStatePreparing,
    MicaVoiceControllerStateListening,
    MicaVoiceControllerStateTranscribing,
    MicaVoiceControllerStateFailed,
};

@class MicaVoiceController;

@protocol MicaVoiceControllerDelegate <NSObject>
- (void)voiceControllerDidUpdate:(MicaVoiceController *)controller;
- (BOOL)voiceController:(MicaVoiceController *)controller
      didFinishTranscript:(NSString *)transcript;
@end

@interface MicaVoiceController : NSObject
@property(nonatomic, weak) id<MicaVoiceControllerDelegate> delegate;
@property(nonatomic, assign, readonly) MicaVoiceControllerState state;
@property(nonatomic, copy, readonly) NSString *statusText;
@property(nonatomic, copy, readonly) NSString *transcript;
@property(nonatomic, copy, readonly) NSString *confirmedTranscript;
@property(nonatomic, assign, readonly) NSTimeInterval elapsedSeconds;
@property(nonatomic, assign, readonly) double progress;
@property(nonatomic, assign, readonly) BOOL hasProgress;
@property(nonatomic, assign, readonly) BOOL isPushToTalk;

- (instancetype)initWithHelperURL:(NSURL *)helperURL;
- (void)startPushToTalkForWorkingDirectory:(NSString *)workingDirectory;
- (void)finishPushToTalk;
- (void)cancel;
// After an app update Core ML recompiles the speech model on first use (about 30 s). Run that once in
// the background, only when the model is already downloaded, and only once per helper build.
- (void)prewarmSpeechModelIfNeeded;
@end
