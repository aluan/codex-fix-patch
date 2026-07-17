import Foundation

struct ProviderHealthResult: Equatable, Sendable {
    let state: ProviderHealthState
    let latencyMilliseconds: Int
    let statusCode: Int?
    let message: String?
}

struct ProviderHealthService: Sendable {
    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(session: URLSession = .shared) {
        load = { request in
            try await session.data(for: request)
        }
    }

    init(load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.load = load
    }

    func measureEndpoint(provider: ProviderProfile, token: String?) async -> ProviderHealthResult {
        await perform(provider: provider, token: token, endpoint: "models", body: nil)
    }

    func testModel(provider: ProviderProfile, token: String?) async -> ProviderHealthResult {
        let body = try? JSONSerialization.data(withJSONObject: [
            "model": provider.effectiveTestModel,
            "input": [[
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "Reply with OK.",
                ]],
            ]],
            "max_output_tokens": 8,
            "stream": false,
            "store": false,
        ])
        return await perform(provider: provider, token: token, endpoint: "responses", body: body)
    }

    private func perform(
        provider: ProviderProfile,
        token: String?,
        endpoint: String,
        body: Data?
    ) async -> ProviderHealthResult {
        let urls = ProviderEndpointResolver.urls(baseURL: provider.baseURL, endpoint: endpoint)
        guard !urls.isEmpty else {
            return ProviderHealthResult(state: .unavailable, latencyMilliseconds: 0, statusCode: nil, message: "无效的 Provider 地址")
        }
        let startedAt = Date()
        for (index, url) in urls.enumerated() {
            var request = URLRequest(url: url)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = body
            request.timeoutInterval = max(1, 15 - Date().timeIntervalSince(startedAt))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (_, response) = try await load(request)
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                guard let response = response as? HTTPURLResponse else {
                    return ProviderHealthResult(state: .unavailable, latencyMilliseconds: elapsed, statusCode: nil, message: "上游响应格式无效")
                }
                if (200..<300).contains(response.statusCode) {
                    return ProviderHealthResult(
                        state: elapsed > 6_000 ? .degraded : .healthy,
                        latencyMilliseconds: elapsed,
                        statusCode: response.statusCode,
                        message: nil
                    )
                }
                if index < urls.count - 1, [404, 405].contains(response.statusCode) {
                    continue
                }
                return ProviderHealthResult(
                    state: .unavailable,
                    latencyMilliseconds: elapsed,
                    statusCode: response.statusCode,
                    message: "HTTP \(response.statusCode)"
                )
            } catch {
                return ProviderHealthResult(
                    state: .unavailable,
                    latencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                    statusCode: nil,
                    message: error is URLError ? "网络请求失败" : "检测失败"
                )
            }
        }
        return ProviderHealthResult(state: .unavailable, latencyMilliseconds: 0, statusCode: nil, message: "检测失败")
    }
}

enum ProviderEndpointResolver {
    static func urls(baseURL: String, endpoint: String) -> [URL] {
        guard let primary = endpointURL(baseURL: baseURL, pathComponents: [endpoint]) else { return [] }
        guard endpoint == "models",
              primary.pathComponents.dropLast().last?.lowercased() != "v1",
              let fallback = endpointURL(baseURL: baseURL, pathComponents: ["v1", endpoint]),
              fallback != primary else {
            return [primary]
        }
        return [primary, fallback]
    }

    private static func endpointURL(baseURL: String, pathComponents: [String]) -> URL? {
        guard let base = URL(string: baseURL),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = pathComponents.joined(separator: "/")
        components.path = path.isEmpty ? "/\(suffix)" : "/\(path)/\(suffix)"
        components.query = nil
        return components.url
    }
}
