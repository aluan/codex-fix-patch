import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedSkinImage: Sendable {
    let data: Data
    let palette: SkinPalette
    let width: Int
    let height: Int
}

struct SkinImageProcessor: Sendable {
    static let maximumSourceBytes = 8 * 1_024 * 1_024
    static let maximumSourceSide = 8_192
    static let maximumSourcePixels = 32_000_000
    static let maximumOutputSide = 2_048
    static let maximumOutputPixels = 4_000_000

    func prepare(url: URL) throws -> PreparedSkinImage {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw SkinError.invalidImage("不是普通文件") }
        guard let fileSize = values.fileSize, fileSize <= Self.maximumSourceBytes else {
            throw SkinError.imageTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maximumSourceBytes else { throw SkinError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              Self.allowedTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SkinError.invalidImage("仅支持 PNG、JPEG 和 WebP")
        }
        try validateDimensions(width: width, height: height)
        let outputSize = fittedSize(width: width, height: height)
        let scaled = try draw(image, width: outputSize.width, height: outputSize.height)
        let representation = NSBitmapImageRep(cgImage: scaled)
        guard let jpeg = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
            throw SkinError.invalidImage("无法编码 JPEG")
        }
        return PreparedSkinImage(
            data: jpeg,
            palette: extractPalette(from: scaled),
            width: outputSize.width,
            height: outputSize.height
        )
    }

    func saveCustomTheme(
        prepared: PreparedSkinImage,
        name: String,
        palette: SkinPalette? = nil,
        id: String = UUID().uuidString.lowercased()
    ) throws -> SkinTheme {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 80 else {
            throw SkinError.invalidImage("主题名称必须为 1–80 个字符")
        }
        let root = AppPaths.skins.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.skins.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let destination = root.appendingPathComponent("hero.jpg")
        do {
            try prepared.data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let now = Date()
        return SkinTheme(
            id: id,
            name: trimmedName,
            source: .custom,
            imageReference: destination.path,
            palette: try (palette ?? prepared.palette).validated(),
            createdAt: now,
            updatedAt: now
        )
    }

    func deleteFiles(for theme: SkinTheme) throws {
        guard theme.source == .custom else { return }
        let themeRoot = URL(fileURLWithPath: theme.imageReference).deletingLastPathComponent()
        let skinsRoot = AppPaths.skins.standardizedFileURL.path
        guard themeRoot.standardizedFileURL.path.hasPrefix(skinsRoot + "/") else { return }
        if FileManager.default.fileExists(atPath: themeRoot.path) {
            try FileManager.default.removeItem(at: themeRoot)
        }
    }

    private static let allowedTypes: Set<String> = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.webP.identifier,
    ]

    private func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= Self.maximumSourceSide,
              height <= Self.maximumSourceSide,
              width <= Self.maximumSourcePixels / height,
              max(width, height) <= min(width, height) * 100 else {
            throw SkinError.imageDimensionsTooLarge
        }
    }

    private func fittedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let sideScale = min(1, Double(Self.maximumOutputSide) / Double(max(width, height)))
        let pixelScale = min(1, sqrt(Double(Self.maximumOutputPixels) / Double(width * height)))
        let scale = min(sideScale, pixelScale)
        return (
            max(1, Int((Double(width) * scale).rounded(.down))),
            max(1, Int((Double(height) * scale).rounded(.down)))
        )
    }

    private func draw(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw SkinError.invalidImage("无法创建缩放画布") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw SkinError.invalidImage("无法缩放图片") }
        return output
    }

    private func extractPalette(from image: CGImage) -> SkinPalette {
        let sampleWidth = 64
        let sampleHeight = 64
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard rendered else { return SkinPalette.defaultValue }

        var bins: [Int: ColorBin] = [:]
        var total = RGB.zero
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] >= 128 {
            let color = RGB(red: Int(pixels[index]), green: Int(pixels[index + 1]), blue: Int(pixels[index + 2]))
            let key = (color.red >> 4) << 8 | (color.green >> 4) << 4 | (color.blue >> 4)
            bins[key, default: ColorBin()].add(color)
            total.add(color)
            count += 1
        }
        guard count > 0 else { return SkinPalette.defaultValue }
        let candidates = bins.values.sorted { $0.count > $1.count }.prefix(32).map(\.average)
        let accent = candidates.max { left, right in left.vibrancy < right.vibrancy } ?? total.divided(by: count)
        let secondary = candidates
            .filter { $0.distance(to: accent) >= 70 }
            .max { left, right in left.vibrancy < right.vibrancy }
            ?? candidates.dropFirst().first
            ?? accent
        let average = total.divided(by: count)
        let surface = average.luminance < 0.5 ? average.mixed(with: .black, amount: 0.72) : average.mixed(with: .white, amount: 0.84)
        let text = surface.contrast(with: .white) >= surface.contrast(with: .darkText) ? RGB.white : RGB.darkText
        return SkinPalette(
            accent: accent.saturated.hex,
            secondary: secondary.saturated.hex,
            surface: surface.hex,
            text: text.hex
        )
    }
}

private struct ColorBin {
    var count = 0
    var total = RGB.zero

    mutating func add(_ color: RGB) {
        count += 1
        total.add(color)
    }

    var average: RGB { total.divided(by: max(1, count)) }
}

private struct RGB {
    var red: Int
    var green: Int
    var blue: Int

    static let zero = RGB(red: 0, green: 0, blue: 0)
    static let black = RGB(red: 0, green: 0, blue: 0)
    static let white = RGB(red: 255, green: 255, blue: 255)
    static let darkText = RGB(red: 18, green: 24, blue: 32)

    mutating func add(_ other: RGB) {
        red += other.red
        green += other.green
        blue += other.blue
    }

    func divided(by divisor: Int) -> RGB {
        RGB(red: red / divisor, green: green / divisor, blue: blue / divisor)
    }

    var luminance: Double {
        func channel(_ value: Int) -> Double {
            let normalized = Double(value) / 255
            return normalized <= 0.03928 ? normalized / 12.92 : pow((normalized + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    var vibrancy: Double {
        let values = [red, green, blue]
        return Double((values.max() ?? 0) - (values.min() ?? 0)) * (0.35 + luminance)
    }

    var saturated: RGB {
        let mean = (red + green + blue) / 3
        return RGB(
            red: Self.clamp(mean + Int(Double(red - mean) * 1.22)),
            green: Self.clamp(mean + Int(Double(green - mean) * 1.22)),
            blue: Self.clamp(mean + Int(Double(blue - mean) * 1.22))
        )
    }

    func distance(to other: RGB) -> Double {
        let redDelta = Double(red - other.red)
        let greenDelta = Double(green - other.green)
        let blueDelta = Double(blue - other.blue)
        return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
    }

    func mixed(with other: RGB, amount: Double) -> RGB {
        RGB(
            red: Self.clamp(Int(Double(red) * (1 - amount) + Double(other.red) * amount)),
            green: Self.clamp(Int(Double(green) * (1 - amount) + Double(other.green) * amount)),
            blue: Self.clamp(Int(Double(blue) * (1 - amount) + Double(other.blue) * amount))
        )
    }

    func contrast(with other: RGB) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    private static func clamp(_ value: Int) -> Int { min(255, max(0, value)) }
}

private extension SkinPalette {
    static let defaultValue = SkinPalette(
        accent: "#24C9D7",
        secondary: "#7F78D2",
        surface: "#F4F8FA",
        text: "#12202C"
    )
}
