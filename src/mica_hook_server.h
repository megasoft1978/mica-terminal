#import <Foundation/Foundation.h>
#import "mica_hook.h"

typedef void (^MicaHookDelivery)(MicaHookEvent event);
@interface MicaHookServer : NSObject
@property(nonatomic, copy, readonly) NSString *socketPath;
@property(nonatomic, copy) MicaHookDelivery delivery;
+ (instancetype)sharedServer;
- (BOOL)startAtPath:(NSString *)path;
- (void)stop;
@end
