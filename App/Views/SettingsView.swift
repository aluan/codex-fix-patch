import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            configuration
            Divider()
            actions
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("GPTSwitch")
                    .font(.title2.weight(.semibold))
                Text(model.status.title)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(ProxyConfiguration.currentToolVersion)")
                .foregroundStyle(.tertiary)
        }
    }

    private var configuration: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            infoRow("Provider", model.providerName)
            infoRow("上游地址", model.upstreamBaseURL)
            GridRow {
                Text("桥接模型")
                    .foregroundStyle(.secondary)
                TextField("模型名称", text: $model.editableBridgeModel)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("本地端口")
                    .foregroundStyle(.secondary)
                TextField("17891", text: $model.editablePort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            GridRow {
                Text("请求统计")
                    .foregroundStyle(.secondary)
                Text("转发 \(model.metrics.forwardedRequests) · 生图 \(model.metrics.bridgedImages) · 失败 \(model.metrics.failedRequests)")
            }
            GridRow {
                Text("登录启动")
                    .foregroundStyle(.secondary)
                Toggle("登录后自动运行", isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { model.setLoginItemEnabled($0) }
                ))
                .toggleStyle(.switch)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(model.isRunning ? "应用并重启" : "应用并启动") {
                model.applyAndStart()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApply || model.status == .starting || model.status == .testing)

            Button("生图自检") {
                model.runSelfTest()
            }
            .disabled(!model.isRunning || model.status == .testing)

            Button("打开配置") {
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

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .running: .green
        case .failed: .red
        case .starting, .testing: .orange
        case .notConfigured, .stopped: .secondary
        }
    }
}
