#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef int (*CPMainConnectionFunction)(void);
typedef CGError (*CPGetGlobalCursorDataSizeFunction)(
    int connection,
    int *size
);
typedef CGError (*CPGetGlobalCursorDataProbeFunction)(
    int connection,
    void *data,
    void *argument3,
    void *argument4,
    void *argument5,
    void *argument6,
    void *argument7,
    void *argument8,
    void *argument9
);

static void CPPrintBuffer(NSString *label, const uint8_t *bytes) {
    const double *doubles = (const double *)bytes;
    const int32_t *integers = (const int32_t *)bytes;
    printf(
        "%s doubles={%.17g, %.17g, %.17g, %.17g} "
        "ints={%d, %d, %d, %d}\n",
        label.UTF8String,
        doubles[0],
        doubles[1],
        doubles[2],
        doubles[3],
        integers[0],
        integers[1],
        integers[2],
        integers[3]
    );
}

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
        CPGetGlobalCursorDataProbeFunction getData =
            (CPGetGlobalCursorDataProbeFunction)dlsym(
                RTLD_DEFAULT,
                "CGSGetGlobalCursorData"
            );
        if (mainConnection == NULL || getSize == NULL || getData == NULL) {
            return 2;
        }

        int byteCount = 0;
        int connection = mainConnection();
        if (getSize(connection, &byteCount) != kCGErrorSuccess ||
            byteCount <= 0 || byteCount > 64 * 1024 * 1024) {
            return 3;
        }

        NSMutableData *data =
            [NSMutableData dataWithLength:(NSUInteger)byteCount];
        uint8_t outputs[7][64] = {{0}};
        memcpy(outputs[0], &byteCount, sizeof(byteCount));
        CGError result = getData(
            connection,
            data.mutableBytes,
            outputs[0],
            outputs[1],
            outputs[2],
            outputs[3],
            outputs[4],
            outputs[5],
            outputs[6]
        );
        printf("result=%d requestedBytes=%d\n", result, byteCount);
        for (NSUInteger index = 0; index < 7; index++) {
            CPPrintBuffer(
                [NSString stringWithFormat:@"arg%lu",
                    (unsigned long)index + 3],
                outputs[index]
            );
        }
        return result == kCGErrorSuccess ? 0 : 4;
    }
}
