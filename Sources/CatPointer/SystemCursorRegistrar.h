#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CPSystemCursorErrorDomain;

@interface CPSystemCursorRegistrar : NSObject

@property(nonatomic, readonly, getter=isAvailable) BOOL available;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly, copy, nullable) NSString *unavailableReason;
@property(nonatomic, readonly) CGFloat scale;
/// Zero keeps the source cycle duration. Positive values request a constant
/// display rate. Every speed shares the same high-fidelity original frames.
@property(nonatomic, readonly) CGFloat targetFramesPerSecond;

- (BOOL)startWithScale:(CGFloat)scale error:(NSError **)error;
- (BOOL)reapplyWithScale:(CGFloat)scale error:(NSError **)error;
- (BOOL)startWithScale:(CGFloat)scale
 targetFramesPerSecond:(CGFloat)targetFramesPerSecond
                 error:(NSError **)error;
- (BOOL)reapplyWithScale:(CGFloat)scale
   targetFramesPerSecond:(CGFloat)targetFramesPerSecond
                   error:(NSError **)error;
/// Reasserts the newly registered cursor now and on the next main-loop turn.
/// This avoids a stale AppKit cursor seed winning at the end of the settings
/// mouse event, without synthesizing or intercepting any input.
- (BOOL)refreshVisibleCursorAfterSettingChange;
/// Prepares the bounded set of user-facing size choices off the main thread.
/// This only renders image assets into a bounded local cache; it never touches
/// the WindowServer cursor registry or observes input.
- (void)prewarmScales:(NSArray<NSNumber *> *)scales
targetFramesPerSecond:(CGFloat)targetFramesPerSecond;
/// Waits for already-requested local image preparation to finish. Call only
/// from outside the private prewarm queue.
- (void)waitForPrewarming;
- (void)cancelPrewarming;
- (void)stop;
- (BOOL)stopWithError:(NSError **)error;
- (void)restoreStaleBackup;
- (BOOL)restoreStaleBackupWithError:(NSError **)error;

- (NSDictionary<NSString *, id> *)performSelfTestWithScale:(CGFloat)scale
                                                      error:(NSError **)error;
- (NSDictionary<NSString *, id> *)liveCursorProbe;
- (BOOL)writePreviewToURL:(NSURL *)url error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
