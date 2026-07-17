import Foundation

struct CDPTarget: Decodable, Equatable, Sendable {
    let id: String
    let type: String
    let url: String
    let webSocketDebuggerUrl: String
}

struct CodexCDPClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func apply(theme: SkinTheme) async throws {
        guard let imageURL = theme.imageURL else { throw SkinError.missingTheme }
        let image = try Data(contentsOf: imageURL, options: .mappedIfSafe)
        guard image.count <= SkinImageProcessor.maximumSourceBytes else { throw SkinError.imageTooLarge }
        let palette = try theme.palette.validated()
        let css = SkinCSSBuilder.build(theme: theme, palette: palette, imageData: image)
        let expression = SkinCSSBuilder.installExpression(themeID: theme.id, css: css)
        let targets = try await mainTargets()
        guard !targets.isEmpty else { throw SkinError.noMainRenderer }
        var success = false
        var lastError: Error?
        for target in targets {
            do {
                _ = try await evaluate(expression, target: target)
                success = true
            } catch {
                lastError = error
            }
        }
        if !success { throw lastError ?? SkinError.noMainRenderer }
    }

    func remove() async throws {
        let targets = try await mainTargets()
        guard !targets.isEmpty else { throw SkinError.noMainRenderer }
        for target in targets {
            _ = try await evaluate(SkinCSSBuilder.removeExpression, target: target)
        }
    }

    func isThemeActive(_ themeID: String) async throws -> Bool {
        let targets = try await mainTargets()
        guard !targets.isEmpty else { throw SkinError.noMainRenderer }
        for target in targets {
            let result = try await evaluate(SkinCSSBuilder.statusExpression, target: target)
            if result != SkinCSSBuilder.statusValue(themeID: themeID) { return false }
        }
        return true
    }

    func mainTargets() async throws -> [CDPTarget] {
        let endpoint = URL(string: "http://127.0.0.1:\(CodexSkinLifecycle.cdpPort)/json/list")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_048_576 else {
            throw SkinError.cdpUnavailable
        }
        let targets = try JSONDecoder().decode([CDPTarget].self, from: data)
        guard targets.count <= 256 else { throw SkinError.cdpUnavailable }
        return targets.filter { target in
            target.type == "page" && target.url == "app://-/index.html" && Self.validWebSocket(target.webSocketDebuggerUrl)
        }
    }

    private func evaluate(_ expression: String, target: CDPTarget) async throws -> String? {
        guard let url = URL(string: target.webSocketDebuggerUrl), Self.validWebSocket(target.webSocketDebuggerUrl) else {
            throw SkinError.cdpUnavailable
        }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1_024 * 1_024
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let identifier = 1
        let payload: [String: Any] = [
            "id": identifier,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true,
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(decoding: requestData, as: UTF8.self)))
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    while true {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              object["id"] as? Int == identifier else { continue }
                        if let error = object["error"] as? [String: Any] {
                            throw SkinError.injectionFailed(error["message"] as? String ?? "CDP 协议错误")
                        }
                        guard let result = object["result"] as? [String: Any],
                              result["exceptionDetails"] == nil,
                              let remote = result["result"] as? [String: Any] else {
                            throw SkinError.injectionFailed("renderer 返回异常")
                        }
                        return remote["value"] as? String
                    }
                } onCancel: {
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw SkinError.injectionFailed("CDP 命令超时")
            }
            let value = try await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    static func validWebSocket(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "ws",
              components.host == "127.0.0.1",
              components.port == Int(CodexSkinLifecycle.cdpPort),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return false }
        return components.path.range(of: #"^/devtools/page/[A-Za-z0-9_-]{1,256}$"#, options: .regularExpression) != nil
    }
}
