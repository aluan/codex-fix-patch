import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel
    let navigation: MainNavigation

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

        if !model.isRunning && (model.configuration != nil || model.activeProvider != nil) {
            Divider()

            Button("启动本地代理") {
                model.applyAndStart()
            }
        }

        Divider()

        Button("打开主界面…") {
            openMain(.providers)
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

    private func openMain(_ section: MainSection) {
        navigation.show(section)
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
