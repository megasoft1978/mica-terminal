#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN
@interface MicaStatusItem : NSObject <NSMenuDelegate>
- (void)enableWithMenuBuilder:(NSMenu * (^)(void))builder;
- (void)disable;
- (void)updateTitle:(NSString *)title accessibilityLabel:(NSString *)label;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@end
NS_ASSUME_NONNULL_END
