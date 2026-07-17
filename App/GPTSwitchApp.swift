import SwiftUI

@main
struct GPTSwitchApp: App {
    @State private var model = AppModel()
    @State private var navigation = MainNavigation()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model, navigation: navigation)
        } label: {
            MenuBarStatusIcon(status: model.status)
            .accessibilityLabel("GPTSwitch，\(model.status.title)")
        }

        Window("GPTSwitch", id: "main") {
            ManagementView(model: model, navigation: navigation)
        }
        .defaultSize(width: 1_020, height: 700)
    }
}
