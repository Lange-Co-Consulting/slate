import XCTest
import SlateRemoteProtocol
@testable import SlateRemote

@MainActor
final class SlateRemoteTests: XCTestCase {

    func testMacStatusMetadataIsComplete() {
        for s in MacStatus.allCases {
            XCTAssertFalse(s.label.isEmpty, "\(s) has no label")
            XCTAssertFalse(s.detail.isEmpty, "\(s) has no detail")
            XCTAssertFalse(s.icon.isEmpty, "\(s) has no icon")
        }
    }

    func testActionableStatusesOfferAnAction() {
        // Offline says "Retry", not "Wake Mac". There is no Wake-on-LAN in the app, so the
        // old label named an ability it does not have — and against a live Mac the button
        // ran a demo-only animation and changed nothing at all.
        XCTAssertEqual(MacStatus.offline.action, "Retry")
        XCTAssertEqual(MacStatus.wakeFailed.action, "Retry")
        XCTAssertEqual(MacStatus.sleeping.action, "Wake Mac")
        XCTAssertNil(MacStatus.reachable.action)
        XCTAssertNil(MacStatus.connecting.action)
    }

    func testInitialStateIsUnpairedWelcome() {
        let app = AppState()
        XCTAssertFalse(app.isPaired)
        XCTAssertEqual(app.onboarding, .welcome)
        XCTAssertEqual(app.macStatus, .reachable)
        XCTAssertFalse(app.conversations.isEmpty, "seeded demo content expected")
        XCTAssertEqual(app.macs.count, 1)
    }

    func testResetReturnsToOnboarding() {
        let app = AppState()
        app.isPaired = true
        app.onboarding = .paired
        app.reset()
        XCTAssertFalse(app.isPaired)
        XCTAssertEqual(app.onboarding, .welcome)
        XCTAssertFalse(app.pairingFailed)
    }

    func testRevokingLastMacResetsPairing() {
        let app = AppState()
        app.isPaired = true
        app.macs.removeAll()
        // Mirrors MacSecurityDetail's revoke branch.
        if app.macs.isEmpty { app.reset() }
        XCTAssertFalse(app.isPaired)
    }

    func testModelCatalogHasExpectedContent() {
        let app = AppState()
        XCTAssertTrue(app.models.contains("Qwen2.5-Coder 32B"))
        XCTAssertEqual(app.defaultModel.label, "Qwen2.5-Coder 32B")
        // Unpaired, so there is no ref to send: the wire identifier only exists once a Mac
        // has told us its catalog.
        XCTAssertNil(app.defaultModel.ref)
    }

    /// A new chat must carry the model the user last chose, not a fixed demo string.
    func testNewConversationUsesRememberedModel() {
        let app = AppState()
        app.rememberModel(ref: nil, label: "Llama 3.3 70B")
        XCTAssertEqual(app.newConversation().modelLabel, "Llama 3.3 70B")
    }

    /// A named chat with no messages is not a scratch pad. Recycling it would drop the next
    /// turn into somebody else's conversation and leave its title describing the wrong thing.
    func testOnlyUntitledEmptyChatsCountAsBlank() {
        let app = AppState()
        XCTAssertTrue(app.newConversation().isBlank)
        let named = Conversation(title: "Refactor AudioCapture", subtitle: "",
                                 modelRef: nil, modelLabel: "m", messages: [])
        XCTAssertFalse(named.isBlank)
    }

    /// Sending must post the user's turn and open an assistant bubble to stream into,
    /// tracked on the app rather than on whichever view happens to be on screen.
    func testSendOpensAnAssistantTurnOwnedByTheApp() {
        let app = AppState()
        let convo = app.newConversation()
        app.conversations = [convo]
        app.send("hello", attachments: [], in: convo.id, shownAs: "hello")

        let messages = app.conversations[0].messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertTrue(messages[1].streaming)
        XCTAssertTrue(app.isStreaming(convo.id))

        app.stopRun(in: convo.id)
        XCTAssertFalse(app.isStreaming(convo.id))
    }

    /// Block syntax must not reach the screen as literal characters.
    func testProseBlocksAreClassifiedNotPrinted() {
        let lines = ProseLine.parse("## Findings\n- first\n- second\n\n> quoted\n1. one")
        XCTAssertEqual(lines[0].kind, .heading(level: 2))
        XCTAssertEqual(lines[0].text, "Findings")
        XCTAssertEqual(lines[1].kind, .bullet(depth: 0))
        XCTAssertEqual(lines[1].text, "first")
        XCTAssertEqual(lines[3].kind, .quote)
        XCTAssertEqual(lines[3].text, "quoted")
        XCTAssertEqual(lines[4].kind, .ordered(number: 1, depth: 0))
        XCTAssertEqual(lines[4].text, "one")
    }

    /// A lone asterisk is emphasis, not a list. Splitting on it would eat bold text.
    func testEmphasisIsNotMistakenForABullet() {
        let lines = ProseLine.parse("*emphasis* stays prose")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .paragraph)
    }

    func testPairingCodeParses() {
        let payload = PairingPayload(name: "LUCC's MacBook Pro", psk: Data(repeating: 7, count: 32))
        let parsed = PairingPayload(code: payload.encodedCode())
        XCTAssertEqual(parsed?.name, "LUCC's MacBook Pro")
        XCTAssertEqual(parsed?.psk.count, 32)
    }
    func testGarbageCodeReturnsNil() { XCTAssertNil(PairingPayload(code: "not-base64!!")) }
}
