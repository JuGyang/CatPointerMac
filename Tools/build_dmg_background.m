#import <AppKit/AppKit.h>

static NSColor *Color(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:red / 255.0
                               green:green / 255.0
                                blue:blue / 255.0
                               alpha:alpha];
}

static void DrawString(NSString *text,
                       NSRect rect,
                       NSFont *font,
                       NSColor *color,
                       NSTextAlignment alignment) {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = alignment;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph
    };
    [text drawInRect:rect withAttributes:attributes];
}

static void DrawArrow(NSRect rect) {
    NSColor *coral = Color(244, 112, 78, 1.0);
    NSColor *coralSoft = Color(244, 112, 78, 0.16);

    NSBezierPath *halo = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, -20, -18)
                                                         xRadius:30
                                                         yRadius:30];
    [coralSoft setFill];
    [halo fill];

    CGFloat centerX = NSMidX(rect);
    CGFloat centerY = NSMidY(rect);
    CGFloat startX = centerX - 50;
    CGFloat endX = centerX + 50;
    CGFloat headBaseX = endX - 26;
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(startX, centerY)];
    [arrow lineToPoint:NSMakePoint(endX, centerY)];
    [arrow moveToPoint:NSMakePoint(headBaseX, centerY + 22)];
    [arrow lineToPoint:NSMakePoint(endX, centerY)];
    [arrow lineToPoint:NSMakePoint(headBaseX, centerY - 22)];
    arrow.lineWidth = 5.0;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;
    [coral setStroke];
    [arrow stroke];
}

static void DrawPaw(NSPoint center) {
    NSColor *pawColor = Color(237, 122, 91, 0.10);
    [pawColor setFill];

    NSBezierPath *pad = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(center.x - 21, center.y - 20, 42, 34)];
    [pad fill];

    const NSPoint offsets[] = {
        {-25, 18}, {-8, 29}, {11, 29}, {27, 16}
    };
    const NSSize sizes[] = {
        {14, 19}, {15, 21}, {15, 21}, {14, 19}
    };
    for (NSInteger index = 0; index < 4; index++) {
        NSSize size = sizes[index];
        NSPoint offset = offsets[index];
        NSBezierPath *toe = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(center.x + offset.x - size.width / 2,
                       center.y + offset.y - size.height / 2,
                       size.width,
                       size.height)];
        [toe fill];
    }
}

static BOOL WriteBackground(NSString *path, CGFloat scale, NSError **error) {
    const NSSize logicalSize = NSMakeSize(720, 450);
    const NSSize pixelSize = NSMakeSize(logicalSize.width * scale,
                                        logicalSize.height * scale);
    NSBitmapImageRep *representation = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)pixelSize.width
                      pixelsHigh:(NSInteger)pixelSize.height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    representation.size = pixelSize;
    NSGraphicsContext *context =
        [NSGraphicsContext graphicsContextWithBitmapImageRep:representation];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    context.imageInterpolation = NSImageInterpolationHigh;

    NSGradient *background = [[NSGradient alloc]
        initWithStartingColor:Color(255, 251, 247, 1.0)
                 endingColor:Color(250, 239, 229, 1.0)];
    [background drawInRect:NSMakeRect(0, 0, pixelSize.width, pixelSize.height)
                    angle:-18];

    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform scaleBy:scale];
    [transform concat];

    NSBezierPath *glow = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(470, 265, 330, 290)];
    [Color(255, 131, 91, 0.09) setFill];
    [glow fill];

    NSBezierPath *lowerGlow = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(-120, -100, 360, 260)];
    [Color(255, 186, 132, 0.10) setFill];
    [lowerGlow fill];

    DrawPaw(NSMakePoint(653, 374));
    DrawPaw(NSMakePoint(71, 75));

    NSBezierPath *badge = [NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(302, 391, 116, 25) xRadius:12.5 yRadius:12.5];
    [Color(244, 112, 78, 0.12) setFill];
    [badge fill];
    DrawString(@"CATPOINTER",
               NSMakeRect(302, 397, 116, 13),
               [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold],
               Color(188, 75, 49, 1.0),
               NSTextAlignmentCenter);

    DrawString(@"安装 CatPointer",
               NSMakeRect(80, 344, 560, 36),
               [NSFont systemFontOfSize:27 weight:NSFontWeightSemibold],
               Color(49, 42, 38, 1.0),
               NSTextAlignmentCenter);
    DrawString(@"将左侧应用拖入右侧“应用程序”即可完成安装",
               NSMakeRect(80, 316, 560, 22),
               [NSFont systemFontOfSize:13.5 weight:NSFontWeightRegular],
               Color(112, 98, 89, 1.0),
               NSTextAlignmentCenter);

    // Finder positions both icons at y=250 from the top. A center of y=200
    // in this bottom-up canvas aligns the arrow exactly with those icons.
    DrawArrow(NSMakeRect(304, 179, 112, 42));

    NSBezierPath *footer = [NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(181, 34, 358, 38) xRadius:19 yRadius:19];
    [Color(255, 255, 255, 0.63) setFill];
    [footer fill];
    footer.lineWidth = 1.0;
    [Color(184, 143, 120, 0.18) setStroke];
    [footer stroke];
    DrawString(@"Drag to install   ·   macOS 13+   ·   Apple Silicon",
               NSMakeRect(195, 46, 330, 16),
               [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
               Color(111, 91, 80, 1.0),
               NSTextAlignmentCenter);

    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [representation representationUsingType:NSBitmapImageFileTypePNG
                                               properties:@{}];
    return [png writeToFile:path options:NSDataWritingAtomic error:error];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr,
                    "usage: build_dmg_background <scale> <output.png> <label>\n");
            return 64;
        }

        CGFloat scale = [[NSString stringWithUTF8String:argv[1]] doubleValue];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        if (scale != 1.0 && scale != 2.0) {
            fprintf(stderr, "scale must be 1 or 2\n");
            return 64;
        }

        NSError *error = nil;
        if (!WriteBackground(output, scale, &error)) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
    }
    return 0;
}
