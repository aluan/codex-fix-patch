import Foundation
import XCTest
@testable import GPTSwitch

final class AnthropicMessagesBridgeTests: XCTestCase {
    func testBuildsNativeMessagesRequest() throws {
        let request = try incoming([
            "instructions": "You are Codex, a coding agent based on GPT-5.\n\nKeep changes focused.",
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "Inspect the repo"]],
            ]],
            "tools": [[
                "type": "function",
                "name": "exec",
                "description": "Run a command",
                "parameters": ["type": "object"],
            ]],
            "reasoning": ["effort": "high"],
            "max_output_tokens": 8_192,
            "stream": true,
        ])
        let result = try AnthropicMessagesBridge().makeRequest(from: request, provider: snapshot())
        let body = try XCTUnwrap(result.urlRequest.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(result.urlRequest.url?.absoluteString, "https://relay.example/api/v1/messages")
        XCTAssertEqual(result.urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(object["model"] as? String, "claude-opus-4-8")
        XCTAssertNotNil(object["thinking"])
        XCTAssertEqual((object["tools"] as? [[String: Any]])?.first?["name"] as? String, "exec")
        let system = try XCTUnwrap(object["system"] as? String)
        XCTAssertFalse(system.contains("You are Codex"))
        XCTAssertTrue(system.contains("You are a coding agent. Do not claim to be GPT-5 or to be made by OpenAI."))
        XCTAssertTrue(system.contains("Keep changes focused."))
        XCTAssertTrue(system.contains("Valid tool names for this turn are exactly `exec`."))
        XCTAssertTrue(system.contains("Do not use neighboring-agent tool names `Read`, `Grep`, `Glob`, `Bash`, `LS`, `apply_patch` unless this turn's catalog lists those exact names."))
        XCTAssertTrue(system.contains("Count a tool call only after its tool result returns; batch independent read-only calls when the runtime supports it."))
        XCTAssertTrue(system.contains("do not emit <tool_call>, tool_code, functions.*"))
    }

    func testAdditionalToolsInputItemIsForwardedAsTools() throws {
        let request = try incoming([
            "input": [
                [
                    "type": "additional_tools",
                    "role": "developer",
                    "tools": [
                        ["type": "function", "name": "exec_command", "description": "Run a command", "parameters": ["type": "object"]],
                        ["type": "custom", "name": "apply_patch", "description": "Apply a patch",
                         "format": ["definition": "diff grammar"]],
                    ],
                ],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "create a file"]]],
            ],
            "stream": false,
        ])
        let result = try AnthropicMessagesBridge().makeRequest(from: request, provider: snapshot())
        let body = try XCTUnwrap(result.urlRequest.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("exec_command"))
        XCTAssertTrue(names.contains("apply_patch"))
        // additional_tools 项本身不应作为消息发送
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertFalse(messages.contains { ($0["role"] as? String) == "developer" && (($0["content"] as? [[String: Any]])?.contains { ($0["type"] as? String) == "text" && (($0["text"] as? String ?? "").contains("diff grammar")) } ?? false) })
    }

    func testAnthropicAPIKeyAuthentication() throws {
        let request = try incoming(["input": [], "stream": false])
        let result = try AnthropicMessagesBridge().makeRequest(from: request, provider: snapshot(
            credentialMode: .keychainAPIKey
        ))
        XCTAssertEqual(result.urlRequest.value(forHTTPHeaderField: "x-api-key"), "secret")
        XCTAssertNil(result.urlRequest.value(forHTTPHeaderField: "Authorization"))
    }

    func testStreamingConverterEmitsNativeTextThinkingAndToolEvents() throws {
        let stream = [
            event("message_start", #"{"type":"message_start","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":12,"output_tokens":0}}}"#),
            event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"think"}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}"#),
            event("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            event("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque-stream-data"}}"#),
            event("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            event("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"done"}}"#),
            event("content_block_start", #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu-1","name":"exec","input":{}}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"input\":\"pwd\"}"}}"#),
            event("content_block_stop", #"{"type":"content_block_stop","index":3}"#),
            event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#),
            event("message_stop", #"{"type":"message_stop"}"#),
        ].joined()
        let converter = AnthropicMessagesStreamConverter(mappings: ["exec": .function(name: "exec", namespace: nil)])
        var output = Data()
        for byte in Data(stream.utf8) { output.append(try converter.consume(Data([byte]))) }
        output.append(try converter.finish())
        let text = String(decoding: output, as: UTF8.self)
        let frames = try sseFrames(output)
        let types = frames.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains("response.reasoning_summary_part.added"))
        XCTAssertTrue(types.contains("response.reasoning_summary_text.delta"))
        XCTAssertTrue(types.contains("response.reasoning_summary_text.done"))
        XCTAssertTrue(types.contains("response.reasoning_summary_part.done"))
        XCTAssertFalse(types.contains("response.reasoning_text.delta"))
        XCTAssertTrue(text.contains("response.output_text.delta"))
        XCTAssertTrue(text.contains("function_call"))
        XCTAssertTrue(text.contains("gpts2:"))
        XCTAssertTrue(text.contains("response.completed"))

        let addedToolFrame = try XCTUnwrap(frames.first { frame in
            frame["type"] as? String == "response.output_item.added"
                && (frame["item"] as? [String: Any])?["type"] as? String == "function_call"
        })
        let addedTool = try XCTUnwrap(addedToolFrame["item"] as? [String: Any])
        let doneArgumentsFrame = try XCTUnwrap(frames.first {
            $0["type"] as? String == "response.function_call_arguments.done"
        })
        let doneToolFrame = try XCTUnwrap(frames.first { frame in
            frame["type"] as? String == "response.output_item.done"
                && (frame["item"] as? [String: Any])?["type"] as? String == "function_call"
        })
        let doneTool = try XCTUnwrap(doneToolFrame["item"] as? [String: Any])
        XCTAssertEqual(addedTool["arguments"] as? String, "")
        XCTAssertEqual(addedTool["id"] as? String, doneArgumentsFrame["item_id"] as? String)
        XCTAssertEqual(addedTool["id"] as? String, doneTool["id"] as? String)
        XCTAssertEqual(addedToolFrame["output_index"] as? Int, doneArgumentsFrame["output_index"] as? Int)
        XCTAssertEqual(addedToolFrame["output_index"] as? Int, doneToolFrame["output_index"] as? Int)
        XCTAssertEqual(doneTool["status"] as? String, "completed")
        XCTAssertEqual(converter.observation.usage?.inputTokens, 12)
    }

    func testPseudoXMLToolCallsStayText() throws {
        let data = Data(#"{"id":"msg-1","model":"claude","content":[{"type":"text","text":"<function_calls><invoke name=\"exec\"/></function_calls>"}],"stop_reason":"end_turn"}"#.utf8)
        let output = try AnthropicMessagesBridge().makeNonStreamingResponse(data: data, mappings: [:])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let items = try XCTUnwrap(root["output"] as? [[String: Any]])
        XCTAssertTrue(items.allSatisfy { $0["type"] as? String != "function_call" })
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("function_calls"))
    }

    func testUnknownNativeToolAndMalformedArgumentsAreRejected() throws {
        let unknown = Data(#"{"id":"msg-1","model":"claude","content":[{"type":"tool_use","id":"toolu","name":"unknown","input":{}}],"stop_reason":"tool_use"}"#.utf8)
        XCTAssertThrowsError(try AnthropicMessagesBridge().makeNonStreamingResponse(data: unknown, mappings: [:]))
        let malformed = Data(#"{"id":"msg-1","model":"claude","content":[{"type":"tool_use","id":"toolu","name":"exec","input":"bad"}],"stop_reason":"tool_use"}"#.utf8)
        XCTAssertThrowsError(try AnthropicMessagesBridge().makeNonStreamingResponse(
            data: malformed,
            mappings: ["exec": .function(name: "exec", namespace: nil)]
        ))
    }

    func testReasoningEnvelopeRoundTrips() throws {
        let blocks: [AnthropicReasoningBlock] = [
            .thinking(text: "think", signature: "signature-123456"),
            .redacted(data: "opaque-redacted-data"),
            .thinking(text: "think again", signature: "signature-789"),
        ]
        let encoded = try XCTUnwrap(AnthropicReasoningEnvelope.encode(blocks: blocks))
        XCTAssertTrue(encoded.hasPrefix("gpts2:"))
        let decoded = try XCTUnwrap(AnthropicReasoningEnvelope.decode(encoded))
        XCTAssertEqual(decoded.blocks, blocks)
        XCTAssertEqual(decoded.signature, "signature-123456")
        XCTAssertEqual(decoded.thinking, "think\nthink again")
        XCTAssertNil(AnthropicReasoningEnvelope.decode("real-anthropic-signature"))
        XCTAssertNil(AnthropicReasoningEnvelope.decode("gpts2:not-base64"))
        XCTAssertNil(AnthropicReasoningEnvelope.encode(blocks: [
            .redacted(data: String(repeating: "x", count: 1_048_577)),
        ]))
        let unknownData = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "blocks": [["type": "unknown", "data": "opaque"]],
        ])
        XCTAssertNil(AnthropicReasoningEnvelope.decode(
            "gpts2:\(unknownData.base64EncodedString())"
        ))
    }

    func testLegacyReasoningEnvelopeStillDecodes() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "signature": "legacy-signature",
            "thinking": "legacy thinking",
        ])
        let decoded = try XCTUnwrap(AnthropicReasoningEnvelope.decode(
            "gpts1:\(data.base64EncodedString())"
        ))
        XCTAssertEqual(decoded.blocks, [
            .thinking(text: "legacy thinking", signature: "legacy-signature"),
        ])
    }

    func testRedactedThinkingRoundTripsInOriginalBlockOrder() throws {
        let data = Data(#"{"id":"msg-1","model":"claude","content":[{"type":"thinking","thinking":"first","signature":"sig-1"},{"type":"redacted_thinking","data":"opaque-data"},{"type":"thinking","thinking":"second","signature":"sig-2"},{"type":"tool_use","id":"toolu-1","name":"exec","input":{"input":"pwd"}}],"stop_reason":"tool_use"}"#.utf8)
        let mappings: [String: ChatToolIdentity] = ["exec": .function(name: "exec", namespace: nil)]
        let response = try AnthropicMessagesBridge().makeNonStreamingResponse(data: data, mappings: mappings)
        let responseRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let output = try XCTUnwrap(responseRoot["output"] as? [[String: Any]])
        XCTAssertEqual(output.map { $0["type"] as? String }, ["reasoning", "function_call"])
        let encrypted = try XCTUnwrap(output.first?["encrypted_content"] as? String)
        XCTAssertEqual(AnthropicReasoningEnvelope.decode(encrypted)?.blocks, [
            .thinking(text: "first", signature: "sig-1"),
            .redacted(data: "opaque-data"),
            .thinking(text: "second", signature: "sig-2"),
        ])

        let replay = try incoming([
            "input": output,
            "tools": [[
                "type": "function",
                "name": "exec",
                "parameters": ["type": "object"],
            ]],
            "stream": false,
        ])
        let upstream = try AnthropicMessagesBridge().makeRequest(from: replay, provider: snapshot())
        let body = try XCTUnwrap(upstream.urlRequest.httpBody)
        let bodyRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(bodyRoot["messages"] as? [[String: Any]])
        let replayedBlocks = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(replayedBlocks.map { $0["type"] as? String }, [
            "thinking", "redacted_thinking", "thinking", "tool_use",
        ])
        XCTAssertEqual(replayedBlocks[1]["data"] as? String, "opaque-data")
    }

    func testPureRedactedThinkingProducesEnvelopeWithoutVisibleContent() throws {
        let data = Data(#"{"id":"msg-1","model":"claude","content":[{"type":"redacted_thinking","data":"opaque-only"}],"stop_reason":"end_turn"}"#.utf8)
        let response = try AnthropicMessagesBridge().makeNonStreamingResponse(data: data, mappings: [:])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let reasoning = try XCTUnwrap((root["output"] as? [[String: Any]])?.first)
        XCTAssertEqual(reasoning["type"] as? String, "reasoning")
        XCTAssertNil(reasoning["content"])
        let encrypted = try XCTUnwrap(reasoning["encrypted_content"] as? String)
        XCTAssertEqual(AnthropicReasoningEnvelope.decode(encrypted)?.blocks, [
            .redacted(data: "opaque-only"),
        ])
    }

    private func event(_ name: String, _ payload: String) -> String {
        "event: \(name)\ndata: \(payload)\n\n"
    }

    private func sseFrames(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n\n")
            .compactMap { frame in
                guard let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }),
                      line != "data: [DONE]" else { return nil }
                let payload = line.dropFirst("data: ".count)
                return try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            }
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

    private func snapshot(credentialMode: ProviderCredentialMode = .keychainBearer) -> ActiveProviderSnapshot {
        ActiveProviderSnapshot(
            profile: ProviderProfile(
                configName: "claude",
                displayName: "Claude",
                baseURL: "https://relay.example/api/v1",
                bridgeModel: "",
                wireProtocol: .anthropicMessages,
                inferenceModel: "claude-opus-4-8",
                credentialMode: credentialMode
            ),
            bearerToken: "secret"
        )
    }
}
