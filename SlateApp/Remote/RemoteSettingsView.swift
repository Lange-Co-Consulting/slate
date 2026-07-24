import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import SlateUI
import SlateRemoteProtocol

/// Settings → Remote: turn Slate Remote on/off and show the pairing QR + text
/// code to scan/paste into the Slate Remote iPhone app. Free feature, no Pro
/// gate - the toggle just starts/stops `AppModel.remoteServer`.
struct RemoteSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section {
            Toggle("Enable Slate Remote", isOn: $model.remoteEnabled)
            Text("Chat with your local models from Slate Remote on your iPhone, over your home Wi-Fi. Nothing leaves your network.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if model.remoteEnabled {
            Section("Pairing") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.remoteServer?.isRunning == true ? .green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(model.remoteServer?.isRunning == true ? "Active" : "Starting…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(macName).font(.callout.weight(.semibold))
                }

                if let code = pairingCode {
                    if let qr = Self.qrImage(for: code) {
                        HStack {
                            Spacer()
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 176, height: 176)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }

                    LabeledContent("Pairing code") {
                        Text(code)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Button("Copy code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            model.notify(.notice, "Pairing code copied.")
                        }
                        Spacer()
                    }
                    Text("Scan this in Slate Remote on your iPhone (same Wi-Fi).")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Starting the Remote server…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Revoke & regenerate code", role: .destructive) {
                    model.revokeRemote()
                    model.notify(.notice, "Old pairing code revoked - re-scan the new code on your phone.")
                }
                Text("Immediately disconnects every paired iPhone. Use this if a phone is lost or a code leaked.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var macName: String {
        model.remoteServer?.pairingPayload.name ?? Host.current().localizedName ?? "This Mac"
    }
    private var pairingCode: String? { model.remoteServer?.pairingPayload.encodedCode() }

    /// Renders `string` as a QR code. CoreImage's generator is native-resolution
    /// (~1pt per module), so we scale up with nearest-neighbor before wrapping in
    /// an NSImage - otherwise it's blurry and phones struggle to focus on it.
    private static func qrImage(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
