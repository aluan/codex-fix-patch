import SwiftUI

struct MenuBarStatusIcon: View {
    let status: ProxyRuntimeStatus

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 19, height: 19)
                .opacity(isInactive ? 0.55 : 1)

            badge
                .offset(x: 2, y: 2)
        }
        .frame(width: 22, height: 19)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .running:
            statusBadge(symbol: "checkmark", color: .green)
        case .starting, .testing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 9, height: 9)
        case .failed:
            statusBadge(symbol: "exclamationmark", color: .red)
        case .notConfigured, .stopped:
            statusBadge(symbol: "pause.fill", color: .secondary)
        }
    }

    private func statusBadge(symbol: String, color: Color) -> some View {
        Circle()
            .fill(.background)
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .fill(color)
                    .padding(1)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 5.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
    }

    private var isInactive: Bool {
        switch status {
        case .notConfigured, .stopped: true
        default: false
        }
    }
}
