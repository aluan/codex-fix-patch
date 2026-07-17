import Foundation
import XCTest
@testable import GPTSwitch

final class ProviderModelsTests: XCTestCase {
    @MainActor
    func testMainNavigationCoordinatesProviderEditingAndUsageFiltering() {
        let navigation = MainNavigation()
        let providerID = UUID()

        navigation.editProvider(providerID)
        XCTAssertEqual(navigation.section, .providers)
        XCTAssertEqual(navigation.editingProviderID, providerID)

        navigation.showUsage(for: providerID)
        XCTAssertEqual(navigation.section, .usage)
        XCTAssertNil(navigation.editingProviderID)
        XCTAssertEqual(navigation.usageProviderFilter, providerID)

        navigation.show(.settings)
        XCTAssertEqual(navigation.section, .settings)
        XCTAssertNil(navigation.usageProviderFilter)
    }

    func testURLValidationNormalizesAndRejectsProxyLoop() throws {
        let normalized = try ProviderURLValidator.normalize(" HTTPS://relay.example/v1/ ", proxyPort: 17891)
        XCTAssertEqual(normalized, "https://relay.example/v1")
        XCTAssertThrowsError(try ProviderURLValidator.normalize("http://127.0.0.1:17891/v1", proxyPort: 17891))
        XCTAssertThrowsError(try ProviderURLValidator.normalize("https://user:pass@example.com/v1", proxyPort: 17891))
        XCTAssertNoThrow(try ProviderURLValidator.normalize("http://127.0.0.1:8080/v1", proxyPort: 17891))
    }

    func testRouterUsesStableRequestSnapshot() {
        let first = snapshot(name: "First", token: "first-token")
        let second = snapshot(name: "Second", token: "second-token")
        let router = ActiveProviderRouter(snapshot: first)

        let requestSnapshot = router.snapshot()
        router.update(second)

        XCTAssertEqual(requestSnapshot.profile.displayName, "First")
        XCTAssertEqual(router.snapshot().profile.displayName, "Second")
    }

    func testAuthorizerReplacesBearerTokenWithoutPersistingItInProfile() {
        let provider = snapshot(name: "Relay", token: "new-secret")
        var request = URLRequest(url: URL(string: "https://relay.example/v1/responses")!)
        request.setValue("Bearer old-secret", forHTTPHeaderField: "Authorization")

        ProviderRequestAuthorizer.apply(provider, to: &request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-secret")
        XCTAssertFalse(provider.profile.baseURL.contains("new-secret"))
    }

    private func snapshot(name: String, token: String) -> ActiveProviderSnapshot {
        ActiveProviderSnapshot(
            profile: ProviderProfile(
                configName: name.lowercased(),
                displayName: name,
                baseURL: "https://\(name.lowercased()).example/v1",
                bridgeModel: "gpt-5"
            ),
            bearerToken: token
        )
    }
}
