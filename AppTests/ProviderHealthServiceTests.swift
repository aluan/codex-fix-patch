import Foundation
import XCTest
@testable import GPTSwitch

final class ProviderHealthServiceTests: XCTestCase {
    func testModelsCheckFallsBackToV1AfterNotFound() async {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ProviderProfile(
            configName: "relay",
            displayName: "Relay",
            baseURL: "https://relay.example/api",
            bridgeModel: "gpt-5"
        )

        let result = await service.measureEndpoint(provider: provider, token: "secret")

        XCTAssertEqual(result.state, .healthy)
        XCTAssertEqual(result.statusCode, 200)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.url?.path), ["/api/models", "/api/v1/models"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer secret", "Bearer secret"])
    }

    func testResponsesCheckKeepsConfiguredBasePath() async {
        let urls = ProviderEndpointResolver.urls(baseURL: "https://relay.example/api", endpoint: "responses")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://relay.example/api/responses"])
    }

    func testModelCheckUsesStructuredResponsesInput() async throws {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ProviderProfile(
            configName: "relay",
            displayName: "Relay",
            baseURL: "https://relay.example/api",
            bridgeModel: "gpt-5.5"
        )

        let result = await service.testModel(provider: provider, token: "secret")

        XCTAssertEqual(result.state, .healthy)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        XCTAssertEqual(content.first?["type"], "input_text")
        XCTAssertEqual(content.first?["text"], "Reply with OK.")
        XCTAssertEqual(object["stream"] as? Bool, false)
    }

    func testModelsCheckDoesNotDuplicateExistingV1Path() async {
        let urls = ProviderEndpointResolver.urls(baseURL: "https://relay.example/api/v1", endpoint: "models")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://relay.example/api/v1/models"])
    }
}

private actor HealthRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func response(for request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        let statusCode = request.url?.path == "/api/models" ? 404 : 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (Data(), response)
    }
}
