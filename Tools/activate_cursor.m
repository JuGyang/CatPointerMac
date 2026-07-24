#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

typedef int CPConnection;
typedef CPConnection (*CPMainConnection)(void);
typedef CGError (*CPSetRegistered)(
    CPConnection,
    char *,
    int *
);
typedef CGError (*CPSetSystemDefined)(CPConnection, int);
typedef void (*CPSetSystemDefinedWithSeed)(
    CPConnection,
    int,
    int *
);
typedef CGError (*CPGetCursorScale)(CPConnection, float *);
typedef CGError (*CPSetCursorScale)(CPConnection, float);
typedef CGError (*CPGetGlobalSize)(CPConnection, int *);
typedef CGError (*CPGetGlobalData)(
    CPConnection,
    void *,
    int *,
    int *,
    CGRect *,
    CGPoint *,
    int *,
    int *,
    int *
);

static void CPPrintGlobal(
    CPConnection connection,
    CPGetGlobalSize getSize,
    CPGetGlobalData getData,
    NSString *label
) {
    int byteCount = 0;
    CGError sizeError = getSize(connection, &byteCount);
    NSMutableData *bytes = byteCount > 0
        ? [NSMutableData dataWithLength:(NSUInteger)byteCount]
        : nil;
    int bytesPerRow = 0;
    CGRect cursorBounds = CGRectZero;
    CGPoint hotspot = CGPointZero;
    int bitsPerPixel = 0;
    int samplesPerPixel = 0;
    int bitsPerSample = 0;
    int mutableCount = byteCount;
    CGError dataError = bytes == nil ? -1 : getData(
        connection,
        bytes.mutableBytes,
        &mutableCount,
        &bytesPerRow,
        &cursorBounds,
        &hotspot,
        &bitsPerPixel,
        &samplesPerPixel,
        &bitsPerSample
    );
    printf(
        "%s sizeError=%d dataError=%d bytes=%d size=%.0fx%.0f "
        "hotspot=%.0f,%.0f\n",
        label.UTF8String,
        sizeError,
        dataError,
        mutableCount,
        cursorBounds.size.width,
        cursorBounds.size.height,
        hotspot.x,
        hotspot.y
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        CPMainConnection mainConnection =
            (CPMainConnection)dlsym(
                RTLD_DEFAULT,
                "CGSMainConnectionID"
            );
        CPSetRegistered setRegistered =
            (CPSetRegistered)dlsym(
                RTLD_DEFAULT,
                "CGSSetRegisteredCursor"
            );
        CPSetSystemDefined setSystemDefined =
            (CPSetSystemDefined)dlsym(
                RTLD_DEFAULT,
                "CGSSetSystemDefinedCursor"
            );
        CPSetSystemDefinedWithSeed setSystemDefinedWithSeed =
            (CPSetSystemDefinedWithSeed)dlsym(
                RTLD_DEFAULT,
                "CGSSetSystemDefinedCursorWithSeed"
            );
        CPGetGlobalSize getGlobalSize =
            (CPGetGlobalSize)dlsym(
                RTLD_DEFAULT,
                "CGSGetGlobalCursorDataSize"
            );
        CPGetGlobalData getGlobalData =
            (CPGetGlobalData)dlsym(
                RTLD_DEFAULT,
                "CGSGetGlobalCursorData"
            );
        CPGetCursorScale getCursorScale =
            (CPGetCursorScale)dlsym(
                RTLD_DEFAULT,
                "CGSGetCursorScale"
            );
        CPSetCursorScale setCursorScale =
            (CPSetCursorScale)dlsym(
                RTLD_DEFAULT,
                "CGSSetCursorScale"
            );
        if (mainConnection == NULL || setRegistered == NULL ||
            setSystemDefined == NULL ||
            setSystemDefinedWithSeed == NULL ||
            getGlobalSize == NULL || getGlobalData == NULL) {
            return 2;
        }

        CPConnection connection = mainConnection();
        NSString *identifier = argc > 1
            ? [NSString stringWithUTF8String:argv[1]]
            : @"com.apple.coregraphics.ArrowS";
        int cursorID = argc > 2 ? atoi(argv[2]) : 0;
        CPPrintGlobal(
            connection,
            getGlobalSize,
            getGlobalData,
            @"before"
        );

        int seed = 0;
        CGError registeredError = setRegistered(
            connection,
            (char *)identifier.UTF8String,
            &seed
        );
        printf(
            "setRegistered(%s) error=%d seed=%d\n",
            identifier.UTF8String,
            registeredError,
            seed
        );
        CPPrintGlobal(
            connection,
            getGlobalSize,
            getGlobalData,
            @"after registered seed0"
        );

        CGError registeredAgainError = setRegistered(
            connection,
            (char *)identifier.UTF8String,
            &seed
        );
        printf(
            "setRegistered(same seed) error=%d seed=%d\n",
            registeredAgainError,
            seed
        );
        CPPrintGlobal(
            connection,
            getGlobalSize,
            getGlobalData,
            @"after registered seedN"
        );

        CGError systemError =
            setSystemDefined(connection, cursorID);
        printf(
            "setSystemDefined(%d) error=%d\n",
            cursorID,
            systemError
        );
        CPPrintGlobal(
            connection,
            getGlobalSize,
            getGlobalData,
            @"after system defined"
        );

        setSystemDefinedWithSeed(connection, cursorID, &seed);
        printf(
            "setSystemDefinedWithSeed(%d) seed=%d\n",
            cursorID,
            seed
        );
        CPPrintGlobal(
            connection,
            getGlobalSize,
            getGlobalData,
            @"after system seed"
        );

        NSCursor *appKitCursor = cursorID == 1
            ? NSCursor.IBeamCursor
            : NSCursor.arrowCursor;
        [appKitCursor set];
        printf(
            "NSCursor.set image=%.0fx%.0f hotspot=%.0f,%.0f\n",
            appKitCursor.image.size.width,
            appKitCursor.image.size.height,
            appKitCursor.hotSpot.x,
            appKitCursor.hotSpot.y
        );
        CPPrintGlobal(
            connection,
            getGlobalSize,
            getGlobalData,
            @"after NSCursor.set"
        );

        if (getCursorScale != NULL && setCursorScale != NULL) {
            float scale = 1.0f;
            CGError getScaleError =
                getCursorScale(connection, &scale);
            CGError bumpError =
                setCursorScale(connection, scale + 0.01f);
            CGError restoreScaleError =
                setCursorScale(connection, scale);
            printf(
                "cursorScale=%.3f get=%d bump=%d restore=%d\n",
                scale,
                getScaleError,
                bumpError,
                restoreScaleError
            );
            CPPrintGlobal(
                connection,
                getGlobalSize,
                getGlobalData,
                @"after cursor scale refresh"
            );
        }
    }
    return 0;
}
