import Foundation
import XCTest
@testable import GPTSwitch

final class ModelProtocolAdapterTests: XCTestCase {
    func testParserNormalizesImagesReasoningNamespacesAndToolResults() throws {
        let request = try incoming([
            "instructions": "System",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": "Look"],
                        ["type": "input_image", "image_url": "data:image/png;base64,AAAA"],
                    ],
                ],
                ["type": "reasoning", "content": [["type": "reasoning_text", "text": "think"]]],
                [
                    "type": "function_call",
                    "namespace": "mcp",
                    "name": "search",
                    "call_id": "call-1",
                    "arguments": #"{"query":"swift"}"#,
                ],
                ["type": "function_call_output", "call_id": "call-1", "output": "done"],
            ],
            "tools": [[
                "type": "namespace",
                "name": "mcp",
                "tools": [["type": "function", "name": "search", "parameters": ["type": "object"]]],
            ]],
            "stream": true,
        ])
        let parsed = try ResponsesRequestParser().parse(request)
        XCTAssertEqual(parsed.instructions, "System")
        XCTAssertEqual(parsed.input.count, 4)
        XCTAssertEqual(parsed.toolMappings["mcp__search"], .function(name: "search", namespace: "mcp"))
        XCTAssertTrue(parsed.stream)
    }

    func testParserRejectsHostedToolsAndMalformedArguments() throws {
        XCTAssertThrowsError(try ResponsesRequestParser().parse(try incoming([
            "input": [],
            "tools": [["type": "web_search"]],
        ])))
        XCTAssertThrowsError(try ResponsesRequestParser().parse(try incoming([
            "input": [[
                "type": "function_call",
                "name": "exec",
                "call_id": "call-1",
                "arguments": "bad",
            ]],
            "tools": [["type": "function", "name": "exec", "parameters": ["type": "object"]]],
        ])))
    }

    func testEventBridgeRejectsUnknownTool() throws {
        let bridge = ResponsesEventBridge(mappings: [:])
        XCTAssertThrowsError(try bridge.consume([
            .responseStarted(id: "resp-1", model: "model"),
            .toolCallStarted(index: 0, id: "call-1", name: "unknown"),
        ], streaming: true))
    }

    func testEventBridgeEmitsCompleteReasoningAndFunctionCallLifecycles() throws {
        let bridge = ResponsesEventBridge(mappings: [
            "exec": .function(name: "exec", namespace: nil),
        ])
        let output = try bridge.consume([
            .responseStarted(id: "resp-1", model: "claude"),
            .reasoningDelta("think"),
            .reasoningBlock(.thinking(text: "think", signature: "signed")),
            .toolCallStarted(index: 0, id: "call-1", name: "exec"),
            .toolCallArgumentsDelta(index: 0, delta: #"{"command":"pwd"}"#),
            .toolCallEnded(index: 0),
            .completed,
        ], streaming: true)
        let frames = try sseFrames(output)
        let types = frames.compactMap { $0["type"] as? String }
        XCTAssertEqual(types, [
            "response.created",
            "response.output_item.added",
            "response.reasoning_summary_part.added",
            "response.reasoning_summary_text.delta",
            "response.reasoning_summary_text.done",
            "response.reasoning_summary_part.done",
            "response.output_item.done",
            "response.output_item.added",
            "response.function_call_arguments.delta",
            "response.function_call_arguments.done",
            "response.output_item.done",
            "response.completed",
        ])

        let toolAdded = try XCTUnwrap(frames.first { frame in
            frame["type"] as? String == "response.output_item.added"
                && (frame["item"] as? [String: Any])?["type"] as? String == "function_call"
        })
        let toolDone = try XCTUnwrap(frames.first { frame in
            frame["type"] as? String == "response.output_item.done"
                && (frame["item"] as? [String: Any])?["type"] as? String == "function_call"
        })
        let startedItem = try XCTUnwrap(toolAdded["item"] as? [String: Any])
        let completedItem = try XCTUnwrap(toolDone["item"] as? [String: Any])
        XCTAssertEqual(startedItem["id"] as? String, completedItem["id"] as? String)
        XCTAssertEqual(toolAdded["output_index"] as? Int, toolDone["output_index"] as? Int)
        XCTAssertEqual(startedItem["arguments"] as? String, "")
        XCTAssertEqual(completedItem["arguments"] as? String, #"{"command":"pwd"}"#)
        XCTAssertEqual(completedItem["status"] as? String, "completed")

        let completed = try XCTUnwrap(frames.last?["response"] as? [String: Any])
        let items = try XCTUnwrap(completed["output"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["type"] as? String }, ["reasoning", "function_call"])
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
}
