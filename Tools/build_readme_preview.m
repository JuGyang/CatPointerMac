#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static CGImageRef CPCopyImageAtPath(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source =
        CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (source == NULL) {
        return NULL;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    return image;
}

static BOOL CPDrawFrame(
    CGImageDestinationRef destination,
    NSString *projectDirectory,
    NSNumber *defaultFrame,
    NSNumber *textFrame
) {
    NSString *defaultPath = [projectDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"Resources/Cursors/default/%@.png", defaultFrame]];
    NSString *textPath = [projectDirectory
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"Resources/Cursors/text/%@.png", textFrame]];
    CGImageRef defaultImage = CPCopyImageAtPath(defaultPath);
    CGImageRef textImage = CPCopyImageAtPath(textPath);
    if (defaultImage == NULL || textImage == NULL) {
        if (defaultImage != NULL) {
            CGImageRelease(defaultImage);
        }
        if (textImage != NULL) {
            CGImageRelease(textImage);
        }
        return NO;
    }

    const size_t width = 560;
    const size_t height = 240;
    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        NULL,
        width,
        height,
        8,
        width * 4,
        colorSpace,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        CGImageRelease(defaultImage);
        CGImageRelease(textImage);
        return NO;
    }

    CGContextSetRGBFillColor(context, 0.91, 0.94, 1.0, 1.0);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetRGBFillColor(context, 0.80, 0.86, 0.96, 1.0);
    CGContextFillRect(context, CGRectMake(279, 24, 2, 192));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(
        context,
        CGRectMake(25, 5, 230, 230),
        defaultImage
    );
    CGContextDrawImage(
        context,
        CGRectMake(305, 5, 230, 230),
        textImage
    );

    CGImageRef composedImage = CGBitmapContextCreateImage(context);
    NSDictionary *frameProperties = @{
        (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
            (__bridge NSString *)kCGImagePropertyGIFDelayTime:
                @(1.0 / 12.0),
            (__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime:
                @(1.0 / 12.0),
        },
    };
    CGImageDestinationAddImage(
        destination,
        composedImage,
        (__bridge CFDictionaryRef)frameProperties
    );

    CGImageRelease(composedImage);
    CGContextRelease(context);
    CGImageRelease(defaultImage);
    CGImageRelease(textImage);
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(
                stderr,
                "usage: build_readme_preview PROJECT_DIR OUTPUT_GIF\n"
            );
            return 64;
        }

        NSString *projectDirectory =
            [NSString stringWithUTF8String:argv[1]];
        NSString *outputPath = [NSString stringWithUTF8String:argv[2]];
        NSArray<NSNumber *> *defaultFrames = @[
            @1, @6, @12, @17, @23, @28, @34, @39,
            @44, @50, @55, @61, @66, @71, @77, @82,
            @88, @93, @99, @104, @109, @115, @120, @126,
        ];
        NSArray<NSNumber *> *textFrames = @[
            @1, @7, @13, @19, @24, @30, @36, @42,
            @48, @54, @59, @65, @71, @77, @83, @89,
            @94, @100, @106, @112, @118, @124, @129, @135,
        ];

        NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
        CGImageDestinationRef destination =
            CGImageDestinationCreateWithURL(
                (__bridge CFURLRef)outputURL,
                (__bridge CFStringRef)UTTypeGIF.identifier,
                defaultFrames.count,
                NULL
            );
        if (destination == NULL) {
            fprintf(stderr, "could not create GIF destination\n");
            return 1;
        }
        NSDictionary *gifProperties = @{
            (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                (__bridge NSString *)kCGImagePropertyGIFLoopCount: @0,
            },
        };
        CGImageDestinationSetProperties(
            destination,
            (__bridge CFDictionaryRef)gifProperties
        );

        for (NSUInteger index = 0; index < defaultFrames.count; index++) {
            if (!CPDrawFrame(
                    destination,
                    projectDirectory,
                    defaultFrames[index],
                    textFrames[index])) {
                fprintf(stderr, "could not compose frame %lu\n",
                    (unsigned long)index);
                CFRelease(destination);
                return 1;
            }
        }

        BOOL finalized = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        if (!finalized) {
            fprintf(stderr, "could not finalize GIF\n");
            return 1;
        }
        CGImageSourceRef verificationSource =
            CGImageSourceCreateWithURL(
                (__bridge CFURLRef)outputURL,
                NULL
            );
        size_t writtenFrameCount = verificationSource == NULL
            ? 0
            : CGImageSourceGetCount(verificationSource);
        if (verificationSource != NULL) {
            CFRelease(verificationSource);
        }
        if (writtenFrameCount != defaultFrames.count) {
            fprintf(
                stderr,
                "expected %lu GIF frames, wrote %lu\n",
                (unsigned long)defaultFrames.count,
                (unsigned long)writtenFrameCount
            );
            return 1;
        }
        printf("%s\n", outputPath.fileSystemRepresentation);
        return 0;
    }
}
