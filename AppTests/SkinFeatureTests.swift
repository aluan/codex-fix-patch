import AppKit
import Foundation
import SQLite3
import XCTest
@testable import GPTSwitch

final class SkinFeatureTests: XCTestCase {
    func testDatabaseMigratesVersionOneAndPersistsSkinSettings() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("skin.sqlite3")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, """
        CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
        INSERT INTO schema_migrations VALUES (1, strftime('%s', 'now'));
        CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)

        let database = try AppDatabase(url: databaseURL)
        let initiallyEnabled = try await database.skinEnabled()
        let initialThemeID = try await database.selectedSkinThemeID()
        XCTAssertFalse(initiallyEnabled)
        XCTAssertEqual(initialThemeID, BuiltInSkinCatalog.defaultThemeID)
        try await database.setSkinEnabled(true)
        try await database.setSelectedSkinThemeID("custom-theme")
        try await database.setLoginItemBeforeSkin(false)

        let theme = SkinTheme(
            id: "custom-theme",
            name: "Custom",
            source: .custom,
            imageReference: "/tmp/custom.jpg",
            palette: SkinPalette(accent: "#112233", secondary: "#445566", surface: "#778899", text: "#FFFFFF"),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try await database.saveCustomSkinTheme(theme)

        let reopened = try AppDatabase(url: databaseURL)
        let reopenedEnabled = try await reopened.skinEnabled()
        let reopenedThemeID = try await reopened.selectedSkinThemeID()
        let previousLoginItem = try await reopened.loginItemBeforeSkin()
        let themes = try await reopened.customSkinThemes()
        XCTAssertTrue(reopenedEnabled)
        XCTAssertEqual(reopenedThemeID, "custom-theme")
        XCTAssertEqual(previousLoginItem, false)
        XCTAssertEqual(themes, [theme])
        try await reopened.deleteCustomSkinTheme(id: theme.id)
        let remainingThemes = try await reopened.customSkinThemes()
        XCTAssertTrue(remainingThemes.isEmpty)
    }

    func testImagePreparationDownscalesAndExtractsValidPalette() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("wide.png")
        try makePNG(width: 3_000, height: 1_000, red: 20, green: 150, blue: 210).write(to: imageURL)

        let prepared = try SkinImageProcessor().prepare(url: imageURL)

        XCTAssertEqual(prepared.width, 2_048)
        XCTAssertLessThanOrEqual(prepared.width * prepared.height, SkinImageProcessor.maximumOutputPixels)
        XCTAssertNoThrow(try prepared.palette.validated())
        XCTAssertTrue(prepared.data.starts(with: [0xFF, 0xD8]))
    }

    func testImagePreparationRejectsUnsupportedData() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: file)
        XCTAssertThrowsError(try SkinImageProcessor().prepare(url: file))
    }

    func testSkinCSSUsesTextContentAndEscapesThemeIdentifier() throws {
        let theme = SkinTheme(
            id: "custom-'theme",
            name: "Custom",
            source: .custom,
            imageReference: "/tmp/custom.jpg",
            palette: SkinPalette(accent: "#112233", secondary: "#445566", surface: "#778899", text: "#FFFFFF"),
            createdAt: Date(),
            updatedAt: Date()
        )
        let css = SkinCSSBuilder.build(theme: theme, palette: try theme.palette.validated(), imageData: Data([0xFF, 0xD8, 0xFF]))
        let expression = SkinCSSBuilder.installExpression(themeID: theme.id, css: css)

        XCTAssertTrue(css.contains("data:image/jpeg;base64,"))
        XCTAssertTrue(expression.contains("style.textContent"))
        XCTAssertTrue(expression.contains(#"custom-'theme"#))
        XCTAssertTrue(expression.contains(SkinCSSBuilder.revision))
        XCTAssertEqual(SkinCSSBuilder.statusValue(themeID: theme.id), "custom-'theme@2")
        XCTAssertFalse(expression.contains("style.innerHTML"))
    }

    func testLightPaletteCreatesHighContrastDarkModeVariant() throws {
        let palette = SkinPalette(accent: "#F2745F", secondary: "#9C4965", surface: "#FFF1E7", text: "#4B2931")

        let darkPalette = palette.darkModeVariant()

        XCTAssertTrue(darkPalette.isDark)
        XCTAssertNotEqual(darkPalette, palette)
        XCTAssertNoThrow(try darkPalette.validated())
        XCTAssertEqual(SkinPalette(accent: "#28E0C1", secondary: "#8D63FF", surface: "#101B35", text: "#F2F7FF").darkModeVariant(),
                       SkinPalette(accent: "#28E0C1", secondary: "#8D63FF", surface: "#101B35", text: "#F2F7FF"))
    }

    func testLightBuiltInSkinsFollowSystemDarkMode() throws {
        for themeID in ["ocean-glass", "sunset-atelier"] {
            let theme = try XCTUnwrap(BuiltInSkinCatalog.themes.first { $0.id == themeID })
            let css = SkinCSSBuilder.build(theme: theme, palette: theme.palette, imageData: Data([0xFF, 0xD8, 0xFF]))
            let darkPalette = theme.palette.darkModeVariant()

            XCTAssertTrue(darkPalette.isDark, "\(themeID) should produce a dark surface")
            XCTAssertTrue(css.contains("@media (prefers-color-scheme: dark)"))
            XCTAssertTrue(css.contains("--gpts-surface: \(darkPalette.surface)"))
            XCTAssertTrue(css.contains("--gpts-text: \(darkPalette.text)"))
            XCTAssertTrue(css.contains("linear-gradient(var(--gpts-image-overlay), var(--gpts-image-overlay))"))
        }
    }

    func testCDPWebSocketValidationIsLoopbackAndPortSpecific() {
        XCTAssertTrue(CodexCDPClient.validWebSocket("ws://127.0.0.1:9341/devtools/page/abc_123"))
        XCTAssertFalse(CodexCDPClient.validWebSocket("ws://localhost:9341/devtools/page/abc"))
        XCTAssertFalse(CodexCDPClient.validWebSocket("ws://127.0.0.1:9342/devtools/page/abc"))
        XCTAssertFalse(CodexCDPClient.validWebSocket("ws://127.0.0.1:9341/devtools/browser/abc"))
        XCTAssertFalse(CodexCDPClient.validWebSocket("ws://user@127.0.0.1:9341/devtools/page/abc"))
    }

    func testDebugPortParserAcceptsEqualsAndSpaceForms() {
        XCTAssertEqual(CodexSkinLifecycle.debugPort(in: "/Applications/ChatGPT --remote-debugging-port=9341"), 9_341)
        XCTAssertEqual(CodexSkinLifecycle.debugPort(in: "/Applications/ChatGPT --remote-debugging-port 9444"), 9_444)
        XCTAssertNil(CodexSkinLifecycle.debugPort(in: "/Applications/ChatGPT --remote-debugging-port=invalid"))
    }

    func testLifecycleParsesOnlyExactCodexExecutableAndChecksPortAvailability() throws {
        let executable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        let processTable = """
        100 Fri Jul 17 11:25:10 2026 /Applications/Other.app/Contents/MacOS/ChatGPT --remote-debugging-port=9341
        123 Fri Jul 17 11:25:10 2026     \(executable) --remote-debugging-port=9341
        """
        let freeExecutor = StaticCommandExecutor(results: [
            StaticCommandExecutor.key("/bin/ps", ["-axo", "pid=,lstart=,command="]): CommandResult(status: 0, output: processTable),
            StaticCommandExecutor.key("/usr/sbin/lsof", ["-nP", "-iTCP:9341", "-sTCP:LISTEN", "-t"]): CommandResult(status: 1, output: ""),
        ])
        let lifecycle = CodexSkinLifecycle(executor: freeExecutor)
        let installation = CodexInstallation(
            appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            executableURL: URL(fileURLWithPath: executable)
        )

        let process = try XCTUnwrap(lifecycle.runningProcess(for: installation))
        XCTAssertEqual(process.pid, 123)
        XCTAssertEqual(process.cdpPort, 9_341)
        XCTAssertNoThrow(try lifecycle.ensureCDPPortAvailable())

        let occupied = CodexSkinLifecycle(executor: StaticCommandExecutor(results: [
            StaticCommandExecutor.key("/usr/sbin/lsof", ["-nP", "-iTCP:9341", "-sTCP:LISTEN", "-t"]): CommandResult(status: 0, output: "999\n"),
        ]))
        XCTAssertThrowsError(try occupied.ensureCDPPortAvailable())
    }

    func testLifecycleLaunchesCodexWithLoopbackCDPFlags() throws {
        let executor = RecordingCommandExecutor()
        let lifecycle = CodexSkinLifecycle(executor: executor)
        let installation = CodexInstallation(
            appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            executableURL: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
        )

        try lifecycle.launch(installation, withCDP: true)

        XCTAssertEqual(executor.invocations, [[
            "/usr/bin/open",
            "-na",
            "/Applications/ChatGPT.app",
            "--args",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=9341",
        ]])
    }

    func testBuiltInThemeResourcesAreBundled() throws {
        XCTAssertEqual(BuiltInSkinCatalog.themes.count, 4)
        for theme in BuiltInSkinCatalog.themes {
            let url = try XCTUnwrap(theme.imageURL, "Missing bundled image for \(theme.id)")
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 100_000)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePNG(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let buffer = representation.bitmapData else {
            throw SkinError.invalidImage("无法创建测试图片")
        }
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            buffer[index] = red
            buffer[index + 1] = green
            buffer[index + 2] = blue
            buffer[index + 3] = 255
        }
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SkinError.invalidImage("无法编码测试图片")
        }
        return data
    }
}

private final class StaticCommandExecutor: CommandExecuting, @unchecked Sendable {
    private let results: [String: CommandResult]

    init(results: [String: CommandResult]) {
        self.results = results
    }

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        results[Self.key(executable, arguments)] ?? CommandResult(status: 1, output: "")
    }

    static func key(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: "\u{0}")
    }
}

private final class RecordingCommandExecutor: CommandExecuting, @unchecked Sendable {
    private(set) var invocations: [[String]] = []

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        invocations.append([executable] + arguments)
        return CommandResult(status: 0, output: "")
    }
}
