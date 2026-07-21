import SwiftUI
import SlateUI
import SlateCore

/// Immersive voice mode: a reactive Siri-tone aurora with a live transcript and
/// minimal controls. The aurora IS the state indicator - it breathes while listening,
/// swirls while thinking, and blooms while Slate speaks. Adapts to light and dark:
/// a glowing additive orb on a dark canvas, a soft frosted orb on a light one.
struct VoiceOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    let session: VoiceSession
    let onEnd: () -> Void

    private var ink: Color { scheme == .dark ? .white : Color(red: 0.11, green: 0.12, blue: 0.18) }

    private var messages: [ChatMessage] {
        (model.conversations.first { $0.id == session.convoID }?.messages ?? [])
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
    }

    var body: some View {
        ZStack {
            VoiceBackdrop(state: liveState, scheme: scheme)
            content
        }
        .transition(.opacity)
        .onExitCommand(perform: onEnd)
    }

    private var liveState: VoiceTurnMachine.State {
        if case .live = session.phase { return session.machineState }
        return .thinking
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .chooseVoice:      chooseVoice
        case .preparing(let p): preparing(p)
        case .failed(let msg):  failed(msg)
        case .live:             live
        }
    }

    // MARK: first-launch voice choice

    @State private var pickedVoice = "M1"
    @State private var previewID = UUID()

    private struct VoiceOption: Identifiable {
        let id: String; let name: String; let detail: String
    }
    private var voiceOptions: [VoiceOption] {
        var opts: [VoiceOption] = [
            .init(id: "M1", name: "Male", detail: "Neural · on-device"),
            .init(id: "F1", name: "Female", detail: "Neural · on-device"),
        ]
        if let sys = SystemTTS.defaultVoiceID {
            opts.append(.init(id: sys, name: "macOS voice", detail: "Instant · no download"))
        }
        return opts
    }

    private var chooseVoice: some View {
        VStack(spacing: 26) {
            AuroraOrb(state: .idle, level: 0, muted: false, reduceMotion: reduceMotion, scheme: scheme)
                .frame(height: 190).scaleEffect(0.72)
            VStack(spacing: 6) {
                Text("Choose Slate's voice")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.94))
                Text("Listen and pick - you can change it anytime in Settings.")
                    .font(.callout).foregroundStyle(ink.opacity(0.6))
            }
            VStack(spacing: 10) {
                ForEach(voiceOptions) { opt in
                    Button {
                        pickedVoice = opt.id
                        // Preview through the read-aloud engine (falls back to a
                        // system voice while the neural model is not provisioned).
                        previewID = UUID()
                        model.speech.toggle("Hi! I'm Slate. This is how I sound.", id: previewID, voice: opt.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pickedVoice == opt.id ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(pickedVoice == opt.id ? ink : ink.opacity(0.35))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(opt.name).font(.callout.weight(.medium)).foregroundStyle(ink.opacity(0.92))
                                Text(opt.detail).font(.caption).foregroundStyle(ink.opacity(0.55))
                            }
                            Spacer()
                            Image(systemName: "speaker.wave.2")
                                .font(.system(size: 14)).foregroundStyle(ink.opacity(0.5))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(ink.opacity(pickedVoice == opt.id ? 0.12 : 0.055),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(ink.opacity(pickedVoice == opt.id ? 0.28 : 0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(opt.name), \(opt.detail)\(pickedVoice == opt.id ? ", selected" : "")")
                    .accessibilityHint("Plays a short preview and selects this voice")
                }
            }
            .frame(maxWidth: 380)
            Button { session.chooseVoice(pickedVoice) } label: {
                Text("Start voice chat")
                    .font(.callout.weight(.semibold)).foregroundStyle(ink)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Capsule().fill(ink.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(ink.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(36)
        .onAppear { pickedVoice = model.settings.assistantVoice }
    }

    // MARK: live

    private var live: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)
            AuroraOrb(state: session.machineState, level: session.micLevel,
                      muted: session.muted, reduceMotion: reduceMotion, scheme: scheme)
                .padding(.top, 20)
            Text(stateLabel)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.92))
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.25), value: stateLabel)
                .padding(.top, 10)
            Spacer(minLength: 4)
            transcript
            controls.padding(.vertical, 24)
        }
    }

    private var stateLabel: String {
        if session.muted { return "Muted" }
        switch session.machineState {
        case .listening:    return "Listening"
        case .transcribing: return "Transcribing…"
        case .thinking:     return "Thinking"
        case .speaking:     return "Speaking"
        case .idle:         return ""
        }
    }

    // MARK: live transcript (both sides, fades at the top)

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { m in line(role: m.role, text: m.content) }
                    if !session.liveResponse.isEmpty { line(role: .assistant, text: session.liveResponse) }
                    if session.machineState == .listening, !session.caption.isEmpty {
                        line(role: .user, text: session.caption, dim: true)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 34).padding(.vertical, 12)
                .frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 250)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.12),
                                         .init(color: .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: messages.count) { _, _ in withAnimation(.smooth) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: session.liveResponse) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: session.caption) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func line(role: ChatMessage.Role, text: String, dim: Bool = false) -> some View {
        let isUser = role == .user
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(isUser ? "YOU" : "SLATE")
                .font(.caption2.weight(.semibold)).tracking(1.0)
                .foregroundStyle(ink.opacity(0.36))
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(ink.opacity(dim ? 0.44 : 0.84))
                .multilineTextAlignment(isUser ? .trailing : .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 18) {
            circleButton(system: session.muted ? "mic.slash.fill" : "mic.fill",
                         help: session.muted ? "Unmute microphone" : "Mute microphone") {
                session.muted.toggle()
            }
            circleButton(system: "xmark", help: "End conversation (Esc)", prominent: true, action: onEnd)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func circleButton(system: String, help: String,
                              prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ink.opacity(0.92))
                .frame(width: 52, height: 52)
                .background(ink.opacity(prominent ? 0.15 : 0.08), in: Circle())
                .overlay(Circle().stroke(ink.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .liquidHover(1.08)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: preparing / failed

    private func preparing(_ p: Double) -> some View {
        VStack(spacing: 22) {
            AuroraOrb(state: .thinking, level: 0, muted: false, reduceMotion: reduceMotion, scheme: scheme)
            ProgressView(value: p).frame(width: 200).tint(ink)
            Text("Preparing voice…").font(.callout).foregroundStyle(ink.opacity(0.7))
        }
    }

    private func failed(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(ink.opacity(0.8))
            Text(msg).font(.callout).foregroundStyle(ink.opacity(0.78))
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            Button("Close", action: onEnd)
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(ink.opacity(0.14)))
                .overlay(Capsule().strokeBorder(ink.opacity(0.18), lineWidth: 0.5))
        }.padding(40)
    }
}

// MARK: - Aurora orb

/// Reactive Siri-tone aurora: blurred multi-color blobs orbit a bright center. Swirl
/// speed + spread + glow rise with the conversation state and the live mic level, so
/// the orb visibly listens, thinks, and speaks. On dark it glows additively; on light
/// it reads as a soft frosted marble.
private struct AuroraOrb: View {
    let state: VoiceTurnMachine.State
    let level: Float
    let muted: Bool
    let reduceMotion: Bool
    let scheme: ColorScheme

    private struct Blob { let color: Color; let radius: CGFloat; let speed: Double; let phase: Double; let size: CGFloat }
    private let blobs: [Blob] = [
        .init(color: Color(red: 0.28, green: 0.60, blue: 1.00), radius: 34, speed:  0.55, phase: 0.0, size: 156),
        .init(color: Color(red: 0.58, green: 0.47, blue: 1.00), radius: 40, speed: -0.42, phase: 2.1, size: 146),
        .init(color: Color(red: 0.30, green: 0.85, blue: 0.80), radius: 30, speed:  0.72, phase: 4.0, size: 132),
        .init(color: Color(red: 1.00, green: 0.46, blue: 0.82), radius: 24, speed: -0.63, phase: 1.2, size: 100),
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion && state != .speaking)) { tl in
            orb(t: reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: 300, height: 300)
        .accessibilityHidden(true)
    }

    private var energy: CGFloat {
        if muted { return 0.08 }
        switch state {
        case .listening:    return 0.32
        case .transcribing: return 0.48
        case .thinking:     return 0.74
        case .speaking:     return 0.96
        case .idle:         return 0.20
        }
    }

    private func orb(t: TimeInterval) -> some View {
        let dark = scheme == .dark
        let lvl = min(1, CGFloat(level) * 1.5)
        let e = energy
        let pulse = 1 + 0.05 * sin(t * (state == .speaking ? 5.2 : 1.2))
        let scale = (0.84 + 0.16 * e + 0.16 * lvl) * pulse
        return ZStack {
            ForEach(blobs.indices, id: \.self) { i in
                let b = blobs[i]
                let a = t * b.speed * (0.6 + e) + b.phase
                let rr = b.radius * (1 + 0.55 * e + 0.30 * lvl)
                Circle()
                    .fill(RadialGradient(colors: [b.color.opacity(dark ? 0.9 : 0.85), b.color.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: b.size * 0.5))
                    .frame(width: b.size, height: b.size)
                    .offset(x: cos(a) * rr, y: sin(a * 1.25) * rr)
                    .blendMode(dark ? .plusLighter : .normal)
            }
        }
        .blur(radius: dark ? 22 : 26)
        .saturation(dark ? 1.0 : 1.15)
        .scaleEffect(scale)
        .overlay(core(dark: dark, lvl: lvl))
        .compositingGroup()
        .shadow(color: Color(red: 0.42, green: 0.48, blue: 0.95).opacity((dark ? 0.42 : 0.28) * (0.6 + e)),
                radius: dark ? 36 : 28, y: dark ? 0 : 8)
    }

    /// A soft luminous center. Dark: a white glow that adds to the aurora. Light: a
    /// gentle top specular so the frosted orb looks glossy, not flat.
    @ViewBuilder private func core(dark: Bool, lvl: CGFloat) -> some View {
        if dark {
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.5 + 0.25 * lvl), .white.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 54))
                .frame(width: 118, height: 118).blur(radius: 8)
        } else {
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.55), .white.opacity(0)],
                                     center: .init(x: 0.42, y: 0.36), startRadius: 0, endRadius: 90))
                .frame(width: 150, height: 150).blur(radius: 6).blendMode(.softLight)
        }
    }
}

// MARK: - Backdrop

/// The canvas the aurora sits on. Dark: near-black so the glow reads. Light: a soft
/// cool paper so the frosted orb reads. A faint top wash picks up the orb's state.
private struct VoiceBackdrop: View {
    let state: VoiceTurnMachine.State
    let scheme: ColorScheme

    var body: some View {
        ZStack {
            LinearGradient(colors: grounds, startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [wash.opacity(scheme == .dark ? 0.20 : 0.12), .clear],
                           center: .init(x: 0.5, y: 0.32), startRadius: 0, endRadius: 440)
        }
        .ignoresSafeArea()
    }

    private var grounds: [Color] {
        scheme == .dark
            ? [Color(red: 0.03, green: 0.03, blue: 0.06), Color(red: 0.06, green: 0.06, blue: 0.11)]
            : [Color(red: 0.93, green: 0.94, blue: 0.97), Color(red: 0.88, green: 0.89, blue: 0.94)]
    }

    private var wash: Color {
        switch state {
        case .speaking: return Color(red: 0.58, green: 0.47, blue: 1.0)
        case .thinking: return Color(red: 0.30, green: 0.85, blue: 0.80)
        default:        return Color(red: 0.28, green: 0.60, blue: 1.0)
        }
    }
}
