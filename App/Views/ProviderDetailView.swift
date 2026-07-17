import SwiftUI

struct ProviderDetailView: View {
    @Bindable var model: AppModel
    let provider: ProviderProfile
    let onDeleted: () -> Void
    @State private var draft: ProviderProfile
    @State private var apiKey = ""
    @State private var showingDeleteConfirmation = false
    @State private var isSaving = false
    @State private var isDeleting = false

    init(model: AppModel, provider: ProviderProfile, onDeleted: @escaping () -> Void) {
        self.model = model
        self.provider = provider
        self.onDeleted = onDeleted
        _draft = State(initialValue: provider)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                GroupBox("Provider 配置") {
                    ProviderEditorForm(
                        draft: $draft,
                        apiKey: $apiKey,
                        hasStoredCredential: model.providerHasCredential(provider.id)
                    )
                    .padding(.top, 4)
                }
                health
                actions
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(provider.displayName)
        .onChange(of: provider.updatedAt) {
            draft = provider
        }
        .confirmationDialog(
            "删除 \(provider.displayName)？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 Provider", role: .destructive) {
                isDeleting = true
                Task {
                    if await model.deleteProvider(provider.id) {
                        onDeleted()
                    } else {
                        isDeleting = false
                    }
                }
            }
        } message: {
            Text("Provider 配置和对应的钥匙串密钥将被删除，此操作无法撤销。")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.displayName)
                    .font(.largeTitle.weight(.semibold))
                Text(provider.baseURL)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if provider.id == model.activeProviderID {
                Label("当前使用", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("启用") { model.switchProvider(to: provider.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var health: some View {
        GroupBox("健康检查") {
            HStack(spacing: 16) {
                Label(provider.healthState.title, systemImage: provider.healthState.symbolName)
                if let latency = provider.lastHealthLatencyMilliseconds {
                    Text("\(latency) ms")
                        .foregroundStyle(.secondary)
                }
                if let checked = provider.lastCheckedAt {
                    Text(checked, style: .relative)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(isChecking ? 1 : 0)
                Button("端点测速") { model.measureProvider(provider.id) }
                Button("模型自检") { model.testProviderModel(provider.id) }
                Button("生图自检") { model.runSelfTest(for: provider.id) }
                    .disabled(!model.canRunImageSelfTest(for: provider.id))
                    .help(imageSelfTestHelp)
            }
            if let message = provider.lastHealthError {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }

    private var isChecking: Bool {
        model.checkingProviderIDs.contains(provider.id)
            || (provider.id == model.activeProviderID && model.status == .testing)
    }

    private var imageSelfTestHelp: String {
        if provider.id != model.activeProviderID {
            return "请先启用此 Provider"
        }
        if model.status == .testing {
            return "生图自检正在运行"
        }
        if !model.isRunning {
            return "请先启动本地代理"
        }
        return "通过本地代理执行一次真实生图请求"
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("保存更改") {
                    isSaving = true
                    Task {
                        if await model.saveProvider(draft, apiKey: apiKey.isEmpty ? nil : apiKey) != nil {
                            apiKey = ""
                        }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || isDeleting)

                Button("还原") {
                    draft = provider
                    apiKey = ""
                }
                .disabled((draft == provider && apiKey.isEmpty) || isSaving || isDeleting)

                Button("复制") { model.duplicateProvider(provider.id) }
                    .disabled(isSaving || isDeleting)

                if model.providerHasCredential(provider.id) {
                    Button("删除密钥", role: .destructive) {
                        model.deleteProviderCredential(provider.id)
                    }
                    .disabled(isSaving || isDeleting)
                }

                Spacer()

                Button("删除 Provider", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .disabled(provider.id == model.activeProviderID || isSaving || isDeleting)
                .help(provider.id == model.activeProviderID
                    ? "请先启用其他 Provider，再删除当前 Provider"
                    : "删除此 Provider")
            }

            if provider.id == model.activeProviderID {
                Text("当前 Provider 不能删除；请先启用另一个 Provider。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProviderEditorForm: View {
    @Binding var draft: ProviderProfile
    @Binding var apiKey: String
    let hasStoredCredential: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            row("显示名称") {
                TextField("Provider 名称", text: $draft.displayName)
            }
            row("配置标识") {
                TextField("provider-id", text: $draft.configName)
            }
            row("Responses 地址") {
                TextField("https://api.example.com/v1", text: $draft.baseURL)
            }
            row("桥接模型") {
                TextField("gpt-5", text: $draft.bridgeModel)
            }
            row("测试模型") {
                TextField("留空则使用桥接模型", text: $draft.testModel)
            }
            row("认证方式") {
                Picker("", selection: $draft.credentialMode) {
                    ForEach(ProviderCredentialMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
            }
            if draft.credentialMode == .keychainBearer {
                row("API Key") {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(hasStoredCredential ? "留空以保留现有密钥" : "输入 API Key", text: $apiKey)
                        Text(hasStoredCredential ? "密钥已保存在 macOS 钥匙串" : "密钥不会写入数据库或日志")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            row("成本倍率") {
                TextField("1.0", value: $draft.costMultiplier, format: .number.precision(.fractionLength(0...3)))
                    .frame(width: 120)
            }
            row("网站") {
                TextField("https://provider.example.com", text: $draft.website)
            }
            row("备注") {
                TextField("用途、套餐或到期时间", text: $draft.note, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            content()
        }
    }
}
