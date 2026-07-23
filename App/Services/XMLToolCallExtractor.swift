import Foundation

/// 把上游模型以 XML 文本形式输出的工具调用转换回原生工具调用事件，
/// 避免 Codex CLI 把裸标签当普通文本显示。
///
/// 支持三种泄漏格式（按出现频率）：
/// 1. AntML：`<function_calls><invoke name="functions.exec_command"><parameter name="cmd">touch x</parameter></invoke></function_calls>`
/// 2. JSON-in-tag：`<tool_call>{"name":"apply_patch","arguments":{...}}</tool_call>`
/// 3. 扁平：`<exec_command><cmd>touch x</cmd></exec_command>`
///
/// 仅当工具名（去掉 `functions.` 等前缀后）匹配当前请求工具目录时才转换；
/// 未知标签、代码里的 `<` 原样透传，绝不丢内容。
final class XMLToolCallExtractor {
    private let mappings: [String: ChatToolIdentity]
    private let nameIndex: [String: String]
    private var buffer = ""
    private var syntheticCount = 0

    private static let syntheticIndexBase = 900_000
    private static let bufferLimit = 1_048_576
    private static let wrapperTags: Set<String> = ["function_calls", "tool_call", "tool_use", "function_call"]

    init(mappings: [String: ChatToolIdentity]) {
        self.mappings = mappings
        var index: [String: String] = [:]
        for (wireName, identity) in mappings {
            index[wireName] = wireName
            let original: String
            switch identity {
            case .function(let name, _): original = name
            case .custom(let name): original = name
            case .toolSearch: original = "tool_search"
            }
            index[original] = wireName
        }
        self.nameIndex = index
    }

    func process(_ events: [AdapterEvent]) -> [AdapterEvent] {
        var output: [AdapterEvent] = []
        for event in events {
            if case .textDelta(let delta) = event {
                buffer += delta
            } else {
                output.append(contentsOf: drain(final: isTerminal(event)))
                output.append(event)
            }
        }
        output.append(contentsOf: drain(final: false))
        return output
    }

    func finish() -> [AdapterEvent] {
        drain(final: true)
    }

    private func isTerminal(_ event: AdapterEvent) -> Bool {
        switch event {
        case .completed, .incomplete, .failed: true
        default: false
        }
    }

    private func drain(final: Bool) -> [AdapterEvent] {
        var events: [AdapterEvent] = []
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            events.append(.textDelta(text))
            text = ""
        }

        while !buffer.isEmpty {
            guard let lt = buffer.firstIndex(of: "<") else {
                text += buffer
                buffer = ""
                break
            }
            if lt != buffer.startIndex {
                text += buffer[..<lt]
                buffer = String(buffer[lt...])
                continue
            }
            switch scanTag() {
            case .incomplete:
                if final || buffer.count >= Self.bufferLimit {
                    text += buffer
                    buffer = ""
                    continue
                }
                flushText()
                return events
            case .notTag:
                text += "<"
                buffer.removeFirst()
                continue
            case .selfClosing(let name, let raw):
                buffer.removeFirst(raw.count)
                if mappings[name] != nil, let toolEvents = makeFlatToolEvents(name: name, inner: "") {
                    flushText()
                    events.append(contentsOf: toolEvents)
                } else {
                    text += raw
                }
                continue
            case .closingTag(_, let raw):
                text += raw
                buffer.removeFirst(raw.count)
                continue
            case .openTag(let name, let raw):
                let afterOpen = buffer.index(buffer.startIndex, offsetBy: raw.count)
                let closer = "</\(name)>"
                guard let closeRange = buffer.range(of: closer, range: afterOpen..<buffer.endIndex) else {
                    // 非闭合块：仅当是「值得等待」的标签（目录工具名或包装标签）才挂起
                    let worthWaiting = mappings[name] != nil || Self.wrapperTags.contains(name)
                    if final || buffer.count >= Self.bufferLimit || !worthWaiting {
                        text += raw
                        buffer.removeFirst(raw.count)
                        continue
                    }
                    flushText()
                    return events
                }
                let inner = String(buffer[afterOpen..<closeRange.lowerBound])
                let blockEnd = closeRange.upperBound
                if Self.wrapperTags.contains(name) {
                    let calls = parseWrapperCalls(inner)
                    if calls.isEmpty {
                        text += String(buffer[buffer.startIndex..<blockEnd])
                    } else {
                        flushText()
                        for call in calls {
                            events.append(contentsOf: makeToolEvents(name: call.name, arguments: call.arguments))
                        }
                    }
                } else if mappings[name] != nil, let toolEvents = makeFlatToolEvents(name: name, inner: inner) {
                    flushText()
                    events.append(contentsOf: toolEvents)
                } else {
                    text += String(buffer[buffer.startIndex..<blockEnd])
                }
                buffer = String(buffer[blockEnd...])
                continue
            }
        }
        flushText()
        return events
    }

    private struct ParsedCall {
        let name: String
        let arguments: String
    }

    private enum TagScan {
        case incomplete
        case notTag
        case openTag(name: String, raw: String)
        case selfClosing(name: String, raw: String)
        case closingTag(name: String, raw: String)
    }

    private func scanTag() -> TagScan {
        // buffer starts with "<"
        var i = buffer.index(after: buffer.startIndex)
        guard i < buffer.endIndex else { return .incomplete }
        var closing = false
        if buffer[i] == "/" {
            closing = true
            i = buffer.index(after: i)
            guard i < buffer.endIndex else { return .incomplete }
        }
        guard isNameStart(buffer[i]) else { return .notTag }
        var j = i
        while j < buffer.endIndex, isNameChar(buffer[j]) {
            j = buffer.index(after: j)
        }
        let name = String(buffer[i..<j])
        guard !name.isEmpty else { return .notTag }
        guard j < buffer.endIndex else { return .incomplete }
        if buffer[j] == ">" {
            let raw = String(buffer[buffer.startIndex...j])
            return closing ? .closingTag(name: name, raw: raw) : .openTag(name: name, raw: raw)
        }
        if !closing, buffer[j] == "/" {
            let k = buffer.index(after: j)
            guard k < buffer.endIndex, buffer[k] == ">" else {
                return k < buffer.endIndex ? .notTag : .incomplete
            }
            return .selfClosing(name: name, raw: String(buffer[buffer.startIndex...k]))
        }
        return .notTag
    }

    // MARK: - 扁平格式 <tool><param>..</param></tool>

    private func makeFlatToolEvents(name: String, inner: String) -> [AdapterEvent]? {
        guard let identity = mappings[name] else { return nil }
        let arguments: String
        switch identity {
        case .custom:
            arguments = jsonString(["input": inner]) ?? "{\"input\":\"\"}"
        case .function, .toolSearch:
            guard let object = parseParameters(inner) ?? jsonObject(inner) else { return nil }
            guard let encoded = jsonString(object) else { return nil }
            arguments = encoded
        }
        return makeToolEvents(name: name, arguments: arguments)
    }

    // MARK: - 包装格式 <function_calls>/<tool_call>/<tool_use>

    private func parseWrapperCalls(_ inner: String) -> [ParsedCall] {
        if let calls = parseJSONCalls(inner) { return calls }
        if let calls = parseInvokeCalls(inner) { return calls }
        if let calls = parseNameArgumentsCalls(inner) { return calls }
        return []
    }

    /// `<tool_call>{"name":"X","arguments":{...}}</tool_call>` 或 JSON 数组
    private func parseJSONCalls(_ inner: String) -> [ParsedCall]? {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8) else { return nil }
        let objects: [[String: Any]]
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            objects = array
        } else if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            objects = [single]
        } else {
            return nil
        }
        var calls: [ParsedCall] = []
        for object in objects {
            guard let rawName = object["name"] as? String,
                  let wireName = resolveName(rawName) else { continue }
            let arguments: String
            if let args = object["arguments"] as? [String: Any] {
                arguments = jsonString(args) ?? "{}"
            } else if let argsString = object["arguments"] as? String,
                      let argsData = argsString.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                arguments = jsonString(args) ?? "{}"
            } else {
                arguments = "{}"
            }
            calls.append(ParsedCall(name: wireName, arguments: arguments))
        }
        return calls.isEmpty ? nil : calls
    }

    /// AntML：`<invoke name="functions.exec_command"><parameter name="cmd">..</parameter></invoke>`
    private func parseInvokeCalls(_ inner: String) -> [ParsedCall]? {
        var calls: [ParsedCall] = []
        var search = inner[...]
        while let invoke = findTagBlock(in: search, name: "invoke") {
            // invoke 是 `<invoke ...>...</invoke>` 或 `<invoke .../>`，提取 name 属性与内部 parameter
            let nameAttr = attribute(in: invoke.openTag, named: "name").flatMap { resolveName($0) }
            let params = parseParameters(invoke.inner)
            search = invoke.rest
            guard let wireName = nameAttr, let params else { continue }
            calls.append(ParsedCall(name: wireName, arguments: jsonString(params) ?? "{}"))
        }
        return calls.isEmpty ? nil : calls
    }

    /// `<tool_use><name>X</name><arguments>{...}</arguments></tool_use>`
    private func parseNameArgumentsCalls(_ inner: String) -> [ParsedCall]? {
        guard let name = textContent(of: "name", in: inner),
              let wireName = resolveName(name) else { return nil }
        let arguments: String
        if let argsText = textContent(of: "arguments", in: inner) {
            arguments = jsonObject(argsText).map { jsonString($0) ?? "{}" } ?? argsText
        } else {
            arguments = "{}"
        }
        return [ParsedCall(name: wireName, arguments: arguments)]
    }

    // MARK: - 参数解析

    private func parseParameters(_ inner: String) -> [String: Any]? {
        var rest = inner[...]
        var params: [String: Any] = [:]
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            guard !rest.isEmpty else { return params }
            guard rest.first == "<" else { return nil }
            guard let openEnd = rest.firstIndex(of: ">") else { return nil }
            var tagBody = String(rest[rest.index(after: rest.startIndex)..<openEnd])
            if tagBody.hasSuffix("/") { tagBody = String(tagBody.dropLast()) }
            // tagName = 第一个 token（如 parameter / cmd）；paramName 优先取 name 属性
            let tagName = tagBody.split(separator: " ").first.map(String.init) ?? tagBody
            guard !tagName.isEmpty, isNameStart(tagName.first!), tagName.allSatisfy({ isNameChar($0) }) else { return nil }
            let paramName = attribute(in: "<\(tagBody)>", named: "name") ?? tagName
            let valueStart = rest.index(after: openEnd)
            // 自闭合 <parameter name="x"/>：无值
            if String(rest[rest.index(after: rest.startIndex)..<openEnd]).hasSuffix("/") {
                params[paramName] = ""
                rest = rest[rest.index(after: openEnd)...]
                continue
            }
            let closer = "</\(tagName)>"
            guard let closeRange = rest.range(of: closer, range: valueStart..<rest.endIndex) else { return nil }
            let value = String(rest[valueStart..<closeRange.lowerBound])
            params[paramName] = merge(existing: params[paramName], new: coerce(value))
            rest = rest[closeRange.upperBound...]
        }
    }

    private func jsonObject(_ inner: String) -> [String: Any]? {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func coerce(_ value: String) -> Any {
        guard !value.isEmpty else { return "" }
        guard let data = value.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return value
        }
        if parsed is NSNull { return value }
        return parsed
    }

    private func merge(existing: Any?, new: Any) -> Any {
        guard let existing else { return new }
        if var array = existing as? [Any] {
            array.append(new)
            return array
        }
        return [existing, new]
    }

    // MARK: - 工具事件

    private func makeToolEvents(name: String, arguments: String) -> [AdapterEvent] {
        let index = Self.syntheticIndexBase + syntheticCount
        syntheticCount += 1
        let id = "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        return [
            .toolCallStarted(index: index, id: id, name: name),
            .toolCallArgumentsDelta(index: index, delta: arguments),
            .toolCallEnded(index: index),
        ]
    }

    private func resolveName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉常见前缀：functions. / functions__ / antml:
        for prefix in ["functions.", "functions__", "antml:", "antml_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return nameIndex[name]
    }

    // MARK: - 字符串工具

    private func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private struct TagBlock {
        let openTag: String
        let inner: String
        let rest: String.SubSequence
    }

    private func findTagBlock(in source: String.SubSequence, name: String) -> TagBlock? {
        guard let openStart = source.range(of: "<\(name)") else { return nil }
        guard let openEnd = source.range(of: ">", range: openStart.upperBound..<source.endIndex) else { return nil }
        let openTag = String(source[openStart.lowerBound...openEnd.lowerBound])
        let afterOpen = openEnd.upperBound
        let closer = "</\(name)>"
        // 自闭合 <invoke .../>
        if openTag.hasSuffix("/>") {
            let rest = source[afterOpen...]
            // afterOpen 已越过 '>'，修正：自闭合时 inner 为空
            return TagBlock(openTag: String(openTag.dropLast()), inner: "", rest: rest)
        }
        guard let closeRange = source.range(of: closer, range: afterOpen..<source.endIndex) else { return nil }
        let inner = String(source[afterOpen..<closeRange.lowerBound])
        let rest = source[closeRange.upperBound...]
        return TagBlock(openTag: openTag, inner: inner, rest: rest)
    }

    private func attribute(in tag: String, named key: String) -> String? {
        // 在 `<invoke name="X">` 中取 name 属性
        guard let range = tag.range(of: "\(key)=\"") else { return nil }
        let start = range.upperBound
        guard let end = tag[start...].firstIndex(of: "\"") else { return nil }
        return String(tag[start..<end])
    }

    private func textContent(of tag: String, in source: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let openRange = source.range(of: open),
              let closeRange = source.range(of: close, range: openRange.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isNameStart(_ c: Character) -> Bool {
        c.isLetter || c == "_"
    }

    private func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }
}
