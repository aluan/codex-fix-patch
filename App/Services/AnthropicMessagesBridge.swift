import Foundation

enum AnthropicMessagesBridgeError: LocalizedError {
    case invalidResponsesRequest
    case invalidUpstreamResponse
    case unsupportedHostedTool(String)
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponsesRequest: "无法转换 Responses 请求"
        case .invalidUpstreamResponse: "无法解析 Anthropic Messages 响应"
        case .unsupportedHostedTool(let type): "Anthropic Provider 不支持托管工具：\(type)"
        case .conversion(let message): message
        }
    }
}

typealias AnthropicBridgeRequest = AdapterRequest

struct AnthropicMessagesBridge: ProviderAdapter, Sendable {
    func makeRequest(
        from request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot
    ) throws -> AnthropicBridgeRequest {
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
        let maximumTokens = max(parsed.maxOutputTokens ?? 8_192, 1_025)
        var body: [String: Any] = [
            "model": provider.inferenceModel,
            "messages": try makeMessages(parsed),
            "max_tokens": maximumTokens,
            "stream": parsed.stream,
        ]
        var system = neutralizeCodexIdentity(parsed.instructions ?? "")
        if !parsed.tools.isEmpty {
            let instruction = "Use tools only through native tool_use blocks. Never write tool calls as XML or JSON text."
            system = system.isEmpty ? instruction : "\(system)\n\n\(instruction)"
            if shouldInjectToolCatalogNudge(provider: provider) {
                system += "\n\n\(toolCatalogNudge(parsed.tools))"
            }
        }
        if !system.isEmpty { body["system"] = system }

        if !parsed.tools.isEmpty, case .none = parsed.toolChoice {
            // Anthropic rejects tools when tool_choice is explicitly none.
        } else if !parsed.tools.isEmpty {
            body["tools"] = parsed.tools.map { tool in
                [
                    "name": tool.wireName,
                    "description": tool.description,
                    "input_schema": tool.parameters,
                ]
            }
            var choice = anthropicToolChoice(parsed.toolChoice)
            if !parsed.parallelToolCalls { choice["disable_parallel_tool_use"] = true }
            body["tool_choice"] = choice
        }
        if let temperature = parsed.temperature { body["temperature"] = temperature }
        if let topP = parsed.topP { body["top_p"] = topP }
        applyReasoning(parsed.reasoningEffort, maximumTokens: maximumTokens, to: &body)

        guard let url = ProviderEndpointResolver.urls(
            baseURL: provider.upstreamBaseURL,
            endpoint: "messages"
        ).first else { throw URLError(.badURL) }
        var output = URLRequest(url: url)
        output.httpMethod = "POST"
        output.httpBody = try JSONSerialization.data(withJSONObject: body)
        output.timeoutInterval = 300
        copySafeHeaders(from: incoming, to: &output)
        output.setValue(parsed.stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        output.setValue("application/json", forHTTPHeaderField: "Content-Type")
        output.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        ProviderRequestAuthorizer.apply(provider, to: &output)
        return AdapterRequest(
            urlRequest: output,
            toolMappings: parsed.toolMappings,
            clientRequestedStreaming: parsed.stream
        )
    }

    func makeStreamDecoder(mappings: [String: ChatToolIdentity]) -> any AdapterStreamDecoder {
        AnthropicMessagesStreamDecoder(mappings: mappings)
    }

    func parseResponse(
        data: Data,
        mappings: [String: ChatToolIdentity]
    ) throws -> [AdapterEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw AnthropicMessagesBridgeError.invalidUpstreamResponse
        }
        let responseID = root["id"] as? String ?? "resp_\(compactUUID())"
        var events: [AdapterEvent] = [
            .responseStarted(id: responseID, model: root["model"] as? String),
        ]
        var toolIndex = 0
        for block in content {
            switch block["type"] as? String {
            case "thinking":
                let thinking = block["thinking"] as? String ?? ""
                let signature = block["signature"] as? String ?? ""
                if !thinking.isEmpty {
                    events.append(.reasoningDelta(thinking))
                }
                if !signature.isEmpty {
                    events.append(.reasoningBlock(.thinking(text: thinking, signature: signature)))
                }
            case "redacted_thinking":
                if let data = block["data"] as? String, !data.isEmpty {
                    events.append(.reasoningBlock(.redacted(data: data)))
                }
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { events.append(.textDelta(text)) }
            case "tool_use":
                guard let name = block["name"] as? String,
                      mappings[name] != nil,
                      let input = block["input"] as? [String: Any],
                      let arguments = try? JSONSerialization.data(withJSONObject: input) else {
                    throw AnthropicMessagesBridgeError.invalidUpstreamResponse
                }
                events.append(.toolCallStarted(
                    index: toolIndex,
                    id: block["id"] as? String ?? "toolu_\(compactUUID())",
                    name: name
                ))
                events.append(.toolCallArgumentsDelta(
                    index: toolIndex,
                    delta: String(decoding: arguments, as: UTF8.self)
                ))
                events.append(.toolCallEnded(index: toolIndex))
                toolIndex += 1
            default:
                continue
            }
        }
        if let usage = Self.tokenUsage(root["usage"] as? [String: Any]) { events.append(.usage(usage)) }
        events.append(root["stop_reason"] as? String == "max_tokens"
            ? .incomplete("max_output_tokens")
            : .completed)
        return events
    }

    func makeNonStreamingResponse(
        data: Data,
        mappings: [String: ChatToolIdentity]
    ) throws -> Data {
        try AdapterResponseBuilder.json(events: parseResponse(data: data, mappings: mappings), mappings: mappings)
    }

    private func makeMessages(_ parsed: NormalizedResponsesRequest) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for item in parsed.input {
            switch item {
            case .message(let role, let content):
                appendBlocks(
                    role: role == "assistant" ? "assistant" : "user",
                    blocks: anthropicContent(content),
                    to: &messages
                )
            case .reasoning(_, let blocks):
                appendBlocks(
                    role: "assistant",
                    blocks: blocks.map { block in
                        switch block {
                        case .thinking(let text, let signature):
                            [
                                "type": "thinking",
                                "thinking": text,
                                "signature": signature,
                            ]
                        case .redacted(let data):
                            ["type": "redacted_thinking", "data": data]
                        }
                    },
                    to: &messages
                )
            case .toolCall(let identity, let callID, let arguments):
                let name = try wireName(for: identity, mappings: parsed.toolMappings)
                appendBlocks(role: "assistant", blocks: [[
                    "type": "tool_use",
                    "id": callID,
                    "name": name,
                    "input": arguments,
                ]], to: &messages)
            case .toolResult(let callID, let output):
                appendBlocks(role: "user", blocks: [[
                    "type": "tool_result",
                    "tool_use_id": callID,
                    "content": output.isEmpty ? "(empty tool output)" : output,
                ]], to: &messages)
            case .compaction(let content):
                appendBlocks(role: "user", blocks: [["type": "text", "text": content]], to: &messages)
            }
        }
        return messages
    }

    private func anthropicContent(_ content: [NormalizedContentPart]) -> [[String: Any]] {
        content.compactMap { part in
            switch part {
            case .text(let text):
                return text.isEmpty ? nil : ["type": "text", "text": text]
            case .image(let value):
                guard let source = imageSource(value) else { return nil }
                return ["type": "image", "source": source]
            }
        }
    }

    private func imageSource(_ value: String) -> [String: Any]? {
        if value.hasPrefix("data:"), let separator = value.firstIndex(of: ",") {
            let metadata = String(value[value.index(value.startIndex, offsetBy: 5)..<separator])
            let parts = metadata.split(separator: ";")
            guard parts.count == 2, parts[1] == "base64" else { return nil }
            return [
                "type": "base64",
                "media_type": String(parts[0]),
                "data": String(value[value.index(after: separator)...]),
            ]
        }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return ["type": "url", "url": value]
    }

    private func shouldInjectToolCatalogNudge(provider: ActiveProviderSnapshot) -> Bool {
        guard let host = URL(string: provider.upstreamBaseURL)?.host?.lowercased() else { return true }
        return host != "openai.com"
            && !host.hasSuffix(".openai.com")
            && host != "chatgpt.com"
            && !host.hasSuffix(".chatgpt.com")
    }

    private func neutralizeCodexIdentity(_ system: String) -> String {
        let neutralIdentity = "You are a coding agent. Do not claim to be GPT-5 or to be made by OpenAI."
        return [
            "You are Codex, a coding agent based on GPT-5.",
            "You are Codex, an agent based on GPT-5.",
            "You are Codex.",
        ].reduce(system) { output, identity in
            output.replacingOccurrences(of: identity, with: neutralIdentity)
        }
    }

    private func toolCatalogNudge(_ tools: [NormalizedTool]) -> String {
        let names = tools.map(\.wireName).filter { !$0.isEmpty }
        let quotedNames = names.map { "`\($0)`" }.joined(separator: ", ")
        let advertised = Set(names)
        let unavailableNeighborNames = Self.neighborAgentToolNames.filter { !advertised.contains($0) }
        var lines: [String] = [
            "Tool contract: use the current tool catalog as ground truth.",
            "Valid tool names for this turn are exactly \(quotedNames).",
            "Call only listed names with their listed argument keys; do not invent, translate, or rename tools.",
        ]
        if !unavailableNeighborNames.isEmpty {
            let quoted = unavailableNeighborNames.map { "`\($0)`" }.joined(separator: ", ")
            lines.append("Do not use neighboring-agent tool names \(quoted) unless this turn's catalog lists those exact names.")
        }
        lines.append("If you need shell, file search, file read, edit, or discovery behavior, choose the listed tool that provides that capability.")
        lines.append("Count a tool call only after its tool result returns; batch independent read-only calls when the runtime supports it.")
        lines.append("Return tool calls only as native tool_use blocks; do not emit <tool_call>, tool_code, functions.*, XML, or JSON tool-call text.")
        return lines.joined(separator: " ")
    }

    private static let neighborAgentToolNames = ["Read", "Grep", "Glob", "Bash", "LS", "apply_patch"]

    private func appendBlocks(
        role: String,
        blocks: [[String: Any]],
        to messages: inout [[String: Any]]
    ) {
        guard !blocks.isEmpty else { return }
        if let index = messages.indices.last,
           messages[index]["role"] as? String == role,
           var content = messages[index]["content"] as? [[String: Any]] {
            content.append(contentsOf: blocks)
            messages[index]["content"] = content
        } else {
            messages.append(["role": role, "content": blocks])
        }
    }

    private func wireName(
        for identity: ChatToolIdentity,
        mappings: [String: ChatToolIdentity]
    ) throws -> String {
        guard let match = mappings.first(where: { $0.value == identity }) else {
            throw AnthropicMessagesBridgeError.invalidResponsesRequest
        }
        return match.key
    }

    private func anthropicToolChoice(_ choice: NormalizedToolChoice) -> [String: Any] {
        switch choice {
        case .auto, .none: ["type": "auto"]
        case .required: ["type": "any"]
        case .tool(let name): ["type": "tool", "name": name]
        }
    }

    private func applyReasoning(
        _ effort: String?,
        maximumTokens: Int,
        to body: inout [String: Any]
    ) {
        guard let effort else { return }
        if ["none", "minimal"].contains(effort) {
            body["thinking"] = ["type": "disabled"]
            return
        }
        let requestedBudget: Int
        switch effort {
        case "low": requestedBudget = 1_024
        case "medium": requestedBudget = 2_048
        case "xhigh", "max": requestedBudget = 8_192
        default: requestedBudget = 4_096
        }
        body["thinking"] = [
            "type": "enabled",
            "budget_tokens": min(requestedBudget, maximumTokens - 1),
        ]
        body.removeValue(forKey: "temperature")
        body.removeValue(forKey: "top_p")
    }

    private func copySafeHeaders(from incoming: IncomingHTTPRequest, to request: inout URLRequest) {
        for name in ["authorization", "user-agent", "x-request-id", "x-client-request-id"] {
            if let value = incoming.header(name) { request.setValue(value, forHTTPHeaderField: name) }
        }
    }

    private func bridgeError(_ error: ModelProtocolError) -> AnthropicMessagesBridgeError {
        switch error {
        case .invalidResponsesRequest: .invalidResponsesRequest
        case .invalidUpstreamResponse: .invalidUpstreamResponse
        case .unsupportedHostedTool(let type): .unsupportedHostedTool(type)
        default: .conversion(error.localizedDescription)
        }
    }

    fileprivate static func tokenUsage(_ usage: [String: Any]?) -> TokenUsage? {
        guard let usage else { return nil }
        let direct = integer(usage["input_tokens"]) ?? 0
        let cached = integer(usage["cache_read_input_tokens"]) ?? 0
        let created = integer(usage["cache_creation_input_tokens"]) ?? 0
        return TokenUsage(
            inputTokens: direct + cached + created,
            outputTokens: integer(usage["output_tokens"]) ?? 0,
            cachedInputTokens: cached,
            reasoningTokens: 0
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

final class AnthropicMessagesStreamDecoder: AdapterStreamDecoder {
    private struct PendingToolCall {
        var id: String
        var name: String
        var arguments: String
        var started: Bool
    }

    private struct PendingReasoning {
        var thinking: String
        var signature: String
    }

    private let mappings: [String: ChatToolIdentity]
    private var lineBuffer = Data()
    private var responseID = "resp_\(AnthropicMessagesBridge.compactUUID())"
    private var model: String?
    private var tools: [Int: PendingToolCall] = [:]
    private var reasoning: [Int: PendingReasoning] = [:]
    private var usage: TokenUsage?
    private var stopReason: String?
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
            throw AnthropicMessagesBridgeError.invalidUpstreamResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let eventData = payload.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: eventData) as? [String: Any],
              let type = root["type"] as? String else {
            throw AnthropicMessagesBridgeError.invalidUpstreamResponse
        }
        switch type {
        case "message_start":
            if let message = root["message"] as? [String: Any] {
                responseID = message["id"] as? String ?? responseID
                model = message["model"] as? String ?? model
                mergeUsage(message["usage"] as? [String: Any])
            }
            return startIfNeeded()
        case "content_block_start":
            guard let index = root["index"] as? Int,
                  let block = root["content_block"] as? [String: Any] else { return [] }
            var events = startIfNeeded()
            switch block["type"] as? String {
            case "text":
                if let value = block["text"] as? String, !value.isEmpty { events.append(.textDelta(value)) }
            case "thinking":
                let thinking = block["thinking"] as? String ?? ""
                let signature = block["signature"] as? String ?? ""
                reasoning[index] = PendingReasoning(thinking: thinking, signature: signature)
                if !thinking.isEmpty { events.append(.reasoningDelta(thinking)) }
            case "redacted_thinking":
                if let data = block["data"] as? String, !data.isEmpty {
                    events.append(.reasoningBlock(.redacted(data: data)))
                }
            case "tool_use":
                guard let name = block["name"] as? String, mappings[name] != nil else {
                    throw ModelProtocolError.unknownTool(block["name"] as? String ?? "")
                }
                let id = block["id"] as? String ?? "toolu_\(AnthropicMessagesBridge.compactUUID())"
                events.append(.toolCallStarted(index: index, id: id, name: name))
                var arguments = ""
                if let input = block["input"] as? [String: Any], !input.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: input) {
                    arguments = String(decoding: data, as: UTF8.self)
                    events.append(.toolCallArgumentsDelta(index: index, delta: arguments))
                }
                tools[index] = PendingToolCall(id: id, name: name, arguments: arguments, started: true)
            default:
                break
            }
            return events
        case "content_block_delta":
            guard let index = root["index"] as? Int,
                  let delta = root["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta": return [.textDelta(delta["text"] as? String ?? "")]
            case "thinking_delta":
                guard var pending = reasoning[index] else {
                    throw AnthropicMessagesBridgeError.invalidUpstreamResponse
                }
                let value = delta["thinking"] as? String ?? ""
                pending.thinking += value
                reasoning[index] = pending
                return [.reasoningDelta(value)]
            case "signature_delta":
                guard var pending = reasoning[index] else {
                    throw AnthropicMessagesBridgeError.invalidUpstreamResponse
                }
                pending.signature += delta["signature"] as? String ?? ""
                reasoning[index] = pending
                return []
            case "input_json_delta":
                guard var pending = tools[index] else { throw AnthropicMessagesBridgeError.invalidUpstreamResponse }
                let value = delta["partial_json"] as? String ?? ""
                pending.arguments += value
                tools[index] = pending
                return [.toolCallArgumentsDelta(index: index, delta: value)]
            default: return []
            }
        case "content_block_stop":
            guard let index = root["index"] as? Int else { return [] }
            if tools.removeValue(forKey: index) != nil { return [.toolCallEnded(index: index)] }
            if let pending = reasoning.removeValue(forKey: index), !pending.signature.isEmpty {
                return [.reasoningBlock(.thinking(
                    text: pending.thinking,
                    signature: pending.signature
                ))]
            }
            return []
        case "message_delta":
            if let delta = root["delta"] as? [String: Any] {
                stopReason = delta["stop_reason"] as? String ?? stopReason
            }
            mergeUsage(root["usage"] as? [String: Any])
            return []
        case "message_stop":
            return try complete()
        case "error":
            completed = true
            let message = ((root["error"] as? [String: Any])?["message"] as? String)
                ?? "Anthropic upstream stream failed"
            return [.failed(message)]
        default:
            return []
        }
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
        for index in tools.keys.sorted() {
            events.append(.toolCallEnded(index: index))
        }
        tools.removeAll()
        for index in reasoning.keys.sorted() {
            guard let pending = reasoning[index], !pending.signature.isEmpty else { continue }
            events.append(.reasoningBlock(.thinking(
                text: pending.thinking,
                signature: pending.signature
            )))
        }
        reasoning.removeAll()
        if let usage { events.append(.usage(usage)) }
        events.append(stopReason == "max_tokens" ? .incomplete("max_output_tokens") : .completed)
        return events
    }

    private func mergeUsage(_ incoming: [String: Any]?) {
        guard let incoming else { return }
        let latest = AnthropicMessagesBridge.tokenUsage(incoming)
        guard let latest else { return }
        if let usage {
            self.usage = TokenUsage(
                inputTokens: latest.inputTokens == 0 ? usage.inputTokens : latest.inputTokens,
                outputTokens: latest.outputTokens == 0 ? usage.outputTokens : latest.outputTokens,
                cachedInputTokens: latest.cachedInputTokens == 0 ? usage.cachedInputTokens : latest.cachedInputTokens,
                reasoningTokens: 0
            )
        } else {
            usage = latest
        }
    }
}

final class AnthropicMessagesStreamConverter: ResponsesStreamConverting {
    private let converter: AdapterResponsesStreamConverter

    init(mappings: [String: ChatToolIdentity]) {
        converter = AdapterResponsesStreamConverter(
            decoder: AnthropicMessagesStreamDecoder(mappings: mappings),
            mappings: mappings
        )
    }

    func consume(_ data: Data) throws -> Data { try converter.consume(data) }
    func finish() throws -> Data { try converter.finish() }
    var observation: ResponseUsageObservation { converter.observation }
}
