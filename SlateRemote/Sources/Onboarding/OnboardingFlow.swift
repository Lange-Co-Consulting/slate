import SwiftUI
import SlateRemoteProtocol

/// The pre-pairing journey: value-first welcome → permission priming → QR scan →
/// secure pairing → paired. A rotated/expired QR gets its own friendly recovery.
struct OnboardingFlow: View {
    @Environment(AppState.self) private var app
    var body: some View {
        ZStack {
            switch app.onboarding {
            case .welcome:  WelcomeView()
            case .priming:  PermissionPrimingView()
            case .scanning: QRScanView()
            case .entering: EnterCodeView()
            case .pairing:  PairingProgressView()
            case .paired:   PairedView()
            }
        }
        .canvas()
        .transition(.opacity)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            WeaveMark(size: 52)
            Text("Slate Remote")
                .font(.slate(34, .medium)).foregroundStyle(Theme.ink)
                .padding(.top, 18)
            Text("Your Mac runs the models.\nYour iPhone is the remote.\nNo account, no cloud, no subscription.")
                .font(.slate(17)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).lineSpacing(3)
                .padding(.top, 14).padding(.horizontal, 24)
            HStack(spacing: 8) {
                Chip(icon: "lock.fill", text: "On-device")
                Chip(icon: "wifi", text: "Local network")
            }
            .padding(.top, 26)
            Chip(icon: "square.stack.3d.up.fill", text: "Your models")
                .padding(.top, 8)
            Spacer(); Spacer()
            PrimaryButton(title: "Pair with your Mac", icon: "qrcode.viewfinder") {
                app.onboarding = .priming
            }
            .padding(.horizontal, 24)
            Text("Open Slate on your Mac to begin.")
                .font(.slate(14)).foregroundStyle(Theme.inkTertiary)
                .padding(.top, 14).padding(.bottom, 8)
        }
        .padding(.bottom, 24)
    }
}

// MARK: - Local Network permission priming (before the OS dialog)

struct PermissionPrimingView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Theme.surface).frame(width: 96, height: 96)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                Image(systemName: "wifi").font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Theme.ink)
            }
            Text("Find your Mac on Wi-Fi")
                .font(.slate(26, .medium)).foregroundStyle(Theme.ink).padding(.top, 22)
            Text("Slate Remote talks to your Mac directly over your local network. It never sends your prompts or answers to the internet.")
                .font(.slate(16)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).lineSpacing(3)
                .padding(.top, 12).padding(.horizontal, 28)
            // On-brand heads-up for the OS permission prompts, never a mock of them.
            LocalNetworkExplainerCard()
                .padding(.top, 22).padding(.horizontal, 24)
            Spacer()
            PrimaryButton(title: "Continue") { app.onboarding = .scanning }
                .padding(.horizontal, 24)
            Button("Not now") { app.onboarding = .welcome }
                .font(.slate(16)).foregroundStyle(Theme.inkSecondary)
                .padding(.top, 14).padding(.bottom, 8)
        }
        .padding(.bottom, 24)
    }
}

/// A Slate-styled explainer preparing the user for the OS-owned Local Network
/// permission alert (we never imitate system UI).
struct LocalNetworkExplainerCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised")
                .font(.slate(16, .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("iOS will ask for Local Network access. Choose “Allow” so your iPhone can find your Mac.")
                Text("The next screen opens the camera to scan the pairing code, so iOS will ask for that too.")
            }
            .font(.slate(14)).foregroundStyle(Theme.inkSecondary)
            .multilineTextAlignment(.leading).lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .slateCard(Theme.rControl)
    }
}

// MARK: - QR scan

struct QRScanView: View {
    @Environment(AppState.self) private var app
    @State private var sweep = false
    @State private var scan: ScanAvailability = .needsPermission
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.onboarding = .priming } label: {
                    Image(systemName: "chevron.left").font(.slate(18, .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Theme.ink)
                Spacer()
                Text("Scan to pair").font(.slate(17, .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Color.clear.frame(width: 44, height: 44)   // balances the back button
            }
            .padding(.horizontal, 8).padding(.top, 8)

            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.well)
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
                // The live camera when we have one; otherwise a quiet placeholder plus the
                // reason, so the manual path below reads as the intended route rather than
                // a workaround for something broken.
                if scan == .ready {
                    QRScannerView { code in handleScanned(code) }
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: scan == .denied ? "video.slash" : "qrcode")
                            .font(.system(size: 76, weight: .regular))
                            .foregroundStyle(Theme.inkTertiary.opacity(0.45))
                        Text(scanHint).font(.slate(14))
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                }
                // Fixed light stroke: the camera well is near-black in BOTH schemes,
                // so scheme-flipping ink would vanish in light mode.
                ReticleCorners()
                    .stroke(Color.white.opacity(0.85), style: .init(lineWidth: 3, lineCap: .round))
                    .frame(width: 210, height: 210)
                if scan != .ready {
                    Rectangle().fill(Color.white.opacity(0.55)).frame(width: 200, height: 2)
                        .offset(y: sweep ? 100 : -100)
                        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: sweep)
                }
            }
            .frame(height: 320)
            .padding(.horizontal, 24)
            .onAppear { sweep = true }
            .task {
                scan = ScanAvailability.current()
                if scan == .needsPermission { scan = await ScanAvailability.request() }
            }

            Text("Point at the QR code in Slate →\nSettings → Remote on your Mac.")
                .font(.slate(15)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).lineSpacing(2).padding(.top, 22)
            Spacer()
            // Real pairing entry — the Simulator has no camera, so pasting the Mac's
            // pairing code is how we pair (and the same code the QR encodes).
            PrimaryButton(title: "Enter code", icon: "keyboard") { app.onboarding = .entering }
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 24)
    }

    private var scanHint: String {
        switch scan {
        case .ready: ""
        case .needsPermission: "Asking for camera access…"
        case .denied: "Camera access is off. Turn it on in Settings, or enter the code below."
        case .unsupported: "This device has no scanner. Enter the code below."
        }
    }

    /// A scanned QR carries the same payload the "Enter code" field takes, so both paths land
    /// in exactly one place.
    private func handleScanned(_ code: String) {
        guard let payload = PairingPayload(code: code) else {
            app.failPairingUnreadable()
            return
        }
        app.beginPairing(with: payload)
    }
}

// MARK: - Enter pairing code (the real, camera-free pairing path)

/// Paste the Mac's pairing code (Slate → Settings → Remote). Decodes to a
/// `PairingPayload` and starts a live connection; a bad code routes to the
/// same friendly expired/invalid recovery the QR flow uses.
struct EnterCodeView: View {
    @Environment(AppState.self) private var app
    @State private var code = ""
    @FocusState private var focused: Bool
    private var trimmed: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.onboarding = .scanning } label: {
                    Image(systemName: "chevron.left").font(.slate(18, .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Theme.ink)
                Spacer()
                Text("Enter code").font(.slate(17, .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Color.clear.frame(width: 44, height: 44)   // balances the back button
            }
            .padding(.horizontal, 8).padding(.top, 8)

            Spacer()
            ZStack {
                Circle().fill(Theme.surface).frame(width: 88, height: 88)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                Image(systemName: "keyboard").font(.system(size: 36)).foregroundStyle(Theme.ink)
            }
            Text("Paste your Mac's pairing code")
                .font(.slate(22, .medium)).foregroundStyle(Theme.ink).padding(.top, 20)
            Text("Open Slate → Settings → Remote on your Mac and copy the code shown under the QR.")
                .font(.slate(15)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).lineSpacing(2)
                .padding(.top, 10).padding(.horizontal, 30)

            TextField("Pairing code", text: $code, axis: .vertical)
                .font(.slate(15)).foregroundStyle(Theme.ink).tint(Theme.ink)
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(SlateShape(radius: 14).fill(Theme.surface))
                .overlay(SlateShape(radius: 14).strokeBorder(Theme.hairline, lineWidth: 1))
                .padding(.horizontal, 24).padding(.top, 22)

            if UIPasteboard.general.hasStrings {
                Button {
                    code = UIPasteboard.general.string ?? ""
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard").font(.slate(15, .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ink)
                .padding(.top, 14)
            }
            Spacer()
            PrimaryButton(title: "Connect", icon: "link", fill: trimmed.isEmpty ? Theme.inkTertiary : nil) {
                attempt()
            }
            .padding(.horizontal, 24)
            .disabled(trimmed.isEmpty)
            .padding(.bottom, 8)
        }
        .padding(.bottom, 24)
        .onAppear { focused = true }
    }

    private func attempt() {
        guard let payload = PairingPayload(code: trimmed) else {
            app.failPairingUnreadable()
            return
        }
        // The code is only syntactically valid at this point. `beginPairing` holds the user on
        // the progress screen until the Mac actually completes the handshake, and routes a
        // stale or rotated code to the same recovery a malformed one gets.
        app.beginPairing(with: payload)
    }
}

struct ReticleCorners: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let L = r.width * 0.28
        // 4 corner brackets
        for (cx, cy, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                                 (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: cx + dx*L, y: cy)); p.addLine(to: CGPoint(x: cx, y: cy))
            p.addLine(to: CGPoint(x: cx, y: cy + dy*L))
        }
        return p
    }
}

// MARK: - Pairing progress / result

/// Shown while the handshake is actually in flight. It used to declare success on a 1.4-second
/// timer regardless of what the Mac did, which is why a stale-but-well-formed code sailed
/// through to a permanently disconnected app. The outcome now comes from `AppState`: either the
/// link reaches ready, or the attempt times out into the recovery screen below.
struct PairingProgressView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Group {
            if app.pairingFailed {
                ExpiredQRView()
            } else {
                VStack(spacing: 18) {
                    Spacer()
                    ProgressView().controlSize(.large).tint(Theme.ink)
                    Text("Establishing a secure link…")
                        .font(.slate(19, .medium)).foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(.slate(15)).foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 36)
                        .contentTransition(.opacity)
                        .animation(.smooth(duration: 0.25), value: detail)
                    Spacer()
                }
            }
        }
    }

    /// Narrate the real phase. "Looking for your Mac" and "checking the key" fail for very
    /// different reasons, and saying which one we are on turns a dead wait into a diagnosis.
    private var detail: String {
        switch app.client.phase {
        case .idle, .browsing: "Looking for your Mac on this network."
        case .connecting:      "Verifying the pairing key."
        case .ready:           "Connected."
        case .offline:         "Still trying. Check that both devices are on the same Wi-Fi."
        }
    }
}

/// Pairing recovery.
///
/// This screen used to say "That code expired" for every failure. Slate's pairing codes do not
/// expire — they change only when the owner revokes the pairing — so the one explanation it
/// offered was wrong for both of the cases that actually reach it.
struct ExpiredQRView: View {
    @Environment(AppState.self) private var app

    private var title: String {
        app.pairingFailure == .unreadableCode ? "That is not a Slate code" : "Couldn't reach your Mac"
    }
    private var detail: String {
        switch app.pairingFailure {
        case .unreadableCode:
            "Scan the QR in Slate on your Mac, under Settings → Remote, or paste the code printed under it."
        default:
            "The code is fine, but no Mac answered. Check that Slate is open, that Remote is switched on, and that both devices are on the same Wi-Fi."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Theme.danger.opacity(0.12)).frame(width: 96, height: 96)
                Image(systemName: app.pairingFailure == .unreadableCode ? "qrcode.viewfinder" : "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.danger)
            }
            Text(title)
                .font(.slate(26, .medium)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center).padding(.top, 22).padding(.horizontal, 24)
            Text(detail)
                .font(.slate(16)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).lineSpacing(3)
                .padding(.top, 12).padding(.horizontal, 28)
            Spacer()
            PrimaryButton(title: "Try again", icon: "qrcode.viewfinder") {
                app.pairingFailure = nil; app.onboarding = .scanning
            }
            .padding(.horizontal, 24)
            Button("Enter the code instead") {
                app.pairingFailure = nil; app.onboarding = .entering
            }
            .font(.slate(16)).foregroundStyle(Theme.inkSecondary)
            .padding(.top, 14).padding(.bottom, 8)
        }
        .padding(.bottom, 24)
    }
}

struct PairedView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Theme.ok.opacity(0.12)).frame(width: 104, height: 104)
                Image(systemName: "checkmark").font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.ok)
            }
            Text("Paired")
                .font(.slate(28, .medium)).foregroundStyle(Theme.ink).padding(.top, 22)
            Text("You’re connected to")
                .font(.slate(16)).foregroundStyle(Theme.inkSecondary).padding(.top, 8)
            Text(app.macs.first?.name ?? "your Mac")
                .font(.slate(18, .medium)).foregroundStyle(Theme.ink).padding(.top, 2)
            Spacer()
            PrimaryButton(title: "Start chatting", icon: "bubble.left.and.bubble.right") {
                app.isPaired = true
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .padding(.bottom, 24)
    }
}
