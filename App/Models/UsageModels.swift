import Foundation

enum RequestEndpoint: String, Codable, CaseIterable, Sendable {
    case responses
    case models
    case imageGeneration = "image_generation"
    case imageEdit = "image_edit"
    case other

    var title: String {
        switch self {
        case .responses: "Responses"
        case .models: "Models"
        case .imageGeneration: "生图"
        case .imageEdit: "图片编辑"
        case .other: "其他"
        }
    }
}

struct TokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var reasoningTokens: Int = 0

    var totalTokens: Int { inputTokens + outputTokens }
}

struct RequestMetric: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    var completedAt: Date
    var providerID: UUID
    var providerName: String
    var endpoint: RequestEndpoint
    var requestedModel: String?
    var responseModel: String?
    var statusCode: Int?
    var isStreaming: Bool
    var durationMilliseconds: Int
    var timeToFirstByteMilliseconds: Int?
    var usage: TokenUsage?
    var imageCount: Int
    var errorCategory: String?
    var estimatedCostMicros: Int64?
    var currency: PricingCurrency?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        completedAt: Date = Date(),
        providerID: UUID,
        providerName: String,
        endpoint: RequestEndpoint,
        requestedModel: String? = nil,
        responseModel: String? = nil,
        statusCode: Int? = nil,
        isStreaming: Bool = false,
        durationMilliseconds: Int = 0,
        timeToFirstByteMilliseconds: Int? = nil,
        usage: TokenUsage? = nil,
        imageCount: Int = 0,
        errorCategory: String? = nil,
        estimatedCostMicros: Int64? = nil,
        currency: PricingCurrency? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.providerID = providerID
        self.providerName = providerName
        self.endpoint = endpoint
        self.requestedModel = requestedModel
        self.responseModel = responseModel
        self.statusCode = statusCode
        self.isStreaming = isStreaming
        self.durationMilliseconds = durationMilliseconds
        self.timeToFirstByteMilliseconds = timeToFirstByteMilliseconds
        self.usage = usage
        self.imageCount = imageCount
        self.errorCategory = errorCategory
        self.estimatedCostMicros = estimatedCostMicros
        self.currency = currency
    }

    var isSuccess: Bool {
        guard let statusCode else { return false }
        return (200..<300).contains(statusCode)
    }

    var billedModel: String? { responseModel ?? requestedModel }
}

enum UsageTimeRange: String, CaseIterable, Codable, Sendable {
    case hours24
    case days7
    case days30

    var title: String {
        switch self {
        case .hours24: "24 小时"
        case .days7: "7 天"
        case .days30: "30 天"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .hours24: 24 * 60 * 60
        case .days7: 7 * 24 * 60 * 60
        case .days30: 30 * 24 * 60 * 60
        }
    }
}

enum PricingCurrency: String, Codable, CaseIterable, Sendable {
    case usd = "USD"
    case cny = "CNY"

    var symbol: String { self == .usd ? "$" : "¥" }
}

struct CurrencyTotal: Codable, Equatable, Sendable {
    let currency: PricingCurrency
    let micros: Int64
}

struct UsageSummary: Codable, Equatable, Sendable {
    var totalRequests = 0
    var successfulRequests = 0
    var inputTokens = 0
    var outputTokens = 0
    var cachedInputTokens = 0
    var imageCount = 0
    var unpricedRequests = 0
    var costs: [CurrencyTotal] = []

    var successRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(successfulRequests) / Double(totalRequests)
    }

    var totalTokens: Int { inputTokens + outputTokens }
}

struct UsageTrendPoint: Identifiable, Codable, Equatable, Sendable {
    var id: Date { bucket }
    let bucket: Date
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
}

struct ProviderUsageRow: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { providerID }
    let providerID: UUID
    let providerName: String
    let requests: Int
    let successes: Int
    let inputTokens: Int
    let outputTokens: Int
    let averageLatencyMilliseconds: Int
    var costs: [CurrencyTotal] = []
}

struct ModelUsageRow: Identifiable, Codable, Equatable, Sendable {
    var id: String { model }
    let model: String
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
    let averageLatencyMilliseconds: Int
    var costs: [CurrencyTotal] = []
}

struct UsageQueryResult: Equatable, Sendable {
    var summary = UsageSummary()
    var trend: [UsageTrendPoint] = []
    var recentRequests: [RequestMetric] = []
    var providers: [ProviderUsageRow] = []
    var models: [ModelUsageRow] = []
}

struct ModelPricingRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var providerID: UUID?
    var modelPattern: String
    var isPrefix: Bool
    var inputMicrosPerMillion: Int64
    var cachedInputMicrosPerMillion: Int64?
    var outputMicrosPerMillion: Int64
    var currency: PricingCurrency
    var isBuiltIn: Bool
    var source: String?
    var effectiveAt: Date?

    init(
        id: UUID = UUID(),
        providerID: UUID? = nil,
        modelPattern: String,
        isPrefix: Bool = false,
        inputMicrosPerMillion: Int64,
        cachedInputMicrosPerMillion: Int64? = nil,
        outputMicrosPerMillion: Int64,
        currency: PricingCurrency = .usd,
        isBuiltIn: Bool = false,
        source: String? = nil,
        effectiveAt: Date? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.modelPattern = modelPattern
        self.isPrefix = isPrefix
        self.inputMicrosPerMillion = inputMicrosPerMillion
        self.cachedInputMicrosPerMillion = cachedInputMicrosPerMillion
        self.outputMicrosPerMillion = outputMicrosPerMillion
        self.currency = currency
        self.isBuiltIn = isBuiltIn
        self.source = source
        self.effectiveAt = effectiveAt
    }
}

protocol UsageRepository: Sendable {
    func record(_ metric: RequestMetric) async throws
    func usage(range: UsageTimeRange) async throws -> UsageQueryResult
    func clearUsage() async throws
    func purgeUsage(olderThan cutoff: Date) async throws
}

protocol PricingCatalog: Sendable {
    func pricingRules() async throws -> [ModelPricingRule]
    func savePricingRule(_ rule: ModelPricingRule) async throws
    func deletePricingRule(id: UUID) async throws
}
