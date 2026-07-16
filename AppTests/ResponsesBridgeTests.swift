import Foundation
import XCTest
@testable import GPTSwitch

final class ResponsesBridgeTests: XCTestCase {
    func testParsesJSONMislabeledAsEventStream() throws {
        let data = Data(#"{"output":[{"type":"image_generation_call","result":"iVBORw0KGgo="}]}"#.utf8)
        let result = try ResponsesBridge().parseImageResult(data: data, contentType: "text/event-stream")
        XCTAssertEqual(result.base64, "iVBORw0KGgo=")
    }

    func testParsesSSEAndMapsImagesResponse() throws {
        let event = #"data: {"type":"response.completed","response":{"output":[{"type":"image_generation_call","result":"aW1hZ2U=","size":"1024x1024"}]}}"#
        let result = try ResponsesBridge().parseImageResult(data: Data("\(event)\n\ndata: [DONE]\n".utf8), contentType: "text/event-stream")
        let output = try ResponsesBridge().makeImagesResponse(
            imageResult: result,
            originalBody: Data(#"{"prompt":"dog","quality":"high"}"#.utf8)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let images = try XCTUnwrap(json["data"] as? [[String: Any]])

        XCTAssertEqual(images.first?["b64_json"] as? String, "aW1hZ2U=")
        XCTAssertEqual(json["size"] as? String, "1024x1024")
        XCTAssertEqual(json["quality"] as? String, "high")
    }

    func testBuildsHostedImageGenerationRequest() throws {
        let configuration = ProxyConfiguration(
            configPath: "/tmp/config.toml",
            providerName: "relay",
            bridgeModel: "gpt-5.5",
            upstreamBaseURL: "https://relay.example/api",
            localBaseURL: "http://127.0.0.1:17891/api",
            port: 17891,
            backupPath: nil
        )
        let incoming = IncomingHTTPRequest(
            method: "POST",
            target: "/api/images/generations",
            version: "HTTP/1.1",
            headers: ["authorization": "Bearer secret", "content-type": "application/json"],
            body: Data(#"{"prompt":"a dog"}"#.utf8)
        )
        let request = try ResponsesBridge().makeResponsesRequest(from: incoming, configuration: configuration, edit: false)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])

        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/api/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(payload["model"] as? String, "gpt-5.5")
        XCTAssertEqual(tools.first?["type"] as? String, "image_generation")
    }
}
