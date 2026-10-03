#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, MicaAttentionKind) {
    MicaAttentionWaitingPermission, MicaAttentionWaitingInput, MicaAttentionDone,
    MicaAttentionError, MicaAttentionTimerEnd, MicaAttentionHighMemory,
};

@interface MicaAttentionInbox : NSObject
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, copy, nullable) void (^delivery)(NSDictionary *event);
- (BOOL)postTabID:(uint64_t)tabID kind:(MicaAttentionKind)kind title:(NSString *)title body:(NSString *)body muted:(BOOL)muted;
- (void)clearTabID:(uint64_t)tabID;
- (void)setMuted:(BOOL)muted tabID:(uint64_t)tabID;
- (BOOL)isMutedTabID:(uint64_t)tabID;
- (NSArray<NSDictionary *> *)events;
- (NSArray<NSNumber *> *)waitingTabIDs;
- (NSString * _Nullable)dockBadge;
@end
NS_ASSUME_NONNULL_END
