import Foundation
import SlateCore
#if SLATE_PRO
import SlatePro
#endif

/// The seam between the free, open-source app and the private paid layer (SlatePro).
///
/// Every Pro feature gate and every bit of licensing lifecycle the shared app code
/// touches routes through `AppModel.pro` (an `any ProFeatures`). The free build
/// injects `DefaultFreeProFeatures` (Pro capabilities → upsell, licensing inert);
/// the official/owner build injects `SlateProFeatures`, backed by SlatePro's
/// `LicenseService`.
///
/// `ProFeatures` lives in the app (not in SlatePro) on purpose: the free public
/// build must compile with no SlatePro source present, so the protocol the free
/// implementation conforms to cannot live in a module that build omits. The Pro
/// *views* stay in the app under `#if SLATE_PRO`; only the licensing *logic* is
/// private (in SlatePro).
@MainActor
protocol ProFeatures {
    /// The single entitlement question every feature gate asks.
    func allows(_ cap: SlateCapability) -> Bool
    /// Any paid entitlement (trial, pro, founder). Drives a few "is this a Pro user"
    /// UI affordances that aren't tied to one capability.
    var isPro: Bool { get }
    /// Mirror of Silent Mode onto the licensing network client (no-op when free).
    func setNetworkAccessAllowed(_ allowed: Bool)
    /// Throttled launch re-validation (no-op when free).
    func refreshIfDue() async
    /// Drop in-flight licensing state during "Delete all data" (no-op when free).
    func clearLocalStateForDataDeletion()
    /// Whether the one-time local Pro trial can still be started (false when free).
    var trialAvailable: Bool { get }
    /// Start the one-time local Pro trial (no-op when free).
    func startTrial()

    /// Roundtable is freemium: free gets a 2-model taste, Pro gets 3 seats + the
    /// closing synthesis turn. `roundtableModelCap` is the max number of seats and
    /// `roundtableSynthesisAllowed` whether the synthesis turn may run.
    var roundtableModelCap: Int { get }
    var roundtableSynthesisAllowed: Bool { get }
}

/// Free build: only free-tier capabilities are permitted, and every licensing
/// lifecycle call is inert — the free app has no licensing at all.
struct DefaultFreeProFeatures: ProFeatures {
    func allows(_ cap: SlateCapability) -> Bool { cap.minimumTier == .free }
    var isPro: Bool { false }
    func setNetworkAccessAllowed(_ allowed: Bool) {}
    func refreshIfDue() async {}
    func clearLocalStateForDataDeletion() {}
    var trialAvailable: Bool { false }
    func startTrial() {}
    var roundtableModelCap: Int { 2 }
    var roundtableSynthesisAllowed: Bool { false }
}

#if SLATE_PRO
/// Official/owner build: the seam is backed by SlatePro's private `LicenseService`.
struct SlateProFeatures: ProFeatures {
    let license: LicenseService
    func allows(_ cap: SlateCapability) -> Bool { license.entitlement.allows(cap) }
    var isPro: Bool { license.isPro }
    func setNetworkAccessAllowed(_ allowed: Bool) { license.networkAccessAllowed = allowed }
    func refreshIfDue() async { await license.refreshIfDue() }
    func clearLocalStateForDataDeletion() { license.clearLocalStateForDataDeletion() }
    var trialAvailable: Bool { license.trialAvailable }
    func startTrial() { license.startTrial() }
    var roundtableModelCap: Int { license.isPro ? 3 : 2 }
    var roundtableSynthesisAllowed: Bool { license.isPro }
}
#endif

/// Marketing constants shown by the free-facing upsell (`ProUpsellView`), which must
/// compile without SlatePro. These mirror SlatePro's `LicenseConfig` display values;
/// the authoritative copies used by licensing logic live there.
enum ProInfo {
    static let buyProURL = URL(string: "https://slate-app.org/pricing")
    static let deviceLimit = 3
    static let trialDays = 14
}
