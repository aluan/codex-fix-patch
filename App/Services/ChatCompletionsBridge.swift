import Foundation

enum ChatCompletionsBridgeError: LocalizedError {
    case invalidResponsesRequest
    case invalidUpstreamResponse
    case unsupportedHostedTool(String)
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponsesRequest: "无法转换 Responses 请求"
        case .invalidUpstreamResponse: "无法解析 Chat Completions 响应"
        case .unsupportedHostedTool(let type): "Chat Provider 不支持托管工具：\(type)"
        case .conversion(let message): message
        }
    }
}

typealias ChatBridgeRequest = AdapterRequest

struct ChatCompletionsBridge: ProviderAdapter, Sendable {
    func makeRequest(
        from request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot
    ) throws -> ChatBridgeRequest {
        do {
            return try makeRequest(
                parsed: ResponsesRequestParser().parse(request),
                incoming: request,
                provider: provider
            )
        } catch let error as ModelProtocolError {
            throw bridgeError(error)
        }
    }

    func makeRequest(
        parsed: NormalizedResponsesRequest,
        incoming: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot
    ) throws -> AdapterRequest {
        var messages = try makeMessages(parsed)
        var body: [String: Any] = [
            "model": provider.inferenceModel,
            "messages": messages,
            "stream": parsed.stream,
        ]
        if !parsed.tools.isEmpty, case .none = parsed.toolChoice {
            // A tool catalog with tool_choice none is intentionally omitted.
        } else if !parsed.tools.isEmpty {
            body["tools"] = parsed.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.wireName,
                        "description": tool.description,
                        "parameters": tool.parameters,
                    ],
                ]
            }
            body["tool_choice"] = chatToolChoice(parsed.toolChoice)
            body["parallel_tool_calls"] = parsed.parallelToolCalls
        }
        if let maximum = parsed.maxOutputTokens { body["max_tokens"] = maximum }
        if let temperature = parsed.temperature { body["temperature"] = temperature }
        if let topP = parsed.topP { body["top_p"] = topP }
        if parsed.stream { body["stream_options"] = ["include_usage": true] }
        applyReasoning(parsed.reasoningEffort, dialect: provider.profile.chatDialect, to: &body)

        if let format = parsed.responseFormat {
            if provider.profile.chatDialect == .standard {
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": [
                        "name": format["name"] as? String ?? "response",
                        "strict": format["strict"] as? Bool ?? false,
                        "schema": format["schema"] as? [String: Any] ?? [:],
                    ],
                ]
            } else if let schema = format["schema"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: schema) {
                appendSystemInstruction(
                    "Return JSON matching this schema: \(String(decoding: data, as: UTF8.self))",
                    to: &messages
                )
                body["messages"] = messages
                body["response_format"] = ["type": "json_object"]
            }
        }

        guard let url = ProviderEndpointResolver.urls(
            baseURL: provider.upstreamBaseURL,
            endpoint: "chat/completions"
        ).first else { throw URLError(.badURL) }
        var output = URLRequest(url: url)
        output.httpMethod = "POST"
        output.httpBody = try JSONSerialization.data(withJSONObject: body)
        output.timeoutInterval = 300
        copySafeHeaders(from: incoming, to: &output)
        output.setValue(parsed.stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        output.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ProviderRequestAuthorizer.apply(provider, to: &output)
        return AdapterRequest(
            urlRequest: output,
            toolMappings: parsed.toolMappings,
            clientRequestedStreaming: parsed.stream
        )
    }

    func makeStreamDecoder(mappings: [String: ChatToolIdentity]) -> any AdapterStreamDecoder {
        ChatCompletionsStreamDecoder(mappings: mappings)
    }

    func parseResponse(
        data: Data,
        mappings: [String: ChatToolIdentity]
    ) throws -> [AdapterEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw ChatCompletionsBridgeError.invalidUpstreamResponse
        }
        let responseID = root["id"] as? String ?? "resp_\(compactUUID())"
        var events: [AdapterEvent] = [
            .responseStarted(id: responseID, model: root["model"] as? String),
        ]
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            events.append(.rawReasoningDelta(reasoning))
        }
        if let content = message["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        }
        for (index, call) in (message["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  mappings[name] != nil else {
                throw ChatCompletionsBridgeError.invalidUpstreamResponse
            }
            events.append(.toolCallStarted(
                index: index,
                id: call["id"] as? String ?? "call_\(compactUUID())",
                name: name
            ))
            events.append(.toolCallArgumentsDelta(
                index: index,
                delta: function["arguments"] as? String ?? "{}"
            ))
            events.append(.toolCallEnded(index: index))
        }
        if let usage = Self.tokenUsage(root["usage"] as? [String: Any]) { events.append(.usage(usage)) }
        events.append(choice["finish_reason"] as? String == "length"
            ? .incomplete("max_output_tokens")
            : .completed)
        return events
    }

    func makeNonStreamingResponse(data: Data, mappings: [String: ChatToolIdentity]) throws -> Data {
        try AdapterResponseBuilder.json(events: parseResponse(data: data, mappings: mappings), mappings: mappings)
    }

    private func makeMessages(_ parsed: NormalizedResponsesRequest) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let instructions = parsed.instructions, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        var pendingReasoning: String?
        for item in parsed.input {
            switch item {
            case .message(let role, let content):
                messages.append(["role": role, "content": chatContent(content)])
            case .reasoning(let text, _):
                pendingReasoning = text.isEmpty ? nil : text
            case .toolCall(let identity, let callID, let arguments):
                let name = try wireName(for: identity, mappings: parsed.toolMappings)
                let data = try JSONSerialization.data(withJSONObject: arguments)
                appendToolCall(
                    id: callID,
                    name: name,
                    arguments: String(decoding: data, as: UTF8.self),
                    reasoning: &pendingReasoning,
                    to: &messages
                )
            case .toolResult(let callID, let output):
                messages.append(["role": "tool", "tool_call_id": callID, "content": output])
            case .compaction(let content):
                messages.append(["role": "system", "content": content])
            }
        }
        return messages
    }

    private func chatContent(_ content: [NormalizedContentPart]) -> Any {
        let hasImage = content.contains { if case .image = $0 { true } else { false } }
        if !hasImage {
            return content.compactMap { part in
                if case .text(let text) = part { return text }
                return nil
            }.joined(separator: "\n")
        }
        return content.map { part -> [String: Any] in
            switch part {
            case .text(let text): ["type": "text", "text": text]
            case .image(let url): ["type": "image_url", "image_url": ["url": url]]
            }
        }
    }

    private func appendToolCall(
        id: String,
        name: String,
        arguments: String,
        reasoning: inout String?,
        to messages: inout [[String: Any]]
    ) {
        let call: [String: Any] = [
            "id": id,
            "type": "function",
            "function": ["name": name, "arguments": arguments],
        ]
        if let index = messages.indices.last,
           messages[index]["role"] as? String == "assistant",
           var calls = messages[index]["tool_calls"] as? [[String: Any]] {
            calls.append(call)
            messages[index]["tool_calls"] = calls
            return
        }
        var message: [String: Any] = ["role": "assistant", "content": NSNull(), "tool_calls": [call]]
        if let reasoning { message["reasoning_content"] = reasoning }
        reasoning = nil
        messages.append(message)
    }

    private func wireName(
        for identity: ChatToolIdentity,
        mappings: [String: ChatToolIdentity]
    ) throws -> String {
        guard let match = mappings.first(where: { $0.value == identity }) else {
            throw ChatCompletionsBridgeError.invalidResponsesRequest
        }
        return match.key
    }

    private func chatToolChoice(_ choice: NormalizedToolChoice) -> Any {
        switch choice {
        case .auto: "auto"
        case .none: "none"
        case .required: "required"
        case .tool(let name): ["type": "function", "function": ["name": name]]
        }
    }

    private func applyReasoning(
        _ effort: String?,
        dialect: ChatCompletionsDialect,
        to body: inout [String: Any]
    ) {
        guard let effort else { return }
        switch dialect {
        case .deepSeek:
            body["thinking"] = ["type": "enabled"]
            body["reasoning_effort"] = mappedEffort(effort, allowDisabled: false)
        case .glm:
            let mapped = mappedEffort(effort, allowDisabled: true)
            body["thinking"] = ["type": mapped == nil ? "disabled" : "enabled"]
            body["clear_thinking"] = true
            if let mapped { body["reasoning_effort"] = mapped }
        case .standard:
            body["reasoning_effort"] = effort
        }
    }

    private func mappedEffort(_ effort: String, allowDisabled: Bool) -> String? {
        if allowDisabled, ["none", "minimal"].contains(effort) { return nil }
        return ["xhigh", "max"].contains(effort) ? "max" : "high"
    }

    private func appendSystemInstruction(_ instruction: String, to messages: inout [[String: Any]]) {
        if let index = messages.firstIndex(where: { $0["role"] as? String == "system" }) {
            let current = messages[index]["content"] as? String ?? ""
            messages[index]["content"] = current.isEmpty ? instruction : "\(current)\n\n\(instruction)"
        } else {
            messages.insert(["role": "system", "content": instruction], at: 0)
        }
    }

    private func copySafeHeaders(from incoming: IncomingHTTPRequest, to request: inout URLRequest) {
        for name in ["authorization", "user-agent", "x-request-id", "x-client-request-id"] {
            if let value = incoming.header(name) { request.setValue(value, forHTTPHeaderField: name) }
        }
    }

    private func bridgeError(_ error: ModelProtocolError) -> ChatCompletionsBridgeError {
        switch error {
        case .invalidResponsesRequest: .invalidResponsesRequest
        case .invalidUpstreamResponse: .invalidUpstreamResponse
        case .unsupportedHostedTool(let type): .unsupportedHostedTool(type)
        default: .conversion(error.localizedDescription)
        }
    }

    fileprivate static func tokenUsage(_ usage: [String: Any]?) -> TokenUsage? {
        guard let usage else { return nil }
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let completionDetails = usage["completion_tokens_details"] as? [String: Any]
        return TokenUsage(
            inputTokens: integer(usage["prompt_tokens"]) ?? 0,
            outputTokens: integer(usage["completion_tokens"]) ?? 0,
            cachedInputTokens: integer(promptDetails?["cached_tokens"]) ?? 0,
            reasoningTokens: integer(completionDetails?["reasoning_tokens"]) ?? 0
        )
    }

    fileprivate static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    fileprivate static func compactUUID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func compactUUID() -> String { Self.compactUUID() }
}

final class ChatCompletionsStreamDecoder: AdapterStreamDecoder {
    private struct PendingToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private let mappings: [String: ChatToolIdentity]
    private var lineBuffer = Data()
    private var responseID = "resp_\(ChatCompletionsBridge.compactUUID())"
    private var model: String?
    private var tools: [Int: PendingToolCall] = [:]
    private var usage: TokenUsage?
    private var finishReason: String?
    private var started = false
    private var completed = false

    init(mappings: [String: ChatToolIdentity]) {
        self.mappings = mappings
    }

    func consume(_ data: Data) throws -> [AdapterEvent] {
        lineBuffer.append(data)
        var events: [AdapterEvent] = []
        while let range = lineBuffer.range(of: Data([0x0A])) {
            let line = Data(lineBuffer[..<range.lowerBound])
            lineBuffer.removeSubrange(..<range.upperBound)
            events.append(contentsOf: try process(line))
        }
        return events
    }

    func finish() throws -> [AdapterEvent] {
        var events: [AdapterEvent] = []
        if !lineBuffer.isEmpty {
            let line = lineBuffer
            lineBuffer.removeAll()
            events.append(contentsOf: try process(line))
        }
        events.append(contentsOf: try complete())
        return events
    }

    var observation: ResponseUsageObservation {
        ResponseUsageObservation(model: model, usage: usage)
    }

    private func process(_ line: Data) throws -> [AdapterEvent] {
        guard let text = String(data: line, encoding: .utf8) else {
            throw ChatCompletionsBridgeError.invalidUpstreamResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return try complete() }
        guard let eventData = payload.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            throw ChatCompletionsBridgeError.invalidUpstreamResponse
        }
        if let id = root["id"] as? String { responseID = id }
        if let model = root["model"] as? String { self.model = model }
        if let value = ChatCompletionsBridge.tokenUsage(root["usage"] as? [String: Any]) { usage = value }
        var events = startIfNeeded()
        for choice in root["choices"] as? [[String: Any]] ?? [] where (choice["index"] as? Int ?? 0) == 0 {
            if let delta = choice["delta"] as? [String: Any] {
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    events.append(.rawReasoningDelta(reasoning))
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    events.append(.textDelta(content))
                }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = call["index"] as? Int ?? 0
                    var pending = tools[index] ?? PendingToolCall()
                    if let id = call["id"] as? String { pending.id = id }
                    if let function = call["function"] as? [String: Any] {
                        pending.name += function["name"] as? String ?? ""
                        pending.arguments += function["arguments"] as? String ?? ""
                    }
                    tools[index] = pending
                }
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }
        return events
    }

    private func startIfNeeded() -> [AdapterEvent] {
        guard !started else { return [] }
        started = true
        return [.responseStarted(id: responseID, model: model)]
    }

    private func complete() throws -> [AdapterEvent] {
        guard !completed else { return [] }
        completed = true
        var events = startIfNeeded()
        for (index, pending) in tools.sorted(by: { $0.key < $1.key }) {
            guard mappings[pending.name] != nil else {
                throw ModelProtocolError.unknownTool(pending.name)
            }
            events.append(.toolCallStarted(
                index: index,
                id: pending.id.isEmpty ? "call_\(ChatCompletionsBridge.compactUUID())" : pending.id,
                name: pending.name
            ))
            events.append(.toolCallArgumentsDelta(
                index: index,
                delta: pending.arguments.isEmpty ? "{}" : pending.arguments
            ))
            events.append(.toolCallEnded(index: index))
        }
        if let usage { events.append(.usage(usage)) }
        events.append(finishReason == "length" ? .incomplete("max_output_tokens") : .completed)
        return events
    }
}

final class ChatCompletionsStreamConverter: ResponsesStreamConverting {
    private let converter: AdapterResponsesStreamConverter

    init(mappings: [String: ChatToolIdentity]) {
        converter = AdapterResponsesStreamConverter(
            decoder: ChatCompletionsStreamDecoder(mappings: mappings),
            mappings: mappings
        )
    }

    func consume(_ data: Data) throws -> Data { try converter.consume(data) }
    func finish() throws -> Data { try converter.finish() }
    var observation: ResponseUsageObservation { converter.observation }
}
