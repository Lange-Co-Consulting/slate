import AppKit
import QuickLookUI
import SlateCore

@MainActor
final class CodeQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = CodeQuickLook()
    private var previewURL: URL?

    func show(code: String, suggestedName: String) {
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Slate/QuickLook", isDirectory: true)
        do {
            try PrivateStorage.ensureDirectory(dir)
            let url = dir.appendingPathComponent("preview-\(UUID().uuidString).\(safeExtension(suggestedName))")
            try PrivateStorage.write(code, to: url)
            previewURL = url
            guard let panel = QLPreviewPanel.shared() else { return }
            panel.dataSource = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        } catch {
            NSSound.beep()
        }
    }

    private func safeExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard (1...16).contains(ext.utf8.count), ext.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (97...122).contains(byte)
        }) else { return "txt" }
        return ext
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        (previewURL ?? FileManager.default.temporaryDirectory) as NSURL
    }
}
