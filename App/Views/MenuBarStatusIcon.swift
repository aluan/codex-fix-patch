import SwiftUI

struct MenuBarStatusIcon: View {
    let status: ProxyRuntimeStatus

    var body: some View {
        Image("MenuBarIcon")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(statusColor)
            .frame(width: 14, height: 14)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }

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
