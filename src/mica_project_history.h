#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MicaProjectHistory : NSObject

@property (nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *projects;

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (void)recordLayoutPath:(NSString *)path name:(NSString *)name;
- (void)clear;

@end

NS_ASSUME_NONNULL_END
