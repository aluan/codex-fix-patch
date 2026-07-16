import SwiftUI

@main
struct GPTSwitchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarStatusIcon(status: model.status)
            .accessibilityLabel("GPTSwitch，\(model.status.title)")
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
