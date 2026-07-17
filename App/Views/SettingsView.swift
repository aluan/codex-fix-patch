import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("代理") {
                LabeledContent("当前 Provider", value: model.providerName)
                TextField("本地端口", text: $model.editablePort)
                    .frame(width: 120)
                Toggle("登录后自动运行", isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { model.setLoginItemEnabled($0) }
                ))
            }

            Section("统计") {
                Toggle("记录请求统计", isOn: Binding(
                    get: { model.statisticsEnabled },
                    set: { model.setStatisticsEnabled($0) }
                ))
                Picker("保留周期", selection: Binding(
                    get: { model.retentionDays },
                    set: { model.setRetentionDays($0) }
                )) {
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("180 天").tag(180)
                    Text("永久").tag(0)
                }
                Button("清空统计数据", role: .destructive) {
                    model.clearUsage()
                }
            }

            Section {
                HStack {
                    Button(model.isRunning ? "应用设置" : "应用并启动") {
                        model.applyAndStart()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApply)

                    Button("生图自检") {
                        model.runSelfTest()
                    }
                    .disabled(!model.isRunning)

                    Button("打开 Codex 配置") {
                        model.openCodexConfig()
                    }

                    Spacer()

                    if model.configuration?.isEnabled == true {
                        Button("停用并恢复", role: .destructive) {
                            model.disableAndRestore()
                        }
                    }
                }
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding()
    }
}
