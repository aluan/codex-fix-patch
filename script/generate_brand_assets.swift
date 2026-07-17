#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconVariant {
    let filename: String
    let pixels: Int
}

private enum GenerationError: LocalizedError {
    case unreadableSource(URL)
    case bitmapCreation(Int)
    case pngEncoding(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let url):
            "Unable to load AI-generated source image at \(url.path)"
        case .bitmapCreation(let pixels):
            "Unable to create \(pixels)x\(pixels) bitmap"
        case .pngEncoding(let pixels):
            "Unable to encode \(pixels)x\(pixels) PNG"
        }
    }
}

private let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1024),
]

private func render(_ image: NSImage, pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: NSColorSpaceName.deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw GenerationError.bitmapCreation(pixels)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context?.imageInterpolation = NSImageInterpolation.high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else {
        throw GenerationError.pngEncoding(pixels)
    }
    return data
}

private func main() throws {
    let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
    let repositoryURL = scriptURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = repositoryURL.appendingPathComponent("Brand/GPTSwitchLogo.png")
    let outputURL = repositoryURL.appendingPathComponent(
        "App/Resources/Assets.xcassets/AppIcon.appiconset"
    )

    guard let image = NSImage(contentsOf: sourceURL) else {
        throw GenerationError.unreadableSource(sourceURL)
    }

    for variant in variants {
        let data = try render(image, pixels: variant.pixels)
        let destination = outputURL.appendingPathComponent(variant.filename)
        try data.write(to: destination, options: .atomic)
        print("Generated \(variant.filename) (\(variant.pixels)x\(variant.pixels))")
    }
}

do {
    try main()
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
