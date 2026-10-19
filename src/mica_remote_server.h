#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NSDictionary * _Nullable (^MicaRemoteSnapshot)(void);
typedef NSString * _Nullable (^MicaRemoteScreenSnapshot)(NSString *tabID);
typedef BOOL (^MicaRemoteSendText)(NSString *tabID, NSString *text);
typedef BOOL (^MicaRemoteSelectTab)(NSString *tabID);

@interface MicaRemoteServer : NSObject
@property(nonatomic, copy, readonly, nullable) NSString *pairingCode;
@property(nonatomic, copy, readonly, nullable) NSString *localURL;
@property(nonatomic, copy, readonly, nullable) NSString *pairingPayload;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, copy, nullable) MicaRemoteSnapshot snapshot;
@property(nonatomic, copy, nullable) MicaRemoteScreenSnapshot screenSnapshot;
@property(nonatomic, copy, nullable) MicaRemoteSendText sendText;
@property(nonatomic, copy, nullable) MicaRemoteSelectTab selectTab;
+ (instancetype)sharedServer;
- (BOOL)start;
- (nullable NSString *)renewPairingCode;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
