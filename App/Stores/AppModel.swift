import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var status: ProxyRuntimeStatus = .starting
    private(set) var configuration: ProxyConfiguration?
    private(set) var inspection: ConfigInspection?
    private(set) var metrics = ProxyMetrics()
    private(set) var lastError: String?
    private(set) var selfTestImage: URL?
    private(set) var loginItemEnabled = false
    var editablePort = "17891"
    var editableBridgeModel = ""

    private let stateStore = StateStore()
    private let configEditor = CodexConfigEditor()
    private let migrationService = LegacyMigrationService()
    private let loginItemService = LoginItemService()
    private let selfTestService = SelfTestService()
    private var server: NativeProxyServer?

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { await bootstrap() }
        } else {
            status = .notConfigured
        }
    }

    var isRunning: Bool {
        status == .running || status == .testing
    }

    var canApply: Bool {
        UInt16(editablePort) != nil && !editableBridgeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var providerName: String {
        configuration?.providerName ?? inspection?.providerName ?? "—"
    }

    var upstreamBaseURL: String {
        configuration?.upstreamBaseURL ?? inspection?.baseURL ?? "—"
    }

    func bootstrap() async {
        status = .starting
        loginItemEnabled = loginItemService.isEnabled
        do {
            _ = try migrationService.migrateIfNeeded()
            if let saved = try stateStore.load() {
                configuration = saved
                editablePort = String(saved.port)
                editableBridgeModel = saved.bridgeModel
                if saved.isEnabled {
                    enableLoginItemIfPossible()
                    startProxy(with: saved)
                } else {
                    status = .stopped
                }
            } else {
                let found = try configEditor.inspect()
                inspection = found
                editableBridgeModel = found.model
                status = .notConfigured
            }
        } catch {
            fail(error)
        }
    }

    func applyAndStart() {
        guard let port = UInt16(editablePort), port > 0 else {
            failMessage("端口必须是 1–65535 之间的数字")
            return
        }
        let bridgeModel = editableBridgeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bridgeModel.isEmpty else {
            failMessage("桥接模型不能为空")
            return
        }
        do {
            if let current = configuration, current.isEnabled {
                if current.port == port && current.bridgeModel == bridgeModel {
                    startProxy(with: current)
                    return
                }
                stopProxy()
                try configEditor.restore(current)
            }
            var updated = try configEditor.enable(port: port, bridgeModel: bridgeModel)
            updated.isEnabled = true
            try stateStore.save(updated)
            configuration = updated
            inspection = nil
            enableLoginItemIfPossible()
            startProxy(with: updated)
        } catch {
            fail(error)
        }
    }

    func stopProxy() {
        server?.stop()
        server = nil
        if configuration != nil {
            status = .stopped
        }
    }

    func disableAndRestore() {
        guard var current = configuration else { return }
        stopProxy()
        do {
            if current.isEnabled {
                try configEditor.restore(current)
            }
            current.isEnabled = false
            try stateStore.save(current)
            configuration = current
            try? loginItemService.setEnabled(false)
            loginItemEnabled = loginItemService.isEnabled
            status = .stopped
            lastError = nil
            AppLog.info("Restored Codex upstream URL")
        } catch {
            fail(error)
        }
    }

    func runSelfTest() {
        guard let configuration, isRunning else { return }
        status = .testing
        lastError = nil
        Task {
            do {
                let token = try configEditor.bearerToken(for: configuration)
                let output = try await selfTestService.run(configuration: configuration, bearerToken: token)
                selfTestImage = output
                status = .running
                AppLog.info("Image self-test passed: \(output.path)")
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                fail(error)
            }
        }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            try loginItemService.setEnabled(enabled)
            loginItemEnabled = loginItemService.isEnabled
        } catch {
            fail(error)
            loginItemEnabled = loginItemService.isEnabled
        }
    }

    func openLogs() {
        try? FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppPaths.logs)
    }

    func openCodexConfig() {
        NSWorkspace.shared.open(AppPaths.codexConfig)
    }

    private func startProxy(with configuration: ProxyConfiguration) {
        server?.stop()
        status = .starting
        lastError = nil
        let server = NativeProxyServer(
            configuration: configuration,
            eventHandler: { [weak self] event in
                Task { @MainActor in self?.record(event) }
            },
            stateHandler: { [weak self] result in
                Task { @MainActor in self?.handleServerState(result) }
            }
        )
        self.server = server
        do {
            try server.start()
        } catch {
            fail(error)
        }
    }

    private func handleServerState(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            status = .running
            migrationService.removeLegacyPayload()
        case .failure(let error):
            fail(error)
        }
    }

    private func record(_ event: ProxyEvent) {
        metrics.lastActivity = Date()
        switch event {
        case .forwarded:
            metrics.forwardedRequests += 1
        case .imageBridged:
            metrics.bridgedImages += 1
        case .failed(let message):
            metrics.failedRequests += 1
            lastError = message
        }
    }

    private func enableLoginItemIfPossible() {
        do {
            try loginItemService.setEnabled(true)
            loginItemEnabled = loginItemService.isEnabled
        } catch {
            lastError = "代理已启动，但无法注册登录启动：\(error.localizedDescription)"
            AppLog.error(lastError ?? error.localizedDescription)
        }
    }

    private func fail(_ error: Error) {
        failMessage(error.localizedDescription)
    }

    private func failMessage(_ message: String) {
        status = .failed(message)
        lastError = message
        AppLog.error(message)
    }
}
