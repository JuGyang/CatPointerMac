#import "CursorAssetSequence.h"

#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <math.h>

const NSUInteger CPSystemCursorFrameLimit = 24;

static NSString *const CPAssetErrorDomain =
    @"com.local.catpointer.cursor-assets";

static NSDictionary<NSString *, id> *CPAssetMetadataForRole(
    NSString *role
) {
    static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        metadata;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        metadata = @{
            @"default": @{
                @"frameCount": @130,
                @"canvas": @240,
                @"crop": NSStringFromRect(
                    NSMakeRect(48, 48, 128, 120)
                ),
                @"sha256":
                    @"407827d370a0df8ba228f98ce7f3def8a281d3fe902b001504107dca4819d2a4",
            },
            @"text": @{
                @"frameCount": @140,
                @"canvas": @240,
                @"crop": NSStringFromRect(
                    NSMakeRect(32, 48, 128, 104)
                ),
                @"sha256":
                    @"9833bee08c269031d25fceadbb96a9058d3139a50185a3a06fe24e6837560453",
            },
            @"pointer": @{
                @"frameCount": @94,
                @"canvas": @240,
                @"crop": NSStringFromRect(
                    NSMakeRect(48, 48, 128, 96)
                ),
                @"sha256":
                    @"a6d8bb6790103fa9e241aa5318a391d48f95c1294c6d97d5005f54a0bcfc94b6",
            },
            @"progress": @{
                @"frameCount": @45,
                @"canvas": @240,
                @"crop": NSStringFromRect(
                    NSMakeRect(48, 48, 144, 144)
                ),
                @"sha256":
                    @"12234f1e600f160b07bc7a963b83a9ed58e396ba4a540c073979dae578811537",
            },
            @"wait": @{
                @"frameCount": @44,
                @"canvas": @240,
                @"crop": NSStringFromRect(
                    NSMakeRect(56, 56, 128, 128)
                ),
                @"sha256":
                    @"099698b0f63752ffd82f049e82deb292a78f4b4f9225eb068a6ea23a14e6a7fa",
            },
            @"size_hor": @{
                @"frameCount": @127,
                @"canvas": @256,
                @"crop": NSStringFromRect(
                    NSMakeRect(64, 48, 128, 112)
                ),
                @"sha256":
                    @"8e5eca64b621064c751990ad04ed4d833bd9fde874903d89188334f11a3a6a2f",
            },
            @"size_ver": @{
                @"frameCount": @164,
                @"canvas": @256,
                @"crop": NSStringFromRect(
                    NSMakeRect(80, 64, 128, 128)
                ),
                @"sha256":
                    @"75a878ef3757873e9b02d2777271d428379272ea8a8d6c6399650c9cdedf4ed8",
            },
        };
    });
    return metadata[role];
}

@interface CPCursorAssetSequence ()

@property(nonatomic, copy, readwrite) NSString *role;
@property(nonatomic, readwrite) NSUInteger sourceFrameCount;
@property(nonatomic, readwrite) NSUInteger registeredFrameCount;
@property(nonatomic, readwrite) NSTimeInterval sourceFrameDuration;
@property(nonatomic, readwrite) NSTimeInterval registeredFrameDuration;
@property(nonatomic, readwrite) NSTimeInterval totalDuration;
@property(nonatomic, readwrite) NSSize logicalSize;
@property(nonatomic, readwrite) NSPoint logicalHotspot;
@property(nonatomic, copy, readwrite) NSString *sourceAssetSHA256;
@property(nonatomic, readwrite, getter=isMotionOptimized) BOOL motionOptimized;
@property(nonatomic, copy, readwrite) NSArray<NSNumber *> *
    selectedSourceFrameNumbers;
@property(nonatomic, copy) NSArray<NSURL *> *sourceFrameURLs;
@property(nonatomic) NSRect sourceCropRect;

- (nullable CGImageRef)createFilmstripAtPixelScale:(CGFloat)pixelScale
                               baseTwoXFilmstrip:
                                   (CGImageRef)baseTwoXFilmstrip
                                              error:(NSError **)error
    CF_RETURNS_RETAINED;

@end

@implementation CPCursorAssetSequence

+ (nullable instancetype)sequenceForRole:(NSString *)role
                                   error:(NSError **)error {
    return [self sequenceForRole:role
         optimizedForSmoothness:NO
                          error:error];
}

+ (nullable instancetype)sequenceForRole:(NSString *)role
                  optimizedForSmoothness:(BOOL)optimizedForSmoothness
                                   error:(NSError **)error {
    NSDictionary<NSString *, id> *metadata =
        CPAssetMetadataForRole(role);
    if (metadata == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:1
                             description:[NSString stringWithFormat:
                @"未知猫标素材类型：%@", role]];
        }
        return nil;
    }

    NSURL *directory = [self assetDirectoryForRole:role];
    if (directory == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:2
                             description:[NSString stringWithFormat:
                @"找不到 HappyCadogt 原始 %@ 光标帧。", role]];
        }
        return nil;
    }

    NSURL *configurationURL = [directory
        URLByAppendingPathComponent:
            [role stringByAppendingPathExtension:@"conf"]
    ];
    NSError *readError = nil;
    NSString *configuration = [NSString
        stringWithContentsOfURL:configurationURL
                       encoding:NSUTF8StringEncoding
                          error:&readError
    ];
    if (configuration == nil) {
        if (error != NULL) {
            *error = readError ?: [self errorWithCode:3
                                           description:
                @"无法读取原始光标配置。"];
        }
        return nil;
    }

    NSMutableArray<NSURL *> *frameURLs = [NSMutableArray array];
    __block NSInteger sourceCanvasSize = 0;
    __block NSInteger sourceHotspotX = 0;
    __block NSInteger sourceHotspotY = 0;
    __block NSInteger sourceDelayMilliseconds = 0;
    __block NSInteger sourceTotalDurationMilliseconds = 0;
    __block NSError *parseError = nil;
    [configuration enumerateLinesUsingBlock:
        ^(NSString *line, BOOL *stop) {
            NSString *trimmed = [line
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet
            ];
            if (trimmed.length == 0 ||
                [trimmed hasPrefix:@"#"]) {
                return;
            }

            NSArray<NSString *> *rawFields = [trimmed
                componentsSeparatedByCharactersInSet:
                    NSCharacterSet.whitespaceCharacterSet
            ];
            NSMutableArray<NSString *> *fields =
                [NSMutableArray array];
            for (NSString *field in rawFields) {
                if (field.length > 0) {
                    [fields addObject:field];
                }
            }
            if (fields.count != 5) {
                parseError = [self errorWithCode:4
                                      description:
                    @"原始光标配置的帧格式无效。"];
                *stop = YES;
                return;
            }

            NSInteger canvas = fields[0].integerValue;
            NSInteger hotspotX = fields[1].integerValue;
            NSInteger hotspotY = fields[2].integerValue;
            NSInteger delay = fields[4].integerValue;
            if (canvas <= 0 || hotspotX < 0 || hotspotY < 0 ||
                delay <= 0) {
                parseError = [self errorWithCode:5
                                      description:
                    @"原始光标配置包含无效数值。"];
                *stop = YES;
                return;
            }
            if (frameURLs.count == 0) {
                sourceCanvasSize = canvas;
                sourceHotspotX = hotspotX;
                sourceHotspotY = hotspotY;
                sourceDelayMilliseconds = delay;
            } else if (canvas != sourceCanvasSize ||
                       hotspotX != sourceHotspotX ||
                       hotspotY != sourceHotspotY) {
                parseError = [self errorWithCode:6
                                      description:
                    @"原始动画的尺寸或热点不一致。"];
                *stop = YES;
                return;
            }
            sourceTotalDurationMilliseconds += delay;

            NSString *filename = fields[3].lastPathComponent;
            NSURL *frameURL =
                [directory URLByAppendingPathComponent:filename];
            if (![NSFileManager.defaultManager
                    fileExistsAtPath:frameURL.path]) {
                parseError = [self errorWithCode:7
                                      description:[NSString stringWithFormat:
                    @"原始猫标帧缺失：%@", filename]];
                *stop = YES;
                return;
            }
            [frameURLs addObject:frameURL];
        }
    ];
    if (parseError != nil || frameURLs.count == 0) {
        if (error != NULL) {
            *error = parseError ?: [self errorWithCode:8
                                           description:
                @"原始猫标动画没有可用帧。"];
        }
        return nil;
    }

    NSUInteger expectedFrameCount =
        [metadata[@"frameCount"] unsignedIntegerValue];
    NSInteger expectedCanvas = [metadata[@"canvas"] integerValue];
    if (sourceCanvasSize != expectedCanvas ||
        sourceDelayMilliseconds != 33 ||
        frameURLs.count != expectedFrameCount) {
        if (error != NULL) {
            *error = [self errorWithCode:9
                             description:[NSString stringWithFormat:
                @"%@ 原作素材校验失败（应为 %lu 张 %ldpx/约 33ms 原帧）。",
                role,
                (unsigned long)expectedFrameCount,
                (long)expectedCanvas]];
        }
        return nil;
    }

    NSData *configurationData =
        [NSData dataWithContentsOfURL:configurationURL];
    if (configurationData == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:16
                             description:
                @"无法校验原始光标配置内容。"];
        }
        return nil;
    }
    CC_SHA256_CTX hashContext;
    CC_SHA256_Init(&hashContext);
    CC_SHA256_Update(
        &hashContext,
        configurationData.bytes,
        (CC_LONG)configurationData.length
    );
    NSError *frameReadError = nil;
    for (NSURL *frameURL in frameURLs) {
        @autoreleasepool {
            NSData *frameData = [NSData dataWithContentsOfURL:frameURL];
            if (frameData == nil) {
                frameReadError = [self errorWithCode:17
                                         description:
                    @"无法校验原始猫标帧内容。"];
            } else {
                CC_SHA256_Update(
                    &hashContext,
                    frameData.bytes,
                    (CC_LONG)frameData.length
                );
            }
        }
        if (frameReadError != nil) {
            if (error != NULL) {
                *error = frameReadError;
            }
            return nil;
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hashContext);
    NSMutableString *assetSHA256 = [NSMutableString
        stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2
    ];
    for (NSUInteger index = 0;
         index < CC_SHA256_DIGEST_LENGTH;
         index++) {
        [assetSHA256 appendFormat:@"%02x", digest[index]];
    }
    NSString *expectedSHA256 = metadata[@"sha256"];
    if (![assetSHA256 isEqualToString:expectedSHA256]) {
        if (error != NULL) {
            *error = [self errorWithCode:18
                             description:[NSString stringWithFormat:
                @"%@ 原作素材内容哈希不匹配。", role]];
        }
        return nil;
    }

    CPCursorAssetSequence *sequence = [CPCursorAssetSequence new];
    sequence.role = role;
    sequence.sourceFrameURLs = frameURLs.copy;
    sequence.sourceFrameCount = frameURLs.count;
    sequence.sourceAssetSHA256 = assetSHA256.copy;
    sequence.registeredFrameCount =
        MIN(CPSystemCursorFrameLimit, frameURLs.count);
    sequence.sourceFrameDuration =
        sourceDelayMilliseconds / 1000.0;
    sequence.totalDuration =
        sourceTotalDurationMilliseconds / 1000.0;
    sequence.registeredFrameDuration =
        sequence.totalDuration / sequence.registeredFrameCount;
    sequence.motionOptimized = optimizedForSmoothness;

    // Crop only fully transparent padding. At standard scale these rectangles
    // map 2 source pixels to 1 macOS point, so the 2x representation contains
    // the original artist pixels without resampling.
    sequence.sourceCropRect =
        NSRectFromString(metadata[@"crop"]);
    sequence.logicalSize = NSMakeSize(
        NSWidth(sequence.sourceCropRect) / 2.0,
        NSHeight(sequence.sourceCropRect) / 2.0
    );
    sequence.logicalHotspot = NSMakePoint(
        (sourceHotspotX - NSMinX(sequence.sourceCropRect)) / 2.0,
        (sourceHotspotY - NSMinY(sequence.sourceCropRect)) / 2.0
    );

    if (optimizedForSmoothness) {
        // Anchor the first source frame, then use rounded equal-time samples.
        // This keeps each original cycle intact while distributing the
        // WindowServer's 24 available frames as evenly as possible.
        NSMutableArray<NSNumber *> *selected =
            [NSMutableArray array];
        for (NSUInteger index = 0;
             index < sequence.registeredFrameCount;
             index++) {
            double sourcePosition =
                (double)index * sequence.sourceFrameCount /
                sequence.registeredFrameCount;
            NSUInteger sourceIndex =
                (NSUInteger)floor(sourcePosition + 0.5);
            [selected addObject:@(sourceIndex + 1)];
        }
        sequence.selectedSourceFrameNumbers = selected.copy;
    } else {
        NSMutableArray<NSNumber *> *selected = [NSMutableArray array];
        for (NSUInteger index = 0;
             index < sequence.registeredFrameCount;
             index++) {
            NSUInteger sourceIndex =
                (index * sequence.sourceFrameCount) /
                sequence.registeredFrameCount;
            [selected addObject:@(sourceIndex + 1)];
        }
        sequence.selectedSourceFrameNumbers = selected.copy;
    }
    return sequence;
}

+ (nullable NSURL *)assetDirectoryForRole:(NSString *)role {
    NSArray<NSURL *> *candidates;
    NSURL *bundleResources = NSBundle.mainBundle.resourceURL;
    NSURL *bundleCandidate = bundleResources == nil ? nil :
        [[bundleResources URLByAppendingPathComponent:@"Cursors"
                                           isDirectory:YES]
            URLByAppendingPathComponent:role
                             isDirectory:YES];

    NSString *executablePath =
        NSProcessInfo.processInfo.arguments.firstObject.stringByStandardizingPath;
    NSString *projectRoot = executablePath;
    for (NSUInteger level = 0; level < 3; level++) {
        projectRoot = projectRoot.stringByDeletingLastPathComponent;
    }
    NSURL *developmentCandidate = [NSURL fileURLWithPath:
        [[projectRoot stringByAppendingPathComponent:@"Resources/Cursors"]
            stringByAppendingPathComponent:role]
        isDirectory:YES
    ];
    NSURL *workingDirectoryCandidate = [NSURL fileURLWithPath:
        [[NSFileManager.defaultManager.currentDirectoryPath
            stringByAppendingPathComponent:@"Resources/Cursors"]
            stringByAppendingPathComponent:role]
        isDirectory:YES
    ];
    candidates = @[
        bundleCandidate ?: [NSURL fileURLWithPath:@"/nonexistent"],
        developmentCandidate,
        workingDirectoryCandidate,
    ];

    for (NSURL *candidate in candidates) {
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager
                fileExistsAtPath:candidate.path
                     isDirectory:&isDirectory] &&
            isDirectory) {
            return candidate;
        }
    }
    return nil;
}

- (nullable NSArray *)createFilmstripRepresentationsAtScale:(CGFloat)scale
                                                       error:(NSError **)error {
    CGFloat clampedScale = fmax(0.75, fmin(1.25, scale));
    CGImageRef strip1x = [self createFilmstripAtPixelScale:clampedScale
                                                    error:error];
    if (strip1x == NULL) {
        return nil;
    }
    CGImageRef strip2x = [self createFilmstripAtPixelScale:
        clampedScale * 2.0
                                                    error:error];
    if (strip2x == NULL) {
        CGImageRelease(strip1x);
        return nil;
    }

    NSArray *representations = @[
        (__bridge id)strip1x,
        (__bridge id)strip2x,
    ];
    CGImageRelease(strip1x);
    CGImageRelease(strip2x);
    return representations;
}

- (nullable NSArray *)createFilmstripRepresentationsAtScale:(CGFloat)scale
                                        baseTwoXFilmstrip:
                                            (CGImageRef)baseTwoXFilmstrip
                                                       error:(NSError **)error {
    if (baseTwoXFilmstrip == NULL) {
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:19
                                               description:
                @"用于快速缩放的标准猫标动画不存在。"];
        }
        return nil;
    }
    CGFloat clampedScale = fmax(0.75, fmin(1.25, scale));
    CGImageRef strip1x = [self
        createFilmstripAtPixelScale:clampedScale
               baseTwoXFilmstrip:baseTwoXFilmstrip
                              error:error];
    if (strip1x == NULL) {
        return nil;
    }
    CGImageRef strip2x = [self
        createFilmstripAtPixelScale:clampedScale * 2.0
               baseTwoXFilmstrip:baseTwoXFilmstrip
                              error:error];
    if (strip2x == NULL) {
        CGImageRelease(strip1x);
        return nil;
    }

    NSArray *representations = @[
        (__bridge id)strip1x,
        (__bridge id)strip2x,
    ];
    CGImageRelease(strip1x);
    CGImageRelease(strip2x);
    return representations;
}

- (nullable CGImageRef)createFilmstripAtPixelScale:(CGFloat)pixelScale
                               baseTwoXFilmstrip:
                                   (CGImageRef)baseTwoXFilmstrip
                                              error:(NSError **)error
    CF_RETURNS_RETAINED {
    size_t sourceFrameWidth =
        (size_t)lround(self.logicalSize.width * 2.0);
    size_t sourceFrameHeight =
        (size_t)lround(self.logicalSize.height * 2.0);
    if (CGImageGetWidth(baseTwoXFilmstrip) != sourceFrameWidth ||
        CGImageGetHeight(baseTwoXFilmstrip) !=
            sourceFrameHeight * self.registeredFrameCount) {
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:20
                                               description:
                @"标准猫标动画的尺寸不正确。"];
        }
        return NULL;
    }

    size_t frameWidth =
        (size_t)MAX(1, lround(self.logicalSize.width * pixelScale));
    size_t frameHeight =
        (size_t)MAX(1, lround(self.logicalSize.height * pixelScale));
    size_t stripHeight = frameHeight * self.registeredFrameCount;
    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        NULL,
        frameWidth,
        stripHeight,
        8,
        frameWidth * 4,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:21
                                               description:
                @"无法创建缩放后的猫标动画胶片。"];
        }
        return NULL;
    }
    CGContextClearRect(
        context,
        CGRectMake(0, 0, frameWidth, stripHeight)
    );
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);

    for (NSUInteger index = 0;
         index < self.registeredFrameCount;
         index++) {
        CGImageRef frame = CGImageCreateWithImageInRect(
            baseTwoXFilmstrip,
            CGRectMake(
                0,
                index * sourceFrameHeight,
                sourceFrameWidth,
                sourceFrameHeight
            )
        );
        if (frame == NULL) {
            CGContextRelease(context);
            if (error != NULL) {
                *error = [CPCursorAssetSequence errorWithCode:22
                                                   description:
                    @"无法读取标准猫标动画帧。"];
            }
            return NULL;
        }
        CGFloat y =
            (CGFloat)(self.registeredFrameCount - index - 1) *
            frameHeight;
        CGContextDrawImage(
            context,
            CGRectMake(0, y, frameWidth, frameHeight),
            frame
        );
        CGImageRelease(frame);
    }

    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

- (nullable CGImageRef)createFilmstripAtPixelScale:(CGFloat)pixelScale
                                             error:(NSError **)error
    CF_RETURNS_RETAINED {
    size_t frameWidth =
        (size_t)MAX(1, lround(self.logicalSize.width * pixelScale));
    size_t frameHeight =
        (size_t)MAX(1, lround(self.logicalSize.height * pixelScale));
    size_t stripHeight = frameHeight * self.registeredFrameCount;
    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        NULL,
        frameWidth,
        stripHeight,
        8,
        frameWidth * 4,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:10
                                               description:
                @"无法创建原作猫标动画胶片。"];
        }
        return NULL;
    }
    CGContextClearRect(
        context,
        CGRectMake(0, 0, frameWidth, stripHeight)
    );
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);

    for (NSUInteger index = 0;
         index < self.registeredFrameCount;
         index++) {
        CGImageRef frame = [self
            createFrameAtRegisteredIndex:index
                              pixelScale:pixelScale
                                   error:error
        ];
        if (frame == NULL) {
            CGContextRelease(context);
            return NULL;
        }
        CGFloat y =
            (CGFloat)(self.registeredFrameCount - index - 1) *
            frameHeight;
        CGContextDrawImage(
            context,
            CGRectMake(0, y, frameWidth, frameHeight),
            frame
        );
        CGImageRelease(frame);
    }

    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

- (nullable CGImageRef)createFrameAtRegisteredIndex:(NSUInteger)index
                                         pixelScale:(CGFloat)pixelScale
                                              error:(NSError **)error
    CF_RETURNS_RETAINED {
    if (index >= self.selectedSourceFrameNumbers.count) {
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:11
                                               description:
                @"请求了不存在的猫标动画帧。"];
        }
        return NULL;
    }

    NSUInteger sourceFrameNumber =
        self.selectedSourceFrameNumbers[index].unsignedIntegerValue;
    NSURL *sourceURL = self.sourceFrameURLs[sourceFrameNumber - 1];
    CGImageSourceRef source = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)sourceURL,
        NULL
    );
    if (source == NULL) {
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:12
                                               description:[NSString
                stringWithFormat:@"无法打开原作帧 %lu。",
                (unsigned long)sourceFrameNumber]];
        }
        return NULL;
    }
    CGImageRef fullFrame =
        CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (fullFrame == NULL) {
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:13
                                               description:[NSString
                stringWithFormat:@"无法解码原作帧 %lu。",
                (unsigned long)sourceFrameNumber]];
        }
        return NULL;
    }

    CGImageRef cropped = CGImageCreateWithImageInRect(
        fullFrame,
        NSRectToCGRect(self.sourceCropRect)
    );
    CGImageRelease(fullFrame);
    if (cropped == NULL) {
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:14
                                               description:
                @"无法裁掉原作帧的透明边缘。"];
        }
        return NULL;
    }

    size_t outputWidth =
        (size_t)MAX(1, lround(self.logicalSize.width * pixelScale));
    size_t outputHeight =
        (size_t)MAX(1, lround(self.logicalSize.height * pixelScale));
    if (CGImageGetWidth(cropped) == outputWidth &&
        CGImageGetHeight(cropped) == outputHeight) {
        return cropped;
    }

    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        NULL,
        outputWidth,
        outputHeight,
        8,
        outputWidth * 4,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        CGImageRelease(cropped);
        if (error != NULL) {
            *error = [CPCursorAssetSequence errorWithCode:15
                                               description:
                @"无法缩放原作猫标帧。"];
        }
        return NULL;
    }
    CGContextClearRect(
        context,
        CGRectMake(0, 0, outputWidth, outputHeight)
    );
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(
        context,
        CGRectMake(0, 0, outputWidth, outputHeight),
        cropped
    );
    CGImageRelease(cropped);
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

- (NSDictionary<NSString *, id> *)diagnostics {
    return @{
        @"role": self.role,
        @"sourceFrameCount": @(self.sourceFrameCount),
        @"registeredFrameCount": @(self.registeredFrameCount),
        @"sourceFrameDuration": @(self.sourceFrameDuration),
        @"registeredFrameDuration": @(self.registeredFrameDuration),
        @"totalDuration": @(self.totalDuration),
        @"logicalWidth": @(self.logicalSize.width),
        @"logicalHeight": @(self.logicalSize.height),
        @"hotspotX": @(self.logicalHotspot.x),
        @"hotspotY": @(self.logicalHotspot.y),
        @"selectedSourceFrames": self.selectedSourceFrameNumbers,
        @"sourceAssetSHA256": self.sourceAssetSHA256,
        @"motionOptimized": @(self.motionOptimized),
        @"artwork": @"HappyCadogt original PNG frames",
    };
}

+ (NSError *)errorWithCode:(NSInteger)code
               description:(NSString *)description {
    return [NSError errorWithDomain:CPAssetErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: description,
    }];
}

@end
