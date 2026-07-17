import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
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
                    Toggle("登录后自动运行 GPTSwitch", isOn: Binding(
                        get: { model.loginItemEnabled },
                        set: { model.setLoginItemEnabled($0) }
                    ))
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
