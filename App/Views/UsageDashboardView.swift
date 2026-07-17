import Charts
import SwiftUI

struct UsageDashboardView: View {
    @Bindable var model: AppModel
    @Binding var providerFilter: UUID?
    @State private var detailTab = UsageDetailTab.requests
    @State private var statusFilter = RequestStatusFilter.all
    @State private var modelSearch = ""

    init(model: AppModel, providerFilter: Binding<UUID?> = .constant(nil)) {
        self.model = model
        _providerFilter = providerFilter
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用统计")
                            .font(.largeTitle.weight(.semibold))
                        Text("仅记录请求元数据，不保存 Prompt 或响应正文")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("时间范围", selection: Binding(
                        get: { model.usageTimeRange },
                        set: { model.setUsageTimeRange($0) }
                    )) {
                        ForEach(UsageTimeRange.allCases, id: \.self) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Button {
                        Task { await model.refreshUsage() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }

                summaryCards
                trendCharts

                Picker("明细", selection: $detailTab) {
                    ForEach(UsageDetailTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)

                if detailTab == .requests {
                    requestFilters
                }

                detail
                    .frame(minHeight: 260)
            }
            .padding(24)
        }
        .navigationTitle("使用统计")
        .task { await model.refreshUsage() }
    }

    private var summaryCards: some View {
        let summary = model.usageResult.summary
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            MetricCard(title: "请求数", value: summary.totalRequests.formatted(), detail: "成功率 \((summary.successRate * 100).formatted(.number.precision(.fractionLength(1))))%")
            MetricCard(title: "总 Token", value: summary.totalTokens.formatted(), detail: "缓存 \(summary.cachedInputTokens.formatted())")
            MetricCard(title: "生成图片", value: summary.imageCount.formatted(), detail: "桥接 Images API")
            MetricCard(title: "估算成本", value: formattedCosts(summary.costs), detail: "未定价 \(summary.unpricedRequests) 次")
        }
    }

    private var trendCharts: some View {
        HStack(spacing: 12) {
            GroupBox("请求趋势") {
                Chart(model.usageResult.trend) { point in
                    BarMark(
                        x: .value("时间", point.bucket),
                        y: .value("请求", point.requests)
                    )
                    .foregroundStyle(.tint)
                }
                .frame(height: 180)
                .padding(.top, 8)
            }
            GroupBox("Token 趋势") {
                Chart(model.usageResult.trend) { point in
                    LineMark(
                        x: .value("时间", point.bucket),
                        y: .value("Token", point.inputTokens),
                        series: .value("类型", "输入")
                    )
                    .foregroundStyle(by: .value("类型", "输入"))
                    LineMark(
                        x: .value("时间", point.bucket),
                        y: .value("Token", point.outputTokens),
                        series: .value("类型", "输出")
                    )
                    .foregroundStyle(by: .value("类型", "输出"))
                }
                .frame(height: 180)
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch detailTab {
        case .requests:
            Table(filteredRequests) {
                TableColumn("时间") { metric in
                    Text(metric.startedAt, format: .dateTime.month().day().hour().minute().second())
                }
                TableColumn("Provider", value: \.providerName)
                TableColumn("接口") { Text($0.endpoint.title) }
                TableColumn("模型") { Text($0.billedModel ?? "—") }
                TableColumn("状态") { Text($0.statusCode.map(String.init) ?? "失败") }
                TableColumn("Token") { Text(($0.usage?.totalTokens ?? 0).formatted()) }
                TableColumn("耗时") { Text("\($0.durationMilliseconds) ms") }
            }
        case .providers:
            Table(model.usageResult.providers) {
                TableColumn("Provider", value: \.providerName)
                TableColumn("请求") { Text($0.requests.formatted()) }
                TableColumn("成功") { Text($0.successes.formatted()) }
                TableColumn("Token") { Text(($0.inputTokens + $0.outputTokens).formatted()) }
                TableColumn("平均耗时") { Text("\($0.averageLatencyMilliseconds) ms") }
                TableColumn("成本") { Text(formattedCosts($0.costs)) }
            }
        case .models:
            Table(model.usageResult.models) {
                TableColumn("模型", value: \.model)
                TableColumn("请求") { Text($0.requests.formatted()) }
                TableColumn("输入 Token") { Text($0.inputTokens.formatted()) }
                TableColumn("输出 Token") { Text($0.outputTokens.formatted()) }
                TableColumn("平均耗时") { Text("\($0.averageLatencyMilliseconds) ms") }
                TableColumn("成本") { Text(formattedCosts($0.costs)) }
            }
        }
    }

    private func formattedCosts(_ costs: [CurrencyTotal]) -> String {
        guard !costs.isEmpty else { return "—" }
        return costs.map { total in
            "\(total.currency.symbol)\((Double(total.micros) / 1_000_000).formatted(.number.precision(.fractionLength(2...6))))"
        }.joined(separator: " · ")
    }

    private var requestFilters: some View {
        HStack {
            Picker("Provider", selection: $providerFilter) {
                Text("全部 Provider").tag(UUID?.none)
                ForEach(model.providers) { provider in
                    Text(provider.displayName).tag(Optional(provider.id))
                }
            }
            .frame(width: 210)
            Picker("状态", selection: $statusFilter) {
                ForEach(RequestStatusFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .frame(width: 150)
            TextField("搜索模型", text: $modelSearch)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Spacer()
            Button("重置") {
                providerFilter = nil
                statusFilter = .all
                modelSearch = ""
            }
        }
    }

    private var filteredRequests: [RequestMetric] {
        model.usageResult.recentRequests.filter { metric in
            let providerMatches = providerFilter == nil || metric.providerID == providerFilter
            let statusMatches: Bool
            switch statusFilter {
            case .all: statusMatches = true
            case .success: statusMatches = metric.isSuccess
            case .failed: statusMatches = !metric.isSuccess
            }
            let search = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelMatches = search.isEmpty || (metric.billedModel ?? "").localizedCaseInsensitiveContains(search)
            return providerMatches && statusMatches && modelMatches
        }
    }
}

private enum UsageDetailTab: CaseIterable {
    case requests
    case providers
    case models

    var title: String {
        switch self {
        case .requests: "请求日志"
        case .providers: "Provider 统计"
        case .models: "模型统计"
        }
    }
}

private enum RequestStatusFilter: CaseIterable {
    case all
    case success
    case failed

    var title: String {
        switch self {
        case .all: "全部状态"
        case .success: "成功"
        case .failed: "失败"
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
