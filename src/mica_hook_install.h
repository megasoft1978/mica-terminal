#import <Cocoa/Cocoa.h>

@interface MicaHookInstall : NSObject
+ (NSDictionary *)previewForHome:(NSString *)home error:(NSError **)error;
+ (BOOL)applyForHome:(NSString *)home remove:(BOOL)remove error:(NSError **)error;
+ (void)presentFromWindow:(NSWindow *)window;
@end
