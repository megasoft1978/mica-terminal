#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Best-effort local archive for dictation audio and recognition metadata.
/// Archive errors are intentionally not surfaced to the live dictation path.
@interface MicaDictationHistory : NSObject

@property(nonatomic, readonly) NSURL *archiveRootURL;

+ (instancetype)sharedStore;

/// Creates a record synchronously and returns nil when the archive cannot accept it.
/// The caller should continue dictation when nil is returned.
- (nullable NSUUID *)beginRecordWithMetadata:(NSDictionary<NSString *, id> *)metadata;

/// These methods copy/enqueue audio and perform file I/O on the store's serial queue.
- (void)appendMicrophoneBuffer:(AVAudioPCMBuffer *)buffer recordID:(NSUUID *)recordID;
- (void)appendModelInputSamples:(NSData *)samples recordID:(NSUUID *)recordID;

/// Finishes only after all previously queued audio writes have been flushed.
- (void)finishRecordID:(NSUUID *)recordID withMetadata:(NSDictionary<NSString *, id> *)metadata;
- (void)cancelRecordID:(NSUUID *)recordID;
- (void)updateRecordID:(NSUUID *)recordID withMetadata:(NSDictionary<NSString *, id> *)metadata;
- (void)flushWithCompletion:(void (^)(void))completion;

/// Injectable archive root for tests and isolated callers.
- (instancetype)initWithRootURL:(NSURL *)rootURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
