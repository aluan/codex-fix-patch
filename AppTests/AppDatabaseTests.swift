import Foundation
import SQLite3
import XCTest
@testable import GPTSwitch

final class AppDatabaseTests: XCTestCase {
    func testPersistsProxyPortSetting() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite3")
        let database = try AppDatabase(url: databaseURL)

        let defaultPort = try await database.proxyPort()
        XCTAssertEqual(defaultPort, 17891)
        try await database.setProxyPort(23456)
        let updatedPort = try await database.proxyPort()
        XCTAssertEqual(updatedPort, 23456)

        let reopened = try AppDatabase(url: databaseURL)
        let persistedPort = try await reopened.proxyPort()
        XCTAssertEqual(persistedPort, 23456)
    }

    func testCrossProviderRoutingDefaultsOnAndPersists() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite3")
        let database = try AppDatabase(url: databaseURL)

        let defaultValue = try await database.crossProviderRoutingEnabled()
        XCTAssertTrue(defaultValue, "未设置时默认开启跨 provider 路由，catalog 一次性列出全部模型")
        try await database.setCrossProviderRoutingEnabled(false)

        let reopened = try AppDatabase(url: databaseURL)
        let persistedValue = try await reopened.crossProviderRoutingEnabled()
        XCTAssertFalse(persistedValue)
    }

    func testPersistsProviderModelRoutes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite3")
        let database = try AppDatabase(url: databaseURL)
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            configName: "anthropic",
            displayName: "Anthropic",
            baseURL: "https://api.anthropic.com",
            bridgeModel: "",
            wireProtocol: .anthropicMessages,
            inferenceModel: "claude-sonnet-4-6",
            models: [ProviderModelRoute(
                providerID: providerID,
                modelID: "anthropic/claude-sonnet-4-6",
                displayName: "Claude Sonnet",
                reasoningEfforts: ["low", "high"],
                defaultReasoningEffort: "high",
                inputModalities: ["text", "image"]
            )]
        )

        try await database.saveProvider(provider)
        let reopened = try AppDatabase(url: databaseURL)
        let reopenedProviders = try await reopened.providers()
        let stored = try XCTUnwrap(reopenedProviders.first)

        XCTAssertEqual(stored.models, provider.models)
        XCTAssertEqual(stored.models.first?.catalogID(providerConfigName: "anthropic"), "anthropic/anthropic-claude-sonnet-4-6")
    }

    func testPersistsAggregatesPricingAndRetention() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(url: directory.appendingPathComponent("test.sqlite3"))
        let provider = ProviderProfile(
            configName: "relay",
            displayName: "Relay",
            baseURL: "https://relay.example/v1",
            bridgeModel: "gpt-5"
        )
        try await database.saveProvider(provider)
        try await database.setActiveProvider(id: provider.id)
        try await database.savePricingRule(ModelPricingRule(
            providerID: provider.id,
            modelPattern: "gpt-5",
            inputMicrosPerMillion: 3_000_000,
            cachedInputMicrosPerMillion: 1_000_000,
            outputMicrosPerMillion: 4_000_000
        ))
        try await database.savePricingRule(ModelPricingRule(
            modelPattern: "gpt-",
            isPrefix: true,
            inputMicrosPerMillion: 1_000_000,
            outputMicrosPerMillion: 2_000_000,
            isBuiltIn: true
        ))
        try await database.record(RequestMetric(
            startedAt: Date(),
            providerID: provider.id,
            providerName: provider.displayName,
            endpoint: .responses,
            requestedModel: "gpt-5",
            statusCode: 200,
            durationMilliseconds: 900,
            usage: TokenUsage(inputTokens: 100, outputTokens: 50, cachedInputTokens: 20)
        ))
        try await database.record(RequestMetric(
            startedAt: Date(),
            providerID: provider.id,
            providerName: provider.displayName,
            endpoint: .responses,
            requestedModel: "unknown-model",
            statusCode: 500,
            durationMilliseconds: 100,
            errorCategory: "http_500"
        ))
        try await database.record(RequestMetric(
            startedAt: Date().addingTimeInterval(-40 * 86_400),
            providerID: provider.id,
            providerName: provider.displayName,
            endpoint: .models,
            statusCode: 200,
            durationMilliseconds: 10
        ))

        let usage = try await database.usage(range: .hours24)
        XCTAssertEqual(usage.summary.totalRequests, 2)
        XCTAssertEqual(usage.summary.successfulRequests, 1)
        XCTAssertEqual(usage.summary.inputTokens, 100)
        XCTAssertEqual(usage.summary.outputTokens, 50)
        XCTAssertEqual(usage.summary.unpricedRequests, 1)
        XCTAssertEqual(usage.summary.costs.first?.micros, 460)
        XCTAssertEqual(usage.providers.first?.requests, 2)
        XCTAssertEqual(usage.models.first(where: { $0.model == "gpt-5" })?.requests, 1)

        try await database.purgeUsage(olderThan: Date().addingTimeInterval(-30 * 86_400))
        let days30 = try await database.usage(range: .days30)
        XCTAssertEqual(days30.summary.totalRequests, 2)
        try await database.clearUsage()
        let emptyUsage = try await database.usage(range: .hours24)
        XCTAssertEqual(emptyUsage.summary.totalRequests, 0)
    }

    func testPreventsDeletingActiveProvider() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(url: directory.appendingPathComponent("test.sqlite3"))
        let provider = ProviderProfile(
            configName: "relay",
            displayName: "Relay",
            baseURL: "https://relay.example/v1",
            bridgeModel: "gpt-5"
        )
        try await database.saveProvider(provider)
        try await database.setActiveProvider(id: provider.id)

        do {
            try await database.deleteProvider(id: provider.id)
            XCTFail("Expected active provider deletion to fail")
        } catch let error as ProviderValidationError {
            XCTAssertEqual(error.localizedDescription, ProviderValidationError.activeProviderCannotBeDeleted.localizedDescription)
        }
    }

    func testCreatesUpdatesAndDeletesInactiveProvider() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(url: directory.appendingPathComponent("test.sqlite3"))
        let active = ProviderProfile(
            configName: "active",
            displayName: "Active",
            baseURL: "https://active.example/v1",
            bridgeModel: "gpt-5"
        )
        var editable = ProviderProfile(
            configName: "editable",
            displayName: "Editable",
            baseURL: "https://editable.example/v1",
            bridgeModel: "gpt-5"
        )

        try await database.saveProvider(active)
        try await database.setActiveProvider(id: active.id)
        try await database.saveProvider(editable)
        editable.displayName = "Updated"
        editable.baseURL = "https://updated.example/v1"
        try await database.saveProvider(editable)

        var providers = try await database.providers()
        XCTAssertEqual(providers.first(where: { $0.id == editable.id })?.displayName, "Updated")
        XCTAssertEqual(providers.first(where: { $0.id == editable.id })?.baseURL, "https://updated.example/v1")

        try await database.deleteProvider(id: editable.id)
        providers = try await database.providers()
        XCTAssertEqual(providers.map(\.id), [active.id])
    }

    func testPersistsChatProviderConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(url: directory.appendingPathComponent("test.sqlite3"))
        let provider = ProviderProfile(
            configName: "glm",
            displayName: "GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            bridgeModel: "",
            wireProtocol: .chatCompletions,
            chatDialect: .glm,
            inferenceModel: "glm-5.2"
        )

        try await database.saveProvider(provider)
        let providers = try await database.providers()
        let stored = try XCTUnwrap(providers.first)

        XCTAssertEqual(stored.wireProtocol, .chatCompletions)
        XCTAssertEqual(stored.chatDialect, .glm)
        XCTAssertEqual(stored.inferenceModel, "glm-5.2")
        XCTAssertFalse(stored.supportsImageBridge)
    }

    func testMigratesLegacyProvidersToResponsesWithoutChangingOrderOrActiveProvider() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("legacy.sqlite3")
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let activeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, """
        CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
        INSERT INTO schema_migrations VALUES (2, strftime('%s', 'now'));
        CREATE TABLE providers (
            id TEXT PRIMARY KEY, config_name TEXT NOT NULL, display_name TEXT NOT NULL,
            base_url TEXT NOT NULL, bridge_model TEXT NOT NULL, test_model TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '', website TEXT NOT NULL DEFAULT '',
            sort_order INTEGER NOT NULL DEFAULT 0, credential_mode TEXT NOT NULL,
            cost_multiplier REAL NOT NULL DEFAULT 1, health_state TEXT NOT NULL DEFAULT 'unknown',
            health_latency_ms INTEGER, health_error TEXT, last_checked_at REAL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO app_settings VALUES ('active_provider_id', '\(activeID.uuidString)');
        INSERT INTO providers VALUES
            ('\(activeID.uuidString)', 'active', 'Active', 'https://active.example/v1', 'gpt-active', '', '', '', 20, 'keychain_bearer', 1, 'healthy', NULL, NULL, NULL, 200, 200),
            ('\(firstID.uuidString)', 'first', 'First', 'https://first.example/v1', 'gpt-first', '', '', '', 10, 'keychain_bearer', 1, 'unknown', NULL, NULL, NULL, 100, 100);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)

        let database = try AppDatabase(url: databaseURL)
        let providers = try await database.providers()
        let activeProviderID = try await database.activeProviderID()

        XCTAssertEqual(providers.map(\.id), [firstID, activeID])
        XCTAssertEqual(providers.map(\.wireProtocol), [.responses, .responses])
        XCTAssertEqual(providers.map(\.chatDialect), [.standard, .standard])
        XCTAssertEqual(providers.map(\.inferenceModel), ["", ""])
        XCTAssertEqual(providers.map { $0.models.first?.modelID }, ["gpt-first", "gpt-active"])
        XCTAssertEqual(activeProviderID, activeID)

        let reopened = try AppDatabase(url: databaseURL)
        let reopenedProviders = try await reopened.providers()
        let reopenedActiveProviderID = try await reopened.activeProviderID()
        XCTAssertEqual(reopenedProviders, providers)
        XCTAssertEqual(reopenedActiveProviderID, activeID)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
