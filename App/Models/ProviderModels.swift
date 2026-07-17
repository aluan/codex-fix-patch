import Foundation

enum ProviderCredentialMode: String, Codable, CaseIterable, Sendable {
    case keychainBearer = "keychain_bearer"
    case passthrough

    var title: String {
        switch self {
        case .keychainBearer: "钥匙串 Bearer Token"
        case .passthrough: "沿用 Codex 凭据"
        }
    }
}

enum ProviderHealthState: String, Codable, CaseIterable, Sendable {
    case unknown
    case healthy
    case degraded
    case unavailable

    var title: String {
        switch self {
        case .unknown: "未检测"
        case .healthy: "健康"
        case .degraded: "响应较慢"
        case .unavailable: "不可用"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }
}

struct ProviderProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var configName: String
    var displayName: String
    var baseURL: String
    var bridgeModel: String
    var testModel: String
    var note: String
    var website: String
    var sortOrder: Int
    var credentialMode: ProviderCredentialMode
    var costMultiplier: Double
    var healthState: ProviderHealthState
    var lastHealthLatencyMilliseconds: Int?
    var lastHealthError: String?
    var lastCheckedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        configName: String,
        displayName: String,
        baseURL: String,
        bridgeModel: String,
        testModel: String = "",
        note: String = "",
        website: String = "",
        sortOrder: Int = 0,
        credentialMode: ProviderCredentialMode = .keychainBearer,
        costMultiplier: Double = 1,
        healthState: ProviderHealthState = .unknown,
        lastHealthLatencyMilliseconds: Int? = nil,
        lastHealthError: String? = nil,
        lastCheckedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.configName = configName
        self.displayName = displayName
        self.baseURL = baseURL
        self.bridgeModel = bridgeModel
        self.testModel = testModel
        self.note = note
        self.website = website
        self.sortOrder = sortOrder
        self.credentialMode = credentialMode
        self.costMultiplier = costMultiplier
        self.healthState = healthState
        self.lastHealthLatencyMilliseconds = lastHealthLatencyMilliseconds
        self.lastHealthError = lastHealthError
        self.lastCheckedAt = lastCheckedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var effectiveTestModel: String {
        let trimmed = testModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? bridgeModel : trimmed
    }

    func validated(proxyPort: UInt16) throws -> ProviderProfile {
        var output = self
        output.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        output.configName = configName.trimmingCharacters(in: .whitespacesAndNewlines)
        output.bridgeModel = bridgeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        output.testModel = testModel.trimmingCharacters(in: .whitespacesAndNewlines)
        output.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        output.website = website.trimmingCharacters(in: .whitespacesAndNewlines)
        output.baseURL = try ProviderURLValidator.normalize(baseURL, proxyPort: proxyPort)
        output.costMultiplier = max(0, costMultiplier)
        output.updatedAt = Date()
        guard !output.displayName.isEmpty else { throw ProviderValidationError.missingName }
        guard !output.bridgeModel.isEmpty else { throw ProviderValidationError.missingBridgeModel }
        return output
    }
}

struct ActiveProviderSnapshot: Equatable, Sendable {
    let profile: ProviderProfile
    let bearerToken: String?

    var id: UUID { profile.id }
    var upstreamBaseURL: String { profile.baseURL }
    var bridgeModel: String { profile.bridgeModel }
}

enum ProviderValidationError: LocalizedError {
    case missingName
    case missingBridgeModel
    case invalidURL(String)
    case proxyLoop
    case missingCredential
    case activeProviderCannotBeDeleted
    case missingProvider

    var errorDescription: String? {
        switch self {
        case .missingName: "Provider 名称不能为空"
        case .missingBridgeModel: "桥接模型不能为空"
        case .invalidURL(let value): "无效的 Provider 地址：\(value)"
        case .proxyLoop: "Provider 地址不能指向 GPTSwitch 自身监听端口"
        case .missingCredential: "该 Provider 尚未保存 API Key"
        case .activeProviderCannotBeDeleted: "请先切换到其他 Provider，再删除当前 Provider"
        case .missingProvider: "找不到指定的 Provider"
        }
    }
}

enum ProviderURLValidator {
    static func normalize(_ value: String, proxyPort: UInt16) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil else {
            throw ProviderValidationError.invalidURL(value)
        }
        if ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()),
           components.port == Int(proxyPort) {
            throw ProviderValidationError.proxyLoop
        }
        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? ""
            : "/\(components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        components.query = nil
        guard let normalized = components.url?.absoluteString else {
            throw ProviderValidationError.invalidURL(value)
        }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

protocol ProviderRepository: Sendable {
    func providers() async throws -> [ProviderProfile]
    func saveProvider(_ provider: ProviderProfile) async throws
    func deleteProvider(id: UUID) async throws
    func activeProviderID() async throws -> UUID?
    func setActiveProvider(id: UUID) async throws
    func reorderProviders(ids: [UUID]) async throws
}

protocol CredentialStore: Sendable {
    func token(for providerID: UUID) throws -> String?
    func setToken(_ token: String, for providerID: UUID) throws
    func deleteToken(for providerID: UUID) throws
}
