import Foundation
import XCTest
@testable import GPTSwitch

final class ChatCompletionsBridgeTests: XCTestCase {
    func testBuildsDeepSeekRequestWithMessagesToolsAndReasoning() throws {
        let body: [String: Any] = [
            "model": "gpt-5.6-sol",
            "instructions": "You are Codex.",
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "Inspect the repo"]],
            ]],
            "tools": [
                [
                    "type": "function",
                    "name": "exec_command",
                    "description": "Run a command",
                    "parameters": ["type": "object"],
                ],
                [
                    "type": "custom",
                    "name": "apply_patch",
                    "description": "Apply a patch",
                    "format": ["definition": "patch text"],
                ],
                [
                    "type": "namespace",
                    "name": "mcp",
                    "description": "MCP tools",
                    "tools": [[
                        "type": "function",
                        "name": "search",
                        "parameters": ["type": "object"],
                    ]],
                ],
            ],
            "reasoning": ["effort": "medium"],
            "stream": true,
        ]
        let result = try ChatCompletionsBridge().makeRequest(
            from: incoming(body),
            provider: snapshot(dialect: .deepSeek, model: "deepseek-v4-pro")
        )
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(result.urlRequest.httpBody)) as? [String: Any])
        let tools = try XCTUnwrap(output["tools"] as? [[String: Any]])
        let messages = try XCTUnwrap(output["messages"] as? [[String: Any]])

        XCTAssertEqual(result.urlRequest.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(output["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual((output["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(output["reasoning_effort"] as? String, "high")
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["content"] as? String, "Inspect the repo")
        XCTAssertEqual(tools.count, 3)
        XCTAssertNotNil(result.toolMappings["exec_command"])
        XCTAssertEqual(result.toolMappings["mcp__search"], .function(name: "search", namespace: "mcp"))
        XCTAssertEqual(result.toolMappings["apply_patch"], .custom(name: "apply_patch"))
    }

    func testBuildsGLMRequestAndDisablesMinimalReasoning() throws {
        let result = try ChatCompletionsBridge().makeRequest(
            from: incoming([
                "input": [],
                "reasoning": ["effort": "minimal"],
                "stream": false,
            ]),
            provider: snapshot(dialect: .glm, model: "glm-5.2")
        )
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(result.urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual((output["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(output["clear_thinking"] as? Bool, true)
        XCTAssertNil(output["reasoning_effort"])
    }

    func testPassthroughProviderPreservesIncomingAuthorization() throws {
        let profile = ProviderProfile(
            configName: "chat",
            displayName: "Chat",
            baseURL: "https://api.example.com/v1",
            bridgeModel: "",
            wireProtocol: .chatCompletions,
            inferenceModel: "relay-opus",
            credentialMode: .passthrough
        )
        let request = IncomingHTTPRequest(
            method: "POST",
            target: "/v1/responses",
            version: "HTTP/1.1",
            headers: ["authorization": "Bearer passthrough", "content-type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: ["input": [], "stream": false])
        )

        let result = try ChatCompletionsBridge().makeRequest(
            from: request,
            provider: ActiveProviderSnapshot(profile: profile, bearerToken: nil)
        )

        XCTAssertEqual(result.urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer passthrough")
    }

    func testRejectsHostedTools() throws {
        XCTAssertThrowsError(try ChatCompletionsBridge().makeRequest(
            from: incoming([
                "input": [],
                "tools": [["type": "web_search"]],
                "stream": true,
            ]),
            provider: snapshot(dialect: .standard, model: "relay-opus")
        )) { error in
            XCTAssertEqual(error.localizedDescription, "Chat Provider 不支持托管工具：web_search")
        }
    }

    func testStreamingConverterHandlesByteSizedFragments() throws {
        let chunks = [
            #"data: {"id":"chat-1","model":"glm-5.2","choices":[{"index":0,"delta":{"reasoning_content":"think "},"finish_reason":null}]}"#,
            #"data: {"id":"chat-1","model":"glm-5.2","choices":[{"index":0,"delta":{"content":"done"},"finish_reason":null}]}"#,
            #"data: {"id":"chat-1","model":"glm-5.2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"apply_patch","arguments":"{\"input\":\"*** Begin Patch\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}"#,
            "data: [DONE]",
        ].joined(separator: "\n\n") + "\n\n"
        let converter = ChatCompletionsStreamConverter(mappings: ["apply_patch": .custom(name: "apply_patch")])
        var output = Data()
        for byte in Data(chunks.utf8) {
            output.append(try converter.consume(Data([byte])))
        }
        output.append(try converter.finish())
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains("response.reasoning_text.delta"))
        XCTAssertTrue(text.contains("response.output_text.delta"))
        XCTAssertTrue(text.contains("custom_tool_call"))
        XCTAssertTrue(text.contains("response.custom_tool_call_input.delta"))
        XCTAssertTrue(text.contains("response.custom_tool_call_input.done"))
        XCTAssertTrue(text.contains("*** Begin Patch"))
        XCTAssertTrue(text.contains("response.completed"))
        XCTAssertEqual(converter.observation.model, "glm-5.2")
        XCTAssertEqual(converter.observation.usage?.inputTokens, 10)
        XCTAssertEqual(converter.observation.usage?.outputTokens, 4)
    }

    func testConvertsNonStreamingToolCallResponse() throws {
        let data = Data(#"{"id":"chat-2","model":"relay-opus","choices":[{"message":{"content":null,"tool_calls":[{"id":"call-2","type":"function","function":{"name":"mcp__search","arguments":"{\"query\":\"swift\"}"}}]}}],"usage":{"prompt_tokens":8,"completion_tokens":2,"total_tokens":10}}"#.utf8)
        let output = try ChatCompletionsBridge().makeNonStreamingResponse(
            data: data,
            mappings: ["mcp__search": .function(name: "search", namespace: "mcp")]
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let items = try XCTUnwrap(root["output"] as? [[String: Any]])
        let usage = try XCTUnwrap(root["usage"] as? [String: Any])

        XCTAssertEqual(items.first?["type"] as? String, "function_call")
        XCTAssertEqual(items.first?["name"] as? String, "search")
        XCTAssertEqual(items.first?["namespace"] as? String, "mcp")
        XCTAssertEqual(usage["input_tokens"] as? Int, 8)
    }

    private func incoming(_ body: [String: Any]) throws -> IncomingHTTPRequest {
        IncomingHTTPRequest(
            method: "POST",
            target: "/v1/responses",
            version: "HTTP/1.1",
            headers: ["content-type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    private func snapshot(dialect: ChatCompletionsDialect, model: String) -> ActiveProviderSnapshot {
        ActiveProviderSnapshot(
            profile: ProviderProfile(
                configName: "chat",
                displayName: "Chat",
                baseURL: "https://api.example.com/v1",
                bridgeModel: "",
                wireProtocol: .chatCompletions,
                chatDialect: dialect,
                inferenceModel: model
            ),
            bearerToken: "secret"
        )
    }
}
