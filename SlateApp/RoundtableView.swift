import SwiftUI
import SlateUI
import SlateCore

/// A model that can take a roundtable seat: a downloaded local GGUF, or a cloud
/// seat (provider with a key / OpenCode model / Claude Code). Built by
/// `AppModel.roundtableCandidates`.
struct RoundtableCandidate: Identifiable, Equatable {
    let ref: String        // local file path | "cloud:<id>" | "opencode:<id>" | "claude-code"
    let name: String
    let detail: String     // "3.8 GB" for local, "Cloud" for remote
    let sizeGB: Double      // 0 for cloud seats
    let isLocal: Bool
    var id: String { ref }
}

/// Per-speaker seat colors: a small, curated, cool-leaning set (to sit with
/// Slate's navy theme) rather than a full hue-wheel rainbow. Tuned per light/dark
/// so each reads cleanly as a name label or a thin rule against the bubble.
/// Shared by the setup dots, the transcript rule, and the name labels.
enum SpeakerStyle {
    private static let hues: [Double] = [0.60, 0.47, 0.11, 0.97, 0.34, 0.73]  // steel, teal, ochre, rose, sage, violet

    static func color(_ index: Int, scheme: ColorScheme) -> Color {
        let h = hues[index % hues.count]
        let dark = scheme == .dark
        // Deep + saturated enough to read as text on the pale light bubble;
        // brighter + softer on the near-black dark bubble.
        return Color(hue: h, saturation: dark ? 0.46 : 0.60, brightness: dark ? 0.82 : 0.48)
    }

    /// A brighter, more luminous version of the seat color for the aurora orb (which
    /// glows on a dark canvas), independent of the text-tuned `color(_:)`.
    static func aura(_ index: Int, scheme: ColorScheme) -> Color {
        Color(hue: hues[index % hues.count], saturation: 0.72, brightness: scheme == .dark ? 0.98 : 0.86)
    }

    /// Short display name for a roundtable seat, from its model ref.
    static func seatName(_ ref: String) -> String {
        if ref.hasPrefix("cloud:") { return String(ref.dropFirst(6)) }
        if ref == "claude-code" { return "Claude Code" }
        if ref.hasPrefix("opencode:") { return String(ref.dropFirst(9)) }
        return ModelName.pretty(URL(fileURLWithPath: ref).lastPathComponent)
    }
}

/// A small aurora "seat" orb tinted to the speaker colour. It blooms + pulses while
/// that seat is speaking and dims at rest - the visible signal of whose turn it is.
struct RoundtableSeatOrb: View {
    let color: Color
    let active: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !active)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            let pulse = active ? 1 + 0.07 * sin(t * 3.1) : 1
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(active ? 0.95 : 0.55), color.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 16))
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(active ? 0.9 : 0.4), .clear],
                                         center: .center, startRadius: 0, endRadius: 5))
                    .frame(width: 11, height: 11)
            }
            .frame(width: 26, height: 26)
            .scaleEffect(pulse)
            .shadow(color: color.opacity(active ? 0.6 : 0), radius: active ? 9 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// "The Table": a pinned rail of the seated models as aurora orbs. The active
/// speaker's orb blooms while the others dim, so turn-taking is visible at a glance.
struct RoundtableSeatRail: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let refs: [String]
    let activeSeat: Int?      // 0-based seat currently speaking, or nil
    let synthesizing: Bool    // the closing synthesis turn is streaming
    /// true when the rail lives inside the merged agent header (no own glass).
    var embedded = false
    /// Live round progress while the roundtable runs (nil when idle/synthesis).
    var round: Int? = nil
    var totalRounds: Int = 0

    @ViewBuilder
    var body: some View {
        if embedded {
            core
        } else {
            core
                .padding(.horizontal, 16).padding(.vertical, 8)
                .clearGlass(Capsule(style: .continuous))
        }
    }

    private var core: some View {
        HStack(spacing: 12) {
            ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                let active = activeSeat == i
                HStack(spacing: 7) {
                    RoundtableSeatOrb(color: SpeakerStyle.aura(i, scheme: scheme), active: active, reduceMotion: reduceMotion)
                    Text(SpeakerStyle.seatName(ref))
                        .font(.caption.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.primary : .secondary)
                        .lineLimit(1)
                }
                // Dim the seats that aren't speaking while someone is; all equal at rest.
                .opacity((activeSeat == nil && !synthesizing) || active ? 1 : 0.5)
                .animation(.smooth(duration: 0.3), value: activeSeat)
                if i < refs.count - 1 {
                    Image(systemName: "circle.fill").font(.system(size: 3)).foregroundStyle(.quaternary)
                }
            }
            if synthesizing {
                Image(systemName: "circle.fill").font(.system(size: 3)).foregroundStyle(.quaternary)
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary)
                    Text("Synthesis").font(.caption.weight(.semibold)).foregroundStyle(Color.primary)
                }
            }
            Spacer(minLength: 8)
            if let round, totalRounds > 0, !synthesizing {
                Text("Round \(round)/\(totalRounds)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary.opacity(0.5)))
                    .accessibilityLabel("Round \(round) of \(totalRounds)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Roundtable seats: \(refs.map(SpeakerStyle.seatName).joined(separator: ", "))")
    }
}

/// A quiet chapter mark between rounds, so the debate's structure is readable.
struct RoundtableRoundDivider: View {
    let round: Int
    var body: some View {
        HStack(spacing: 10) {
            line
            Text("ROUND \(round)")
                .font(.caption2.weight(.semibold)).tracking(1.5)
                .foregroundStyle(.tertiary).fixedSize()
            line
        }
        .padding(.vertical, 2)
        .accessibilityLabel("Round \(round)")
    }
    private var line: some View {
        Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: .infinity)
    }
}

/// The closing synthesis, rendered as a distinct elevated "verdict" card (aurora
/// hairline + sparkles) so it reads as the group's conclusion, not another turn.
struct RoundtableSynthesisCard: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.caption)
                Text("SYNTHESIS").font(.caption2.weight(.semibold)).tracking(1.5)
            }
            .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
            .fill((scheme == .dark ? Color.white : Color.black).opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color(hue: 0.60, saturation: 0.7, brightness: 0.95).opacity(0.55),
                                                  Color(hue: 0.73, saturation: 0.6, brightness: 0.95).opacity(0.35),
                                                  Color(hue: 0.34, saturation: 0.6, brightness: 0.9).opacity(0.45)],
                                         startPoint: .leading, endPoint: .trailing), lineWidth: 1))
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
    }
}

/// A roundtable's opening prompt, shown as a quiet centered header ("the question
/// on the table") instead of a saturated chat bubble - always high-contrast and
/// readable, and it never reads as one participant's message.
struct RoundtableTopicHeader: View {
    let text: String
    var body: some View {
        VStack(spacing: 7) {
            Text("TOPIC")
                .font(.caption2.weight(.semibold)).tracking(1.5)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 22).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }
}

/// Agent Chat setup: pick 2-3 models, give each an optional persona, choose the
/// number of rounds and whether to close with a synthesis, then start. Shown
/// full-screen for a fresh session and as a sheet when reconfiguring an existing
/// roundtable.
struct RoundtableSetup: View {
    let convo: Conversation
    var isSheet: Bool = false
    var onDone: (() -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    @State private var selected: [String]           // model refs, in seat order
    @State private var personas: [String: String]
    @State private var rounds: Int
    @State private var synthesis: Bool
    @State private var topic: String = ""

    init(convo: Conversation, isSheet: Bool = false, onDone: (() -> Void)? = nil) {
        self.convo = convo
        self.isSheet = isSheet
        self.onDone = onDone
        _selected = State(initialValue: convo.agentModels)
        _rounds = State(initialValue: convo.agentRounds < 1 ? 3 : convo.agentRounds)
        _synthesis = State(initialValue: convo.agentSynthesis)
        var p: [String: String] = [:]
        for (i, ref) in convo.agentModels.enumerated() where i < convo.agentPersonas.count {
            p[ref] = convo.agentPersonas[i]
        }
        _personas = State(initialValue: p)
    }

    private var candidates: [RoundtableCandidate] { model.roundtableCandidates }
    /// Freemium seat cap: Free 2, Pro 3. Synthesis is Pro-only.
    private var modelCap: Int { model.pro.roundtableModelCap }
    /// Pro has no fixed seat limit (`.max`); the RAM readout + preflight are the
    /// real guard. Free is capped at 2.
    private var unlimitedSeats: Bool { modelCap == .max }
    private var synthesisAllowed: Bool { model.pro.roundtableSynthesisAllowed }
    private var canProceed: Bool { selected.count >= 2 && selected.count <= modelCap }
    private var canStart: Bool {
        canProceed && !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isGenerating && !model.roundtableActive
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !isSheet { intro; howItWorks }
                    participants
                    if !candidates.filter(\.isLocal).isEmpty || !selected.isEmpty { ramReadout }
                    rounds_
                    Toggle(isOn: Binding(
                        get: { synthesis && synthesisAllowed },
                        set: { on in
                            if on && !synthesisAllowed { model.requirePro(.agents); return }
                            synthesis = on
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Close with a synthesis").font(.callout.weight(.medium))
                                if !synthesisAllowed {
                                    Text("PRO").font(.caption2.weight(.bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("A final turn where the first seat summarizes the discussion and gives the group's best combined answer.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityLabel("Close with a synthesis")
                    .accessibilityHint("Adds a final turn where the first participant combines the discussion")
                    if !isSheet { topicField }
                }
                .padding(isSheet ? 22 : 32)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, isSheet ? 0 : 84)   // clear the floating agent header
            }
            footer
        }
        .onAppear {
            // Align a Pro-authored config down to the Free tier when opened by a
            // Free user (e.g. after a licence lapses): trim extra seats + synthesis.
            if selected.count > modelCap { selected = Array(selected.prefix(modelCap)) }
            if !synthesisAllowed { synthesis = false }
        }
    }

    // MARK: Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Roundtable").font(.largeTitle.weight(.semibold))
            Text("Let several models discuss a topic in turns - each one sees the others' points and builds on them. Everything runs locally unless you add a cloud seat.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Quick onboarding: what the four setup choices actually do.
    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 11) {
            onboardRow("theatermasks", "Roles",
                       "Give a seat an optional stance - “the skeptic”, “the optimist” - to shape how it argues.")
            onboardRow("arrow.triangle.2.circlepath", "Rounds",
                       "How many times each model speaks before the discussion ends.")
            onboardRow("sparkles", "Synthesis",
                       "An optional final turn that merges the discussion into one combined answer.")
            onboardRow("memorychip", "Runs on your Mac",
                       "Small models fit best - 2-3 at once. The estimate below shows the memory they use.")
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: DS.R.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func onboardRow(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var participants: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Participants").font(.headline)
                Spacer()
                Text(unlimitedSeats ? "\(selected.count)" : "\(selected.count)/\(modelCap)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if candidates.isEmpty {
                emptyCandidates
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedCandidates, id: \.label) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(group.label.uppercased())
                                    .font(.caption2.weight(.semibold)).tracking(1.2)
                                Text(group.hint).font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                            VStack(spacing: 8) {
                                ForEach(group.items) { c in candidateRow(c) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Group the models by rough size class so it's obvious which will run several
    /// at once. Local models bucket by file size (a good proxy for RAM); cloud
    /// seats form their own group since they cost no local memory.
    private var groupedCandidates: [(label: String, hint: String, items: [RoundtableCandidate])] {
        let local = candidates.filter { $0.isLocal }
        let cloud = candidates.filter { !$0.isLocal }
        var groups: [(String, String, [RoundtableCandidate])] = []
        let small = local.filter { $0.sizeGB > 0 && $0.sizeGB < 3.5 }
        let medium = local.filter { $0.sizeGB >= 3.5 && $0.sizeGB < 9 }
        let large = local.filter { $0.sizeGB >= 9 }
        if !small.isEmpty  { groups.append(("Small",  "best chance for 2-3 seats", small)) }
        if !medium.isEmpty { groups.append(("Medium", "usually one seat, check the estimate", medium)) }
        if !large.isEmpty  { groups.append(("Large",  "usually too heavy for a roundtable", large)) }
        if !cloud.isEmpty  { groups.append(("Cloud",  "no local memory", cloud)) }
        return groups.map { (label: $0.0, hint: $0.1, items: $0.2) }
    }

    private var emptyCandidates: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No models available yet.").font(.callout.weight(.medium))
            Text("Download at least two local models (or enable Cloud in Settings) to hold a roundtable.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Get models") { model.showModelManager = true }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: DS.R.card, style: .continuous))
    }

    @ViewBuilder
    private func candidateRow(_ c: RoundtableCandidate) -> some View {
        let seat = selected.firstIndex(of: c.ref)
        let isOn = seat != nil
        let full = !isOn && !unlimitedSeats && selected.count >= 3
        VStack(alignment: .leading, spacing: 8) {
            Button { toggle(c.ref) } label: {
                HStack(spacing: 11) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isOn ? (seat.map { SpeakerStyle.color($0, scheme: scheme) } ?? .accentColor) : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(c.isLocal ? c.detail : "Runs in the cloud")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let seat {
                        Text("Seat \(seat + 1)").font(.caption2.weight(.medium))
                            .foregroundStyle(SpeakerStyle.color(seat, scheme: scheme))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(full)
            .opacity(full ? 0.4 : 1)

            if isOn {
                TextField("Optional persona - e.g. \"the skeptic\", \"the pragmatist\"",
                          text: personaBinding(c.ref))
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, 29)
                    .accessibilityLabel("\(c.name) persona")
                    .accessibilityHint("Optional role or point of view for this participant")
            }
        }
        .padding(12)
        .background((isOn ? (seat.map { SpeakerStyle.color($0, scheme: scheme).opacity(scheme == .dark ? 0.12 : 0.08) } ?? Color.clear) : Color.clear),
                    in: RoundedRectangle(cornerRadius: DS.R.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private var ramReadout: some View {
        let localSizes = selected.compactMap { ref -> Double? in
            guard let candidate = candidates.first(where: { $0.ref == ref }), candidate.isLocal else { return nil }
            return candidate.sizeGB
        }
        let localGB = Roundtable.estimatedLocalMemoryGB(fileSizesGB: localSizes)
        let localCount = selected.filter { ref in candidates.first(where: { $0.ref == ref })?.isLocal == true }.count
        let freeGB = max(0, model.ram.totalGB - model.ram.usedGB) + residentGB
        let tight = localGB > 0 && localGB > freeGB - 2.0
        return HStack(spacing: 8) {
            Image(systemName: tight ? "exclamationmark.triangle.fill" : "memorychip")
                .foregroundStyle(tight ? Color.orange : Color.secondary)
            if localCount == 0 {
                Text("Cloud seats only - no local RAM needed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(String(format: "≈%.1f GB estimated across %d local model%@ (8K context each) · ~%.0f GB free",
                            localGB, localCount, localCount == 1 ? "" : "s", freeGB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tight ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var rounds_: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rounds").font(.callout.weight(.medium))
                Text("How many times each model speaks.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Stepper(value: $rounds, in: 1...5) {
                Text("\(rounds)").font(.body.monospacedDigit().weight(.medium))
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Rounds")
            .accessibilityValue("\(rounds)")
            Text("\(rounds)").font(.body.monospacedDigit().weight(.medium)).frame(width: 18)
        }
    }

    private var topicField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Topic").font(.headline)
            TextField("What should the models discuss?", text: $topic, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.R.pill, style: .continuous))
                .accessibilityLabel("Roundtable topic")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isSheet {
                Button("Cancel") { onDone?() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save(); onDone?() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
            } else {
                Spacer()
                Button {
                    save()
                    let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                    topic = ""
                    model.runRoundtable(topic: t, in: convo.id)
                } label: {
                    Label("Start roundtable", systemImage: "person.3.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStart)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, isSheet ? 22 : 32)
        .padding(.vertical, 16)
        .background(.bar)
    }

    // MARK: Helpers

    private var residentGB: Double {
        guard let u = model.activeModelURL,
              let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return 0 }
        return Double(sz) / 1_073_741_824
    }

    private func toggle(_ ref: String) {
        if let i = selected.firstIndex(of: ref) {
            selected.remove(at: i)
        } else if selected.count < modelCap {
            selected.append(ref)
        } else if selected.count < 3 {
            // Blocked by the Free 2-seat cap - offer the 3rd seat with Pro.
            model.requirePro(.agents)
        }
    }

    private func personaBinding(_ ref: String) -> Binding<String> {
        Binding(get: { personas[ref] ?? "" }, set: { personas[ref] = $0 })
    }

    private func save() {
        let personaArr = selected.map { personas[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        model.setAgentConfig(models: selected, personas: personaArr,
                             rounds: rounds, synthesis: synthesis, for: convo.id)
    }
}
