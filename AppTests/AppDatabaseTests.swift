import Foundation
import XCTest
@testable import GPTSwitch

final class AppDatabaseTests: XCTestCase {
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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
