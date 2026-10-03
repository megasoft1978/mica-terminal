#import <Foundation/Foundation.h>
#include <stdint.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN
@interface MicaAgentRSSMonitor : NSObject
@property(nonatomic, copy) uint64_t (^sampler)(pid_t rootPid);
@property(nonatomic) uint64_t thresholdBytes;
- (NSDictionary<NSNumber *, NSNumber *> *)sampleTabs:(NSArray *)tabs;
- (NSArray<NSNumber *> *)crossingsForSamples:(NSDictionary<NSNumber *, NSNumber *> *)samples;
@end
NS_ASSUME_NONNULL_END
