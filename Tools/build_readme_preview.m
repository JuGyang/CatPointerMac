#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

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
    NSArray<NSString *> *roles,
    NSArray<NSNumber *> *frameNumbers
) {
    if (roles.count != 7 || frameNumbers.count != roles.count) {
        return NO;
    }
    CGImageRef images[7] = {NULL};
    for (NSUInteger index = 0; index < roles.count; index++) {
        NSString *path = [projectDirectory
            stringByAppendingPathComponent:[NSString stringWithFormat:
                @"Resources/Cursors/%@/%@.png",
                roles[index],
                frameNumbers[index]]];
        images[index] = CPCopyImageAtPath(path);
        if (images[index] == NULL) {
            for (NSUInteger releaseIndex = 0;
                 releaseIndex < index;
                 releaseIndex++) {
                CGImageRelease(images[releaseIndex]);
            }
            return NO;
        }
    }

    const size_t width = 720;
    const size_t height = 360;
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
        for (NSUInteger index = 0; index < roles.count; index++) {
            CGImageRelease(images[index]);
        }
        return NO;
    }

    CGContextSetRGBFillColor(context, 0.96, 0.975, 1.0, 1.0);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    const CGRect tiles[7] = {
        {{10, 185}, {160, 160}},
        {{190, 185}, {160, 160}},
        {{370, 185}, {160, 160}},
        {{550, 185}, {160, 160}},
        {{100, 15}, {160, 160}},
        {{280, 15}, {160, 160}},
        {{460, 15}, {160, 160}},
    };
    for (NSUInteger index = 0; index < roles.count; index++) {
        CGRect card = CGRectInset(tiles[index], 4, 4);
        CGContextSetRGBFillColor(
            context,
            0.90,
            0.94,
            0.995,
            1.0
        );
        CGContextFillRect(context, card);
        CGContextDrawImage(context, tiles[index], images[index]);
    }

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
    for (NSUInteger index = 0; index < roles.count; index++) {
        CGImageRelease(images[index]);
    }
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
        NSArray<NSString *> *roles = @[
            @"default",
            @"text",
            @"pointer",
            @"progress",
            @"wait",
            @"size_hor",
            @"size_ver",
        ];
        NSArray<NSNumber *> *sourceFrameCounts = @[
            @130, @140, @94, @45, @44, @127, @164,
        ];
        const NSUInteger previewFrameCount = 24;

        NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
        CGImageDestinationRef destination =
            CGImageDestinationCreateWithURL(
                (__bridge CFURLRef)outputURL,
                (__bridge CFStringRef)UTTypeGIF.identifier,
                previewFrameCount,
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

        for (NSUInteger index = 0;
             index < previewFrameCount;
             index++) {
            NSMutableArray<NSNumber *> *frameNumbers =
                [NSMutableArray arrayWithCapacity:roles.count];
            for (NSNumber *sourceFrameCount in sourceFrameCounts) {
                double position =
                    (double)index *
                    sourceFrameCount.unsignedIntegerValue /
                    previewFrameCount;
                [frameNumbers addObject:
                    @((NSUInteger)floor(position + 0.5) + 1)];
            }
            if (!CPDrawFrame(
                    destination,
                    projectDirectory,
                    roles,
                    frameNumbers)) {
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
        if (writtenFrameCount != previewFrameCount) {
            fprintf(
                stderr,
                "expected %lu GIF frames, wrote %lu\n",
                (unsigned long)previewFrameCount,
                (unsigned long)writtenFrameCount
            );
            return 1;
        }
        printf("%s\n", outputPath.fileSystemRepresentation);
        return 0;
    }
}
