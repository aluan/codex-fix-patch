import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var selectedPage = SettingsPage.general

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置页面", selection: $selectedPage) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.systemImage)
                        .tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.top, 16)
            .padding(.bottom, 8)

            switch selectedPage {
            case .general:
                generalSettings
            case .about:
                AboutSettingsView()
            }
        }
    }

    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置")
                        .font(.largeTitle.weight(.semibold))
                    Text("管理本地代理、登录启动和统计数据。")
                        .foregroundStyle(.secondary)
                }

                GroupBox("本地代理") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("当前 Provider")
                                .foregroundStyle(.secondary)
                            Text(model.providerName)
                        }
                        GridRow {
                            Text("监听端口")
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField("17891", text: $model.editablePort)
                                    .frame(width: 120)
                                Button(model.proxyEnabled ? "应用并重启" : "应用设置") {
                                    model.applyProxySettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.canApplyProxySettings || model.isProxyTransitioning)
                                Text(model.proxyEnabled ? "运行中修改会安全重启代理" : "下次启动代理时生效")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("启动") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("登录后自动运行 GPTSwitch", isOn: Binding(
                            get: { model.loginItemEnabled },
                            set: { model.setLoginItemEnabled($0) }
                        ))
                        .disabled(model.skinEnabled)
                        if model.skinEnabled {
                            Text("换肤常驻期间需要保持登录启动；关闭换肤后会恢复之前的设置。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("模型路由") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("允许跨 Provider 路由", isOn: Binding(
                            get: { model.crossProviderRoutingEnabled },
                            set: { model.setCrossProviderRoutingEnabled($0) }
                        ))
                        Text("默认开启。开启后可通过 provider/model 手动指定其他 Provider；Codex 模型菜单仍只显示当前 Provider。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                GroupBox("请求统计") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("记录请求统计", isOn: Binding(
                            get: { model.statisticsEnabled },
                            set: { model.setStatisticsEnabled($0) }
                        ))
                        HStack {
                            Text("保留周期")
                                .foregroundStyle(.secondary)
                            Picker("保留周期", selection: Binding(
                                get: { model.retentionDays },
                                set: { model.setRetentionDays($0) }
                            )) {
                                Text("30 天").tag(30)
                                Text("90 天").tag(90)
                                Text("180 天").tag(180)
                                Text("永久").tag(0)
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            Spacer()
                            Button("清空统计数据", role: .destructive) {
                                model.clearUsage()
                            }
                        }
                        Text("仅保存 Provider、模型、状态码、Token 和耗时等元数据，不保存 Prompt 或响应正文。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                GroupBox("文件与诊断") {
                    HStack {
                        Button("打开 Codex 配置") { model.openCodexConfig() }
                        Button("打开运行日志") { model.openLogs() }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

private struct AboutSettingsView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 48)

            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("GPTSwitch")
                .font(.largeTitle.weight(.semibold))

            Text(versionText)
                .font(.headline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("本地模型协议转换与 Provider 路由工具")
                .foregroundStyle(.secondary)

            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var versionText: String {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)):
            return "版本 \(version)（\(build)）"
        case let (.some(version), nil):
            return "版本 \(version)"
        case (nil, _):
            return "版本未知"
        }
    }
}
