#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSUInteger const MicaSSHProfileMaximumCount;

/// Returns a normalized profile or nil with a user-presentable validation error.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> * _Nullable
MicaSSHProfileNormalize(NSDictionary *candidate, NSError **error);

/// Returns an ssh command for Mica's existing interactive zsh launcher.
/// The remote path is quoted for the remote POSIX shell, and each local
/// argument is quoted independently for zsh. No shell data is evaluated here.
FOUNDATION_EXPORT NSString * _Nullable
MicaSSHProfileCommand(NSDictionary<NSString *, NSString *> *profile);

NS_ASSUME_NONNULL_END
