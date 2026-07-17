import Foundation

struct BuiltInPricingCatalog: Sendable {
    struct Catalog: Decodable {
        let version: String
        let source: String
        let effectiveAt: String
        let rules: [Rule]

        enum CodingKeys: String, CodingKey {
            case version
            case source
            case effectiveAt = "effective_at"
            case rules
        }
    }

    struct Rule: Decodable {
        let id: UUID
        let pattern: String
        let prefix: Bool
        let input: Int64
        let cachedInput: Int64?
        let output: Int64

        enum CodingKeys: String, CodingKey {
            case id
            case pattern
            case prefix
            case input
            case cachedInput = "cached_input"
            case output
        }
    }

    func load(bundle: Bundle = .main) throws -> (version: String, rules: [ModelPricingRule]) {
        guard let url = bundle.url(forResource: "ModelPricing", withExtension: "json") else {
            throw PricingCatalogError.missingResource
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        let formatter = ISO8601DateFormatter()
        let effectiveAt = formatter.date(from: catalog.effectiveAt)
        return (
            catalog.version,
            catalog.rules.map { rule in
                ModelPricingRule(
                    id: rule.id,
                    modelPattern: rule.pattern,
                    isPrefix: rule.prefix,
                    inputMicrosPerMillion: rule.input,
                    cachedInputMicrosPerMillion: rule.cachedInput,
                    outputMicrosPerMillion: rule.output,
                    currency: .usd,
                    isBuiltIn: true,
                    source: catalog.source,
                    effectiveAt: effectiveAt
                )
            }
        )
    }
}

enum PricingCatalogError: LocalizedError {
    case missingResource

    var errorDescription: String? { "应用包缺少内置模型定价资源" }
}
