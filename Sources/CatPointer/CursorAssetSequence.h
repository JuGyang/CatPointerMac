#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger CPSystemCursorFrameLimit;

/// Loads the original HappyCadogt PNG sequence and prepares the exact frames
/// for macOS' private, 24-frame system-cursor format.
@interface CPCursorAssetSequence : NSObject

@property(nonatomic, copy, readonly) NSString *role;
@property(nonatomic, readonly) NSUInteger sourceFrameCount;
@property(nonatomic, readonly) NSUInteger registeredFrameCount;
@property(nonatomic, readonly) NSTimeInterval sourceFrameDuration;
@property(nonatomic, readonly) NSTimeInterval registeredFrameDuration;
@property(nonatomic, readonly) NSTimeInterval totalDuration;
@property(nonatomic, readonly) NSSize logicalSize;
@property(nonatomic, readonly) NSPoint logicalHotspot;
@property(nonatomic, copy, readonly) NSString *sourceAssetSHA256;
@property(nonatomic, readonly, getter=isMotionOptimized) BOOL motionOptimized;
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *
    selectedSourceFrameNumbers;

+ (nullable instancetype)sequenceForRole:(NSString *)role
                                   error:(NSError **)error;

+ (nullable instancetype)sequenceForRole:(NSString *)role
                  optimizedForSmoothness:(BOOL)optimizedForSmoothness
                                   error:(NSError **)error;

- (nullable NSArray *)createFilmstripRepresentationsAtScale:(CGFloat)scale
                                                       error:(NSError **)error;

/// Builds the same per-frame filmstrips from the unscaled 2x strip. At 100%
/// that strip contains the original cropped artist pixels, so this avoids
/// reopening every PNG when preparing another user-facing size.
- (nullable NSArray *)createFilmstripRepresentationsAtScale:(CGFloat)scale
                                        baseTwoXFilmstrip:
                                            (CGImageRef)baseTwoXFilmstrip
                                                       error:(NSError **)error;

- (nullable CGImageRef)createFrameAtRegisteredIndex:(NSUInteger)index
                                         pixelScale:(CGFloat)pixelScale
                                              error:(NSError **)error
    CF_RETURNS_RETAINED;

- (NSDictionary<NSString *, id> *)diagnostics;

@end

NS_ASSUME_NONNULL_END
