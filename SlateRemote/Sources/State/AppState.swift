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
    var action: String? {
        switch self {
        case .sleeping, .offline: return "Wake Mac"
        case .wakeFailed:         return "Retry"
        default:                  return nil
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
    var model: String
    var messages: [ChatMessage]
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
///    PSK WebSocket to the paired Mac, and streams tokens. `connect(using:)` flips
///    the app into this mode; the banner + model picker then follow the real link.
@MainActor @Observable
final class AppState {
    // Onboarding
    enum Onboarding { case welcome, priming, scanning, entering, pairing, paired }
    var onboarding: Onboarding = .welcome
    var isPaired = false
    var pairingFailed = false          // expired / rotated / invalid code

    /// True while the in-app mock drives the UI (no real Mac). Cleared by `connect`.
    var isDemo = true

    // The real LAN client. Idle until `connect(using:)` starts it.
    @ObservationIgnored let client = RemoteClient()

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
    private let demoModels = ["Qwen2.5-Coder 32B", "Llama 3.3 70B", "Claude Sonnet (cloud)"]
    var models: [String] {
        guard !isDemo else { return demoModels }
        return client.models.map(\.label)
    }
    var currentModel = "Qwen2.5-Coder 32B"

    static let demoMac = PairedMac(name: "LUCC's MacBook Pro",
                                   fingerprint: "A4:2F:9C:11:5E:D0:73:88",
                                   pairedOn: "22 Jul 2026")
    var macs: [PairedMac] = [AppState.demoMac]

    var conversations: [Conversation] = [
        .init(title: "Q3 board deck outline",
              subtitle: "Summarised the six sections and drafted the intro",
              model: "Qwen2.5-Coder 32B",
              messages: [
                .init(role: .user, text: "Outline the Q3 board deck from the notes in ~/decks."),
                .init(role: .assistant, text: "Six sections: (1) Headline metrics, (2) Revenue vs. plan, (3) Product velocity, (4) Hiring, (5) Risks, (6) Asks. I drafted the intro — want me to expand section 2?")
              ]),
        .init(title: "EU AI Act — obligations",
              subtitle: "Which articles apply to a local-inference app",
              model: "Llama 3.3 70B",
              messages: [
                .init(role: .user, text: "Which EU AI Act obligations apply to an app that runs models locally?")
              ]),
        .init(title: "Refactor AudioCapture",
              subtitle: "Made the tap closure @Sendable",
              model: "Qwen2.5-Coder 32B",
              messages: [])
    ]

    init() {
        // Auto-connect a returning user straight into the app. Guarded out of unit
        // tests (which construct `AppState()` and assert the pristine unpaired state)
        // via XCTest's env marker, so construction stays side-effect-free there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let payload = PairingStore.load() {
            connect(using: payload)
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

    /// Enter live mode: persist the pairing, start the client, and surface the Mac.
    func connect(using payload: PairingPayload) {
        PairingStore.save(payload)
        isDemo = false
        client.connect(using: payload)
        macs = [PairedMac(name: payload.name,
                          fingerprint: AppState.fingerprint(payload.psk),
                          pairedOn: AppState.todayString())]
        isPaired = true
    }

    // Demo controls (for the concept build — reach every state for review)
    func reset() {
        PairingStore.clear()
        isDemo = true
        demoMacStatus = .reachable
        macs = [AppState.demoMac]
        onboarding = .welcome
        isPaired = false
        pairingFailed = false
    }

    private static func fingerprint(_ psk: Data) -> String {
        psk.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    private static func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        return f.string(from: Date())
    }
}
