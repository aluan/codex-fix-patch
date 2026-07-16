import SwiftUI

@main
struct CodexImageGenProxyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label("Codex 生图代理", systemImage: model.status.symbolName)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
