import Foundation
import XCTest
@testable import GPTSwitch

final class UsageExtractorTests: XCTestCase {
    func testExtractsRequestMetadataWithoutRetainingPrompt() {
        let body = Data(#"{"model":"gpt-5","stream":true,"input":"private prompt"}"#.utf8)
        let metadata = UsageExtractor.requestMetadata(from: body)

        XCTAssertEqual(metadata.model, "gpt-5")
        XCTAssertTrue(metadata.isStreaming)
        XCTAssertFalse(String(describing: metadata).contains("private prompt"))
    }

    func testExtractsResponsesJSONUsage() {
        let data = Data(#"{"model":"gpt-5","usage":{"input_tokens":120,"output_tokens":30,"input_tokens_details":{"cached_tokens":20},"output_tokens_details":{"reasoning_tokens":10}}}"#.utf8)
        let observation = UsageExtractor.observation(from: data, contentType: "application/json")

        XCTAssertEqual(observation.model, "gpt-5")
        XCTAssertEqual(observation.usage, TokenUsage(inputTokens: 120, outputTokens: 30, cachedInputTokens: 20, reasoningTokens: 10))
    }

    func testStreamingParserHandlesFragmentedSSE() {
        let parser = StreamingUsageParser()
        parser.begin(contentType: "text/event-stream")
        let event = #"data: {"type":"response.completed","response":{"model":"gpt-5-mini","usage":{"input_tokens":42,"output_tokens":8,"input_tokens_details":{"cached_tokens":12}}}}"# + "\n\n"
        let data = Data(event.utf8)
        parser.consume(Data(data.prefix(37)))
        parser.consume(Data(data.dropFirst(37)))

        let observation = parser.finish()
        XCTAssertEqual(observation.model, "gpt-5-mini")
        XCTAssertEqual(observation.usage?.inputTokens, 42)
        XCTAssertEqual(observation.usage?.cachedInputTokens, 12)
        XCTAssertEqual(observation.usage?.outputTokens, 8)
    }

    func testOversizedResponseSkipsUsage() {
        let parser = StreamingUsageParser()
        parser.begin(contentType: "application/json")
        parser.consume(Data(repeating: 0x20, count: UsageExtractor.maximumBufferedEventBytes + 1))
        XCTAssertNil(parser.finish().usage)
    }
}
