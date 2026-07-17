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
    private(set) var providers: [ProviderProfile] = []
    private(set) var activeProviderID: UUID?
    private(set) var usageResult = UsageQueryResult()
    private(set) var statisticsEnabled = true
    private(set) var retentionDays = 90
    private(set) var checkingProviderIDs: Set<UUID> = []
    private(set) var persistedProxyPort: UInt16 = 17891
    private(set) var skinThemes: [SkinTheme] = BuiltInSkinCatalog.themes
    private(set) var selectedSkinThemeID = BuiltInSkinCatalog.defaultThemeID
    private(set) var skinEnabled = false
    private(set) var skinRuntimeStatus: SkinRuntimeStatus = .native
    var usageTimeRange: UsageTimeRange = .hours24
    var editablePort = "17891"

    private let stateStore = StateStore()
    private let configEditor = CodexConfigEditor()
    private let legacyMigrationService = LegacyMigrationService()
    private let providerMigrationService = ProviderMigrationService()
    private let loginItemService = LoginItemService()
    private let selfTestService = SelfTestService()
    private let healthService = ProviderHealthService()
    private let skinService = CodexSkinService()
    private let skinImageProcessor = SkinImageProcessor()
    private let credentialStore: any CredentialStore = KeychainCredentialStore()
    private var database: AppDatabase?
    private var providerRouter: ActiveProviderRouter?
    private var server: NativeProxyServer?
    private var lastUsageRefresh = Date.distantPast
    private var skinMonitorTask: Task<Void, Never>?
    private var skinLaunchObserver: NSObjectProtocol?
    private var skinReconcileInProgress = false
    private var skinReconcileRequested = false

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

    var proxyEnabled: Bool {
        configuration?.isEnabled == true
    }

    var isProxyTransitioning: Bool {
        status == .starting || status == .testing
    }

    var canApply: Bool {
        guard let port = UInt16(editablePort), port > 0 else { return false }
        return activeProvider != nil
    }

    var canApplyProxySettings: Bool {
        guard let port = UInt16(editablePort), port > 0 else { return false }
        return port != persistedProxyPort
    }

    var activeProvider: ProviderProfile? {
        providers.first { $0.id == activeProviderID }
    }

    var providerName: String {
        activeProvider?.displayName ?? configuration?.providerName ?? inspection?.providerName ?? "—"
    }

    var upstreamBaseURL: String {
        activeProvider?.baseURL ?? configuration?.upstreamBaseURL ?? inspection?.baseURL ?? "—"
    }

    var selectedSkinTheme: SkinTheme? {
        skinThemes.first { $0.id == selectedSkinThemeID }
    }

    var isSkinTransitioning: Bool {
        skinRuntimeStatus == .restarting || skinRuntimeStatus == .injecting
    }

    func bootstrap() async {
        status = .starting
        loginItemEnabled = loginItemService.isEnabled
        var savedConfiguration: ProxyConfiguration?
        do {
            _ = try legacyMigrationService.migrateIfNeeded()
            let database = try AppDatabase()
            self.database = database
            var saved = try stateStore.load()
            savedConfiguration = saved
            let defaultPort = saved?.port ?? 17891
            let storedPort = try await database.proxyPort(default: defaultPort)
            persistedProxyPort = saved?.isEnabled == true ? defaultPort : storedPort
            editablePort = String(persistedProxyPort)
            if var current = saved {
                let refreshLoginItem = current.toolVersion != ProxyConfiguration.currentToolVersion
                if refreshLoginItem {
                    current.toolVersion = ProxyConfiguration.currentToolVersion
                    try stateStore.save(current)
                    saved = current
                }
                configuration = current
                savedConfiguration = current
            } else {
                inspection = try configEditor.inspect()
            }
            let migrationPort = persistedProxyPort
            try await providerMigrationService.migrateIfNeeded(
                database: database,
                configuration: saved,
                proxyPort: migrationPort
            )
            if let catalog = try? BuiltInPricingCatalog().load() {
                try await database.seedBuiltInPricingRules(catalog.rules, version: catalog.version)
            }
            try await reloadProviders()
            statisticsEnabled = try await database.statisticsEnabled()
            retentionDays = try await database.retentionDays()
            await bootstrapSkin(database: database)
            if retentionDays > 0 {
                try await database.purgeUsage(olderThan: Date().addingTimeInterval(-Double(retentionDays) * 86_400))
            }
            await refreshUsage()
            if let saved, saved.isEnabled {
                try configEditor.activate(saved)
                enableLoginItemIfPossible(refresh: saved.toolVersion != ProxyConfiguration.currentToolVersion)
                let snapshot = try makeActiveSnapshot()
                startProxy(with: saved, snapshot: snapshot)
            } else {
                status = saved == nil ? .notConfigured : .stopped
            }
        } catch {
            if savedConfiguration == nil {
                savedConfiguration = try? stateStore.load()
            }
            if let savedConfiguration {
                startLegacyFallback(configuration: savedConfiguration, migrationError: error)
            } else {
                fail(error)
            }
        }
    }

    func applyAndStart() {
        Task { await applyAndStartAsync() }
    }

    func setProxyEnabled(_ enabled: Bool) {
        guard enabled != proxyEnabled else { return }
        if enabled {
            applyAndStart()
        } else {
            disableAndRestore()
        }
    }

    func applyProxySettings() {
        guard let port = UInt16(editablePort), port > 0 else {
            failMessage("端口必须是 1–65535 之间的数字")
            return
        }
        if proxyEnabled {
            Task { await applyAndStartAsync() }
        } else {
            Task {
                do {
                    try await database?.setProxyPort(port)
                    persistedProxyPort = port
                    lastError = nil
                } catch {
                    fail(error)
                }
            }
        }
    }

    func stopProxy() {
        server?.stop()
        server = nil
        if configuration != nil { status = .stopped }
    }

    func disableAndRestore() {
        guard var current = configuration else { return }
        stopProxy()
        do {
            if current.isEnabled { try configEditor.restore(current) }
            current.isEnabled = false
            try stateStore.save(current)
            configuration = current
            try? loginItemService.setEnabled(skinEnabled)
            loginItemEnabled = loginItemService.isEnabled
            status = .stopped
            lastError = nil
            AppLog.info("Restored Codex upstream URL")
        } catch {
            fail(error)
        }
    }

    func canRunImageSelfTest(for providerID: UUID) -> Bool {
        providerID == activeProviderID && status == .running
    }

    func runSelfTest(for providerID: UUID) {
        guard let configuration, canRunImageSelfTest(for: providerID) else { return }
        status = .testing
        lastError = nil
        Task {
            do {
                let passthroughToken = activeProvider?.credentialMode == .passthrough
                    ? try? configEditor.bearerToken(for: configuration)
                    : nil
                let output = try await selfTestService.run(
                    configuration: configuration,
                    bearerToken: passthroughToken
                )
                selfTestImage = output
                status = .running
                AppLog.info("Image self-test passed: \(output.path)")
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                fail(error)
            }
        }
    }

    func switchProvider(to id: UUID) {
        Task {
            do {
                guard let database, let provider = providers.first(where: { $0.id == id }) else {
                    throw ProviderValidationError.missingProvider
                }
                let snapshot = try makeSnapshot(for: provider)
                try await database.setActiveProvider(id: id)
                activeProviderID = id
                providerRouter?.update(snapshot)
                lastError = nil
                AppLog.info("Switched active Provider to \(provider.displayName)")
            } catch {
                fail(error)
            }
        }
    }

    func saveProvider(_ draft: ProviderProfile, apiKey: String?) async -> ProviderProfile? {
        do {
            guard let database else { throw ProviderValidationError.missingProvider }
            lastError = nil
            let port = UInt16(editablePort) ?? configuration?.port ?? 17891
            let provider = try draft.validated(proxyPort: port)
            if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try credentialStore.setToken(apiKey, for: provider.id)
            }
            let routerSnapshot = activeProviderID == provider.id && providerRouter != nil
                ? try makeSnapshot(for: provider)
                : nil
            try await database.saveProvider(provider)
            if activeProviderID == nil {
                try await database.setActiveProvider(id: provider.id)
                activeProviderID = provider.id
            }
            try await reloadProviders()
            if let routerSnapshot {
                providerRouter?.update(routerSnapshot)
            }
            lastError = nil
            return provider
        } catch {
            fail(error)
            return nil
        }
    }

    func duplicateProvider(_ id: UUID) {
        Task {
            do {
                guard let database, let source = providers.first(where: { $0.id == id }) else {
                    throw ProviderValidationError.missingProvider
                }
                var duplicate = source
                duplicate.id = UUID()
                duplicate.displayName += " copy"
                duplicate.configName += "-copy"
                duplicate.sortOrder = source.sortOrder + 1
                duplicate.healthState = .unknown
                duplicate.lastCheckedAt = nil
                duplicate.lastHealthError = nil
                duplicate.lastHealthLatencyMilliseconds = nil
                duplicate.createdAt = Date()
                duplicate.updatedAt = Date()
                if let token = try credentialStore.token(for: source.id) {
                    try credentialStore.setToken(token, for: duplicate.id)
                }
                try await database.saveProvider(duplicate)
                var orderedIDs = providers.map(\.id)
                if let sourceIndex = orderedIDs.firstIndex(of: source.id) {
                    orderedIDs.insert(duplicate.id, at: sourceIndex + 1)
                    try await database.reorderProviders(ids: orderedIDs)
                }
                try await reloadProviders()
            } catch {
                fail(error)
            }
        }
    }

    func deleteProvider(_ id: UUID) async -> Bool {
        do {
            guard let database else { throw ProviderValidationError.missingProvider }
            lastError = nil
            try await database.deleteProvider(id: id)
            do {
                try credentialStore.deleteToken(for: id)
            } catch {
                AppLog.error("Provider was deleted but its Keychain credential could not be removed")
                lastError = "Provider 已删除，但钥匙串密钥清理失败"
            }
            try await reloadProviders()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func deleteProviderCredential(_ id: UUID) {
        do {
            try credentialStore.deleteToken(for: id)
            if let index = providers.firstIndex(where: { $0.id == id }) {
                providers[index].credentialMode = .keychainBearer
            }
        } catch {
            fail(error)
        }
    }

    func reorderProviders(_ ids: [UUID]) {
        Task {
            do {
                try await database?.reorderProviders(ids: ids)
                try await reloadProviders()
            } catch {
                fail(error)
            }
        }
    }

    func providerHasCredential(_ id: UUID) -> Bool {
        (try? credentialStore.token(for: id)) != nil
    }

    func measureProvider(_ id: UUID) {
        runProviderCheck(id, modelCheck: false)
    }

    func testProviderModel(_ id: UUID) {
        runProviderCheck(id, modelCheck: true)
    }

    func refreshUsage() async {
        guard let database else { return }
        do {
            usageResult = try await database.usage(range: usageTimeRange)
            lastUsageRefresh = Date()
        } catch {
            fail(error)
        }
    }

    func setUsageTimeRange(_ range: UsageTimeRange) {
        usageTimeRange = range
        Task { await refreshUsage() }
    }

    func setStatisticsEnabled(_ enabled: Bool) {
        statisticsEnabled = enabled
        Task {
            do { try await database?.setStatisticsEnabled(enabled) }
            catch { fail(error) }
        }
    }

    func setRetentionDays(_ days: Int) {
        retentionDays = days
        Task {
            do {
                try await database?.setRetentionDays(days)
                if days > 0 {
                    try await database?.purgeUsage(olderThan: Date().addingTimeInterval(-Double(days) * 86_400))
                }
                await refreshUsage()
            } catch {
                fail(error)
            }
        }
    }

    func clearUsage() {
        Task {
            do {
                try await database?.clearUsage()
                await refreshUsage()
            } catch {
                fail(error)
            }
        }
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        guard enabled || !skinEnabled else {
            failSkinMessage("换肤常驻期间需要登录启动 GPTSwitch")
            return
        }
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

    func selectSkinTheme(_ id: String) {
        guard skinThemes.contains(where: { $0.id == id }) else { return }
        selectedSkinThemeID = id
        Task {
            do {
                try await database?.setSelectedSkinThemeID(id)
                if skinEnabled, selectedSkinTheme != nil {
                    skinRuntimeStatus = .injecting
                    await reconcileSkin()
                }
            } catch {
                failSkin(error)
            }
        }
    }

    func applySelectedSkin() {
        guard let theme = selectedSkinTheme else {
            failSkin(SkinError.missingTheme)
            return
        }
        Task {
            do {
                if !skinEnabled {
                    try await database?.setLoginItemBeforeSkin(loginItemEnabled)
                    try loginItemService.setEnabled(true)
                    loginItemEnabled = loginItemService.isEnabled
                    try await database?.setSkinEnabled(true)
                    skinEnabled = true
                }
                skinRuntimeStatus = (try skinService.isCodexRunning()) ? .restarting : .waitingForCodex
                skinRuntimeStatus = try await skinService.apply(theme)
                startSkinMonitor()
                lastError = nil
            } catch {
                failSkin(error)
            }
        }
    }

    func isCodexRunningForSkin() -> Bool {
        (try? skinService.isCodexRunning()) == true
    }

    func restoreNativeSkin() {
        stopSkinMonitor()
        Task {
            do {
                while skinReconcileInProgress {
                    try await Task.sleep(for: .milliseconds(100))
                }
                if try skinService.isCodexRunning() { skinRuntimeStatus = .restarting }
                skinRuntimeStatus = try await skinService.restore()
                try await database?.setSkinEnabled(false)
                skinEnabled = false
                let previousLoginItem = try await database?.loginItemBeforeSkin() ?? false
                try loginItemService.setEnabled(proxyEnabled || previousLoginItem)
                loginItemEnabled = loginItemService.isEnabled
                lastError = nil
            } catch {
                failSkin(error)
                if skinEnabled { startSkinMonitor() }
            }
        }
    }

    func prepareSkinImage(at url: URL) async throws -> PreparedSkinImage {
        try await Task.detached { try SkinImageProcessor().prepare(url: url) }.value
    }

    func saveCustomSkin(
        name: String,
        prepared: PreparedSkinImage,
        palette: SkinPalette
    ) async -> SkinTheme? {
        var savedTheme: SkinTheme?
        do {
            guard let database else { throw SkinError.missingTheme }
            let theme = try await Task.detached {
                try SkinImageProcessor().saveCustomTheme(prepared: prepared, name: name, palette: palette)
            }.value
            savedTheme = theme
            try await database.saveCustomSkinTheme(theme)
            try await reloadSkinThemes()
            selectSkinTheme(theme.id)
            lastError = nil
            return theme
        } catch {
            if let savedTheme { try? skinImageProcessor.deleteFiles(for: savedTheme) }
            failSkin(error)
            return nil
        }
    }

    func updateCustomSkin(_ theme: SkinTheme) async -> Bool {
        do {
            guard theme.source == .custom, let database else { throw SkinError.missingTheme }
            var updated = theme
            updated.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !updated.name.isEmpty, updated.name.count <= 80 else {
                throw SkinError.invalidImage("主题名称必须为 1–80 个字符")
            }
            updated.palette = try updated.palette.validated()
            updated.updatedAt = Date()
            try await database.saveCustomSkinTheme(updated)
            try await reloadSkinThemes()
            if skinEnabled, selectedSkinThemeID == updated.id {
                skinRuntimeStatus = .injecting
                await reconcileSkin()
            }
            lastError = nil
            return true
        } catch {
            failSkin(error)
            return false
        }
    }

    func deleteCustomSkin(_ id: String) async -> Bool {
        do {
            guard let database,
                  let theme = skinThemes.first(where: { $0.id == id && $0.source == .custom }) else {
                throw SkinError.missingTheme
            }
            if selectedSkinThemeID == id {
                selectedSkinThemeID = BuiltInSkinCatalog.defaultThemeID
                try await database.setSelectedSkinThemeID(selectedSkinThemeID)
            }
            try await database.deleteCustomSkinTheme(id: id)
            do {
                try skinImageProcessor.deleteFiles(for: theme)
            } catch {
                AppLog.error("Custom skin metadata was deleted but its image files could not be removed")
            }
            try await reloadSkinThemes()
            if skinEnabled, selectedSkinTheme != nil {
                skinRuntimeStatus = .injecting
                await reconcileSkin()
            }
            lastError = nil
            return true
        } catch {
            failSkin(error)
            return false
        }
    }

    private func applyAndStartAsync() async {
        guard let port = UInt16(editablePort), port > 0 else {
            failMessage("端口必须是 1–65535 之间的数字")
            return
        }
        do {
            let snapshot = try makeActiveSnapshot()
            try await database?.setProxyPort(port)
            persistedProxyPort = port
            if let current = configuration, current.isEnabled {
                if current.port == port {
                    try configEditor.activate(current)
                    providerRouter?.update(snapshot)
                    if server == nil { startProxy(with: current, snapshot: snapshot) }
                    return
                }
                stopProxy()
                try configEditor.restore(current)
            }
            var updated = try configEditor.enable(
                port: port,
                bridgeModel: snapshot.profile.bridgeModel
            )
            updated.isEnabled = true
            try stateStore.save(updated)
            configuration = updated
            inspection = nil
            enableLoginItemIfPossible()
            startProxy(with: updated, snapshot: snapshot)
        } catch {
            fail(error)
        }
    }

    private func startProxy(with configuration: ProxyConfiguration, snapshot: ActiveProviderSnapshot) {
        server?.stop()
        status = .starting
        lastError = nil
        let router = ActiveProviderRouter(snapshot: snapshot)
        providerRouter = router
        let server = NativeProxyServer(
            configuration: configuration,
            providerRouter: router,
            eventHandler: { [weak self] metric in
                Task { @MainActor in self?.record(metric) }
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

    private func startLegacyFallback(configuration: ProxyConfiguration, migrationError: Error) {
        self.configuration = configuration
        editablePort = String(configuration.port)
        let profile = ProviderProfile(
            configName: configuration.providerName,
            displayName: configuration.providerName,
            baseURL: configuration.upstreamBaseURL,
            bridgeModel: configuration.bridgeModel,
            credentialMode: .passthrough
        )
        providers = [profile]
        activeProviderID = profile.id
        AppLog.error("Provider data migration failed; continuing with legacy routing")
        if configuration.isEnabled {
            startProxy(
                with: configuration,
                snapshot: ActiveProviderSnapshot(profile: profile, bearerToken: nil)
            )
        } else {
            status = .stopped
            lastError = "Provider 数据迁移失败，已保留原代理配置：\(migrationError.localizedDescription)"
        }
    }

    private func makeActiveSnapshot() throws -> ActiveProviderSnapshot {
        guard let activeProvider else { throw ProviderValidationError.missingProvider }
        return try makeSnapshot(for: activeProvider)
    }

    private func makeSnapshot(for provider: ProviderProfile) throws -> ActiveProviderSnapshot {
        let token = try credentialStore.token(for: provider.id)
        if provider.credentialMode == .keychainBearer, token == nil {
            throw ProviderValidationError.missingCredential
        }
        return ActiveProviderSnapshot(profile: provider, bearerToken: token)
    }

    private func reloadProviders() async throws {
        guard let database else { return }
        providers = try await database.providers()
        activeProviderID = try await database.activeProviderID()
        if activeProviderID == nil, let first = providers.first {
            try await database.setActiveProvider(id: first.id)
            activeProviderID = first.id
        }
    }

    private func bootstrapSkin(database: AppDatabase) async {
        do {
            skinThemes = BuiltInSkinCatalog.themes + (try await database.customSkinThemes())
            selectedSkinThemeID = try await database.selectedSkinThemeID()
            if !skinThemes.contains(where: { $0.id == selectedSkinThemeID }) {
                selectedSkinThemeID = BuiltInSkinCatalog.defaultThemeID
                try await database.setSelectedSkinThemeID(selectedSkinThemeID)
            }
            skinEnabled = try await database.skinEnabled()
            if skinEnabled {
                try loginItemService.setEnabled(true)
                loginItemEnabled = loginItemService.isEnabled
                startSkinMonitor()
            } else {
                skinRuntimeStatus = .native
            }
        } catch {
            failSkin(error)
        }
    }

    private func reloadSkinThemes() async throws {
        guard let database else { return }
        skinThemes = BuiltInSkinCatalog.themes + (try await database.customSkinThemes())
    }

    private func startSkinMonitor() {
        guard skinMonitorTask == nil || skinMonitorTask?.isCancelled == true else { return }
        if skinLaunchObserver == nil {
            skinLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.openai.codex" else { return }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    await self?.reconcileSkin()
                }
            }
        }
        skinMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.skinEnabled else { return }
                await self.reconcileSkin()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopSkinMonitor() {
        skinMonitorTask?.cancel()
        skinMonitorTask = nil
        if let skinLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(skinLaunchObserver)
            self.skinLaunchObserver = nil
        }
    }

    private func reconcileSkin() async {
        if skinReconcileInProgress {
            skinReconcileRequested = true
            return
        }
        skinReconcileInProgress = true
        defer { skinReconcileInProgress = false }
        repeat {
            skinReconcileRequested = false
            guard skinEnabled, let theme = selectedSkinTheme else { return }
            do {
                skinRuntimeStatus = try await skinService.apply(theme)
                lastError = nil
            } catch {
                failSkin(error)
            }
        } while skinReconcileRequested
    }

    private func runProviderCheck(_ id: UUID, modelCheck: Bool) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        checkingProviderIDs.insert(id)
        Task {
            let token: String?
            if provider.credentialMode == .keychainBearer {
                token = try? credentialStore.token(for: id)
            } else if provider.id == activeProviderID, let configuration {
                token = try? configEditor.bearerToken(for: configuration)
            } else {
                token = nil
            }
            let result = modelCheck
                ? await healthService.testModel(provider: provider, token: token)
                : await healthService.measureEndpoint(provider: provider, token: token)
            do {
                guard let database else { return }
                var updated = provider
                updated.healthState = result.state
                updated.lastHealthLatencyMilliseconds = result.latencyMilliseconds
                updated.lastHealthError = result.message
                updated.lastCheckedAt = Date()
                updated.updatedAt = Date()
                try await database.saveProvider(updated)
                try await reloadProviders()
                if activeProviderID == id, let activeProvider {
                    providerRouter?.update(try makeSnapshot(for: activeProvider))
                }
            } catch {
                fail(error)
            }
            checkingProviderIDs.remove(id)
        }
    }

    private func handleServerState(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            status = .running
            legacyMigrationService.removeLegacyPayload()
        case .failure(let error):
            fail(error)
        }
    }

    private func record(_ metric: RequestMetric) {
        metrics.lastActivity = Date()
        if metric.isSuccess {
            if metric.endpoint == .imageGeneration || metric.endpoint == .imageEdit {
                metrics.bridgedImages += metric.imageCount
            } else {
                metrics.forwardedRequests += 1
            }
        } else {
            metrics.failedRequests += 1
        }
        Task {
            do {
                try await database?.record(metric)
                if Date().timeIntervalSince(lastUsageRefresh) > 2 {
                    await refreshUsage()
                }
            } catch {
                AppLog.error("Failed to record request metrics")
            }
        }
    }

    private func enableLoginItemIfPossible(refresh: Bool = false) {
        do {
            try loginItemService.setEnabled(true, refresh: refresh)
            loginItemEnabled = loginItemService.isEnabled
        } catch {
            lastError = "代理已启动，但无法注册登录启动：\(error.localizedDescription)"
            AppLog.error(lastError ?? "Failed to register login item")
        }
    }

    private func fail(_ error: Error) {
        failMessage(error.localizedDescription)
    }

    private func failSkin(_ error: Error) {
        failSkinMessage(error.localizedDescription)
    }

    private func failSkinMessage(_ message: String) {
        skinRuntimeStatus = .failed(message)
        lastError = message
        AppLog.error(message)
    }

    private func failMessage(_ message: String) {
        status = .failed(message)
        lastError = message
        AppLog.error(message)
    }
}
