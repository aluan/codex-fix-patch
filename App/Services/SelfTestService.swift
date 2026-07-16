import Foundation

enum SelfTestError: LocalizedError {
    case invalidLocalURL
    case invalidResponse
    case requestFailed(Int, String)
    case missingImage
    case invalidPNG

    var errorDescription: String? {
        switch self {
        case .invalidLocalURL: "无法生成本地自检地址"
        case .invalidResponse: "本地代理返回了无效响应"
        case .requestFailed(let status, let message): "自检返回 HTTP \(status)：\(message)"
        case .missingImage: "自检响应中没有图片数据"
        case .invalidPNG: "自检返回的数据不是有效 PNG"
        }
    }
}

struct SelfTestService: Sendable {
    func run(configuration: ProxyConfiguration, bearerToken: String) async throws -> URL {
        guard let baseURL = URL(string: configuration.localBaseURL) else {
            throw SelfTestError.invalidLocalURL
        }
        let endpoint = baseURL
            .appendingPathComponent("images")
            .appendingPathComponent("generations")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-image-1",
            "prompt": "A tiny friendly blue bird, simple icon, white background",
            "response_format": "b64_json",
            "size": "1024x1024",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SelfTestError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data.prefix(2_000), encoding: .utf8) ?? "未知错误"
            throw SelfTestError.requestFailed(response.statusCode, message)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = root["data"] as? [[String: Any]],
              let encoded = images.first?["b64_json"] as? String,
              let imageData = Data(base64Encoded: encoded) else {
            throw SelfTestError.missingImage
        }
        guard imageData.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw SelfTestError.invalidPNG
        }
        try FileManager.default.createDirectory(at: AppPaths.generatedImages, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let output = AppPaths.generatedImages.appendingPathComponent("self-test-\(formatter.string(from: Date())).png")
        try imageData.write(to: output, options: .atomic)
        return output
    }
}
