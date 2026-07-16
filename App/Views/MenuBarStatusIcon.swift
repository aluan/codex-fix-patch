import AppKit
import SwiftUI

struct MenuBarStatusIcon: View {
    let status: ProxyRuntimeStatus

    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .foregroundStyle(statusColor)
            .frame(width: 16, height: 16)
    }

    private static let templateImage: NSImage = {
        guard let source = NSImage(named: "MenuBarIcon"),
              let image = source.copy() as? NSImage else {
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()

    private var statusColor: Color {
        switch status {
        case .running:
            .green
        case .starting, .testing:
            .orange
        case .failed:
            .red
        case .notConfigured, .stopped:
            .secondary
        }
    }
}
