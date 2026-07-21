import SwiftUI
import SlateUI

/// Renders the app's toast queue as a top-anchored stack. Each toast auto-dismisses
/// (notices fastest, errors slowest); action + close remove it immediately.
struct ToastHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { item in
                SlateToast(kind: item.kind, text: item.text,
                           actionLabel: item.actionLabel,
                           onAction: item.action.map { a in { a(); model.dismissToast(item.id) } },
                           onClose: { withAnimation(.snappy(duration: 0.28)) { model.dismissToast(item.id) } })
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: item.id) {
                        let secs: Double = item.kind == .error ? 12 : item.kind == .warning ? 9 : 5
                        try? await Task.sleep(for: .seconds(secs))
                        withAnimation(.snappy(duration: 0.28)) { model.dismissToast(item.id) }
                    }
            }
        }
        .frame(maxWidth: 460)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: model.toasts.count)
    }
}
