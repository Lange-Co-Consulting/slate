import AVFoundation
import SwiftUI
import VisionKit

/// A real QR scanner.
///
/// The pairing screen used to be a drawn viewfinder with a reticle and no camera behind it, so
/// the only way to pair was typing the Mac's code by hand. This is the camera.
///
/// `DataScannerViewController` is the modern, accessible route (it brings VoiceOver support, a
/// system zoom control and Live Text hand-off for free). It is unavailable on the Simulator and
/// on devices without the Neural Engine, so `ScanAvailability` lets the caller keep offering the
/// manual path instead of showing a dead rectangle.
enum ScanAvailability {
    case ready
    case needsPermission
    case denied
    case unsupported

    @MainActor static func current() -> ScanAvailability {
        guard DataScannerViewController.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return DataScannerViewController.isAvailable ? .ready : .unsupported
        case .notDetermined: return .needsPermission
        case .denied, .restricted: return .denied
        @unknown default: return .unsupported
        }
    }

    /// Ask once. The Info.plist already carries NSCameraUsageDescription.
    @MainActor static func request() async -> ScanAvailability {
        guard DataScannerViewController.isSupported else { return .unsupported }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return current()
    }
}

/// Live QR capture. Calls `onCode` exactly once, with the raw payload string.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        // Starting is only valid once the view is in a window; try on every update until it takes.
        guard !vc.isScanning, vc.view.window != nil else { return }
        try? vc.startScanning()
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        /// One shot: a QR code stays in frame for many callbacks, and pairing twice would
        /// race two connections against each other.
        private var fired = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(items)
        }
        func dataScanner(_ scanner: DataScannerViewController, didUpdate items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(items)
        }

        private func handle(_ items: [RecognizedItem]) {
            guard !fired else { return }
            for case let .barcode(code) in items {
                guard let payload = code.payloadStringValue, !payload.isEmpty else { continue }
                fired = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode(payload)
                return
            }
        }
    }
}
