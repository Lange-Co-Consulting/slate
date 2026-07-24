import SwiftUI
import Observation
import SlateRemoteProtocol

/// Reachability of the paired Mac — surfaced as a calm inline banner, never a modal.
enum MacStatus: String, CaseIterable {
    case reachable, connecting, offline, sleeping, waking, wakeFailed

    var label: String {
        switch self {
        case .reachable:  return "Connected"
        case .connecting: return "Connecting…"
        case .offline:    return "Mac offline"
        case .sleeping:   return "Mac asleep"
        case .waking:     return "Waking your Mac…"
        case .wakeFailed: return "Couldn't wake your Mac"
        }
    }
    var detail: String {
        switch self {
        case .reachable:  return "LUCC's MacBook Pro · local network"
        case .connecting: return "Finding your Mac on the network"
        case .offline:    return "It's not on this network right now"
        case .sleeping:   return "Wake it to run a prompt"
        case .waking:     return "This can take a few seconds"
        case .wakeFailed: return "Open the lid or check it's plugged in"
        }
    }
    var icon: String {
        switch self {
        case .reachable:  return "checkmark.circle.fill"
        case .connecting: return "dot.radiowaves.left.and.right"
        case .offline:    return "wifi.slash"
        case .sleeping:   return "moon.zzz.fill"
        case .waking:     return "sunrise.fill"
        case .wakeFailed: return "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .reachable:  return Theme.ok
        case .connecting, .waking: return Theme.warn
        case .offline, .wakeFailed: return Theme.danger
        case .sleeping:   return Theme.inkSecondary
        }
    }
    /// The banner's one action. Offline says "Retry", not "Wake Mac": there is no
    /// Wake-on-LAN here, and a button that names an ability the app does not have is worse
    /// than no button. `sleeping` and `wakeFailed` are only ever reached by the demo.
    var action: String? {
        switch self {
        case .offline, .wakeFailed: return "Retry"
        case .sleeping:             return "Wake Mac"
        default:                    return nil
        }
    }
}

struct ChatMessage: Identifiable, Equatable, Hashable {
    enum Role: Hashable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var streaming: Bool = false
    var tool: String? = nil   // inline agent activity, e.g. "Searching the web…"
}

struct Conversation: Identifiable, Equatable, Hashable {
    let id = UUID()
    var title: String
    var subtitle: String
    /// The Mac's identifier for the model — what actually goes on the wire. Nil until a Mac is
    /// paired and has sent its catalog. Kept separate from the label because a label never
    /// loaded a model: two Macs can show the same pretty name for different files.
    var modelRef: String?
    /// What the user sees.
    var modelLabel: String
    var messages: [ChatMessage]

    /// A chat that has never been used and carries no identity of its own. Only these may be
    /// recycled when the app wants "a chat to type into" — reusing any *empty* conversation
    /// would drop the next turn into a named one and leave its old title and subtitle
    /// describing a conversation that no longer exists.
    var isBlank: Bool { messages.isEmpty && title == Conversation.untitled }

    static let untitled = "New chat"
}

struct PairedMac: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var fingerprint: String
    var pairedOn: String
}

/// The app's state. Two modes share one shape:
///  • **Demo** (`isDemo == true`) — the concept made native, driven by an in-app
///    state machine so every screen is reviewable in the Simulator with no Mac.
///  • **Live** (`isDemo == false`) — a real `RemoteClient` browses Bonjour, opens a
///    PSK WebSocket to the paired Mac, and streams tokens. `beginPairing` flips the
///    app into this mode once the Mac has actually answered.
@MainActor @Observable
final class AppState {
    // Onboarding
    enum Onboarding { case welcome, priming, scanning, entering, pairing, paired }
    var onboarding: Onboarding = .welcome
    var isPaired = false
    /// Why a pairing attempt ended. The two causes need different words: a code we could not
    /// read is the user's clipboard or a foreign QR, while a code we read but could not use is
    /// almost always a revoked key or a Mac that is not reachable.
    enum PairingFailure { case unreadableCode, noAnswer }
    var pairingFailure: PairingFailure?
    var pairingFailed: Bool { pairingFailure != nil }

    /// True while the in-app mock drives the UI (no real Mac). Cleared once a Mac answers.
    var isDemo = true

    // The real LAN client. Idle until `beginPairing` starts it.
    @ObservationIgnored let client = RemoteClient()

    /// Everything the paired Mac has, across all of Slate's surfaces.
    let library = Library()

    // MARK: Runs in flight
    //
    // Run state lives here, not in ChatView, because the view is destroyed whenever the user
    // switches conversation or opens another surface. When ChatView owned it, navigating away
    // mid-answer had to kill the run to avoid orphaning it — so a long answer could not be left
    // alone for even a second. Keyed by conversation, so several can stream at once.

    /// Conversation → the assistant message currently being written into.
    var activeRun: [Conversation.ID: UUID] = [:]
    /// Conversation → a failed run's explanation, cleared on the next send.
    var runError: [Conversation.ID: String] = [:]
    /// Conversation → a transient "that's a Slate Pro feature" hint.
    var proNudge: [Conversation.ID: String] = [:]
    /// Demo-mode fake streams, cancellable per conversation.
    @ObservationIgnored var mockRuns: [Conversation.ID: Task<Void, Never>] = [:]

    func isStreaming(_ id: Conversation.ID) -> Bool { activeRun[id] != nil }

    // MARK: Connection status
    //
    // In demo mode the banner is whatever the demo controls set. In live mode it is
    // *derived* from the client's connection phase, so SwiftUI updates as the link
    // comes up / drops. The demo "Mac status" menu still writes `demoMacStatus`
    // (a no-op visually while live), so nothing about the concept build regresses.
    private var demoMacStatus: MacStatus = .reachable
    var macStatus: MacStatus {
        get {
            guard !isDemo else { return demoMacStatus }
            switch client.phase {
            case .idle, .browsing, .connecting: return .connecting
            case .ready:                        return .reachable
            case .offline:                      return .offline
            }
        }
        set { demoMacStatus = newValue }
    }

    // MARK: Models
    //
    // The picker shows the demo catalog until we're live, then the Mac's real models.
    private static let demoModels = ["Qwen2.5-Coder 32B", "Llama 3.3 70B", "Claude Sonnet (cloud)"]
    var models: [String] {
        guard !isDemo else { return AppState.demoModels }
        return client.models.map(\.label)
    }

    private var preferredRef: String?
    private var preferredLabel: String?

    /// The model a new chat starts on: whatever the user last picked, if the Mac still has it,
    /// else the Mac's first model. This used to be a hardcoded demo string, so every new chat
    /// on a real Mac opened claiming a model that Mac had most likely never heard of.
    var defaultModel: (ref: String?, label: String) {
        guard !isDemo else { return (nil, preferredLabel ?? AppState.demoModels[0]) }
        let catalog = client.models
        if let ref = preferredRef, let hit = catalog.first(where: { $0.ref == ref }) {
            return (hit.ref, hit.label)
        }
        guard let first = catalog.first else { return (nil, "No model") }
        return (first.ref, first.label)
    }

    /// Remember the user's pick so the next new chat opens on it.
    func rememberModel(ref: String?, label: String) {
        preferredRef = ref; preferredLabel = label
    }

    static let demoMac = PairedMac(name: "LUCC's MacBook Pro",
                                   fingerprint: "A4:2F:9C:11:5E:D0:73:88",
                                   pairedOn: "22 Jul 2026")
    var macs: [PairedMac] = [AppState.demoMac]

    var conversations: [Conversation] = [
        .init(title: "Q3 board deck outline",
              subtitle: "Summarised the six sections and drafted the intro",
              modelRef: nil, modelLabel: "Qwen2.5-Coder 32B",
              messages: [
                .init(role: .user, text: "Outline the Q3 board deck from the notes in ~/decks."),
                .init(role: .assistant, text: "Six sections: (1) Headline metrics, (2) Revenue vs. plan, (3) Product velocity, (4) Hiring, (5) Risks, (6) Asks. I drafted the intro. Want me to expand section 2?")
              ]),
        .init(title: "EU AI Act obligations",
              subtitle: "Which articles apply to a local-inference app",
              modelRef: nil, modelLabel: "Llama 3.3 70B",
              messages: [
                .init(role: .user, text: "Which EU AI Act obligations apply to an app that runs models locally?")
              ]),
        .init(title: "Refactor AudioCapture",
              subtitle: "Made the tap closure @Sendable",
              modelRef: nil, modelLabel: "Qwen2.5-Coder 32B",
              messages: [])
    ]

    init() {
        wireLibrary()
        wireRuns()
        #if DEBUG
        // Open straight into the main UI, still in demo mode, so every post-pairing screen can
        // be reviewed on a Simulator with no Mac on the network. Real pairing now waits for an
        // actual handshake, which is correct — but it also means the only route past onboarding
        // is a live Mac, and screenshots of the app should not require one.
        if ProcessInfo.processInfo.environment["SLATE_DEMO_PAIRED"] == "1" {
            isPaired = true
            onboarding = .paired
            return
        }
        #endif
        // Auto-connect a returning user straight into the app. Guarded out of unit
        // tests (which construct `AppState()` and assert the pristine unpaired state)
        // via XCTest's env marker, so construction stays side-effect-free there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let payload = PairingStore.load() {
            resume(with: payload)
        }
    }

    /// Write a conversation's latest state back into the list (ChatView edits a value copy,
    /// so without this its messages/title are lost on navigation). Keeps list position.
    func upsert(_ convo: Conversation) {
        if let i = conversations.firstIndex(where: { $0.id == convo.id }) {
            conversations[i] = convo
        } else {
            conversations.insert(convo, at: 0)
        }
    }

    /// Remove a conversation (chat-list swipe/context delete). Local removal only.
    func deleteConversation(_ id: Conversation.ID) {
        conversations.removeAll { $0.id == id }
    }

    /// A blank chat on the current default model.
    func newConversation() -> Conversation {
        let m = defaultModel
        return Conversation(title: Conversation.untitled, subtitle: "",
                            modelRef: m.ref, modelLabel: m.label, messages: [])
    }

    // MARK: - Pairing

    /// A pairing attempt in flight. The Mac has not answered yet.
    @ObservationIgnored private var pairingTask: Task<Void, Never>?

    /// Try a scanned or pasted code. **Nothing is persisted and the app does not enter the
    /// main UI until the Mac actually answers.** The old flow trusted the code's syntax alone,
    /// so a rotated or stale code — still perfectly well-formed — dropped the user into the app
    /// with a banner reading "Connecting…" forever and no route back to pairing.
    func beginPairing(with payload: PairingPayload) {
        pairingFailure = nil
        onboarding = .pairing
        isDemo = false
        client.connect(using: payload)

        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            // The handshake is TLS-PSK, so a wrong key fails the connection itself rather than
            // being refused at the app layer: "did it work" is "did we reach .ready".
            for _ in 0..<120 {                       // 12s, polled every 100ms
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if self.client.phase == .ready { self.confirmPaired(payload); return }
            }
            guard let self, !Task.isCancelled else { return }
            self.failPairing()
        }
    }

    private func confirmPaired(_ payload: PairingPayload) {
        pairingTask = nil
        PairingStore.save(payload)
        // Drop the seeded sample conversations. They exist so the concept build can be
        // reviewed without a Mac; leaving them after pairing put three fabricated chats in
        // a real user's list, indistinguishable from their own.
        conversations.removeAll()
        library.reset()
        macs = [PairedMac(name: client.macName.isEmpty ? payload.name : client.macName,
                          fingerprint: AppState.fingerprint(payload.psk),
                          pairedOn: AppState.todayString())]
        onboarding = .paired
        isPaired = true
        pairingFailure = nil
        loadLibrary(.chat)
    }

    private func failPairing() {
        pairingTask = nil
        client.disconnect()
        isDemo = true
        pairingFailure = .noAnswer
        onboarding = .pairing
    }

    /// The code itself did not parse, so nothing was ever attempted.
    func failPairingUnreadable() {
        pairingFailure = .unreadableCode
        onboarding = .pairing
    }

    /// A pairing we already completed once. No probation here: the app opens straight away and
    /// the status banner carries the connection state, because making a returning user watch a
    /// spinner before their own chats would be worse than showing them an offline Mac.
    private func resume(with payload: PairingPayload) {
        isDemo = false
        conversations.removeAll()
        client.connect(using: payload)
        macs = [PairedMac(name: payload.name,
                          fingerprint: AppState.fingerprint(payload.psk),
                          pairedOn: AppState.todayString())]
        isPaired = true
    }

    // MARK: - Library

    /// Route the Mac's browsing replies into the library. Bound once, unlike the per-run
    /// streaming callbacks that ChatView rebinds as it comes and goes.
    private func wireLibrary() {
        client.onConversations = { [weak self] items in
            guard let self else { return }
            self.library.items = items
            self.library.loading = false
        }
        client.onHistory = { [weak self] id, items in
            self?.library.history[id] = items
        }
    }

    /// Ask the Mac for its conversations of one kind. A Mac that predates v2 cannot answer, so
    /// say so rather than leave a spinner running against a peer that will never reply.
    func loadLibrary(_ tab: LibraryTab) {
        guard !isDemo else { return }
        guard client.supportsV2 else {
            library.unsupported = true; library.loading = false; return
        }
        library.unsupported = false
        library.loading = true
        client.listConversations(kind: tab.wireKind)
    }

    /// Fetch one conversation's turns. Cached, so re-opening a thread shows it instantly and
    /// refreshes underneath.
    func openLibraryConversation(_ id: String) {
        guard !isDemo, client.supportsV2 else { return }
        client.openConversation(id: id)
    }

    /// What the status banner's button does. Against a real Mac it forces an immediate
    /// reconnect; the button used to run a 1.8-second animation that flipped a demo-only
    /// variable, so on a live link pressing it did nothing whatsoever.
    func retryConnection() {
        guard !isDemo else {
            demoMacStatus = .waking
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.8))
                self?.demoMacStatus = .reachable
            }
            return
        }
        client.retryNow()
    }

    // Demo controls (for the concept build — reach every state for review)
    func reset() {
        PairingStore.clear()
        pairingTask?.cancel(); pairingTask = nil
        client.disconnect()
        library.reset()
        isDemo = true
        demoMacStatus = .reachable
        macs = [AppState.demoMac]
        onboarding = .welcome
        isPaired = false
        pairingFailure = nil
    }

    private static func fingerprint(_ psk: Data) -> String {
        psk.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    private static func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        return f.string(from: Date())
    }
}
