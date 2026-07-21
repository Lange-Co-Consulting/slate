import AppKit

extension Notification.Name {
    static let slateServiceRequest = Notification.Name("SlateServiceRequest")
}

/// Services-menu bridge for text and files selected in other macOS apps.
/// Delivery is local through NotificationCenter; no content leaves the Mac.
@MainActor
final class SlateServicesProvider: NSObject {
    static let shared = SlateServicesProvider()

    @objc func sendSelection(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let fileLines = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?
            .map(\.path)
        let content: String?
        if let fileLines, !fileLines.isEmpty {
            content = "Help me with these files:\n" + fileLines.map { "- `\($0)`" }.joined(separator: "\n")
        } else {
            content = pasteboard.string(forType: .string)
        }

        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "Slate could not read text or file URLs from the selection."
            return
        }
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .slateServiceRequest, object: content)
        }
    }
}
