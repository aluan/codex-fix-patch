import SwiftUI

@main
struct GPTSwitchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label("GPTSwitch", systemImage: model.status.symbolName)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
