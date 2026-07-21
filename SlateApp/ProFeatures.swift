import Foundation
import SwiftUI
import SlateCore
import SlateUI
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

    /// View-factory seam (Phase 3): the app renders a Pro feature's surface through
    /// this rather than constructing the Pro view directly. Free returns an upsell
    /// placeholder; official returns the real view. When a feature's view later moves
    /// physically into SlatePro, only this factory changes, not the call site.
    func imageSurface(_ convo: Conversation) -> AnyView
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
    func imageSurface(_ convo: Conversation) -> AnyView { AnyView(ProFeaturePlaceholder(feature: .image)) }
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
    var roundtableModelCap: Int { license.isPro ? .max : 2 }
    var roundtableSynthesisAllowed: Bool { license.isPro }
    func imageSurface(_ convo: Conversation) -> AnyView { AnyView(ImageSectionView(convo: convo)) }
}
#endif

/// The locked-feature surface shown in the free build where a Pro view would be.
/// Tapping "Unlock" opens the upsell sheet for that feature. Phase 3: as each Pro
/// view moves into SlatePro, the free build renders this instead, so no Pro feature
/// code remains in the public repo.
struct ProFeaturePlaceholder: View {
    @Environment(AppModel.self) private var model
    let feature: ProFeature
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: feature.icon).font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(feature.title).font(.title3.weight(.semibold))
            Text(feature.blurb).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Button("Unlock with Slate Pro") { model.proUpsell = feature }
                .buttonStyle(PaletteProminentButtonStyle()).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Marketing constants shown by the free-facing upsell (`ProUpsellView`), which must
/// compile without SlatePro. These mirror SlatePro's `LicenseConfig` display values;
/// the authoritative copies used by licensing logic live there.
enum ProInfo {
    static let buyProURL = URL(string: "https://slate-app.org/pricing")
    static let deviceLimit = 3
    static let trialDays = 14
}
