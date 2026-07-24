import SwiftUI

/// The calm, ambient reachability banner — sits above content, never a blocking
/// modal. Connecting / offline / asleep / waking / wake-failed each render here with
/// a matching icon and, where useful, one action.
struct MacStatusBanner: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let s = app.macStatus
        HStack(spacing: 11) {
            Image(systemName: s.icon)
                .font(.slate(15, .medium)).foregroundStyle(s.tint)
                .frame(width: 22)
                .symbolEffect(.pulse, options: .repeating,
                              isActive: s == .connecting || s == .waking)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.label).font(.slate(14, .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(.slate(12)).foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let action = s.action {
                Button { app.retryConnection() } label: {
                    Text(action).font(.slate(13, .medium)).foregroundStyle(Theme.canvas)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(SlateShape(radius: 9).fill(Theme.ink))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(SlateShape(radius: Theme.rControl).fill(Theme.surface))
        .overlay(SlateShape(radius: Theme.rControl).strokeBorder(s.tint.opacity(0.35), lineWidth: 1))
    }

    /// The connected line names the Mac we are actually talking to. `MacStatus.detail` carries
    /// the concept build's placeholder name, which would otherwise greet every real user with
    /// somebody else's MacBook.
    private var detail: String {
        guard app.macStatus == .reachable, !app.isDemo,
              let name = app.macs.first?.name, !name.isEmpty else { return app.macStatus.detail }
        return "\(name) · local network"
    }
}
