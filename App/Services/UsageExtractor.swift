import Foundation

struct RequestMetadata: Equatable, Sendable {
    let model: String?
    let isStreaming: Bool
}

struct ResponseUsageObservation: Equatable, Sendable {
    var model: String? = nil
    var usage: TokenUsage? = nil
}

enum UsageExtractor {
    static let maximumBufferedEventBytes = 4 * 1024 * 1024

    static func requestMetadata(from body: Data) -> RequestMetadata {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return RequestMetadata(model: nil, isStreaming: false)
        }
        return RequestMetadata(
            model: object["model"] as? String,
            isStreaming: object["stream"] as? Bool ?? false
        )
    }

    static func observation(from data: Data, contentType: String?) -> ResponseUsageObservation {
        guard data.count <= maximumBufferedEventBytes,
              let text = String(data: data, encoding: .utf8) else {
            return ResponseUsageObservation()
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let root = try? JSONSerialization.jsonObject(with: data) else {
                return ResponseUsageObservation()
            }
            return observation(from: root)
        }
        if contentType?.lowercased().contains("text/event-stream") == true {
            var result = ResponseUsageObservation()
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", let eventData = payload.data(using: .utf8),
                      eventData.count <= maximumBufferedEventBytes,
                      let root = try? JSONSerialization.jsonObject(with: eventData) else { continue }
                result.merge(observation(from: root))
            }
            return result
        }
        return ResponseUsageObservation()
    }

    static func observation(from root: Any) -> ResponseUsageObservation {
        if let dictionary = root as? [String: Any] {
            var result = ResponseUsageObservation(
                model: dictionary["model"] as? String,
                usage: parseUsage(dictionary["usage"] as? [String: Any])
            )
            if let response = dictionary["response"] {
                result.merge(observation(from: response))
            }
            if result.usage == nil {
                for value in dictionary.values {
                    let nested = observation(from: value)
                    result.merge(nested)
                    if result.usage != nil { break }
                }
            }
            return result
        }
        if let array = root as? [Any] {
            var result = ResponseUsageObservation()
            for value in array {
                result.merge(observation(from: value))
            }
            return result
        }
        return ResponseUsageObservation()
    }

    private static func parseUsage(_ object: [String: Any]?) -> TokenUsage? {
        guard let object else { return nil }
        let input = integer(object["input_tokens"])
        let output = integer(object["output_tokens"])
        guard input != nil || output != nil else { return nil }
        let inputDetails = object["input_tokens_details"] as? [String: Any]
        let outputDetails = object["output_tokens_details"] as? [String: Any]
        return TokenUsage(
            inputTokens: input ?? 0,
            outputTokens: output ?? 0,
            cachedInputTokens: integer(inputDetails?["cached_tokens"]) ?? 0,
            reasoningTokens: integer(outputDetails?["reasoning_tokens"]) ?? 0
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

final class StreamingUsageParser: @unchecked Sendable {
    private var contentType: String?
    private var jsonBuffer = Data()
    private var lineBuffer = Data()
    private var latest = ResponseUsageObservation()
    private var exceededLimit = false

    func begin(contentType: String?) {
        self.contentType = contentType
    }

    func consume(_ data: Data) {
        guard !exceededLimit else { return }
        if contentType?.lowercased().contains("text/event-stream") == true {
            lineBuffer.append(data)
            if lineBuffer.count > UsageExtractor.maximumBufferedEventBytes {
                exceededLimit = true
                lineBuffer.removeAll(keepingCapacity: false)
                return
            }
            processCompleteLines()
        } else {
            jsonBuffer.append(data)
            if jsonBuffer.count > UsageExtractor.maximumBufferedEventBytes {
                exceededLimit = true
                jsonBuffer.removeAll(keepingCapacity: false)
            }
        }
    }

    func finish() -> ResponseUsageObservation {
        guard !exceededLimit else { return ResponseUsageObservation() }
        if contentType?.lowercased().contains("text/event-stream") == true {
            process(lineBuffer)
            lineBuffer.removeAll(keepingCapacity: false)
            return latest
        }
        return UsageExtractor.observation(from: jsonBuffer, contentType: contentType)
    }

    private func processCompleteLines() {
        let newline = Data([0x0A])
        while let range = lineBuffer.range(of: newline) {
            let line = Data(lineBuffer[..<range.lowerBound])
            lineBuffer.removeSubrange(..<range.upperBound)
            process(line)
        }
    }

    private func process(_ line: Data) {
        guard let text = String(data: line, encoding: .utf8), text.hasPrefix("data:") else { return }
        let payload = text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              data.count <= UsageExtractor.maximumBufferedEventBytes,
              let root = try? JSONSerialization.jsonObject(with: data) else { return }
        latest.merge(UsageExtractor.observation(from: root))
    }
}

private extension ResponseUsageObservation {
    mutating func merge(_ other: ResponseUsageObservation) {
        if let model = other.model { self.model = model }
        if let usage = other.usage { self.usage = usage }
    }
}
