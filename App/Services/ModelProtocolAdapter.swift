import Foundation

enum ModelProtocolError: LocalizedError {
    case invalidResponsesRequest
    case invalidUpstreamResponse
    case unsupportedHostedTool(String)
    case unknownTool(String)
    case invalidToolArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponsesRequest: "无法解析 Responses 请求"
        case .invalidUpstreamResponse: "无法解析上游模型响应"
        case .unsupportedHostedTool(let type): "当前 Provider 不支持托管工具：\(type)"
        case .unknownTool(let name): "上游返回了未注册的工具：\(name)"
        case .invalidToolArguments(let name): "上游工具 \(name) 返回了无效参数"
        }
    }
}

enum ChatToolIdentity: Equatable, Sendable {
    case function(name: String, namespace: String?)
    case custom(name: String)
    case toolSearch(execution: String)
}

struct NormalizedTool {
    let wireName: String
    let identity: ChatToolIdentity
    let description: String
    let parameters: [String: Any]
}

enum NormalizedContentPart {
    case text(String)
    case image(String)
}

enum NormalizedInputItem {
    case message(role: String, content: [NormalizedContentPart])
    case reasoning(text: String, anthropicBlocks: [AnthropicReasoningBlock])
    case toolCall(identity: ChatToolIdentity, callID: String, arguments: [String: Any])
    case toolResult(callID: String, output: String)
    case compaction(String)
}

enum NormalizedToolChoice {
    case auto
    case none
    case required
    case tool(String)
}

struct NormalizedResponsesRequest {
    let instructions: String?
    let input: [NormalizedInputItem]
    let tools: [NormalizedTool]
    let toolMappings: [String: ChatToolIdentity]
    let toolChoice: NormalizedToolChoice
    let stream: Bool
    let parallelToolCalls: Bool
    let maxOutputTokens: Int?
    let temperature: Double?
    let topP: Double?
    let reasoningEffort: String?
    let responseFormat: [String: Any]?
}

enum ToolNameCodec {
    static func encode(namespace: String?, name: String) -> String {
        let raw = [namespace, Optional(name)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "__")
        guard raw.count > 64 else { return raw }
        let suffix = String(format: "%08x", stableHash(raw))
        return "\(raw.prefix(55))_\(suffix)"
    }

    private static func stableHash(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
}

enum AnthropicReasoningBlock: Equatable, Sendable {
    case thinking(text: String, signature: String)
    case redacted(data: String)
}

enum AnthropicReasoningEnvelope {
    struct Decoded: Equatable, Sendable {
        let blocks: [AnthropicReasoningBlock]

        var thinking: String {
            blocks.compactMap { block in
                guard case .thinking(let text, _) = block else { return nil }
                return text
            }.joined(separator: "\n")
        }

        var signature: String? {
            blocks.compactMap { block in
                guard case .thinking(_, let signature) = block else { return nil }
                return signature
            }.first
        }
    }

    private struct LegacyPayload: Codable {
        let version: Int
        let signature: String
        let thinking: String
    }

    private struct BlockPayload: Codable {
        let type: String
        let thinking: String?
        let signature: String?
        let data: String?
    }

    private struct Payload: Codable {
        let version: Int
        let blocks: [BlockPayload]
    }

    private static let legacyPrefix = "gpts1:"
    private static let prefix = "gpts2:"
    private static let maximumBlockCount = 64
    private static let maximumFieldLength = 1_048_576
    private static let maximumEncodedLength = 4_194_304

    static func encode(signature: String, thinking: String) -> String? {
        encode(blocks: [.thinking(text: thinking, signature: signature)])
    }

    static func encode(blocks: [AnthropicReasoningBlock]) -> String? {
        guard let validated = validated(blocks), !validated.isEmpty else { return nil }
        let payload = Payload(version: 2, blocks: validated.map { block in
            switch block {
            case .thinking(let text, let signature):
                BlockPayload(type: "thinking", thinking: text, signature: signature, data: nil)
            case .redacted(let data):
                BlockPayload(type: "redacted_thinking", thinking: nil, signature: nil, data: data)
            }
        })
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let encoded = prefix + data.base64EncodedString()
        return encoded.count <= maximumEncodedLength ? encoded : nil
    }

    static func decode(_ value: String?) -> Decoded? {
        guard let value, value.count <= maximumEncodedLength else { return nil }
        if value.hasPrefix(prefix) {
            guard let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  payload.version == 2 else { return nil }
            let blocks = payload.blocks.compactMap { block -> AnthropicReasoningBlock? in
                switch block.type {
                case "thinking":
                    guard let thinking = block.thinking, let signature = block.signature else { return nil }
                    return .thinking(text: thinking, signature: signature)
                case "redacted_thinking":
                    guard let data = block.data else { return nil }
                    return .redacted(data: data)
                default:
                    return nil
                }
            }
            guard blocks.count == payload.blocks.count,
                  let validated = validated(blocks), !validated.isEmpty else { return nil }
            return Decoded(blocks: validated)
        }
        if value.hasPrefix(legacyPrefix) {
            guard let data = Data(base64Encoded: String(value.dropFirst(legacyPrefix.count))),
                  let payload = try? JSONDecoder().decode(LegacyPayload.self, from: data),
                  payload.version == 1,
                  let blocks = validated([.thinking(text: payload.thinking, signature: payload.signature)]) else {
                return nil
            }
            return Decoded(blocks: blocks)
        }
        return nil
    }

    private static func validated(
        _ blocks: [AnthropicReasoningBlock]
    ) -> [AnthropicReasoningBlock]? {
        guard blocks.count <= maximumBlockCount else { return nil }
        for block in blocks {
            switch block {
            case .thinking(let text, let signature):
                guard !signature.isEmpty,
                      text.count <= maximumFieldLength,
                      signature.count <= maximumFieldLength else { return nil }
            case .redacted(let data):
                guard !data.isEmpty, data.count <= maximumFieldLength else { return nil }
            }
        }
        return blocks
    }
}

struct ResponsesRequestParser {
    func parse(_ request: IncomingHTTPRequest) throws -> NormalizedResponsesRequest {
        guard let root = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            throw ModelProtocolError.invalidResponsesRequest
        }
        var parsedTools = try parseTools(root["tools"] as? [[String: Any]] ?? [])
        // Codex CLI 可能把工具放在 input 的 additional_tools 项里（role: developer），
        // 而非顶层 tools 字段。这里解析并合并进目录，同时把它们从 input 过滤掉（不当消息发）。
        let inputArray = root["input"] as? [[String: Any]] ?? []
        for item in inputArray where (item["type"] as? String) == "additional_tools" {
            let more = try parseTools(item["tools"] as? [[String: Any]] ?? [])
            for tool in more.tools where parsedTools.mappings[tool.wireName] == nil {
                parsedTools.mappings[tool.wireName] = tool.identity
                parsedTools.tools.append(tool)
            }
        }
        let filteredInput = inputArray.filter { ($0["type"] as? String) != "additional_tools" }
        return NormalizedResponsesRequest(
            instructions: root["instructions"] as? String,
            input: try parseInput(filteredInput, mappings: parsedTools.mappings),
            tools: parsedTools.tools,
            toolMappings: parsedTools.mappings,
            toolChoice: parseToolChoice(root["tool_choice"], mappings: parsedTools.mappings),
            stream: root["stream"] as? Bool ?? false,
            parallelToolCalls: root["parallel_tool_calls"] as? Bool ?? true,
            maxOutputTokens: integer(root["max_output_tokens"] ?? root["max_tokens"]),
            temperature: number(root["temperature"]),
            topP: number(root["top_p"]),
            reasoningEffort: (root["reasoning"] as? [String: Any])?["effort"] as? String,
            responseFormat: (root["text"] as? [String: Any])?["format"] as? [String: Any]
        )
    }

    private func parseTools(
        _ source: [[String: Any]]
    ) throws -> (tools: [NormalizedTool], mappings: [String: ChatToolIdentity]) {
        var tools: [NormalizedTool] = []
        var mappings: [String: ChatToolIdentity] = [:]

        func append(
            name: String,
            namespace: String?,
            description: String,
            parameters: [String: Any],
            identity: ChatToolIdentity
        ) throws {
            let wireName = ToolNameCodec.encode(namespace: namespace, name: name)
            guard mappings[wireName] == nil else { throw ModelProtocolError.invalidResponsesRequest }
            mappings[wireName] = identity
            tools.append(NormalizedTool(
                wireName: wireName,
                identity: identity,
                description: description,
                parameters: parameters
            ))
        }

        for tool in source {
            let type = tool["type"] as? String ?? ""
            switch type {
            case "function":
                guard let name = tool["name"] as? String, !name.isEmpty else {
                    throw ModelProtocolError.invalidResponsesRequest
                }
                try append(
                    name: name,
                    namespace: nil,
                    description: tool["description"] as? String ?? "",
                    parameters: tool["parameters"] as? [String: Any] ?? [:],
                    identity: .function(name: name, namespace: nil)
                )
            case "namespace":
                guard let namespace = tool["name"] as? String,
                      let nested = tool["tools"] as? [[String: Any]] else {
                    throw ModelProtocolError.invalidResponsesRequest
                }
                for function in nested where function["type"] as? String == "function" {
                    guard let name = function["name"] as? String, !name.isEmpty else {
                        throw ModelProtocolError.invalidResponsesRequest
                    }
                    try append(
                        name: name,
                        namespace: namespace,
                        description: function["description"] as? String ?? "",
                        parameters: function["parameters"] as? [String: Any] ?? [:],
                        identity: .function(name: name, namespace: namespace)
                    )
                }
            case "custom":
                guard let name = tool["name"] as? String, !name.isEmpty else {
                    throw ModelProtocolError.invalidResponsesRequest
                }
                var description = tool["description"] as? String ?? ""
                if let definition = (tool["format"] as? [String: Any])?["definition"] as? String,
                   !definition.isEmpty {
                    description += "\nInput format:\n\(definition)"
                }
                try append(
                    name: name,
                    namespace: nil,
                    description: description,
                    parameters: [
                        "type": "object",
                        "properties": ["input": ["type": "string"]],
                        "required": ["input"],
                        "additionalProperties": false,
                    ],
                    identity: .custom(name: name)
                )
            case "tool_search":
                let execution = tool["execution"] as? String ?? "client"
                try append(
                    name: "tool_search",
                    namespace: nil,
                    description: tool["description"] as? String ?? "Search for more tools.",
                    parameters: tool["parameters"] as? [String: Any] ?? [:],
                    identity: .toolSearch(execution: execution)
                )
            case "web_search", "file_search", "image_generation", "computer_use", "code_interpreter":
                throw ModelProtocolError.unsupportedHostedTool(type)
            default:
                throw ModelProtocolError.unsupportedHostedTool(type.isEmpty ? "unknown" : type)
            }
        }
        return (tools, mappings)
    }

    private func parseInput(
        _ source: [[String: Any]],
        mappings: [String: ChatToolIdentity]
    ) throws -> [NormalizedInputItem] {
        var items: [NormalizedInputItem] = []
        for item in source {
            switch item["type"] as? String {
            case "message", "agent_message":
                let defaultRole = item["type"] as? String == "agent_message" ? "assistant" : "user"
                let role = item["role"] as? String ?? defaultRole
                items.append(.message(
                    role: role,
                    content: parseContent(item["content"] as? [[String: Any]] ?? [])
                ))
            case "reasoning":
                let content = text(in: item["content"]) + text(in: item["summary"])
                let envelope = AnthropicReasoningEnvelope.decode(item["encrypted_content"] as? String)
                let thinking = content.isEmpty ? envelope?.thinking ?? "" : content
                items.append(.reasoning(text: thinking, anthropicBlocks: envelope?.blocks ?? []))
            case "function_call":
                guard let name = item["name"] as? String,
                      let callID = item["call_id"] as? String else {
                    throw ModelProtocolError.invalidResponsesRequest
                }
                let wireName = ToolNameCodec.encode(namespace: item["namespace"] as? String, name: name)
                guard let identity = mappings[wireName] else { throw ModelProtocolError.unknownTool(wireName) }
                items.append(.toolCall(
                    identity: identity,
                    callID: callID,
                    arguments: try object(from: item["arguments"], toolName: wireName)
                ))
            case "custom_tool_call":
                guard let name = item["name"] as? String,
                      let callID = item["call_id"] as? String else {
                    throw ModelProtocolError.invalidResponsesRequest
                }
                let wireName = ToolNameCodec.encode(namespace: item["namespace"] as? String, name: name)
                guard let identity = mappings[wireName] else { throw ModelProtocolError.unknownTool(wireName) }
                items.append(.toolCall(
                    identity: identity,
                    callID: callID,
                    arguments: ["input": item["input"] as? String ?? ""]
                ))
            case "tool_search_call":
                guard let callID = item["call_id"] as? String,
                      let identity = mappings["tool_search"] else {
                    throw ModelProtocolError.invalidResponsesRequest
                }
                items.append(.toolCall(
                    identity: identity,
                    callID: callID,
                    arguments: item["arguments"] as? [String: Any] ?? [:]
                ))
            case "function_call_output", "custom_tool_call_output", "tool_search_output":
                guard let callID = item["call_id"] as? String else {
                    throw ModelProtocolError.invalidResponsesRequest
                }
                items.append(.toolResult(callID: callID, output: outputText(item["output"])))
            case "compaction", "context_compaction":
                if let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty {
                    items.append(.compaction(encrypted))
                }
            case .none:
                throw ModelProtocolError.invalidResponsesRequest
            default:
                continue
            }
        }
        return items
    }

    private func parseContent(_ source: [[String: Any]]) -> [NormalizedContentPart] {
        source.compactMap { part -> NormalizedContentPart? in
            switch part["type"] as? String {
            case "input_text", "output_text": return .text(part["text"] as? String ?? "")
            case "input_image":
                guard let value = part["image_url"] as? String, !value.isEmpty else { return nil }
                return .image(value)
            default: return nil
            }
        }
    }

    private func parseToolChoice(
        _ value: Any?,
        mappings: [String: ChatToolIdentity]
    ) -> NormalizedToolChoice {
        if let value = value as? String {
            switch value {
            case "none": return .none
            case "required": return .required
            default: return .auto
            }
        }
        guard let object = value as? [String: Any],
              let name = object["name"] as? String else { return .auto }
        if mappings[name] != nil { return .tool(name) }
        let match = mappings.first { _, identity in
            switch identity {
            case .function(let original, _): original == name
            case .custom(let original): original == name
            case .toolSearch: name == "tool_search"
            }
        }
        return .tool(match?.key ?? name)
    }

    private func object(from value: Any?, toolName: String) throws -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            throw ModelProtocolError.invalidToolArguments(toolName)
        }
        return object
    }

    private func outputText(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func text(in value: Any?) -> String {
        (value as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        return (value as? NSNumber)?.doubleValue
    }
}

struct AdapterRequest: Sendable {
    let urlRequest: URLRequest
    let toolMappings: [String: ChatToolIdentity]
    let clientRequestedStreaming: Bool
}

protocol ProviderAdapter {
    func makeRequest(
        parsed: NormalizedResponsesRequest,
        incoming: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot
    ) throws -> AdapterRequest

    func makeStreamDecoder(mappings: [String: ChatToolIdentity]) -> any AdapterStreamDecoder

    func parseResponse(
        data: Data,
        mappings: [String: ChatToolIdentity]
    ) throws -> [AdapterEvent]
}

enum AdapterEvent {
    case responseStarted(id: String, model: String?)
    case textDelta(String)
    case reasoningDelta(String)
    case rawReasoningDelta(String)
    case reasoningBlock(AnthropicReasoningBlock)
    case toolCallStarted(index: Int, id: String, name: String)
    case toolCallArgumentsDelta(index: Int, delta: String)
    case toolCallEnded(index: Int)
    case usage(TokenUsage)
    case completed
    case incomplete(String)
    case failed(String)
}

protocol AdapterStreamDecoder: AnyObject {
    func consume(_ data: Data) throws -> [AdapterEvent]
    func finish() throws -> [AdapterEvent]
    var observation: ResponseUsageObservation { get }
}

final class ResponsesEventBridge {
    private struct PendingToolCall {
        var id: String
        var name: String
        var identity: ChatToolIdentity
        var itemID: String
        var outputIndex: Int
        var arguments = ""
        var emittedCustomInput = ""
    }

    private enum ReasoningPresentation: Equatable {
        case summary
        case raw
    }

    private let mappings: [String: ChatToolIdentity]
    private var responseID = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    private var model: String?
    private var messageText = ""
    private var messageItemID: String?
    private var messageOutputIndex: Int?
    private var messageStreamStarted = false
    private var reasoningText = ""
    private var reasoningBlocks: [AnthropicReasoningBlock] = []
    private var reasoningPresentation: ReasoningPresentation?
    private var reasoningItemID: String?
    private var reasoningOutputIndex: Int?
    private var reasoningStreamStarted = false
    private var reasoningFinalized = false
    private var pendingTools: [Int: PendingToolCall] = [:]
    private var outputItems: [Int: [String: Any]] = [:]
    private var nextOutputIndex = 0
    private var usage: TokenUsage?
    private var created = false
    private var terminal = false
    private var status = "in_progress"
    private var incompleteReason: String?
    private var lastError: String?

    init(mappings: [String: ChatToolIdentity]) {
        self.mappings = mappings
    }

    func consume(_ events: [AdapterEvent], streaming: Bool) throws -> Data {
        var output = Data()
        for event in events {
            output.append(try consume(event, streaming: streaming))
        }
        return output
    }

    func responseJSON() throws -> Data {
        guard terminal else { throw ModelProtocolError.invalidUpstreamResponse }
        var response: [String: Any] = [
            "id": responseID,
            "object": "response",
            "status": status,
            "output": outputItems.keys.sorted().compactMap { outputItems[$0] },
        ]
        if let model { response["model"] = model }
        if let usage { response["usage"] = usageObject(usage) }
        if let incompleteReason { response["incomplete_details"] = ["reason": incompleteReason] }
        if let lastError { response["error"] = ["message": lastError] }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func consume(_ event: AdapterEvent, streaming: Bool) throws -> Data {
        switch event {
        case .responseStarted(let id, let model):
            if !id.isEmpty { responseID = id }
            self.model = model ?? self.model
            return streaming ? try ensureCreated() : Data()
        case .textDelta(let delta):
            guard !delta.isEmpty else { return Data() }
            var output = try finalizeReasoning(streaming: streaming)
            messageText += delta
            guard streaming else { return output }
            output.append(try ensureCreated())
            output.append(try startMessageIfNeeded())
            output.append(try sse(type: "response.output_text.delta", object: [
                "type": "response.output_text.delta",
                "item_id": messageItemID!,
                "output_index": messageOutputIndex!,
                "content_index": 0,
                "delta": delta,
            ]))
            return output
        case .reasoningDelta(let delta):
            return try consumeReasoningDelta(delta, presentation: .summary, streaming: streaming)
        case .rawReasoningDelta(let delta):
            return try consumeReasoningDelta(delta, presentation: .raw, streaming: streaming)
        case .reasoningBlock(let block):
            guard !reasoningFinalized else { throw ModelProtocolError.invalidUpstreamResponse }
            reasoningBlocks.append(block)
            return Data()
        case .toolCallStarted(let index, let id, let name):
            guard let identity = mappings[name] else { throw ModelProtocolError.unknownTool(name) }
            guard pendingTools[index] == nil else { throw ModelProtocolError.invalidUpstreamResponse }
            var output = try finalizeReasoning(streaming: streaming)
            output.append(try finalizeMessage(streaming: streaming))
            let pending = PendingToolCall(
                id: id.isEmpty ? "call_\(compactUUID())" : id,
                name: name,
                identity: identity,
                itemID: itemID(for: identity),
                outputIndex: allocateOutputIndex()
            )
            pendingTools[index] = pending
            if streaming {
                output.append(try ensureCreated())
                output.append(try sse(type: "response.output_item.added", object: [
                    "type": "response.output_item.added",
                    "output_index": pending.outputIndex,
                    "item": startedToolCallItem(pending),
                ]))
            }
            return output
        case .toolCallArgumentsDelta(let index, let delta):
            guard var pending = pendingTools[index] else { throw ModelProtocolError.invalidUpstreamResponse }
            pending.arguments += delta
            pendingTools[index] = pending
            guard streaming else { return Data() }
            switch pending.identity {
            case .function:
                return try sse(type: "response.function_call_arguments.delta", object: [
                    "type": "response.function_call_arguments.delta",
                    "item_id": pending.itemID,
                    "output_index": pending.outputIndex,
                    "delta": delta,
                ])
            case .custom:
                guard let input = customInput(from: pending.arguments),
                      input.hasPrefix(pending.emittedCustomInput) else { return Data() }
                let customDelta = String(input.dropFirst(pending.emittedCustomInput.count))
                guard !customDelta.isEmpty else { return Data() }
                pending.emittedCustomInput = input
                pendingTools[index] = pending
                return try sse(type: "response.custom_tool_call_input.delta", object: [
                    "type": "response.custom_tool_call_input.delta",
                    "item_id": pending.itemID,
                    "output_index": pending.outputIndex,
                    "delta": customDelta,
                ])
            case .toolSearch:
                return Data()
            }
        case .toolCallEnded(let index):
            guard let pending = pendingTools.removeValue(forKey: index) else {
                throw ModelProtocolError.invalidUpstreamResponse
            }
            let item = try completedToolCallItem(pending)
            outputItems[pending.outputIndex] = item
            guard streaming else { return Data() }
            var output = Data()
            switch pending.identity {
            case .function:
                output.append(try sse(type: "response.function_call_arguments.done", object: [
                    "type": "response.function_call_arguments.done",
                    "item_id": pending.itemID,
                    "output_index": pending.outputIndex,
                    "arguments": item["arguments"] as? String ?? "{}",
                ]))
            case .custom:
                output.append(try sse(type: "response.custom_tool_call_input.done", object: [
                    "type": "response.custom_tool_call_input.done",
                    "item_id": pending.itemID,
                    "output_index": pending.outputIndex,
                    "input": item["input"] as? String ?? "",
                ]))
            case .toolSearch:
                break
            }
            output.append(try sse(type: "response.output_item.done", object: [
                "type": "response.output_item.done",
                "output_index": pending.outputIndex,
                "item": item,
            ]))
            return output
        case .usage(let usage):
            self.usage = usage
            return Data()
        case .completed:
            return try finish(status: "completed", reason: nil, error: nil, streaming: streaming)
        case .incomplete(let reason):
            return try finish(status: "incomplete", reason: reason, error: nil, streaming: streaming)
        case .failed(let message):
            return try finish(status: "failed", reason: nil, error: message, streaming: streaming)
        }
    }

    private func finish(
        status: String,
        reason: String?,
        error: String?,
        streaming: Bool
    ) throws -> Data {
        guard !terminal else { return Data() }
        guard pendingTools.isEmpty else { throw ModelProtocolError.invalidUpstreamResponse }
        terminal = true
        self.status = status
        incompleteReason = reason
        lastError = error

        var output = streaming ? try ensureCreated() : Data()
        output.append(try finalizeReasoning(streaming: streaming))
        output.append(try finalizeMessage(streaming: streaming))
        guard streaming else { return output }

        var response: [String: Any] = [
            "id": responseID,
            "object": "response",
            "status": status,
            "output": outputItems.keys.sorted().compactMap { outputItems[$0] },
        ]
        if let model { response["model"] = model }
        if let usage { response["usage"] = usageObject(usage) }
        let type: String
        if let reason {
            type = "response.incomplete"
            response["incomplete_details"] = ["reason": reason]
        } else if let error {
            type = "response.failed"
            response["error"] = ["message": error]
        } else {
            type = "response.completed"
        }
        output.append(try sse(type: type, object: ["type": type, "response": response]))
        output.append(Data("data: [DONE]\n\n".utf8))
        return output
    }

    private func ensureCreated() throws -> Data {
        guard !created else { return Data() }
        created = true
        var response: [String: Any] = ["id": responseID, "status": "in_progress"]
        if let model { response["model"] = model }
        return try sse(type: "response.created", object: [
            "type": "response.created",
            "response": response,
        ])
    }

    private func startedToolCallItem(_ pending: PendingToolCall) -> [String: Any] {
        switch pending.identity {
        case .function(let name, let namespace):
            var item: [String: Any] = [
                "id": pending.itemID,
                "type": "function_call",
                "name": name,
                "arguments": "",
                "call_id": pending.id,
                "status": "in_progress",
            ]
            if let namespace { item["namespace"] = namespace }
            return item
        case .custom(let name):
            return [
                "id": pending.itemID,
                "type": "custom_tool_call",
                "name": name,
                "input": "",
                "call_id": pending.id,
                "status": "in_progress",
            ]
        case .toolSearch(let execution):
            return [
                "id": pending.itemID,
                "type": "tool_search_call",
                "call_id": pending.id,
                "status": "in_progress",
                "execution": execution,
                "arguments": [:],
            ]
        }
    }

    private func completedToolCallItem(_ pending: PendingToolCall) throws -> [String: Any] {
        let arguments = pending.arguments.isEmpty ? "{}" : pending.arguments
        guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else {
            throw ModelProtocolError.invalidToolArguments(pending.name)
        }
        let callID = pending.id
        switch pending.identity {
        case .function(let name, let namespace):
            var item: [String: Any] = [
                "id": pending.itemID,
                "type": "function_call",
                "name": name,
                "arguments": String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self),
                "call_id": callID,
                "status": "completed",
            ]
            if let namespace { item["namespace"] = namespace }
            return item
        case .custom(let name):
            let input = object["input"] as? String ?? ""
            guard object["input"] is String else {
                throw ModelProtocolError.invalidToolArguments(pending.name)
            }
            return [
                "id": pending.itemID,
                "type": "custom_tool_call",
                "name": name,
                "input": input,
                "call_id": callID,
                "status": "completed",
            ]
        case .toolSearch(let execution):
            return [
                "id": pending.itemID,
                "type": "tool_search_call",
                "call_id": callID,
                "status": "completed",
                "execution": execution,
                "arguments": object,
            ]
        }
    }

    private func customInput(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["input"] as? String
    }

    private func itemID(for identity: ChatToolIdentity) -> String {
        let prefix: String
        switch identity {
        case .function: prefix = "fc"
        case .custom: prefix = "ctc"
        case .toolSearch: prefix = "tsc"
        }
        return "\(prefix)_\(compactUUID())"
    }

    private func consumeReasoningDelta(
        _ delta: String,
        presentation: ReasoningPresentation,
        streaming: Bool
    ) throws -> Data {
        guard !delta.isEmpty else { return Data() }
        guard !reasoningFinalized else { throw ModelProtocolError.invalidUpstreamResponse }
        if let reasoningPresentation, reasoningPresentation != presentation {
            throw ModelProtocolError.invalidUpstreamResponse
        }
        reasoningPresentation = presentation
        reasoningText += delta
        guard streaming else { return Data() }
        var output = try ensureCreated()
        output.append(try startReasoningIfNeeded())
        switch presentation {
        case .summary:
            output.append(try sse(type: "response.reasoning_summary_text.delta", object: [
                "type": "response.reasoning_summary_text.delta",
                "item_id": reasoningItemID!,
                "output_index": reasoningOutputIndex!,
                "summary_index": 0,
                "delta": delta,
            ]))
        case .raw:
            output.append(try sse(type: "response.reasoning_text.delta", object: [
                "type": "response.reasoning_text.delta",
                "item_id": reasoningItemID!,
                "output_index": reasoningOutputIndex!,
                "content_index": 0,
                "delta": delta,
            ]))
        }
        return output
    }

    private func startReasoningIfNeeded() throws -> Data {
        if reasoningItemID == nil {
            reasoningItemID = "rs_\(compactUUID())"
            reasoningOutputIndex = allocateOutputIndex()
        }
        guard !reasoningStreamStarted else { return Data() }
        reasoningStreamStarted = true
        var item: [String: Any] = [
            "id": reasoningItemID!,
            "type": "reasoning",
            "summary": [],
        ]
        if reasoningPresentation == .raw { item["content"] = [] }
        var output = try sse(type: "response.output_item.added", object: [
            "type": "response.output_item.added",
            "output_index": reasoningOutputIndex!,
            "item": item,
        ])
        if reasoningPresentation == .summary, !reasoningText.isEmpty {
            output.append(try sse(type: "response.reasoning_summary_part.added", object: [
                "type": "response.reasoning_summary_part.added",
                "item_id": reasoningItemID!,
                "output_index": reasoningOutputIndex!,
                "summary_index": 0,
                "part": ["type": "summary_text", "text": ""],
            ]))
        }
        return output
    }

    private func finalizeReasoning(streaming: Bool) throws -> Data {
        guard !reasoningFinalized, !reasoningText.isEmpty || !reasoningBlocks.isEmpty else { return Data() }
        reasoningFinalized = true
        if reasoningPresentation == nil { reasoningPresentation = .summary }
        if reasoningItemID == nil {
            reasoningItemID = "rs_\(compactUUID())"
            reasoningOutputIndex = allocateOutputIndex()
        }
        let item = reasoningItem()
        outputItems[reasoningOutputIndex!] = item
        guard streaming else { return Data() }
        var output = try startReasoningIfNeeded()
        if reasoningPresentation == .summary, !reasoningText.isEmpty {
            output.append(try sse(type: "response.reasoning_summary_text.done", object: [
                "type": "response.reasoning_summary_text.done",
                "item_id": reasoningItemID!,
                "output_index": reasoningOutputIndex!,
                "summary_index": 0,
                "text": reasoningText,
            ]))
            output.append(try sse(type: "response.reasoning_summary_part.done", object: [
                "type": "response.reasoning_summary_part.done",
                "item_id": reasoningItemID!,
                "output_index": reasoningOutputIndex!,
                "summary_index": 0,
                "part": ["type": "summary_text", "text": reasoningText],
            ]))
        }
        output.append(try sse(type: "response.output_item.done", object: [
            "type": "response.output_item.done",
            "output_index": reasoningOutputIndex!,
            "item": item,
        ]))
        return output
    }

    private func reasoningItem() -> [String: Any] {
        var item: [String: Any] = [
            "id": reasoningItemID!,
            "type": "reasoning",
            "summary": [],
        ]
        if !reasoningText.isEmpty {
            if reasoningPresentation == .summary {
                item["summary"] = [["type": "summary_text", "text": reasoningText]]
            } else {
                item["content"] = [["type": "reasoning_text", "text": reasoningText]]
            }
        }
        if let envelope = AnthropicReasoningEnvelope.encode(blocks: reasoningBlocks) {
            item["encrypted_content"] = envelope
        }
        return item
    }

    private func startMessageIfNeeded() throws -> Data {
        if messageItemID == nil {
            messageItemID = "msg_\(compactUUID())"
            messageOutputIndex = allocateOutputIndex()
        }
        guard !messageStreamStarted else { return Data() }
        messageStreamStarted = true
        var output = try sse(type: "response.output_item.added", object: [
            "type": "response.output_item.added",
            "output_index": messageOutputIndex!,
            "item": [
                "id": messageItemID!,
                "type": "message",
                "status": "in_progress",
                "role": "assistant",
                "content": [],
            ],
        ])
        output.append(try sse(type: "response.content_part.added", object: [
            "type": "response.content_part.added",
            "item_id": messageItemID!,
            "output_index": messageOutputIndex!,
            "content_index": 0,
            "part": ["type": "output_text", "text": "", "annotations": []],
        ]))
        return output
    }

    private func finalizeMessage(streaming: Bool) throws -> Data {
        guard !messageText.isEmpty else { return Data() }
        if messageItemID == nil {
            messageItemID = "msg_\(compactUUID())"
            messageOutputIndex = allocateOutputIndex()
        }
        let item = messageItem()
        outputItems[messageOutputIndex!] = item
        var output = Data()
        if streaming {
            output.append(try startMessageIfNeeded())
            output.append(try sse(type: "response.output_text.done", object: [
                "type": "response.output_text.done",
                "item_id": messageItemID!,
                "output_index": messageOutputIndex!,
                "content_index": 0,
                "text": messageText,
            ]))
            output.append(try sse(type: "response.content_part.done", object: [
                "type": "response.content_part.done",
                "item_id": messageItemID!,
                "output_index": messageOutputIndex!,
                "content_index": 0,
                "part": ["type": "output_text", "text": messageText, "annotations": []],
            ]))
            output.append(try sse(type: "response.output_item.done", object: [
                "type": "response.output_item.done",
                "output_index": messageOutputIndex!,
                "item": item,
            ]))
        }
        messageText = ""
        messageItemID = nil
        messageOutputIndex = nil
        messageStreamStarted = false
        return output
    }

    private func messageItem() -> [String: Any] {
        [
            "id": messageItemID!,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [["type": "output_text", "text": messageText, "annotations": []]],
        ]
    }

    private func allocateOutputIndex() -> Int {
        defer { nextOutputIndex += 1 }
        return nextOutputIndex
    }

    private func usageObject(_ usage: TokenUsage) -> [String: Any] {
        [
            "input_tokens": usage.inputTokens,
            "input_tokens_details": ["cached_tokens": usage.cachedInputTokens],
            "output_tokens": usage.outputTokens,
            "output_tokens_details": ["reasoning_tokens": usage.reasoningTokens],
            "total_tokens": usage.inputTokens + usage.outputTokens,
        ]
    }

    private func sse(type: String, object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var output = Data("event: \(type)\ndata: ".utf8)
        output.append(payload)
        output.append(Data("\n\n".utf8))
        return output
    }

    private func compactUUID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

protocol ResponsesStreamConverting: AnyObject {
    func consume(_ data: Data) throws -> Data
    func finish() throws -> Data
    var observation: ResponseUsageObservation { get }
}

final class AdapterResponsesStreamConverter: ResponsesStreamConverting {
    private let decoder: any AdapterStreamDecoder
    private let bridge: ResponsesEventBridge
    private let extractor: XMLToolCallExtractor

    init(decoder: any AdapterStreamDecoder, mappings: [String: ChatToolIdentity]) {
        self.decoder = decoder
        bridge = ResponsesEventBridge(mappings: mappings)
        extractor = XMLToolCallExtractor(mappings: mappings)
    }

    func consume(_ data: Data) throws -> Data {
        try bridge.consume(extractor.process(decoder.consume(data)), streaming: true)
    }

    func finish() throws -> Data {
        var events = try extractor.process(decoder.finish())
        events.append(contentsOf: extractor.finish())
        return try bridge.consume(events, streaming: true)
    }

    var observation: ResponseUsageObservation { decoder.observation }
}

enum AdapterResponseBuilder {
    static func json(
        events: [AdapterEvent],
        mappings: [String: ChatToolIdentity]
    ) throws -> Data {
        let extractor = XMLToolCallExtractor(mappings: mappings)
        var processed = extractor.process(events)
        processed.append(contentsOf: extractor.finish())
        let bridge = ResponsesEventBridge(mappings: mappings)
        _ = try bridge.consume(processed, streaming: false)
        return try bridge.responseJSON()
    }
}
