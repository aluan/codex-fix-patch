import Foundation
import SQLite3

actor AppDatabase: ProviderRepository, UsageRepository, PricingCatalog {
    private let connection: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = AppPaths.database) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw DatabaseError.openFailed(message)
        }
        connection = database
        do {
            try Self.execute("PRAGMA journal_mode = WAL", on: database)
            try Self.execute("PRAGMA foreign_keys = ON", on: database)
            try Self.execute("PRAGMA busy_timeout = 5000", on: database)
            try Self.migrate(database)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(connection)
    }

    func providers() async throws -> [ProviderProfile] {
        try queryProviders()
    }

    func saveProvider(_ provider: ProviderProfile) async throws {
        let sql = """
        INSERT INTO providers (
            id, config_name, display_name, base_url, bridge_model, test_model, note, website,
            sort_order, credential_mode, cost_multiplier, health_state, health_latency_ms,
            health_error, last_checked_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            config_name = excluded.config_name,
            display_name = excluded.display_name,
            base_url = excluded.base_url,
            bridge_model = excluded.bridge_model,
            test_model = excluded.test_model,
            note = excluded.note,
            website = excluded.website,
            sort_order = excluded.sort_order,
            credential_mode = excluded.credential_mode,
            cost_multiplier = excluded.cost_multiplier,
            health_state = excluded.health_state,
            health_latency_ms = excluded.health_latency_ms,
            health_error = excluded.health_error,
            last_checked_at = excluded.last_checked_at,
            updated_at = excluded.updated_at
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(provider.id.uuidString, at: 1, in: statement)
        bind(provider.configName, at: 2, in: statement)
        bind(provider.displayName, at: 3, in: statement)
        bind(provider.baseURL, at: 4, in: statement)
        bind(provider.bridgeModel, at: 5, in: statement)
        bind(provider.testModel, at: 6, in: statement)
        bind(provider.note, at: 7, in: statement)
        bind(provider.website, at: 8, in: statement)
        sqlite3_bind_int(statement, 9, Int32(provider.sortOrder))
        bind(provider.credentialMode.rawValue, at: 10, in: statement)
        sqlite3_bind_double(statement, 11, provider.costMultiplier)
        bind(provider.healthState.rawValue, at: 12, in: statement)
        bind(provider.lastHealthLatencyMilliseconds, at: 13, in: statement)
        bind(provider.lastHealthError, at: 14, in: statement)
        bind(provider.lastCheckedAt?.timeIntervalSince1970, at: 15, in: statement)
        sqlite3_bind_double(statement, 16, provider.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 17, provider.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    func deleteProvider(id: UUID) async throws {
        if try setting("active_provider_id") == id.uuidString {
            throw ProviderValidationError.activeProviderCannotBeDeleted
        }
        let statement = try prepare("DELETE FROM providers WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, in: statement)
        try stepDone(statement)
    }

    func activeProviderID() async throws -> UUID? {
        try setting("active_provider_id").flatMap(UUID.init(uuidString:))
    }

    func setActiveProvider(id: UUID) async throws {
        let check = try prepare("SELECT 1 FROM providers WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(check) }
        bind(id.uuidString, at: 1, in: check)
        guard sqlite3_step(check) == SQLITE_ROW else {
            throw ProviderValidationError.missingProvider
        }
        try setSetting("active_provider_id", value: id.uuidString)
    }

    func reorderProviders(ids: [UUID]) async throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("UPDATE providers SET sort_order = ?, updated_at = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            for (index, id) in ids.enumerated() {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int(statement, 1, Int32(index))
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                bind(id.uuidString, at: 3, in: statement)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func importProvidersIfEmpty(_ providers: [ProviderProfile], activeProviderID: UUID?) async throws -> Bool {
        guard try queryProviders().isEmpty else { return false }
        try execute("BEGIN IMMEDIATE")
        do {
            for provider in providers {
                try await saveProvider(provider)
            }
            if let activeProviderID {
                try setSetting("active_provider_id", value: activeProviderID.uuidString)
            }
            try execute("COMMIT")
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func record(_ incoming: RequestMetric) async throws {
        guard try setting("statistics_enabled") != "0" else { return }
        var metric = incoming
        if metric.estimatedCostMicros == nil,
           let usage = metric.usage,
           let model = metric.billedModel,
           let estimate = try estimateCost(usage: usage, model: model, providerID: metric.providerID) {
            metric.estimatedCostMicros = estimate.micros
            metric.currency = estimate.currency
        }
        let sql = """
        INSERT INTO request_metrics (
            id, started_at, completed_at, provider_id, provider_name, endpoint,
            requested_model, response_model, status_code, is_streaming, duration_ms, ttfb_ms,
            input_tokens, output_tokens, cached_input_tokens, reasoning_tokens, image_count,
            error_category, cost_micros, currency
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(metric.id.uuidString, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, metric.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, metric.completedAt.timeIntervalSince1970)
        bind(metric.providerID.uuidString, at: 4, in: statement)
        bind(metric.providerName, at: 5, in: statement)
        bind(metric.endpoint.rawValue, at: 6, in: statement)
        bind(metric.requestedModel, at: 7, in: statement)
        bind(metric.responseModel, at: 8, in: statement)
        bind(metric.statusCode, at: 9, in: statement)
        sqlite3_bind_int(statement, 10, metric.isStreaming ? 1 : 0)
        sqlite3_bind_int64(statement, 11, Int64(metric.durationMilliseconds))
        bind(metric.timeToFirstByteMilliseconds, at: 12, in: statement)
        bind(metric.usage?.inputTokens, at: 13, in: statement)
        bind(metric.usage?.outputTokens, at: 14, in: statement)
        bind(metric.usage?.cachedInputTokens, at: 15, in: statement)
        bind(metric.usage?.reasoningTokens, at: 16, in: statement)
        sqlite3_bind_int(statement, 17, Int32(metric.imageCount))
        bind(metric.errorCategory, at: 18, in: statement)
        bind(metric.estimatedCostMicros, at: 19, in: statement)
        bind(metric.currency?.rawValue, at: 20, in: statement)
        try stepDone(statement)
    }

    func usage(range: UsageTimeRange) async throws -> UsageQueryResult {
        let cutoff = Date().addingTimeInterval(-range.interval).timeIntervalSince1970
        return UsageQueryResult(
            summary: try querySummary(cutoff: cutoff),
            trend: try queryTrend(cutoff: cutoff, bucketSeconds: range == .hours24 ? 3_600 : 86_400),
            recentRequests: try queryRecentRequests(cutoff: cutoff),
            providers: try queryProviderUsage(cutoff: cutoff),
            models: try queryModelUsage(cutoff: cutoff)
        )
    }

    func clearUsage() async throws {
        try execute("DELETE FROM request_metrics")
    }

    func purgeUsage(olderThan cutoff: Date) async throws {
        let statement = try prepare("DELETE FROM request_metrics WHERE started_at < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        try stepDone(statement)
    }

    func pricingRules() async throws -> [ModelPricingRule] {
        let statement = try prepare("""
        SELECT id, provider_id, model_pattern, is_prefix, input_micros_per_million,
               cached_input_micros_per_million, output_micros_per_million, currency,
               is_builtin, source, effective_at
        FROM pricing_rules
        ORDER BY is_builtin DESC, provider_id, model_pattern
        """)
        defer { sqlite3_finalize(statement) }
        var rules: [ModelPricingRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, 0).flatMap(UUID.init(uuidString:)),
                  let pattern = string(statement, 2),
                  let currency = string(statement, 7).flatMap(PricingCurrency.init(rawValue:)) else { continue }
            rules.append(ModelPricingRule(
                id: id,
                providerID: string(statement, 1).flatMap(UUID.init(uuidString:)),
                modelPattern: pattern,
                isPrefix: sqlite3_column_int(statement, 3) != 0,
                inputMicrosPerMillion: sqlite3_column_int64(statement, 4),
                cachedInputMicrosPerMillion: optionalInt64(statement, 5),
                outputMicrosPerMillion: sqlite3_column_int64(statement, 6),
                currency: currency,
                isBuiltIn: sqlite3_column_int(statement, 8) != 0,
                source: string(statement, 9),
                effectiveAt: optionalDouble(statement, 10).map(Date.init(timeIntervalSince1970:))
            ))
        }
        return rules
    }

    func savePricingRule(_ rule: ModelPricingRule) async throws {
        let statement = try prepare("""
        INSERT INTO pricing_rules (
            id, provider_id, model_pattern, is_prefix, input_micros_per_million,
            cached_input_micros_per_million, output_micros_per_million, currency,
            is_builtin, source, effective_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            provider_id = excluded.provider_id,
            model_pattern = excluded.model_pattern,
            is_prefix = excluded.is_prefix,
            input_micros_per_million = excluded.input_micros_per_million,
            cached_input_micros_per_million = excluded.cached_input_micros_per_million,
            output_micros_per_million = excluded.output_micros_per_million,
            currency = excluded.currency,
            source = excluded.source,
            effective_at = excluded.effective_at
        """)
        defer { sqlite3_finalize(statement) }
        bind(rule.id.uuidString, at: 1, in: statement)
        bind(rule.providerID?.uuidString, at: 2, in: statement)
        bind(rule.modelPattern, at: 3, in: statement)
        sqlite3_bind_int(statement, 4, rule.isPrefix ? 1 : 0)
        sqlite3_bind_int64(statement, 5, rule.inputMicrosPerMillion)
        bind(rule.cachedInputMicrosPerMillion, at: 6, in: statement)
        sqlite3_bind_int64(statement, 7, rule.outputMicrosPerMillion)
        bind(rule.currency.rawValue, at: 8, in: statement)
        sqlite3_bind_int(statement, 9, rule.isBuiltIn ? 1 : 0)
        bind(rule.source, at: 10, in: statement)
        bind(rule.effectiveAt?.timeIntervalSince1970, at: 11, in: statement)
        try stepDone(statement)
    }

    func deletePricingRule(id: UUID) async throws {
        let statement = try prepare("DELETE FROM pricing_rules WHERE id = ? AND is_builtin = 0")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, in: statement)
        try stepDone(statement)
    }

    func seedBuiltInPricingRules(_ rules: [ModelPricingRule], version: String) async throws {
        guard try setting("pricing_catalog_version") != version else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM pricing_rules WHERE is_builtin = 1")
            for var rule in rules {
                rule.isBuiltIn = true
                try await savePricingRule(rule)
            }
            try setSetting("pricing_catalog_version", value: version)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func statisticsEnabled() async throws -> Bool {
        try setting("statistics_enabled") != "0"
    }

    func setStatisticsEnabled(_ enabled: Bool) async throws {
        try setSetting("statistics_enabled", value: enabled ? "1" : "0")
    }

    func retentionDays() async throws -> Int {
        Int(try setting("retention_days") ?? "90") ?? 90
    }

    func setRetentionDays(_ days: Int) async throws {
        try setSetting("retention_days", value: String(days))
    }

    func proxyPort(default defaultPort: UInt16 = 17891) async throws -> UInt16 {
        guard let value = try setting("proxy_port"),
              let port = UInt16(value), port > 0 else { return defaultPort }
        return port
    }

    func setProxyPort(_ port: UInt16) async throws {
        try setSetting("proxy_port", value: String(port))
    }

    func customSkinThemes() async throws -> [SkinTheme] {
        let statement = try prepare("""
        SELECT id, name, image_path, accent, secondary, surface, text, created_at, updated_at
        FROM custom_skin_themes ORDER BY updated_at DESC
        """)
        defer { sqlite3_finalize(statement) }
        var themes: [SkinTheme] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, 0),
                  let name = string(statement, 1),
                  let imagePath = string(statement, 2),
                  let accent = string(statement, 3),
                  let secondary = string(statement, 4),
                  let surface = string(statement, 5),
                  let text = string(statement, 6) else { continue }
            themes.append(SkinTheme(
                id: id,
                name: name,
                source: .custom,
                imageReference: imagePath,
                palette: SkinPalette(accent: accent, secondary: secondary, surface: surface, text: text),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            ))
        }
        return themes
    }

    func saveCustomSkinTheme(_ theme: SkinTheme) async throws {
        guard theme.source == .custom else { throw SkinError.missingTheme }
        let palette = try theme.palette.validated()
        let statement = try prepare("""
        INSERT INTO custom_skin_themes (
            id, name, image_path, accent, secondary, surface, text, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            image_path = excluded.image_path,
            accent = excluded.accent,
            secondary = excluded.secondary,
            surface = excluded.surface,
            text = excluded.text,
            updated_at = excluded.updated_at
        """)
        defer { sqlite3_finalize(statement) }
        bind(theme.id, at: 1, in: statement)
        bind(theme.name, at: 2, in: statement)
        bind(theme.imageReference, at: 3, in: statement)
        bind(palette.accent, at: 4, in: statement)
        bind(palette.secondary, at: 5, in: statement)
        bind(palette.surface, at: 6, in: statement)
        bind(palette.text, at: 7, in: statement)
        sqlite3_bind_double(statement, 8, theme.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, theme.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    func deleteCustomSkinTheme(id: String) async throws {
        let statement = try prepare("DELETE FROM custom_skin_themes WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id, at: 1, in: statement)
        try stepDone(statement)
    }

    func skinEnabled() async throws -> Bool {
        try setting("skin_enabled") == "1"
    }

    func setSkinEnabled(_ enabled: Bool) async throws {
        try setSetting("skin_enabled", value: enabled ? "1" : "0")
    }

    func selectedSkinThemeID() async throws -> String {
        try setting("selected_skin_theme_id") ?? BuiltInSkinCatalog.defaultThemeID
    }

    func setSelectedSkinThemeID(_ id: String) async throws {
        try setSetting("selected_skin_theme_id", value: id)
    }

    func loginItemBeforeSkin() async throws -> Bool? {
        guard let value = try setting("login_item_before_skin") else { return nil }
        return value == "1"
    }

    func setLoginItemBeforeSkin(_ enabled: Bool) async throws {
        try setSetting("login_item_before_skin", value: enabled ? "1" : "0")
    }

    private func estimateCost(
        usage: TokenUsage,
        model: String,
        providerID: UUID
    ) throws -> (micros: Int64, currency: PricingCurrency)? {
        let rules = try blockingPricingRules()
        let normalized = model.lowercased()
        let matching = rules.compactMap { rule -> (ModelPricingRule, Int)? in
            let pattern = rule.modelPattern.lowercased()
            let matches = rule.isPrefix ? normalized.hasPrefix(pattern) : normalized == pattern
            guard matches, rule.providerID == nil || rule.providerID == providerID else { return nil }
            let rank: Int
            switch (rule.providerID != nil, rule.isPrefix) {
            case (true, false): rank = 4
            case (true, true): rank = 3
            case (false, false): rank = 2
            case (false, true): rank = 1
            }
            return (rule, rank)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.modelPattern.count > rhs.0.modelPattern.count : lhs.1 > rhs.1
        }
        guard let rule = matching.first?.0 else { return nil }
        let multiplier = try providerMultiplier(id: providerID)
        let uncached = max(0, usage.inputTokens - usage.cachedInputTokens)
        let cachedPrice = rule.cachedInputMicrosPerMillion ?? rule.inputMicrosPerMillion
        let numerator = Decimal(uncached) * Decimal(rule.inputMicrosPerMillion)
            + Decimal(usage.cachedInputTokens) * Decimal(cachedPrice)
            + Decimal(usage.outputTokens) * Decimal(rule.outputMicrosPerMillion)
        let amount = numerator / Decimal(1_000_000) * Decimal(multiplier)
        let rounded = NSDecimalNumber(decimal: amount).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: true
            )
        )
        return (rounded.int64Value, rule.currency)
    }

    private func blockingPricingRules() throws -> [ModelPricingRule] {
        let statement = try prepare("""
        SELECT id, provider_id, model_pattern, is_prefix, input_micros_per_million,
               cached_input_micros_per_million, output_micros_per_million, currency,
               is_builtin, source, effective_at
        FROM pricing_rules
        """)
        defer { sqlite3_finalize(statement) }
        var rules: [ModelPricingRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, 0).flatMap(UUID.init(uuidString:)),
                  let pattern = string(statement, 2),
                  let currency = string(statement, 7).flatMap(PricingCurrency.init(rawValue:)) else { continue }
            rules.append(ModelPricingRule(
                id: id,
                providerID: string(statement, 1).flatMap(UUID.init(uuidString:)),
                modelPattern: pattern,
                isPrefix: sqlite3_column_int(statement, 3) != 0,
                inputMicrosPerMillion: sqlite3_column_int64(statement, 4),
                cachedInputMicrosPerMillion: optionalInt64(statement, 5),
                outputMicrosPerMillion: sqlite3_column_int64(statement, 6),
                currency: currency,
                isBuiltIn: sqlite3_column_int(statement, 8) != 0,
                source: string(statement, 9),
                effectiveAt: optionalDouble(statement, 10).map(Date.init(timeIntervalSince1970:))
            ))
        }
        return rules
    }

    private func providerMultiplier(id: UUID) throws -> Double {
        let statement = try prepare("SELECT cost_multiplier FROM providers WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_double(statement, 0) : 1
    }

    private func queryProviders() throws -> [ProviderProfile] {
        let statement = try prepare("""
        SELECT id, config_name, display_name, base_url, bridge_model, test_model, note, website,
               sort_order, credential_mode, cost_multiplier, health_state, health_latency_ms,
               health_error, last_checked_at, created_at, updated_at
        FROM providers ORDER BY sort_order, created_at
        """)
        defer { sqlite3_finalize(statement) }
        var output: [ProviderProfile] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, 0).flatMap(UUID.init(uuidString:)),
                  let configName = string(statement, 1),
                  let displayName = string(statement, 2),
                  let baseURL = string(statement, 3),
                  let bridgeModel = string(statement, 4),
                  let credentialMode = string(statement, 9).flatMap(ProviderCredentialMode.init(rawValue:)),
                  let healthState = string(statement, 11).flatMap(ProviderHealthState.init(rawValue:)) else { continue }
            output.append(ProviderProfile(
                id: id,
                configName: configName,
                displayName: displayName,
                baseURL: baseURL,
                bridgeModel: bridgeModel,
                testModel: string(statement, 5) ?? "",
                note: string(statement, 6) ?? "",
                website: string(statement, 7) ?? "",
                sortOrder: Int(sqlite3_column_int(statement, 8)),
                credentialMode: credentialMode,
                costMultiplier: sqlite3_column_double(statement, 10),
                healthState: healthState,
                lastHealthLatencyMilliseconds: optionalInt(statement, 12),
                lastHealthError: string(statement, 13),
                lastCheckedAt: optionalDouble(statement, 14).map(Date.init(timeIntervalSince1970:)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16))
            ))
        }
        return output
    }

    private func querySummary(cutoff: TimeInterval) throws -> UsageSummary {
        let statement = try prepare("""
        SELECT COUNT(*),
               SUM(CASE WHEN status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END),
               COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0),
               COALESCE(SUM(cached_input_tokens), 0), COALESCE(SUM(image_count), 0),
               SUM(CASE WHEN cost_micros IS NULL THEN 1 ELSE 0 END)
        FROM request_metrics WHERE started_at >= ?
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        var summary = UsageSummary()
        if sqlite3_step(statement) == SQLITE_ROW {
            summary.totalRequests = Int(sqlite3_column_int64(statement, 0))
            summary.successfulRequests = Int(sqlite3_column_int64(statement, 1))
            summary.inputTokens = Int(sqlite3_column_int64(statement, 2))
            summary.outputTokens = Int(sqlite3_column_int64(statement, 3))
            summary.cachedInputTokens = Int(sqlite3_column_int64(statement, 4))
            summary.imageCount = Int(sqlite3_column_int64(statement, 5))
            summary.unpricedRequests = Int(sqlite3_column_int64(statement, 6))
        }
        let costs = try prepare("""
        SELECT currency, SUM(cost_micros) FROM request_metrics
        WHERE started_at >= ? AND cost_micros IS NOT NULL AND currency IS NOT NULL
        GROUP BY currency
        """)
        defer { sqlite3_finalize(costs) }
        sqlite3_bind_double(costs, 1, cutoff)
        while sqlite3_step(costs) == SQLITE_ROW {
            if let currency = string(costs, 0).flatMap(PricingCurrency.init(rawValue:)) {
                summary.costs.append(CurrencyTotal(currency: currency, micros: sqlite3_column_int64(costs, 1)))
            }
        }
        return summary
    }

    private func queryTrend(cutoff: TimeInterval, bucketSeconds: Int) throws -> [UsageTrendPoint] {
        let statement = try prepare("""
        SELECT CAST(started_at / ? AS INTEGER) * ?, COUNT(*),
               COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0)
        FROM request_metrics WHERE started_at >= ?
        GROUP BY 1 ORDER BY 1
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(bucketSeconds))
        sqlite3_bind_int(statement, 2, Int32(bucketSeconds))
        sqlite3_bind_double(statement, 3, cutoff)
        var output: [UsageTrendPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            output.append(UsageTrendPoint(
                bucket: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                requests: Int(sqlite3_column_int64(statement, 1)),
                inputTokens: Int(sqlite3_column_int64(statement, 2)),
                outputTokens: Int(sqlite3_column_int64(statement, 3))
            ))
        }
        return output
    }

    private func queryRecentRequests(cutoff: TimeInterval) throws -> [RequestMetric] {
        let statement = try prepare("""
        SELECT id, started_at, completed_at, provider_id, provider_name, endpoint,
               requested_model, response_model, status_code, is_streaming, duration_ms, ttfb_ms,
               input_tokens, output_tokens, cached_input_tokens, reasoning_tokens, image_count,
               error_category, cost_micros, currency
        FROM request_metrics WHERE started_at >= ? ORDER BY started_at DESC LIMIT 200
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        var output: [RequestMetric] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, 0).flatMap(UUID.init(uuidString:)),
                  let providerID = string(statement, 3).flatMap(UUID.init(uuidString:)),
                  let providerName = string(statement, 4),
                  let endpoint = string(statement, 5).flatMap(RequestEndpoint.init(rawValue:)) else { continue }
            let input = optionalInt(statement, 12)
            let outputTokens = optionalInt(statement, 13)
            let usage: TokenUsage? = input == nil && outputTokens == nil ? nil : TokenUsage(
                inputTokens: input ?? 0,
                outputTokens: outputTokens ?? 0,
                cachedInputTokens: optionalInt(statement, 14) ?? 0,
                reasoningTokens: optionalInt(statement, 15) ?? 0
            )
            output.append(RequestMetric(
                id: id,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                completedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                providerID: providerID,
                providerName: providerName,
                endpoint: endpoint,
                requestedModel: string(statement, 6),
                responseModel: string(statement, 7),
                statusCode: optionalInt(statement, 8),
                isStreaming: sqlite3_column_int(statement, 9) != 0,
                durationMilliseconds: Int(sqlite3_column_int64(statement, 10)),
                timeToFirstByteMilliseconds: optionalInt(statement, 11),
                usage: usage,
                imageCount: Int(sqlite3_column_int(statement, 16)),
                errorCategory: string(statement, 17),
                estimatedCostMicros: optionalInt64(statement, 18),
                currency: string(statement, 19).flatMap(PricingCurrency.init(rawValue:))
            ))
        }
        return output
    }

    private func queryProviderUsage(cutoff: TimeInterval) throws -> [ProviderUsageRow] {
        let statement = try prepare("""
        SELECT provider_id, provider_name, COUNT(*),
               SUM(CASE WHEN status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END),
               COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0),
               COALESCE(AVG(duration_ms), 0)
        FROM request_metrics WHERE started_at >= ?
        GROUP BY provider_id, provider_name ORDER BY COUNT(*) DESC
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        var output: [ProviderUsageRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let providerID = string(statement, 0).flatMap(UUID.init(uuidString:)),
                  let providerName = string(statement, 1) else { continue }
            output.append(ProviderUsageRow(
                providerID: providerID,
                providerName: providerName,
                requests: Int(sqlite3_column_int64(statement, 2)),
                successes: Int(sqlite3_column_int64(statement, 3)),
                inputTokens: Int(sqlite3_column_int64(statement, 4)),
                outputTokens: Int(sqlite3_column_int64(statement, 5)),
                averageLatencyMilliseconds: Int(sqlite3_column_double(statement, 6))
            ))
        }
        let costs = try prepare("""
        SELECT provider_id, currency, SUM(cost_micros)
        FROM request_metrics
        WHERE started_at >= ? AND cost_micros IS NOT NULL AND currency IS NOT NULL
        GROUP BY provider_id, currency
        """)
        defer { sqlite3_finalize(costs) }
        sqlite3_bind_double(costs, 1, cutoff)
        while sqlite3_step(costs) == SQLITE_ROW {
            guard let providerID = string(costs, 0).flatMap(UUID.init(uuidString:)),
                  let currency = string(costs, 1).flatMap(PricingCurrency.init(rawValue:)),
                  let index = output.firstIndex(where: { $0.providerID == providerID }) else { continue }
            output[index].costs.append(CurrencyTotal(currency: currency, micros: sqlite3_column_int64(costs, 2)))
        }
        return output
    }

    private func queryModelUsage(cutoff: TimeInterval) throws -> [ModelUsageRow] {
        let statement = try prepare("""
        SELECT COALESCE(response_model, requested_model, '未知模型'), COUNT(*),
               COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0),
               COALESCE(AVG(duration_ms), 0)
        FROM request_metrics WHERE started_at >= ?
        GROUP BY 1 ORDER BY COUNT(*) DESC
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        var output: [ModelUsageRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let model = string(statement, 0) else { continue }
            output.append(ModelUsageRow(
                model: model,
                requests: Int(sqlite3_column_int64(statement, 1)),
                inputTokens: Int(sqlite3_column_int64(statement, 2)),
                outputTokens: Int(sqlite3_column_int64(statement, 3)),
                averageLatencyMilliseconds: Int(sqlite3_column_double(statement, 4))
            ))
        }
        let costs = try prepare("""
        SELECT COALESCE(response_model, requested_model, '未知模型'), currency, SUM(cost_micros)
        FROM request_metrics
        WHERE started_at >= ? AND cost_micros IS NOT NULL AND currency IS NOT NULL
        GROUP BY 1, currency
        """)
        defer { sqlite3_finalize(costs) }
        sqlite3_bind_double(costs, 1, cutoff)
        while sqlite3_step(costs) == SQLITE_ROW {
            guard let model = string(costs, 0),
                  let currency = string(costs, 1).flatMap(PricingCurrency.init(rawValue:)),
                  let index = output.firstIndex(where: { $0.model == model }) else { continue }
            output[index].costs.append(CurrencyTotal(currency: currency, micros: sqlite3_column_int64(costs, 2)))
        }
        return output
    }

    private func setting(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM app_settings WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? string(statement, 0) : nil
    }

    private func setSetting(_ key: String, value: String) throws {
        let statement = try prepare("""
        INSERT INTO app_settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """)
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(connection)))
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: connection)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(connection)))
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func bind(_ value: Int64?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
    }

    private func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private static func execute(_ sql: String, on connection: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(errorMessage)
            throw DatabaseError.queryFailed(message)
        }
    }

    private static func migrate(_ connection: OpaquePointer) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL
        );
        """, on: connection)
        var version = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(connection, "SELECT COALESCE(MAX(version), 0) FROM schema_migrations", -1, &statement, nil) == SQLITE_OK,
           let statement {
            if sqlite3_step(statement) == SQLITE_ROW { version = Int(sqlite3_column_int(statement, 0)) }
            sqlite3_finalize(statement)
        }
        if version < 1 {
            try execute("BEGIN IMMEDIATE", on: connection)
            do {
            try execute("""
            CREATE TABLE providers (
                id TEXT PRIMARY KEY,
                config_name TEXT NOT NULL,
                display_name TEXT NOT NULL,
                base_url TEXT NOT NULL,
                bridge_model TEXT NOT NULL,
                test_model TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                website TEXT NOT NULL DEFAULT '',
                sort_order INTEGER NOT NULL DEFAULT 0,
                credential_mode TEXT NOT NULL,
                cost_multiplier REAL NOT NULL DEFAULT 1,
                health_state TEXT NOT NULL DEFAULT 'unknown',
                health_latency_ms INTEGER,
                health_error TEXT,
                last_checked_at REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX providers_sort_order_idx ON providers(sort_order);

            CREATE TABLE app_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            INSERT INTO app_settings(key, value) VALUES ('statistics_enabled', '1');
            INSERT INTO app_settings(key, value) VALUES ('retention_days', '90');

            CREATE TABLE request_metrics (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                completed_at REAL NOT NULL,
                provider_id TEXT NOT NULL,
                provider_name TEXT NOT NULL,
                endpoint TEXT NOT NULL,
                requested_model TEXT,
                response_model TEXT,
                status_code INTEGER,
                is_streaming INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                ttfb_ms INTEGER,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cached_input_tokens INTEGER,
                reasoning_tokens INTEGER,
                image_count INTEGER NOT NULL DEFAULT 0,
                error_category TEXT,
                cost_micros INTEGER,
                currency TEXT
            );
            CREATE INDEX request_metrics_started_idx ON request_metrics(started_at);
            CREATE INDEX request_metrics_provider_idx ON request_metrics(provider_id, started_at);
            CREATE INDEX request_metrics_model_idx ON request_metrics(response_model, requested_model, started_at);
            CREATE INDEX request_metrics_status_idx ON request_metrics(status_code, started_at);

            CREATE TABLE pricing_rules (
                id TEXT PRIMARY KEY,
                provider_id TEXT,
                model_pattern TEXT NOT NULL,
                is_prefix INTEGER NOT NULL DEFAULT 0,
                input_micros_per_million INTEGER NOT NULL,
                cached_input_micros_per_million INTEGER,
                output_micros_per_million INTEGER NOT NULL,
                currency TEXT NOT NULL,
                is_builtin INTEGER NOT NULL DEFAULT 0,
                source TEXT,
                effective_at REAL
            );
            CREATE INDEX pricing_rules_match_idx ON pricing_rules(provider_id, model_pattern, is_prefix);
            INSERT INTO schema_migrations(version, applied_at) VALUES (1, strftime('%s', 'now'));
            """, on: connection)
            try execute("COMMIT", on: connection)
                version = 1
            } catch {
                try? execute("ROLLBACK", on: connection)
                throw error
            }
        }
        if version < 2 {
            try execute("BEGIN IMMEDIATE", on: connection)
            do {
                try execute("""
                CREATE TABLE custom_skin_themes (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    image_path TEXT NOT NULL,
                    accent TEXT NOT NULL,
                    secondary TEXT NOT NULL,
                    surface TEXT NOT NULL,
                    text TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX custom_skin_themes_updated_idx ON custom_skin_themes(updated_at DESC);
                INSERT OR IGNORE INTO app_settings(key, value) VALUES ('skin_enabled', '0');
                INSERT OR IGNORE INTO app_settings(key, value) VALUES ('selected_skin_theme_id', 'ocean-glass');
                INSERT INTO schema_migrations(version, applied_at) VALUES (2, strftime('%s', 'now'));
                """, on: connection)
                try execute("COMMIT", on: connection)
            } catch {
                try? execute("ROLLBACK", on: connection)
                throw error
            }
        }
    }
}

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "无法打开 GPTSwitch 数据库：\(message)"
        case .queryFailed(let message): "GPTSwitch 数据库操作失败：\(message)"
        }
    }
}
