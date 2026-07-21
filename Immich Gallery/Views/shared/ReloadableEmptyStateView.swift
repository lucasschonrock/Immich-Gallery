import SwiftUI

/// A focusable empty state that preserves a route back to tvOS navigation chrome.
struct ReloadableEmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title)
                .foregroundStyle(.primary)

            Text(message)
                .foregroundStyle(.secondary)

            Button(action: onReload) {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .reloadButtonStyle()
            .padding(.top, 14)
            .accessibilityHint("Reloads this section")
        }
        .padding(36)
    }
}

private extension View {
    @ViewBuilder
    func reloadButtonStyle() -> some View {
        if #available(tvOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
