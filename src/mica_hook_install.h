#import <Cocoa/Cocoa.h>

@interface MicaHookInstall : NSObject
+ (NSArray<NSString *> *)claudeConfigDirsForHome:(NSString *)home env:(NSDictionary *)env;
+ (NSDictionary *)previewForHome:(NSString *)home env:(NSDictionary *)env error:(NSError **)error;
+ (BOOL)applyForHome:(NSString *)home env:(NSDictionary *)env remove:(BOOL)remove error:(NSError **)error;
+ (NSDictionary *)previewForHome:(NSString *)home error:(NSError **)error;
+ (BOOL)applyForHome:(NSString *)home remove:(BOOL)remove error:(NSError **)error;
+ (void)presentFromWindow:(NSWindow *)window;
@end
