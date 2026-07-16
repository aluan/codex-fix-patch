import Darwin
import Foundation

struct LegacyMigrationService: Sendable {
    private let stateStore = StateStore()

    func migrateIfNeeded() throws -> ProxyConfiguration? {
        if try stateStore.load() != nil {
            return nil
        }
        guard FileManager.default.fileExists(atPath: AppPaths.legacyState.path) else {
            return nil
        }
        let data = try Data(contentsOf: AppPaths.legacyState)
        var configuration = try JSONDecoder().decode(ProxyConfiguration.self, from: data)
        configuration.toolVersion = ProxyConfiguration.currentToolVersion
        configuration.isEnabled = true
        try stopLegacyAgent()
        try stateStore.save(configuration)
        AppLog.info("Imported legacy Python proxy state")
        return configuration
    }

    func removeLegacyPayload() {
        try? FileManager.default.removeItem(at: AppPaths.legacyRoot)
    }

    private func stopLegacyAgent() throws {
        let domain = "gui/\(getuid())/com.local.codex-imagegen-patch"
        _ = try? ProcessRunner.run("/bin/launchctl", arguments: ["bootout", domain])
        _ = try? ProcessRunner.run("/bin/launchctl", arguments: ["unsetenv", "CODEX_CLI_PATH"])
        if FileManager.default.fileExists(atPath: AppPaths.legacyLaunchAgent.path) {
            try FileManager.default.removeItem(at: AppPaths.legacyLaunchAgent)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
