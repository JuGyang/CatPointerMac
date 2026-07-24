#import <AppKit/AppKit.h>
#import <math.h>

#import "CursorAssetSequence.h"

static void CPAssert(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

static BOOL CPNear(CGFloat left, CGFloat right) {
    return fabs(left - right) < 0.001;
}

static BOOL CPImagesEqual(CGImageRef left, CGImageRef right) {
    if (left == NULL || right == NULL ||
        CGImageGetWidth(left) != CGImageGetWidth(right) ||
        CGImageGetHeight(left) != CGImageGetHeight(right)) {
        return NO;
    }
    CFDataRef leftData = CGDataProviderCopyData(
        CGImageGetDataProvider(left)
    );
    CFDataRef rightData = CGDataProviderCopyData(
        CGImageGetDataProvider(right)
    );
    BOOL equal = leftData != NULL && rightData != NULL &&
        CFEqual(leftData, rightData);
    if (leftData != NULL) {
        CFRelease(leftData);
    }
    if (rightData != NULL) {
        CFRelease(rightData);
    }
    return equal;
}

static void CPValidateSequence(
    CPCursorAssetSequence *sequence,
    NSUInteger expectedSourceFrames,
    NSTimeInterval expectedTotalDuration,
    NSSize expectedSize,
    NSPoint expectedHotspot,
    NSString *expectedSHA256
) {
    CPAssert(sequence != nil, @"sequence loads");
    CPAssert(
        sequence.sourceFrameCount == expectedSourceFrames,
        @"original source frame count"
    );
    CPAssert(
        sequence.registeredFrameCount == 24,
        @"macOS registered frame count"
    );
    CPAssert(
        CPNear(sequence.sourceFrameDuration, 0.033),
        @"original frame duration"
    );
    CPAssert(
        CPNear(sequence.totalDuration, expectedTotalDuration),
        @"full original cycle duration"
    );
    CPAssert(
        CPNear(
            sequence.registeredFrameDuration * 24,
            expectedTotalDuration
        ),
        @"sampled cycle retains full duration"
    );
    CPAssert(
        NSEqualSizes(sequence.logicalSize, expectedSize),
        @"logical crop size"
    );
    CPAssert(
        NSEqualPoints(sequence.logicalHotspot, expectedHotspot),
        @"hotspot preserved after transparent crop"
    );
    CPAssert(
        sequence.selectedSourceFrameNumbers.count == 24,
        @"24 source frames selected"
    );
    CPAssert(
        [sequence.sourceAssetSHA256 isEqualToString:expectedSHA256],
        @"original source bytes match pinned SHA-256"
    );

    NSError *error = nil;
    NSArray *representations =
        [sequence createFilmstripRepresentationsAtScale:1.0
                                                   error:&error];
    CPAssert(representations != nil && error == nil,
             @"filmstrip representations render");
    CPAssert(representations.count == 2, @"1x and 2x representations");

    CGImageRef strip1x =
        (__bridge CGImageRef)representations[0];
    CGImageRef strip2x =
        (__bridge CGImageRef)representations[1];
    CPAssert(
        CGImageGetWidth(strip1x) == (size_t)expectedSize.width &&
        CGImageGetHeight(strip1x) ==
            (size_t)expectedSize.height * 24,
        @"1x filmstrip dimensions"
    );
    CPAssert(
        CGImageGetWidth(strip2x) == (size_t)expectedSize.width * 2 &&
        CGImageGetHeight(strip2x) ==
            (size_t)expectedSize.height * 2 * 24,
        @"2x filmstrip dimensions"
    );

    NSArray *resizedAtStandard = [sequence
        createFilmstripRepresentationsAtScale:1.0
                         baseTwoXFilmstrip:strip2x
                                        error:&error];
    CPAssert(
        resizedAtStandard != nil && error == nil,
        @"standard base filmstrip resizes"
    );
    CPAssert(
        CPImagesEqual(
            (__bridge CGImageRef)resizedAtStandard[0],
            strip1x
        ) &&
        CPImagesEqual(
            (__bridge CGImageRef)resizedAtStandard[1],
            strip2x
        ),
        @"standard base resize is pixel-identical"
    );

    for (NSNumber *scale in @[@0.8, @0.9, @1.1, @1.2]) {
        error = nil;
        NSArray *direct = [sequence
            createFilmstripRepresentationsAtScale:scale.doubleValue
                                             error:&error];
        CPAssert(
            direct != nil && error == nil,
            @"direct size filmstrip renders"
        );
        error = nil;
        NSArray *resized = [sequence
            createFilmstripRepresentationsAtScale:scale.doubleValue
                             baseTwoXFilmstrip:strip2x
                                            error:&error];
        CPAssert(
            resized != nil && error == nil,
            @"base filmstrip creates another size"
        );
        CPAssert(
            CPImagesEqual(
                (__bridge CGImageRef)direct[0],
                (__bridge CGImageRef)resized[0]
            ) &&
            CPImagesEqual(
                (__bridge CGImageRef)direct[1],
                (__bridge CGImageRef)resized[1]
            ),
            @"base resize matches direct source rendering"
        );
    }
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        CPCursorAssetSequence *defaultSequence =
            [CPCursorAssetSequence sequenceForRole:@"default"
                                             error:&error];
        CPAssert(error == nil, @"default artwork validates");
        CPValidateSequence(
            defaultSequence,
            130,
            4.29,
            NSMakeSize(64, 60),
            NSMakePoint(6, 6),
            @"407827d370a0df8ba228f98ce7f3def8a281d3fe902b001504107dca4819d2a4"
        );

        error = nil;
        CPCursorAssetSequence *textSequence =
            [CPCursorAssetSequence sequenceForRole:@"text"
                                             error:&error];
        CPAssert(error == nil, @"text artwork validates");
        CPValidateSequence(
            textSequence,
            140,
            4.62,
            NSMakeSize(64, 52),
            NSMakePoint(13, 26),
            @"9833bee08c269031d25fceadbb96a9058d3139a50185a3a06fe24e6837560453"
        );

        CPAssert(
            [defaultSequence.selectedSourceFrameNumbers.firstObject
                unsignedIntegerValue] == 1 &&
            [defaultSequence.selectedSourceFrameNumbers.lastObject
                unsignedIntegerValue] == 125,
            @"default sampling follows original timeline"
        );
        CPAssert(
            [textSequence.selectedSourceFrameNumbers.firstObject
                unsignedIntegerValue] == 1 &&
            [textSequence.selectedSourceFrameNumbers.lastObject
                unsignedIntegerValue] == 135,
            @"text sampling follows original timeline"
        );

        CPCursorAssetSequence *smoothDefault =
            [CPCursorAssetSequence
                sequenceForRole:@"default"
         optimizedForSmoothness:YES
                          error:&error];
        CPCursorAssetSequence *smoothText =
            [CPCursorAssetSequence
                sequenceForRole:@"text"
         optimizedForSmoothness:YES
                          error:&error];
        CPValidateSequence(
            smoothDefault,
            130,
            4.29,
            NSMakeSize(64, 60),
            NSMakePoint(6, 6),
            @"407827d370a0df8ba228f98ce7f3def8a281d3fe902b001504107dca4819d2a4"
        );
        CPValidateSequence(
            smoothText,
            140,
            4.62,
            NSMakeSize(64, 52),
            NSMakePoint(13, 26),
            @"9833bee08c269031d25fceadbb96a9058d3139a50185a3a06fe24e6837560453"
        );
        CPAssert(
            smoothDefault.isMotionOptimized &&
            smoothText.isMotionOptimized,
            @"smooth profiles use motion-optimized sampling"
        );
        CPAssert(
            smoothDefault.registeredFrameCount == 24 &&
            smoothText.registeredFrameCount == 24,
            @"smooth profiles retain the macOS maximum frame count"
        );
        CPAssert(
            [NSSet setWithArray:
                smoothDefault.selectedSourceFrameNumbers].count == 24 &&
            [NSSet setWithArray:
                smoothText.selectedSourceFrameNumbers].count == 24,
            @"smooth profiles use 24 distinct timeline positions"
        );
        CPAssert(
            [smoothDefault.selectedSourceFrameNumbers isEqualToArray:@[
                @1, @6, @12, @17, @23, @28, @34, @39,
                @44, @50, @55, @61, @66, @71, @77, @82,
                @88, @93, @99, @104, @109, @115, @120, @126,
            ]],
            @"default motion-aware selection remains pinned"
        );
        CPAssert(
            [smoothText.selectedSourceFrameNumbers isEqualToArray:@[
                @1, @7, @13, @19, @24, @30, @36, @42,
                @48, @54, @59, @65, @71, @77, @83, @89,
                @94, @100, @106, @112, @118, @124, @129, @135,
            ]],
            @"text motion-aware selection remains pinned"
        );

        puts("PASS: original artwork, 24-frame filmstrips, and smooth sampling validated");
    }
    return EXIT_SUCCESS;
}
