import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings
    let model: AppModel

    var body: some View {
        Label(model.status.title, systemImage: model.status.symbolName)

        if model.isRunning {
            Button("运行生图自检") {
                model.runSelfTest()
            }
            .disabled(model.status == .testing)

            Button("停止本地代理") {
                model.stopProxy()
            }
        } else if model.configuration != nil {
            Button("启动本地代理") {
                model.applyAndStart()
            }
        }

        Divider()

        Button("设置…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
            DispatchQueue.main.async {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            AppLog.info("Opened settings window")
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
}
