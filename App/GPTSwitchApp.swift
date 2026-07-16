import SwiftUI

@main
struct GPTSwitchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            HStack(spacing: 4) {
                MenuBarStatusIcon(status: model.status)
                Text("GPTSwitch")
            }
            .accessibilityLabel("GPTSwitch，\(model.status.title)")
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
