import Foundation

struct SkinPalette: Codable, Equatable, Hashable, Sendable {
    var accent: String
    var secondary: String
    var surface: String
    var text: String

    func validated() throws -> SkinPalette {
        SkinPalette(
            accent: try Self.normalize(accent),
            secondary: try Self.normalize(secondary),
            surface: try Self.normalize(surface),
            text: try Self.normalize(text)
        )
    }

    var isDark: Bool {
        Self.luminance(of: surface).map { $0 < 0.45 } ?? false
    }

    func darkModeVariant() -> SkinPalette {
        guard !isDark else { return self }
        return SkinPalette(
            accent: Self.blend(accent, toward: "#FFFFFF", amount: 0.12),
            secondary: Self.blend(secondary, toward: "#FFFFFF", amount: 0.20),
            surface: Self.blend(surface, toward: "#111318", amount: 0.84),
            text: Self.blend(text, toward: "#FFFFFF", amount: 0.86)
        )
    }

    private static func normalize(_ value: String) throws -> String {
        let normalized = value.uppercased()
        guard normalized.range(of: #"^#[0-9A-F]{6}$"#, options: .regularExpression) != nil else {
            throw SkinError.invalidColor(value)
        }
        return normalized
    }

    private static func luminance(of value: String) -> Double? {
        guard let components = components(of: value) else { return nil }
        return 0.2126 * components.red + 0.7152 * components.green + 0.0722 * components.blue
    }

    private static func blend(_ value: String, toward target: String, amount: Double) -> String {
        guard let source = components(of: value), let destination = components(of: target) else { return value }
        let clampedAmount = min(max(amount, 0), 1)
        return hex(
            red: source.red + (destination.red - source.red) * clampedAmount,
            green: source.green + (destination.green - source.green) * clampedAmount,
            blue: source.blue + (destination.blue - source.blue) * clampedAmount
        )
    }

    private static func components(of value: String) -> (red: Double, green: Double, blue: Double)? {
        guard value.count == 7, value.first == "#", let number = Int(value.dropFirst(), radix: 16) else { return nil }
        return (
            Double((number >> 16) & 0xFF) / 255,
            Double((number >> 8) & 0xFF) / 255,
            Double(number & 0xFF) / 255
        )
    }

    private static func hex(red: Double, green: Double, blue: Double) -> String {
        let components = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    }
}

enum SkinThemeSource: String, Codable, Sendable {
    case builtIn
    case custom
}

struct SkinTheme: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var source: SkinThemeSource
    var imageReference: String
    var palette: SkinPalette
    var createdAt: Date
    var updatedAt: Date

    var imageURL: URL? {
        switch source {
        case .builtIn:
            Bundle.main.url(forResource: imageReference, withExtension: "jpg", subdirectory: "SkinThemes")
                ?? Bundle.main.url(forResource: imageReference, withExtension: "jpg")
        case .custom:
            URL(fileURLWithPath: imageReference)
        }
    }

    var isDark: Bool {
        palette.isDark
    }
}

enum BuiltInSkinCatalog {
    static let defaultThemeID = "ocean-glass"

    static let themes: [SkinTheme] = [
        theme(
            id: "ocean-glass",
            name: "海洋玻璃",
            palette: SkinPalette(accent: "#08AFC4", secondary: "#315FD4", surface: "#EAFBFC", text: "#12334A")
        ),
        theme(
            id: "aurora-night",
            name: "极光夜幕",
            palette: SkinPalette(accent: "#28E0C1", secondary: "#8D63FF", surface: "#101B35", text: "#F2F7FF")
        ),
        theme(
            id: "sunset-atelier",
            name: "日落画室",
            palette: SkinPalette(accent: "#F2745F", secondary: "#9C4965", surface: "#FFF1E7", text: "#4B2931")
        ),
        theme(
            id: "deep-space",
            name: "深空星云",
            palette: SkinPalette(accent: "#5A8CFF", secondary: "#9567E8", surface: "#0B1024", text: "#F0F3FF")
        ),
    ]

    private static func theme(id: String, name: String, palette: SkinPalette) -> SkinTheme {
        SkinTheme(
            id: id,
            name: name,
            source: .builtIn,
            imageReference: id,
            palette: palette,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}

enum SkinRuntimeStatus: Equatable, Sendable {
    case native
    case waitingForCodex
    case restarting
    case injecting
    case active(String)
    case failed(String)

    var title: String {
        switch self {
        case .native: "原生界面"
        case .waitingForCodex: "等待 Codex 启动"
        case .restarting: "正在重启 Codex"
        case .injecting: "正在注入主题"
        case .active: "皮肤已启用"
        case .failed: "换肤异常"
        }
    }

    var symbolName: String {
        switch self {
        case .native: "circle"
        case .waitingForCodex: "clock"
        case .restarting, .injecting: "arrow.triangle.2.circlepath"
        case .active: "paintpalette.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum SkinError: LocalizedError {
    case invalidColor(String)
    case invalidImage(String)
    case imageTooLarge
    case imageDimensionsTooLarge
    case missingTheme
    case missingCodex
    case untrustedCodex
    case codexDidNotQuit
    case cdpPortOccupied
    case cdpUnavailable
    case noMainRenderer
    case injectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidColor(let value): "无效的主题颜色：\(value)"
        case .invalidImage(let message): "无法读取主题图片：\(message)"
        case .imageTooLarge: "图片不能超过 8 MiB"
        case .imageDimensionsTooLarge: "图片尺寸超过 8192 像素、3200 万像素或 100:1 比例限制"
        case .missingTheme: "找不到指定主题"
        case .missingCodex: "未找到已安装的 Codex"
        case .untrustedCodex: "Codex 应用身份或签名不符合预期"
        case .codexDidNotQuit: "Codex 未正常退出，已取消重启"
        case .cdpPortOccupied: "调试端口 9341 已被其他进程占用"
        case .cdpUnavailable: "Codex 调试端口未就绪"
        case .noMainRenderer: "未找到可安全注入的 Codex 主窗口"
        case .injectionFailed(let message): "主题注入失败：\(message)"
        }
    }
}
