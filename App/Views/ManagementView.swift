import SwiftUI

enum ManagementSelection: Hashable {
    case provider(UUID)
    case usage
}

struct ManagementView: View {
    @Bindable var model: AppModel
    @State private var selection: ManagementSelection?
    @State private var showingNewProvider = false
    @State private var providerPendingDeletion: ProviderProfile?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Providers") {
                    ForEach(model.providers) { provider in
                        ProviderSidebarRow(
                            provider: provider,
                            isActive: provider.id == model.activeProviderID
                        )
                        .tag(ManagementSelection.provider(provider.id))
                        .contextMenu {
                            Button("编辑") {
                                selection = .provider(provider.id)
                            }
                            Button("启用") { model.switchProvider(to: provider.id) }
                                .disabled(provider.id == model.activeProviderID)
                            Button("复制") { model.duplicateProvider(provider.id) }
                            Divider()
                            Button("删除", role: .destructive) {
                                selection = .provider(provider.id)
                                providerPendingDeletion = provider
                            }
                            .disabled(provider.id == model.activeProviderID)
                        }
                    }
                    .onMove { indices, destination in
                        var ids = model.providers.map(\.id)
                        ids.move(fromOffsets: indices, toOffset: destination)
                        model.reorderProviders(ids)
                    }
                }

                Section("分析") {
                    Label("使用统计", systemImage: "chart.xyaxis.line")
                        .tag(ManagementSelection.usage)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("GPTSwitch")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Button {
                        showingNewProvider = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("添加 Provider")
                    .keyboardShortcut("n")

                    Button {
                        if let selectedProvider {
                            providerPendingDeletion = selectedProvider
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help(deleteHelp)
                    .disabled(selectedProvider == nil || selectedProvider?.id == model.activeProviderID)

                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.bar)
            }
        } detail: {
            detail
        }
        .onAppear {
            if selection == nil {
                selection = model.activeProviderID.map(ManagementSelection.provider) ?? .usage
            }
        }
        .sheet(isPresented: $showingNewProvider) {
            ProviderCreateView(model: model) { providerID in
                selection = .provider(providerID)
            }
        }
        .confirmationDialog(
            providerPendingDeletion.map { "删除 \($0.displayName)？" } ?? "删除 Provider？",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除 Provider", role: .destructive) {
                guard let provider = providerPendingDeletion else { return }
                Task {
                    if await model.deleteProvider(provider.id) {
                        selection = model.activeProviderID.map(ManagementSelection.provider) ?? .usage
                    }
                    providerPendingDeletion = nil
                }
            }
        } message: {
            Text("Provider 配置和对应的钥匙串密钥将被删除，此操作无法撤销。")
        }
    }

    private var selectedProvider: ProviderProfile? {
        guard case .provider(let id) = selection else { return nil }
        return model.providers.first { $0.id == id }
    }

    private var deleteHelp: String {
        selectedProvider?.id == model.activeProviderID
            ? "请先启用其他 Provider，再删除当前 Provider"
            : "删除所选 Provider"
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { providerPendingDeletion != nil },
            set: { if !$0 { providerPendingDeletion = nil } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .provider(let id):
            if let provider = model.providers.first(where: { $0.id == id }) {
                ProviderDetailView(model: model, provider: provider) {
                    selection = model.activeProviderID.map(ManagementSelection.provider) ?? .usage
                }
                    .id(provider.id)
            } else {
                ContentUnavailableView("Provider 不存在", systemImage: "externaldrive.badge.questionmark")
            }
        case .usage:
            UsageDashboardView(model: model)
        case nil:
            ContentUnavailableView("选择一个项目", systemImage: "sidebar.left")
        }
    }
}

private struct ProviderSidebarRow: View {
    let provider: ProviderProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: provider.healthState.symbolName)
                .foregroundStyle(healthColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(provider.displayName)
                        .lineLimit(1)
                    if isActive {
                        Text("使用中")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                Text(URL(string: provider.baseURL)?.host ?? provider.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var healthColor: Color {
        switch provider.healthState {
        case .healthy: .green
        case .degraded: .orange
        case .unavailable: .red
        case .unknown: .secondary
        }
    }
}

private struct ProviderCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let onCreated: (UUID) -> Void
    @State private var draft: ProviderProfile
    @State private var apiKey = ""
    @State private var isSaving = false

    init(model: AppModel, onCreated: @escaping (UUID) -> Void) {
        self.model = model
        self.onCreated = onCreated
        let index = model.providers.count + 1
        _draft = State(initialValue: ProviderProfile(
            configName: "provider-\(index)",
            displayName: "新 Provider",
            baseURL: "https://api.example.com/v1",
            bridgeModel: model.activeProvider?.bridgeModel ?? "gpt-5",
            sortOrder: model.providers.count
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 Provider")
                .font(.title2.weight(.semibold))
            ProviderEditorForm(draft: $draft, apiKey: $apiKey, hasStoredCredential: false)
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") {
                    isSaving = true
                    Task {
                        if let provider = await model.saveProvider(draft, apiKey: apiKey) {
                            onCreated(provider.id)
                            dismiss()
                        }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .overlay {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .offset(x: -54)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(isSaving)
    }
}
