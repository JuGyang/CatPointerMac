#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdbool.h>

typedef int CPWindowServerConnection;
typedef CPWindowServerConnection (*CPMainConnectionFunction)(void);
typedef CGError (*CPRegisterCursorFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    bool globally,
    bool instantly,
    CGSize size,
    CGPoint hotspot,
    NSUInteger frameCount,
    CGFloat frameDuration,
    CFArrayRef images,
    int *seed
);
typedef CGError (*CPCopyCursorFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    CGSize *size,
    CGPoint *hotspot,
    NSUInteger *frameCount,
    CGFloat *frameDuration,
    CFArrayRef *images
);
typedef CGError (*CPRemoveCursorFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    bool unknownFlag
);
typedef CGError (*CPGetCursorDataSizeFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    size_t *size
);
typedef CGError (*CPSetRegisteredCursorFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    int *seed
);
typedef CGError (*CPGetGlobalCursorDataSizeFunction)(
    CPWindowServerConnection connection,
    int *size
);
typedef CGError (*CPGetGlobalCursorDataFunction)(
    CPWindowServerConnection connection,
    void *data,
    int *dataSize,
    int *bytesPerRow,
    CGRect *cursorBounds,
    CGPoint *hotspot,
    int *bitsPerPixel,
    int *samplesPerPixel,
    int *bitsPerSample
);

static CGImageRef CPCreateFilmstrip(size_t frameWidth,
                                    size_t frameHeight,
                                    NSUInteger frameCount)
    CF_RETURNS_RETAINED {
    if (frameCount == 0 ||
        frameHeight > SIZE_MAX / frameCount ||
        frameWidth > SIZE_MAX / 4) {
        return NULL;
    }

    size_t stripHeight = frameHeight * frameCount;
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
        return NULL;
    }

    CGContextClearRect(
        context,
        CGRectMake(0, 0, frameWidth, stripHeight)
    );
    for (NSUInteger index = 0; index < frameCount; index++) {
        CGFloat red = (CGFloat)((index * 37U) % 251U) / 250.0;
        CGFloat green = (CGFloat)((index * 71U) % 241U) / 240.0;
        CGFloat blue = (CGFloat)((index * 101U) % 239U) / 238.0;
        CGContextSetRGBFillColor(context, red, green, blue, 1.0);
        CGContextFillRect(
            context,
            CGRectMake(
                0,
                (CGFloat)index * frameHeight,
                frameWidth,
                frameHeight
            )
        );
    }

    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static NSArray<NSDictionary *> *CPImageMetadata(CFArrayRef images) {
    if (images == NULL) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    CFIndex count = CFArrayGetCount(images);
    for (CFIndex index = 0; index < count; index++) {
        CGImageRef image =
            (CGImageRef)CFArrayGetValueAtIndex(images, index);
        [result addObject:@{
            @"width": @(CGImageGetWidth(image)),
            @"height": @(CGImageGetHeight(image)),
            @"bytesPerRow": @(CGImageGetBytesPerRow(image)),
        }];
    }
    return result.copy;
}

static NSDictionary *CPGlobalCursorMetadata(
    CPWindowServerConnection connection,
    CPGetGlobalCursorDataSizeFunction getSize,
    CPGetGlobalCursorDataFunction getData
) {
    int byteCount = 0;
    CGError sizeError = getSize(connection, &byteCount);
    if (sizeError != kCGErrorSuccess || byteCount <= 0 ||
        byteCount > 128 * 1024 * 1024) {
        return @{
            @"sizeError": @(sizeError),
            @"dataBytes": @(byteCount),
        };
    }

    NSMutableData *bytes =
        [NSMutableData dataWithLength:(NSUInteger)byteCount];
    int mutableByteCount = byteCount;
    int bytesPerRow = 0;
    CGRect cursorBounds = CGRectZero;
    CGPoint hotspot = CGPointZero;
    int bitsPerPixel = 0;
    int samplesPerPixel = 0;
    int bitsPerSample = 0;
    CGError dataError = getData(
        connection,
        bytes.mutableBytes,
        &mutableByteCount,
        &bytesPerRow,
        &cursorBounds,
        &hotspot,
        &bitsPerPixel,
        &samplesPerPixel,
        &bitsPerSample
    );
    if (dataError != kCGErrorSuccess || mutableByteCount < 0 ||
        (NSUInteger)mutableByteCount > bytes.length) {
        return @{
            @"sizeError": @(sizeError),
            @"dataError": @(dataError),
            @"dataBytes": @(mutableByteCount),
        };
    }
    const uint8_t *cursorBytes = bytes.bytes;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (NSUInteger index = 0;
         index < (NSUInteger)mutableByteCount;
         index++) {
        hash ^= cursorBytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return @{
        @"sizeError": @(sizeError),
        @"dataError": @(dataError),
        @"dataBytes": @(mutableByteCount),
        @"width": @(cursorBounds.size.width),
        @"height": @(cursorBounds.size.height),
        @"hotspotX": @(hotspot.x),
        @"hotspotY": @(hotspot.y),
        @"bytesPerRow": @(bytesPerRow),
        @"bitsPerPixel": @(bitsPerPixel),
        @"samplesPerPixel": @(samplesPerPixel),
        @"bitsPerSample": @(bitsPerSample),
        @"fnv1a64": [NSString stringWithFormat:@"%016llx", hash],
    };
}

static void CPWriteJSON(id object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object
                                                   options:
        NSJSONWritingSortedKeys
                                                     error:nil];
    [NSFileHandle.fileHandleWithStandardOutput writeData:json];
    [NSFileHandle.fileHandleWithStandardOutput writeData:
        [@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(
                stderr,
                "usage: %s FRAME_COUNT [FRAME_WIDTH FRAME_HEIGHT [activate]]\n",
                argv[0]
            );
            return 64;
        }

        NSUInteger requestedFrames =
            (NSUInteger)strtoull(argv[1], NULL, 10);
        size_t frameWidth =
            argc >= 3 ? (size_t)strtoull(argv[2], NULL, 10) : 8;
        size_t frameHeight =
            argc >= 4 ? (size_t)strtoull(argv[3], NULL, 10) : 8;
        BOOL activate = argc >= 5 &&
            strcmp(argv[4], "activate") == 0;
        if (requestedFrames == 0 || frameWidth == 0 ||
            frameHeight == 0) {
            return 64;
        }

        CPMainConnectionFunction mainConnection =
            (CPMainConnectionFunction)dlsym(
                RTLD_DEFAULT,
                "CGSMainConnectionID"
            );
        CPRegisterCursorFunction registerCursor =
            (CPRegisterCursorFunction)dlsym(
                RTLD_DEFAULT,
                "CGSRegisterCursorWithImages"
            );
        CPCopyCursorFunction copyCursor =
            (CPCopyCursorFunction)dlsym(
                RTLD_DEFAULT,
                "CGSCopyRegisteredCursorImages"
            );
        CPRemoveCursorFunction removeCursor =
            (CPRemoveCursorFunction)dlsym(
                RTLD_DEFAULT,
                "CGSRemoveRegisteredCursor"
            );
        CPGetCursorDataSizeFunction getCursorDataSize =
            (CPGetCursorDataSizeFunction)dlsym(
                RTLD_DEFAULT,
                "CGSGetRegisteredCursorDataSize"
            );
        CPSetRegisteredCursorFunction setRegisteredCursor =
            (CPSetRegisteredCursorFunction)dlsym(
                RTLD_DEFAULT,
                "CGSSetRegisteredCursor"
            );
        CPGetGlobalCursorDataSizeFunction getGlobalCursorDataSize =
            (CPGetGlobalCursorDataSizeFunction)dlsym(
                RTLD_DEFAULT,
                "CGSGetGlobalCursorDataSize"
            );
        CPGetGlobalCursorDataFunction getGlobalCursorData =
            (CPGetGlobalCursorDataFunction)dlsym(
                RTLD_DEFAULT,
                "CGSGetGlobalCursorData"
            );
        if (mainConnection == NULL || registerCursor == NULL ||
            copyCursor == NULL || removeCursor == NULL ||
            getCursorDataSize == NULL ||
            (activate &&
             (setRegisteredCursor == NULL ||
              getGlobalCursorDataSize == NULL ||
              getGlobalCursorData == NULL))) {
            return 2;
        }

        CPWindowServerConnection connection = mainConnection();
        NSString *identifier = [NSString stringWithFormat:
            @"com.local.catpointer.frameprobe.%d.%llu.%zux%zu",
            getpid(),
            (unsigned long long)requestedFrames,
            frameWidth,
            frameHeight
        ];
        fprintf(stderr, "probe identifier: %s\n", identifier.UTF8String);

        CGImageRef filmstrip1x =
            CPCreateFilmstrip(frameWidth, frameHeight, requestedFrames);
        CGImageRef filmstrip2x =
            CPCreateFilmstrip(
                frameWidth * 2,
                frameHeight * 2,
                requestedFrames
            );
        if (filmstrip1x == NULL || filmstrip2x == NULL) {
            if (filmstrip1x != NULL) CGImageRelease(filmstrip1x);
            if (filmstrip2x != NULL) CGImageRelease(filmstrip2x);
            return 3;
        }

        NSArray *images = @[
            (__bridge id)filmstrip1x,
            (__bridge id)filmstrip2x,
        ];
        size_t preDataSize = 0;
        CGError preDataError = getCursorDataSize(
            connection,
            (char *)identifier.UTF8String,
            &preDataSize
        );
        int seed = 0;
        CGError registerError = registerCursor(
            connection,
            (char *)identifier.UTF8String,
            false,
            false,
            CGSizeMake(frameWidth, frameHeight),
            CGPointMake(1.0, 1.0),
            requestedFrames,
            0.05,
            (__bridge CFArrayRef)images,
            &seed
        );

        size_t registeredDataSize = 0;
        CGError registeredDataError = getCursorDataSize(
            connection,
            (char *)identifier.UTF8String,
            &registeredDataSize
        );

        CGSize copiedSize = CGSizeZero;
        CGPoint copiedHotspot = CGPointZero;
        NSUInteger copiedFrames = 0;
        CGFloat copiedDuration = 0;
        CFArrayRef copiedImages = NULL;
        CGError copyError = copyCursor(
            connection,
            (char *)identifier.UTF8String,
            &copiedSize,
            &copiedHotspot,
            &copiedFrames,
            &copiedDuration,
            &copiedImages
        );
        NSArray *copiedImageMetadata =
            CPImageMetadata(copiedImages);

        NSDictionary *globalBefore = nil;
        NSDictionary *globalActive = nil;
        NSDictionary *globalAfter = nil;
        CGError activateError = -1;
        CGError restoreError = -1;
        if (activate && registerError == kCGErrorSuccess) {
            globalBefore = CPGlobalCursorMetadata(
                connection,
                getGlobalCursorDataSize,
                getGlobalCursorData
            );
            int activeSeed = 0;
            activateError = setRegisteredCursor(
                connection,
                (char *)identifier.UTF8String,
                &activeSeed
            );
            if (activateError == kCGErrorSuccess) {
                globalActive = CPGlobalCursorMetadata(
                    connection,
                    getGlobalCursorDataSize,
                    getGlobalCursorData
                );
            }
            int restoreSeed = 0;
            restoreError = setRegisteredCursor(
                connection,
                "com.apple.coregraphics.ArrowS",
                &restoreSeed
            );
            globalAfter = CPGlobalCursorMetadata(
                connection,
                getGlobalCursorDataSize,
                getGlobalCursorData
            );
        }

        if (copiedImages != NULL) {
            CFRelease(copiedImages);
        }
        CGError removeError = removeCursor(
            connection,
            (char *)identifier.UTF8String,
            false
        );
        size_t postDataSize = 0;
        CGError postDataError = getCursorDataSize(
            connection,
            (char *)identifier.UTF8String,
            &postDataSize
        );
        CGImageRelease(filmstrip1x);
        CGImageRelease(filmstrip2x);

        BOOL metadataTruncated =
            copyError == kCGErrorSuccess &&
            copiedFrames != requestedFrames;
        BOOL clean =
            postDataError != kCGErrorSuccess || postDataSize == 0;
        NSMutableDictionary *result = [@{
            @"identifier": identifier,
            @"requestedFrames": @(requestedFrames),
            @"frameWidth": @(frameWidth),
            @"frameHeight": @(frameHeight),
            @"globally": @NO,
            @"instantly": @NO,
            @"preDataError": @(preDataError),
            @"preDataSize": @(preDataSize),
            @"registerError": @(registerError),
            @"seed": @(seed),
            @"registeredDataError": @(registeredDataError),
            @"registeredDataSize": @(registeredDataSize),
            @"copyError": @(copyError),
            @"copiedWidth": @(copiedSize.width),
            @"copiedHeight": @(copiedSize.height),
            @"copiedHotspotX": @(copiedHotspot.x),
            @"copiedHotspotY": @(copiedHotspot.y),
            @"copiedFrames": @(copiedFrames),
            @"copiedFrameDuration": @(copiedDuration),
            @"copiedImages": copiedImageMetadata,
            @"metadataTruncated": @(metadataTruncated),
            @"removeError": @(removeError),
            @"postDataError": @(postDataError),
            @"postDataSize": @(postDataSize),
            @"clean": @(clean),
            @"activateRequested": @(activate),
            @"activateError": @(activateError),
            @"restoreError": @(restoreError),
        } mutableCopy];
        if (globalBefore != nil) {
            result[@"globalBefore"] = globalBefore;
        }
        if (globalActive != nil) {
            result[@"globalActive"] = globalActive;
        }
        if (globalAfter != nil) {
            result[@"globalAfter"] = globalAfter;
        }
        CPWriteJSON(result);
        return clean ? 0 : 5;
    }
}
