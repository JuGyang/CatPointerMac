#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static BOOL writePNG(CGImageRef image, NSURL *url) {
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)url,
            (__bridge CFStringRef)UTTypePNG.identifier,
            1,
            NULL
        );
    if (destination == NULL) {
        return NO;
    }
    CGImageDestinationAddImage(destination, image, NULL);
    BOOL result = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return result;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr,
                    "usage: extract_video_frames VIDEO OUTPUT_DIR STEP\n");
            return 2;
        }

        NSString *videoPath =
            [NSString stringWithUTF8String:argv[1]];
        NSString *outputPath =
            [NSString stringWithUTF8String:argv[2]];
        double step = strtod(argv[3], NULL);
        if (step <= 0) {
            return 2;
        }

        NSError *directoryError = nil;
        if (![NSFileManager.defaultManager
                createDirectoryAtPath:outputPath
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&directoryError]) {
            fprintf(stderr, "%s\n",
                    directoryError.localizedDescription.UTF8String);
            return 3;
        }

        AVURLAsset *asset = [AVURLAsset
            URLAssetWithURL:[NSURL fileURLWithPath:videoPath]
                    options:nil
        ];
        Float64 duration =
            CMTimeGetSeconds(asset.duration);
        if (!isfinite(duration) || duration <= 0) {
            fprintf(stderr, "invalid video duration\n");
            return 4;
        }

        AVAssetImageGenerator *generator =
            [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.requestedTimeToleranceBefore = kCMTimeZero;
        generator.requestedTimeToleranceAfter = kCMTimeZero;

        NSUInteger index = 0;
        for (double seconds = 0;
             seconds < duration;
             seconds += step, index++) {
            CMTime requested =
                CMTimeMakeWithSeconds(seconds, 600);
            CMTime actual = kCMTimeInvalid;
            NSError *frameError = nil;
            CGImageRef image =
                [generator copyCGImageAtTime:requested
                                  actualTime:&actual
                                       error:&frameError];
            if (image == NULL) {
                fprintf(stderr, "frame %.3f: %s\n", seconds,
                        frameError.localizedDescription.UTF8String);
                continue;
            }

            NSString *filename = [NSString
                stringWithFormat:@"%04lu_%.3f.png",
                                 (unsigned long)index,
                                 CMTimeGetSeconds(actual)];
            NSURL *url = [NSURL fileURLWithPath:
                [outputPath stringByAppendingPathComponent:filename]];
            if (!writePNG(image, url)) {
                fprintf(stderr, "failed to write %s\n",
                        url.path.UTF8String);
                CGImageRelease(image);
                return 5;
            }
            CGImageRelease(image);
        }

        printf("{\"duration\":%.3f,\"frames\":%lu}\n",
               duration, (unsigned long)index);
        return 0;
    }
}
