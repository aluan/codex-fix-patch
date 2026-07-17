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

        Window("GPTSwitch 管理中心", id: "management") {
            ManagementView(model: model)
        }
        .defaultSize(width: 980, height: 680)

        Settings {
            SettingsView(model: model)
        }
    }
}
