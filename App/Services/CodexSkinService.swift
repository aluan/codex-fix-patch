import Foundation

@MainActor
final class CodexSkinService {
    private let lifecycle: CodexSkinLifecycle
    private let client: CodexCDPClient
    private var restartAttempts: [String: Int] = [:]

    init(
        lifecycle: CodexSkinLifecycle = CodexSkinLifecycle(),
        client: CodexCDPClient = CodexCDPClient()
    ) {
        self.lifecycle = lifecycle
        self.client = client
    }

    func isCodexRunning() throws -> Bool {
        let installation = try lifecycle.resolveInstallation()
        return try lifecycle.runningProcess(for: installation) != nil
    }

    func apply(_ theme: SkinTheme, allowRestart: Bool = true) async throws -> SkinRuntimeStatus {
        let installation = try lifecycle.resolveInstallation()
        var process: CodexProcessIdentity
        if let running = try lifecycle.runningProcess(for: installation) {
            process = running
        } else {
            guard allowRestart else { return .waitingForCodex }
            try lifecycle.ensureCDPPortAvailable()
            try lifecycle.launch(installation, withCDP: true)
            process = try await lifecycle.waitForCDP(installation: installation)
        }
        if process.cdpPort != CodexSkinLifecycle.cdpPort {
            guard allowRestart else { return .native }
            let attempts = restartAttempts[process.key, default: 0]
            guard attempts < 3 else { throw SkinError.cdpUnavailable }
            try lifecycle.ensureCDPPortAvailable()
            restartAttempts[process.key] = attempts + 1
            try await lifecycle.restart(process, installation: installation, withCDP: true)
            process = try await lifecycle.waitForCDP(installation: installation)
        }
        try lifecycle.verifyPortOwner(process, installation: installation)
        if try await !client.isThemeActive(theme.id) {
            try await client.apply(theme: theme)
        }
        restartAttempts.removeAll()
        return .active(theme.id)
    }

    func restore() async throws -> SkinRuntimeStatus {
        let installation = try lifecycle.resolveInstallation()
        guard let process = try lifecycle.runningProcess(for: installation) else {
            restartAttempts.removeAll()
            return .native
        }
        guard process.cdpPort == CodexSkinLifecycle.cdpPort else {
            restartAttempts.removeAll()
            return .native
        }
        try lifecycle.verifyPortOwner(process, installation: installation)
        try? await client.remove()
        try await lifecycle.restart(process, installation: installation, withCDP: false)
        restartAttempts.removeAll()
        return .native
    }
}
