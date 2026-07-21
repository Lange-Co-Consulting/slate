import AppKit
import SwiftUI
import SlateUI
import SlateFlowCore

// MARK: - Floating panel (undocked state)

/// The floating dictation pill once it has been PULLED OUT of the window.
/// Non-activating: it never steals focus from the app being dictated into.
/// Lives on every Space, floats above full-screen apps. Docking back happens
/// magnetically: drag it near the Slate window's bottom-right corner and it
/// snaps back inside (FlowRuntime observes the panel's moves).
@MainActor final class FlowBarPanel: NSPanel {
    init(content: some View) {
        super.init(contentRect: .init(x: 0, y: 0, width: 320, height: 84),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                      // the SwiftUI capsule draws its own
        isMovableByWindowBackground = true
        let host = NSHostingView(rootView: content)
        host.frame = contentRect(forFrameRect: frame)
        contentView = host
        positionBottomCenter()
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        setFrameOrigin(.init(x: f.midX - frame.width / 2, y: f.minY + 10))
    }
}

/// Panel content: the shared pill core, centered in the halo-sized canvas.
struct FlowBarView: View {
    @Environment(FlowRuntime.self) private var flow
    var body: some View {
        FlowPillCore()
            .frame(width: 320, height: 84)
    }
}

// MARK: - Slate's aurora palette (blue → violet → green, both modes)

enum FlowAurora {
    static func colors(dark: Bool, palette: SlatePalette = .standard) -> [Color] {
        if palette.enabled {
            return [palette.accent, palette.canvas, palette.surface, palette.accent]
        }
        let s = dark ? 0.85 : 0.7
        let b = dark ? 0.85 : 0.8
        return [Color(hue: 0.62, saturation: s, brightness: b),   // blue
                Color(hue: 0.76, saturation: s, brightness: b),   // violet
                Color(hue: 0.44, saturation: s, brightness: b),   // green
                Color(hue: 0.62, saturation: s, brightness: b)]   // wrap for the sweep
    }
}

/// The identity wash behind the sidebar material - blue fading through violet
/// into green, subtle but ALWAYS there, wallpaper or not.
struct SidebarWash: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.slatePalette) private var palette
    var body: some View {
        let dark = scheme == .dark
        LinearGradient(colors: [
            palette.enabled ? palette.accent : Color(hue: 0.62, saturation: 0.75, brightness: dark ? 0.5 : 0.97),
            palette.enabled ? palette.canvas : Color(hue: 0.74, saturation: 0.65, brightness: dark ? 0.42 : 0.95),
            palette.enabled ? palette.surface : Color(hue: 0.46, saturation: 0.55, brightness: dark ? 0.35 : 0.93),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        .opacity(dark ? (palette.enabled ? 0.30 : 0.26) : (palette.enabled ? 0.20 : 0.30))
        .ignoresSafeArea()
    }
}

// MARK: - Docked pill (in-window state)

/// Sidebar host row: shows the docked pill in the sidebar's bottom cluster
/// whenever Flow is enabled and the pill hasn't been pulled out. Collapses to
/// zero height otherwise; pops in/out with a spring.
struct DockedFlowPillHost: View {
    @Environment(FlowRuntime.self) private var flow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if flow.enabled && flow.pillDocked {
                DockedFlowPill()
                    .padding(.bottom, 2)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3, extraBounce: 0.25), value: flow.pillDocked)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3, extraBounce: 0.25), value: flow.enabled)
    }
}

// MARK: - Voice-reactive edge glow

/// While dictating, the window rim glows ambient in the identity colors - a
/// slowly SWEEPING blue→violet→green gradient whose brightness rides the live
/// mic level. Layered wide bloom + mid glow + crisp rim so it reads as light
/// hugging the edge, not fog. Decor only: no hit-testing, gone on stop.
struct FlowEdgeGlow: View {
    @Environment(FlowRuntime.self) private var flow
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.slatePalette) private var palette

    var body: some View {
        ZStack {
            if flow.controller.state == .recording {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let sweep = reduceMotion ? .zero : Angle(degrees: (t * 24).truncatingRemainder(dividingBy: 360))
                    let dark = scheme == .dark
                    let intensity = (dark ? 0.34 : 0.30) + Double(flow.level) * 0.5
                    let gradient = AngularGradient(colors: FlowAurora.colors(dark: dark, palette: palette),
                                                   center: .center, angle: sweep)
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.R.window - 1, style: .continuous)
                            .strokeBorder(gradient, lineWidth: 22)
                            .blur(radius: 38)
                            .opacity(intensity)
                        RoundedRectangle(cornerRadius: DS.R.window - 1, style: .continuous)
                            .strokeBorder(gradient, lineWidth: 7)
                            .blur(radius: 12)
                            .opacity(intensity * 0.9)
                        RoundedRectangle(cornerRadius: DS.R.window - 1, style: .continuous)
                            .strokeBorder(gradient, lineWidth: 2)
                            .blur(radius: 2.5)
                            .opacity(intensity * 0.8)
                    }
                    .blendMode(dark ? .plusLighter : .normal)
                }
                .padding(1)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: flow.controller.state == .recording)
    }
}

/// The pill living INSIDE the sidebar's bottom cluster - styled as a proper
/// sidebar row (same capsule language as the Downloads pill), not a floating
/// blob. Idle: mic + "Flow" + an Fn keycap. Recording: live waveform + timer
/// with an aurora rim. Dragging fights a magnetic tether (rubber-band with
/// growing strain); past the escape radius it POPS out into the floating
/// panel right under the cursor. Release earlier and it springs home.
struct DockedFlowPill: View {
    @Environment(FlowRuntime.self) private var flow
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGSize = .zero
    @State private var escaped = false
    @State private var showCheck = false

    private let escapeRadius: CGFloat = 72
    private var state: DictationController.State { flow.controller.state }

    var body: some View {
        let dist = hypot(drag.width, drag.height)
        let pull = min(1, dist / escapeRadius)          // 0…1 tether strain
        row
            .offset(rubberBand(drag))
            .scaleEffect(1 + pull * 0.06)
            .opacity(1 - Double(pull) * 0.15)
            .shadow(color: .black.opacity(Double(pull) * 0.25), radius: 8 + pull * 8, y: 3)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        drag = v.translation
                        if !escaped, hypot(v.translation.width, v.translation.height) > escapeRadius {
                            escaped = true               // snap! - pop out under the cursor
                            flow.detachPill()
                            drag = .zero
                        }
                    }
                    .onEnded { _ in
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.55)) { drag = .zero }
                        escaped = false
                    }
            )
            .help("Hold Fn to dictate · drag out to float the pill")
            .onChange(of: state) { old, new in
                if old == .inserting, new == .idle, flow.controller.lastError == nil {
                    showCheck = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        showCheck = false
                    }
                }
            }
    }

    private var row: some View {
        HStack(spacing: 8) {
            if showCheck {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.bounce, value: showCheck)
                Text("Inserted").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                switch state {
                case .idle:
                    Image(systemName: "mic")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Flow").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    keycap("Fn")
                case .recording:
                    ScrollingWaveform(history: flow.levelHistory, compact: true)
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(flow.controller.handsFree ? "\(flow.languageLabel) ∞" : flow.languageLabel)
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        RecordingTimer(since: flow.recordStartedAt)
                    }
                case .processing, .inserting:
                    ThinkingDots()
                    Text("Transcribing…").font(.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(.quinary))
        .overlay {
            if state == .recording {
                // Aurora rim while listening - the row visibly comes alive.
                Capsule()
                    .strokeBorder(
                        AngularGradient(colors: FlowAurora.colors(dark: scheme == .dark), center: .center),
                        lineWidth: 1.2)
                    .opacity(0.55 + Double(flow.level) * 0.45)
                    .animation(reduceMotion ? nil : .spring(duration: 0.2), value: flow.level)
                    .transition(.opacity)
            } else {
                Capsule().strokeBorder(.quaternary.opacity(0.4), lineWidth: 0.5)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25, extraBounce: 0.12), value: state)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25, extraBounce: 0.12), value: showCheck)
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    /// Magnetic tether: full movement for the first few points, then a
    /// square-root falloff - it visibly "resists" until the escape radius.
    private func rubberBand(_ t: CGSize) -> CGSize {
        let d = hypot(t.width, t.height)
        guard d > 0 else { return .zero }
        let pulled = 14 + (d - 14 > 0 ? sqrt(d - 14) * 4.2 : 0)
        let f = min(d, pulled) / d
        return CGSize(width: t.width * f, height: t.height * f)
    }
}

// MARK: - Shared pill core (both states render this)

/// Pill choreography - every animation is state- or data-driven, nothing loops
/// for decoration's sake:
///   idle       → small pill, softly pulsing mic glyph
///   recording  → pill springs wider; a voice-lit halo breathes behind it and
///                a SCROLLING waveform draws the real mic levels + mm:ss timer
///   processing → bars hand over to three thinking dots
///   inserted   → a bouncing checkmark flashes, then the pill settles to idle
struct FlowPillCore: View {
    @Environment(FlowRuntime.self) private var flow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = false
    @State private var showCheck = false

    private var state: DictationController.State { flow.controller.state }

    var body: some View {
        ZStack {
            // Voice halo: brightness + size ride the live mic level.
            if state == .recording {
                Capsule()
                    .fill(.white.opacity(0.08 + Double(flow.level) * 0.22))
                    .frame(width: compact ? 150 : 190, height: compact ? 40 : 46)
                    .blur(radius: 16)
                    .scaleEffect(1 + CGFloat(flow.level) * 0.22)
                    .animation(reduceMotion ? nil : .spring(duration: 0.22), value: flow.level)
                    .transition(.opacity)
            }
            pill
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.18), value: state)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.18), value: showCheck)
        .onChange(of: state) { old, new in
            // .inserting → .idle with no error = the text landed. Celebrate briefly.
            if old == .inserting, new == .idle, flow.controller.lastError == nil {
                showCheck = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    showCheck = false
                }
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 9) {
            if showCheck {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .symbolEffect(.bounce, value: showCheck)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                switch state {
                case .idle:
                    if reduceMotion {
                        Image(systemName: "mic")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "mic")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse.byLayer, options: .repeat(.continuous))
                    }
                    Text("Fn").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                case .recording:
                    ScrollingWaveform(history: flow.levelHistory, compact: compact)
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(flow.controller.handsFree ? "\(flow.languageLabel) · ∞" : flow.languageLabel)
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        RecordingTimer(since: flow.recordStartedAt)
                    }
                case .processing, .inserting:
                    ThinkingDots()
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    Text("…").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, state == .recording ? 16 : 13)
        .frame(height: compact ? 32 : 38)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                .white.opacity(state == .recording ? 0.16 + Double(flow.level) * 0.3 : 0.08),
                lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.28), radius: 11, y: 3)
        .scaleEffect(state == .recording ? 1.04 : 1.0)
    }
}

/// A live scope, not an equalizer prop: each bar is one recent RMS reading from
/// the mic (newest on the right), so speech visibly travels through the pill.
struct ScrollingWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var history: [Float]
    var compact = false
    private var barCount: Int { compact ? 12 : 16 }

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                let idx = history.count - barCount + i
                let lvl: Float = idx >= 0 && idx < history.count ? history[idx] : 0
                Capsule()
                    .fill(.primary.opacity(0.45 + Double(lvl) * 0.55))
                    .frame(width: 2.5, height: 4 + CGFloat(min(1, lvl)) * (compact ? 20 : 26))
            }
        }
        .frame(height: compact ? 26 : 32)
        .animation(reduceMotion ? nil : .spring(duration: 0.18), value: history)
    }
}

/// mm:ss since recording began - quiet, monospaced, no drama.
struct RecordingTimer: View {
    var since: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since ?? ctx.date)))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

/// Three dots breathing in sequence while Parakeet + the LLM do their work.
struct ThinkingDots: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(reduceMotion ? 1 : (on ? 1.0 : 0.5))
                    .opacity(reduceMotion ? 0.7 : (on ? 1 : 0.35))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
    }
}
