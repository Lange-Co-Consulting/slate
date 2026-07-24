import SwiftUI

@main
struct SlateRemoteApp: App {
    @State private var app = AppState()
    @State private var theme = ThemeManager()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(theme)
                .environment(\.slatePalette, theme.palette)          // active color language
                .preferredColorScheme(theme.appearance.colorScheme)  // System / Light / Dark
                .tint(theme.accent)                                  // monochrome ink, or the accent
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Group {
            if app.isPaired {
                MainView()
            } else {
                OnboardingFlow()
            }
        }
        .animation(.smooth(duration: 0.35), value: app.isPaired)
        .animation(.smooth(duration: 0.3), value: app.onboarding)
    }
}
