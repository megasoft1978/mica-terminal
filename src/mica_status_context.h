#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MicaStatusActivity) {
    MicaStatusActivityIdle,
    MicaStatusActivityRunning,
    MicaStatusActivityWaiting,
    MicaStatusActivityNeedsAttention,
    MicaStatusActivityFinished,
};

FOUNDATION_EXPORT NSString *MicaStatusContextForCommand(NSString *commandName,
    NSString * _Nullable agentName, NSString * _Nullable agentState, NSString * _Nullable agentActivity,
    MicaStatusActivity activity, BOOL hasAgentHook, BOOL completed, int exitStatus);

NS_ASSUME_NONNULL_END
