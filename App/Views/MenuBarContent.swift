import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Label(model.status.title, systemImage: model.status.symbolName)
        Text("Provider：\(shortTitle(model.providerName))")

        if !model.providers.isEmpty {
            Menu("切换 Provider") {
                ForEach(model.providers) { provider in
                    Button {
                        model.switchProvider(to: provider.id)
                    } label: {
                        if provider.id == model.activeProviderID {
                            Label(shortTitle(provider.displayName), systemImage: "checkmark")
                        } else {
                            Text(shortTitle(provider.displayName))
                        }
                    }
                }
            }
        }

        Divider()

        if model.isRunning {
            Button("运行生图自检") {
                model.runSelfTest()
            }
            .disabled(model.status == .testing)

            Button("停用并恢复") {
                model.disableAndRestore()
            }
        } else if model.configuration != nil || model.activeProvider != nil {
            Button("启动本地代理") {
                model.applyAndStart()
            }
        }

        Divider()

        Button("打开管理中心…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "management")
        }

        Button("设置…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("打开日志") {
            model.openLogs()
        }

        Divider()

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func shortTitle(_ title: String) -> String {
        title.count <= 30 ? title : String(title.prefix(27)) + "..."
    }
}
