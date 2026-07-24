#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef int (*CPMainConnectionFunction)(void);
typedef CGError (*CPGetGlobalCursorDataSizeFunction)(int connection,
                                                     int *size);
typedef CGError (*CPGetGlobalCursorDataFunction)(
    int connection,
    void *data,
    int *dataSize,
    int *bytesPerRow,
    CGRect *cursorBounds,
    CGPoint *hotspot,
    int *bitsPerPixel,
    int *samplesPerPixel,
    int *bitsPerSample
);

int main(void) {
    @autoreleasepool {
        CPMainConnectionFunction mainConnection =
            (CPMainConnectionFunction)dlsym(
                RTLD_DEFAULT,
                "CGSMainConnectionID"
            );
        CPGetGlobalCursorDataSizeFunction getSize =
            (CPGetGlobalCursorDataSizeFunction)dlsym(
                RTLD_DEFAULT,
                "CGSGetGlobalCursorDataSize"
            );
        CPGetGlobalCursorDataFunction getData =
            (CPGetGlobalCursorDataFunction)dlsym(
                RTLD_DEFAULT,
                "CGSGetGlobalCursorData"
            );
        if (mainConnection == NULL || getSize == NULL || getData == NULL) {
            return 2;
        }

        int connection = mainConnection();
        int byteCount = 0;
        CGError sizeError = getSize(connection, &byteCount);
        if (sizeError != kCGErrorSuccess || byteCount <= 0 ||
            byteCount > 64 * 1024 * 1024) {
            return 3;
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
        if (dataError != kCGErrorSuccess) {
            return 4;
        }

        const uint8_t *cursorBytes = bytes.bytes;
        uint64_t hash = UINT64_C(1469598103934665603);
        for (NSUInteger index = 0;
             index < (NSUInteger)mutableByteCount;
             index++) {
            hash ^= cursorBytes[index];
            hash *= UINT64_C(1099511628211);
        }

        NSDictionary *result = @{
            @"width": @(cursorBounds.size.width),
            @"height": @(cursorBounds.size.height),
            @"hotspotX": @(hotspot.x),
            @"hotspotY": @(hotspot.y),
            @"dataBytes": @(mutableByteCount),
            @"bytesPerRow": @(bytesPerRow),
            @"bitsPerPixel": @(bitsPerPixel),
            @"samplesPerPixel": @(samplesPerPixel),
            @"bitsPerSample": @(bitsPerSample),
            @"fnv1a64": [NSString stringWithFormat:@"%016llx", hash],
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                       options:
            NSJSONWritingSortedKeys
                                                         error:nil];
        NSFileHandle *standardOutput =
            NSFileHandle.fileHandleWithStandardOutput;
        [standardOutput writeData:json];
        [standardOutput writeData:
            [@"\n" dataUsingEncoding:NSUTF8StringEncoding]
        ];
        return 0;
    }
}
