#!/usr/bin/env swift

import AppKit
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func image(at path: String) -> NSImage {
    guard let image = NSImage(contentsOfFile: path) else {
        fail("cannot load image at \(path)")
    }
    return image
}

private func bitmap(at path: String) -> NSBitmapImageRep {
    guard
        let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let bitmap = NSBitmapImageRep(data: data)
    else {
        fail("cannot decode bitmap at \(path)")
    }
    return bitmap
}

private func contentBounds(
    in bitmap: NSBitmapImageRep,
    where isContent: (NSColor) -> Bool
) -> NSRect {
    var minX = bitmap.pixelsWide
    var minY = bitmap.pixelsHigh
    var maxX = -1
    var maxY = -1

    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard
                let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB),
                isContent(color)
            else {
                continue
            }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else {
        fail("image has no visible content")
    }
    return NSRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )
}

struct AlphaComponent {
    let bounds: NSRect
    let pixels: [Bool]
}

private func largestAlphaComponent(in bitmap: NSBitmapImageRep) -> AlphaComponent {
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    var content = Array(repeating: false, count: width * height)
    var visited = Array(repeating: false, count: width * height)

    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            content[index] =
                bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.01
        }
    }

    var bestCount = 0
    var bestBounds = NSRect.zero
    var bestIndices: [Int] = []
    let neighbors = [
        (0, -1),
        (-1, 0), (1, 0),
        (0, 1),
    ]

    for startY in 0..<height {
        for startX in 0..<width {
            let startIndex = startY * width + startX
            if visited[startIndex] || !content[startIndex] {
                continue
            }

            var queue = [startIndex]
            var cursor = 0
            visited[startIndex] = true
            var count = 0
            var minX = startX
            var minY = startY
            var maxX = startX
            var maxY = startY

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                count += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                for (deltaX, deltaY) in neighbors {
                    let nextX = x + deltaX
                    let nextY = y + deltaY
                    if nextX < 0 || nextX >= width ||
                        nextY < 0 || nextY >= height {
                        continue
                    }
                    let nextIndex = nextY * width + nextX
                    if !visited[nextIndex] && content[nextIndex] {
                        visited[nextIndex] = true
                        queue.append(nextIndex)
                    }
                }
            }

            if count > bestCount {
                bestCount = count
                bestIndices = queue
                bestBounds = NSRect(
                    x: minX,
                    y: minY,
                    width: maxX - minX + 1,
                    height: maxY - minY + 1
                )
            }
        }
    }

    guard bestCount > 0 else {
        fail("subject image has no visible content")
    }
    var bestPixels = Array(repeating: false, count: width * height)
    for index in bestIndices {
        bestPixels[index] = true
    }
    return AlphaComponent(bounds: bestBounds, pixels: bestPixels)
}

private func expandedSquare(_ rect: NSRect, limit: NSSize) -> NSRect {
    let side = max(rect.width, rect.height)
    var square = NSRect(
        x: rect.midX - side / 2,
        y: rect.midY - side / 2,
        width: side,
        height: side
    )
    // The generated background uses a chroma-key exterior. Pull the crop
    // safely inside its antialiased edge so no green fringe survives when the
    // artwork is remapped into our deterministic rounded mask.
    square = square.insetBy(dx: 24, dy: 24)
    square.origin.x = max(0, min(square.origin.x, limit.width - square.width))
    square.origin.y = max(0, min(square.origin.y, limit.height - square.height))
    square.size.width = min(square.width, limit.width)
    square.size.height = min(square.height, limit.height)
    return square
}

private func imageCoordinateRect(
    _ pixelRect: NSRect,
    bitmap: NSBitmapImageRep,
    image: NSImage
) -> NSRect {
    let scaleX = image.size.width / CGFloat(bitmap.pixelsWide)
    let scaleY = image.size.height / CGFloat(bitmap.pixelsHigh)
    return NSRect(
        x: pixelRect.origin.x * scaleX,
        y: (CGFloat(bitmap.pixelsHigh) - pixelRect.maxY) * scaleY,
        width: pixelRect.width * scaleX,
        height: pixelRect.height * scaleY
    )
}

private func croppedImage(
    from bitmap: NSBitmapImageRep,
    component: AlphaComponent
) -> NSImage {
    let bounds = component.bounds
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    guard let cropped = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fail("cannot allocate cropped subject bitmap")
    }

    for y in 0..<height {
        for x in 0..<width {
            let sourceX = Int(bounds.minX) + x
            let sourceY = Int(bounds.minY) + y
            let sourceIndex = sourceY * bitmap.pixelsWide + sourceX
            if !component.pixels[sourceIndex] {
                continue
            }
            guard let color = bitmap.colorAt(
                x: sourceX,
                y: sourceY
            ) else {
                continue
            }
            cropped.setColor(color, atX: x, y: y)
        }
    }

    let result = NSImage(size: NSSize(width: width, height: height))
    result.addRepresentation(cropped)
    return result
}

guard CommandLine.arguments.count == 4 else {
    fail(
        "usage: make_app_icon.swift <background.png> "
        + "<original-frame.png> <output.png>"
    )
}

let backgroundPath = CommandLine.arguments[1]
let subjectPath = CommandLine.arguments[2]
let outputPath = CommandLine.arguments[3]
let background = image(at: backgroundPath)
let backgroundBitmap = bitmap(at: backgroundPath)
let subjectBitmap = bitmap(at: subjectPath)

let backgroundBounds = contentBounds(in: backgroundBitmap) { color in
    let red = color.redComponent
    let green = color.greenComponent
    let blue = color.blueComponent
    let isChromaGreen =
        green > 0.5 &&
        green > red * 1.08 &&
        green > blue * 1.08
    return !isChromaGreen
}
let backgroundCrop = expandedSquare(
    backgroundBounds,
    limit: NSSize(
        width: backgroundBitmap.pixelsWide,
        height: backgroundBitmap.pixelsHigh
    )
)
// The cursor and cat are separate alpha components in this frame. Keep only
// the larger cat component so no partial pointer appears in the app icon.
let subjectComponent = largestAlphaComponent(in: subjectBitmap)
let subjectBounds = subjectComponent.bounds
let subject = croppedImage(from: subjectBitmap, component: subjectComponent)
let backgroundSourceRect = imageCoordinateRect(
    backgroundCrop,
    bitmap: backgroundBitmap,
    image: background
)
let canvasPixels = 1024
guard let output = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasPixels,
    pixelsHigh: canvasPixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("cannot allocate output bitmap")
}
guard let graphics = NSGraphicsContext(bitmapImageRep: output) else {
    fail("cannot create output graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high
let context = graphics.cgContext
context.clear(
    CGRect(x: 0, y: 0, width: canvasPixels, height: canvasPixels)
)

let tileRect = NSRect(x: 66, y: 66, width: 892, height: 892)
let tilePath = NSBezierPath(
    roundedRect: tileRect,
    xRadius: 206,
    yRadius: 206
)

NSGraphicsContext.saveGraphicsState()
context.setShadow(
    offset: CGSize(width: 0, height: -11),
    blur: 24,
    color: NSColor.black.withAlphaComponent(0.17).cgColor
)
NSColor.white.setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
background.draw(
    in: tileRect,
    from: backgroundSourceRect,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)

let glaze = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.11),
    NSColor.white.withAlphaComponent(0),
])
glaze?.draw(
    in: NSBezierPath(
        roundedRect: tileRect.insetBy(dx: 5, dy: 5),
        xRadius: 201,
        yRadius: 201
    ),
    angle: -55
)
NSGraphicsContext.restoreGraphicsState()

// Keep the complete cat comfortably inside the icon's safe area.
let subjectWidth: CGFloat = 520
let subjectHeight =
    subjectWidth * subjectBounds.height / subjectBounds.width
let subjectRect = NSRect(
    x: (CGFloat(canvasPixels) - subjectWidth) / 2,
    y: (CGFloat(canvasPixels) - subjectHeight) / 2 - 42,
    width: subjectWidth,
    height: subjectHeight
)

NSGraphicsContext.saveGraphicsState()
context.setShadow(
    offset: CGSize(width: 0, height: -7),
    blur: 13,
    color: NSColor(
        calibratedRed: 0.31,
        green: 0.12,
        blue: 0.08,
        alpha: 0.48
    ).cgColor
)
subject.draw(
    in: subjectRect,
    from: NSRect(origin: .zero, size: subject.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)
NSGraphicsContext.restoreGraphicsState()

NSColor.white.withAlphaComponent(0.18).setStroke()
tilePath.lineWidth = 2
tilePath.stroke()
NSGraphicsContext.restoreGraphicsState()

guard let png = output.representation(
    using: .png,
    properties: [.interlaced: false]
) else {
    fail("cannot encode PNG")
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fail("cannot write \(outputPath): \(error.localizedDescription)")
}
