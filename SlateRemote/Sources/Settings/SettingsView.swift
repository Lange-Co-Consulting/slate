import SwiftUI

struct SettingsView: View {
    /// Read from the bundle, not typed in. The literal here still said 0.1.0 after 0.2.0
    /// shipped, which is exactly how a hardcoded version number always ends up.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    @Environment(AppState.self) private var app
    @Environment(\.slatePalette) private var pal
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                // Appearance — theme (System/Light/Dark) + optional color palette.
                AppearanceSection()

                // Connected Macs
                VStack(spacing: 10) {
                    SectionCaption(text: "Connected Macs")
                    VStack(spacing: 0) {
                        ForEach(app.macs) { mac in
                            NavigationLink { MacSecurityDetail(mac: mac) } label: {
                                SettingsRow(icon: "laptopcomputer", title: mac.name,
                                            subtitle: "Paired \(mac.pairedOn)") {
                                    HStack(spacing: 6) {
                                        Circle().fill(app.macStatus == .reachable ? Theme.ok : Theme.inkTertiary)
                                            .frame(width: 7, height: 7)
                                        Image(systemName: "chevron.right").font(.slate(13))
                                            .foregroundStyle(Theme.inkTertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .slateCard()
                }

                // Network / privacy
                VStack(spacing: 10) {
                    SectionCaption(text: "Connection")
                    VStack(spacing: 0) {
                        SettingsRow(icon: "wifi", title: "Local network",
                                    subtitle: "Direct and encrypted, over Wi-Fi") {
                            Text(app.macStatus == .reachable ? "Connected" : app.macStatus.label)
                                .font(.slate(14))
                                .foregroundStyle(app.macStatus == .reachable ? Theme.ok : Theme.inkSecondary)
                        }
                        Divider().overlay(Theme.hairline).padding(.leading, 52)
                        SettingsRow(icon: "cloud.slash", title: "Cloud relay", subtitle: "Off. Nothing leaves your network.") {
                            Text("Off").font(.slate(14)).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    .slateCard()
                }

                // Concept build: reach every state for review.
                #if DEBUG
                DemoSection()
                #endif

                // About
                VStack(spacing: 10) {
                    SectionCaption(text: "About")
                    VStack(spacing: 0) {
                        SettingsRow(icon: "app.badge", title: "Slate Remote",
                                    subtitle: SettingsView.versionLine) { EmptyView() }
                        Divider().overlay(Theme.hairline).padding(.leading, 52)
                        SettingsRow(icon: "lock.shield", title: "No account, no cloud, no subscription",
                                    subtitle: "Your Mac does the work") { EmptyView() }
                    }
                    .slateCard()
                }
            }
            .padding(16).padding(.bottom, 40)
        }
        .canvas()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MacSecurityDetail: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.slatePalette) private var pal
    @Environment(\.colorScheme) private var scheme
    let mac: PairedMac
    @State private var confirmRevoke = false
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.surface).frame(width: 74, height: 74)
                            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        Image(systemName: "laptopcomputer").font(.system(size: 30)).foregroundStyle(Theme.ink)
                    }
                    Text(mac.name).font(.slate(20, .medium)).foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity).padding(.top, 8)

                VStack(spacing: 10) {
                    SectionCaption(text: "Security")
                    VStack(spacing: 0) {
                        SettingsRow(icon: "checkmark.seal", title: "Certificate pinned",
                                    subtitle: "This Mac only") { Image(systemName: "checkmark").foregroundStyle(Theme.ok) }
                        Divider().overlay(Theme.hairline).padding(.leading, 52)
                        SettingsRow(icon: "number", title: "Fingerprint", subtitle: mac.fingerprint) { EmptyView() }
                        Divider().overlay(Theme.hairline).padding(.leading, 52)
                        SettingsRow(icon: "calendar", title: "Paired", subtitle: mac.pairedOn) { EmptyView() }
                    }
                    .slateCard()
                }

                SecondaryButton(title: "Revoke this Mac", icon: "trash", role: .destructive) {
                    confirmRevoke = true
                }
                Text("Revoking removes the pairing key from this iPhone. You'll need to scan a fresh QR to reconnect.")
                    .font(.slate(13)).foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20)
            }
            .padding(16)
        }
        .canvas()
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Revoke \(mac.name)?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                app.macs.removeAll { $0.id == mac.id }
                if app.macs.isEmpty { app.reset() } else { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone will disconnect immediately.")
        }
    }
}

/// Appearance controls — the two orthogonal axes (Light/Dark + color palette) that the
/// macOS app also exposes. Theme defaults to Dark; custom colors default OFF (monochrome).
struct AppearanceSection: View {
    @Environment(ThemeManager.self) private var theme
    var body: some View {
        @Bindable var theme = theme
        VStack(spacing: 10) {
            SectionCaption(text: "Appearance")
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.lefthalf.filled").font(.slate(15))
                            .foregroundStyle(Theme.inkSecondary).frame(width: 24)
                        Text("Theme").font(.slate(16)).foregroundStyle(Theme.ink)
                    }
                    Picker("Theme", selection: $theme.appearance) {
                        ForEach(ThemeManager.Appearance.allCases) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 13)

                Divider().overlay(Theme.hairline).padding(.leading, 52)

                SettingsRow(icon: "paintpalette", title: "Custom colors",
                            subtitle: theme.customColorsEnabled ? theme.preset.name
                                                                : "Monochrome. Slate's default look.") {
                    Toggle("", isOn: $theme.customColorsEnabled).labelsHidden()
                }
            }
            .slateCard()

            if theme.customColorsEnabled {
                SectionCaption(text: "Theme")
                    .padding(.top, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 12)], spacing: 12) {
                    ForEach(PalettePreset.all) { preset in
                        PresetSwatch(preset: preset, selected: preset.id == theme.presetID) {
                            theme.presetID = preset.id
                        }
                    }
                }
                .padding(.horizontal, 2)
                Text("Themes tint the accent, chat bubbles and canvas, using the same palettes as the Mac app.")
                    .font(.slate(12)).foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4).padding(.top, 2)
            }
        }
        .animation(.smooth(duration: 0.25), value: theme.customColorsEnabled)
    }
}

/// A tappable palette preview — a canvas→surface mini card with the accent, and a selection ring.
struct PresetSwatch: View {
    let preset: PalettePreset
    let selected: Bool
    let tap: () -> Void
    var body: some View {
        let p = preset.palette()
        Button(action: tap) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [p.canvas, p.surface],
                                             startPoint: .top, endPoint: .bottom))
                    Circle().fill(p.accent).frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                }
                .frame(height: 46)
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(selected ? Theme.ink : Theme.hairline, lineWidth: selected ? 2 : 1))
                Text(preset.name)
                    .font(.slate(11, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Concept-build helper: drive the ambient Mac status and jump into edge-state previews, so
/// every screen is reviewable without a real Mac. Debug-only — it was shipping to real users,
/// who have no reason to see a menu that fakes their Mac going offline.
#if DEBUG
struct DemoSection: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 10) {
            SectionCaption(text: "Preview (concept build)")
            VStack(spacing: 0) {
                SettingsRow(icon: "dot.radiowaves.left.and.right", title: "Mac status") {
                    Menu {
                        ForEach(MacStatus.allCases, id: \.self) { s in
                            Button(s.label) { app.macStatus = s }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(app.macStatus.label).font(.slate(14)).foregroundStyle(app.macStatus.tint)
                            Image(systemName: "chevron.up.chevron.down").font(.slate(11)).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
                Divider().overlay(Theme.hairline).padding(.leading, 52)
                NavigationLink { StatesGalleryView() } label: {
                    SettingsRow(icon: "square.grid.2x2", title: "Edge-state gallery") {
                        Image(systemName: "chevron.right").font(.slate(13)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.hairline).padding(.leading, 52)
                Button { app.reset() } label: {
                    SettingsRow(icon: "arrow.counterclockwise", title: "Replay onboarding") { EmptyView() }
                }
                .buttonStyle(.plain)
            }
            .slateCard()
        }
    }
}
#endif
