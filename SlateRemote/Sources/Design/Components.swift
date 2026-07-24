import SwiftUI

/// A small pill with an SF Symbol + label (On-device, Local network, …).
struct Chip: View {
    let icon: String
    let text: String
    var tint: Color = Theme.inkSecondary
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.slate(12, .medium))
            Text(text).font(.slate(13))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(SlateShape(radius: Theme.rChip).fill(Theme.surface))
        .overlay(SlateShape(radius: Theme.rChip).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// The one prominent action per screen. Monochrome default = white(ink) fill / dark(canvas)
/// ink; with a palette on it becomes the accent fill + its WCAG-derived ink. Pass `fill` to
/// override (e.g. a greyed-out disabled state).
struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var fill: Color? = nil        // nil ⇒ use the active accent (or ink when monochrome)
    let action: () -> Void
    @Environment(\.slatePalette) private var pal
    var body: some View {
        let bg = fill ?? (pal.enabled ? pal.accent : Theme.ink)
        let fg = (fill == nil && pal.enabled) ? pal.accentInk : Theme.canvas
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.slate(16, .medium)) }
                Text(title).font(.slate(17, .medium))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(SlateShape(radius: Theme.rControl).fill(bg))
        }
        .buttonStyle(.plain)
    }
}

/// A quiet, bordered secondary action.
struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.slate(15, .medium)) }
                Text(title).font(.slate(16, .medium))
            }
            .foregroundStyle(role == .destructive ? Theme.danger : Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(SlateShape(radius: Theme.rControl).fill(Theme.surface))
            .overlay(SlateShape(radius: Theme.rControl)
                .strokeBorder(role == .destructive ? Theme.danger.opacity(0.4) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A labelled settings row on a card.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.slate(15))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.slate(16)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.slate(13)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}

/// A small section caption above a card group. Secondary ink — tertiary fails AA at 12pt.
struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.slate(12, .medium))
            .foregroundStyle(Theme.inkSecondary)
            .kerning(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Subtle press-down feedback for tappable cards (e.g. chat rows).
struct PressableCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

/// Canvas background applied to every screen: the monochrome near-black (or paper) base,
/// with the active palette's canvas composited as a low-opacity wash — plusLighter in dark,
/// multiply in light — so a chosen theme colours the whole app the way the Mac's CanvasWash does.
struct CanvasBackground: ViewModifier {
    @Environment(\.slatePalette) private var pal
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Theme.canvas
                if pal.enabled {
                    pal.canvas
                        .opacity(scheme == .dark ? 0.16 : 0.10)
                        .blendMode(scheme == .dark ? .plusLighter : .multiply)
                }
            }
            .ignoresSafeArea()
        }
    }
}
extension View { func canvas() -> some View { modifier(CanvasBackground()) } }
