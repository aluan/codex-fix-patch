import Foundation

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let codexConfig = home.appendingPathComponent(".codex/config.toml")
    static let codexAuth = home.appendingPathComponent(".codex/auth.json")
    static let applicationSupport = home.appendingPathComponent("Library/Application Support/CodexImageGenProxy")
    static let state = applicationSupport.appendingPathComponent("state.json")
    static let database = applicationSupport.appendingPathComponent("gptswitch.sqlite3")
    static let logs = home.appendingPathComponent("Library/Logs/CodexImageGenProxy")
    static let logFile = logs.appendingPathComponent("app.log")
    static let generatedImages = home.appendingPathComponent(".codex/generated_images/proxy-self-test")
    static let legacyState = home.appendingPathComponent(".local/share/codex-imagegen-patch/state.json")
    static let legacyRoot = home.appendingPathComponent(".local/share/codex-imagegen-patch")
    static let legacyLaunchAgent = home.appendingPathComponent("Library/LaunchAgents/com.local.codex-imagegen-patch.plist")
}
