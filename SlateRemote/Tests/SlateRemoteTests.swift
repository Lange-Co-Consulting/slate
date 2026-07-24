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
        XCTAssertEqual(MacStatus.sleeping.action, "Wake Mac")
        XCTAssertEqual(MacStatus.offline.action, "Wake Mac")
        XCTAssertEqual(MacStatus.wakeFailed.action, "Retry")
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
        XCTAssertEqual(app.currentModel, "Qwen2.5-Coder 32B")
    }

    func testPairingCodeParses() {
        let payload = PairingPayload(name: "LUCC's MacBook Pro", psk: Data(repeating: 7, count: 32))
        let parsed = PairingPayload(code: payload.encodedCode())
        XCTAssertEqual(parsed?.name, "LUCC's MacBook Pro")
        XCTAssertEqual(parsed?.psk.count, 32)
    }
    func testGarbageCodeReturnsNil() { XCTAssertNil(PairingPayload(code: "not-base64!!")) }
}
