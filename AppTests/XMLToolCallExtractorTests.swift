import Foundation
import XCTest
@testable import GPTSwitch

final class XMLToolCallExtractorTests: XCTestCase {
    private let mappings: [String: ChatToolIdentity] = [
        "exec_command": .function(name: "exec_command", namespace: nil),
        "write_to_file": .function(name: "write_to_file", namespace: nil),
        "apply_patch": .custom(name: "apply_patch"),
    ]

    func testConvertsClineStyleToolCall() throws {
        let events = extractor.process([
            .responseStarted(id: "resp", model: "glm-5.2"),
            .textDelta("<write_to_file>\n<path>ddd</path>\n<content></content>\n</write_to_file>"),
            .completed,
        ]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "write_to_file")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["path"] as? String, "ddd")
        XCTAssertEqual(args["content"] as? String, "")
        XCTAssertFalse(events.text().contains("<write_to_file>"))
    }

    func testExecCommandFromRealLeak() throws {
        let leak = "I'll create the file \"rrr\" for you.\n\n  <exec_command>\n  <cmd>touch rrr</cmd>\n  </exec_command>\n\n  Created the file rrr in the current directory."
        let events = extractor.process([.textDelta(leak), .completed]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "exec_command")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["cmd"] as? String, "touch rrr")
        let text = events.text()
        XCTAssertFalse(text.contains("<exec_command>"))
        XCTAssertTrue(text.contains("I'll create the file"))
        XCTAssertTrue(text.contains("Created the file rrr"))
    }

    func testSplitsAcrossChunks() throws {
        let pieces = ["<exec_", "command>", "<cmd>", "touch rrr", "</cmd>", "</exec_command>"]
        var events: [AdapterEvent] = [.responseStarted(id: "r", model: nil)]
        for piece in pieces { events += extractor.process([.textDelta(piece)]) }
        events += extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "exec_command")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["cmd"] as? String, "touch rrr")
    }

    func testUnknownTagStaysText() {
        let events = extractor.process([.textDelta("<function_calls><invoke name=\"exec\"/></function_calls>")]) + extractor.finish()
        XCTAssertEqual(events.toolCalls().count, 0)
        XCTAssertEqual(events.text(), "<function_calls><invoke name=\"exec\"/></function_calls>")
    }

    func testAngleBracketInCodeNotMisread() {
        let events = extractor.process([.textDelta("use a < b and <div> tags; x < 3 > 2")]) + extractor.finish()
        XCTAssertEqual(events.toolCalls().count, 0)
        XCTAssertEqual(events.text(), "use a < b and <div> tags; x < 3 > 2")
    }

    func testTextAroundCallIsPreserved() {
        let events = extractor.process([.textDelta("Creating file.\n<write_to_file><path>x</path><content>hi</content></write_to_file>\nDone.")]) + extractor.finish()
        XCTAssertEqual(events.toolCalls().count, 1)
        XCTAssertEqual(events.text(), "Creating file.\n\nDone.")
    }

    func testCustomToolReceivesRawInput() throws {
        let events = extractor.process([.textDelta("<apply_patch>*** Begin Patch\n*** End Patch</apply_patch>")]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "apply_patch")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["input"] as? String, "*** Begin Patch\n*** End Patch")
    }

    func testFunctionWithJSONInner() throws {
        let events = extractor.process([.textDelta("<exec_command>{\"cmd\":\"ls -la\"}</exec_command>")]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["cmd"] as? String, "ls -la")
    }

    func testValueCoercion() throws {
        let events = extractor.process([.textDelta("<write_to_file><count>3</count><flag>true</flag></write_to_file>")]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["count"] as? Int, 3)
        XCTAssertEqual(args["flag"] as? Bool, true)
    }

    func testMultipleToolBlocksInOneText() {
        let events = extractor.process([.textDelta("<exec_command><cmd>a</cmd></exec_command>\n<exec_command><cmd>b</cmd></exec_command>")]) + extractor.finish()
        let calls = events.toolCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].arguments.contains("\"a\""), true)
        XCTAssertEqual(calls[1].arguments.contains("\"b\""), true)
    }

    func testUnterminatedBlockFlushesAsText() {
        let events = extractor.process([.textDelta("prefix <write_to_file><path>x")]) + extractor.finish()
        XCTAssertEqual(events.toolCalls().count, 0)
        XCTAssertEqual(events.text(), "prefix <write_to_file><path>x")
    }

    func testSelfClosingTag() throws {
        let events = extractor.process([.textDelta("<exec_command/>")]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "exec_command")
        XCTAssertEqual(tool.arguments, "{}")
    }

    func testAntMLFunctionCallsWithFunctionsPrefix() throws {
        let leak = "<function_calls><invoke name=\"functions.exec_command\"><parameter name=\"cmd\">touch rrr</parameter></invoke></function_calls>"
        let events = extractor.process([.textDelta(leak), .completed]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "exec_command")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["cmd"] as? String, "touch rrr")
        XCTAssertFalse(events.text().contains("function_calls"))
    }

    func testAntMLWriteToFileParams() throws {
        let leak = "<function_calls><invoke name=\"write_to_file\"><parameter name=\"path\">x</parameter><parameter name=\"content\">hi</parameter></invoke></function_calls>"
        let events = extractor.process([.textDelta(leak)]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "write_to_file")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["path"] as? String, "x")
        XCTAssertEqual(args["content"] as? String, "hi")
    }

    func testToolUseNameArgumentsFormat() throws {
        let leak = "creating file.\n<tool_use><name>apply_patch</name><arguments>{\"input\":\"patch\"}</arguments></tool_use>\ndone."
        let events = extractor.process([.textDelta(leak)]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "apply_patch")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["input"] as? String, "patch")
        XCTAssertTrue(events.text().contains("creating file."))
        XCTAssertTrue(events.text().contains("done."))
    }

    func testJSONInWrapperTag() throws {
        let leak = "<function_call>{\"name\":\"exec_command\",\"arguments\":{\"cmd\":\"ls\"}}</function_call>"
        let events = extractor.process([.textDelta(leak)]) + extractor.finish()
        let tool = try XCTUnwrap(events.toolCalls().first)
        XCTAssertEqual(tool.name, "exec_command")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["cmd"] as? String, "ls")
    }

    func testUnknownInvokeNamePassesThrough() {
        let leak = "<function_calls><invoke name=\"not_a_tool\"><parameter name=\"x\">y</parameter></invoke></function_calls>"
        let events = extractor.process([.textDelta(leak)]) + extractor.finish()
        XCTAssertEqual(events.toolCalls().count, 0)
        XCTAssertEqual(events.text(), leak)
    }

    func testEndToEndNonStreamingJSON() throws {
        let events: [AdapterEvent] = [
            .responseStarted(id: "msg-1", model: "glm-5.2"),
            .textDelta("I'll create the file.\n<write_to_file>\n<path>rrr</path>\n<content></content>\n</write_to_file>"),
            .completed,
        ]
        let data = try AdapterResponseBuilder.json(events: events, mappings: mappings)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(root["output"] as? [[String: Any]])
        let call = try XCTUnwrap(output.first { $0["type"] as? String == "function_call" })
        XCTAssertEqual(call["name"] as? String, "write_to_file")
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((call["arguments"] as? String ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(args["path"] as? String, "rrr")
        let message = try XCTUnwrap(output.first { $0["type"] as? String == "message" })
        let text = try XCTUnwrap(((message["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertFalse(text.contains("<write_to_file>"))
        XCTAssertTrue(text.contains("I'll create the file."))
    }

    private lazy var extractor: XMLToolCallExtractor = XMLToolCallExtractor(mappings: self.mappings)
}

private struct ToolCallSnapshot {
    let name: String
    let arguments: String
}

private extension Array where Element == AdapterEvent {
    func toolCalls() -> [ToolCallSnapshot] {
        var calls: [ToolCallSnapshot] = []
        var nameByID: [Int: String] = [:]
        var argsByID: [Int: String] = [:]
        for event in self {
            switch event {
            case .toolCallStarted(let index, _, let name): nameByID[index] = name
            case .toolCallArgumentsDelta(let index, let delta): argsByID[index, default: ""] += delta
            default: continue
            }
        }
        for index in nameByID.keys.sorted() {
            calls.append(ToolCallSnapshot(name: nameByID[index] ?? "", arguments: argsByID[index] ?? ""))
        }
        return calls
    }

    func text() -> String {
        compactMap { event -> String? in
            if case .textDelta(let delta) = event { return delta }
            return nil
        }.joined()
    }
}
