import SwiftUI
import WebKit

/// What the live preview renders: a file on disk (agent-written site - loaded
/// via loadFileURL so WKWebView gets read access to the whole folder: css, js,
/// images all work), an inline HTML string (chat artifact, self-contained), or a
/// local dev-server URL (localhost only - the code-mode live preview).
enum PreviewSource: Equatable {
    case file(URL)
    case inline(String)
    case url(URL)
}

/// Renders HTML live (Artifacts-style preview). Offline for local content.
/// `reloadToken` bumps to reload the CURRENT source in place (no view rebuild,
/// no flicker) - the manual refresh button and the dev-server auto-refresh both
/// drive it.
struct WebPreview: NSViewRepresentable {
    let source: PreviewSource
    var folder: URL? = nil     // read-access root for .file (defaults to the file's dir)
    var reloadToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.allowsMagnification = true
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let sourceChanged = context.coordinator.last != source
        let tokenChanged = context.coordinator.token != reloadToken
        guard sourceChanged || tokenChanged else { return }
        context.coordinator.last = source
        context.coordinator.token = reloadToken

        // A reload-token bump with an unchanged live URL → reload in place so the
        // dev server refreshes without tearing down the web view.
        if !sourceChanged, tokenChanged, case .url = source { web.reload(); return }

        switch source {
        case .file(let url):
            // loadHTMLString(baseURL: file://…) does NOT grant local read access -
            // subresources silently fail. loadFileURL does.
            web.loadFileURL(url, allowingReadAccessTo: folder ?? url.deletingLastPathComponent())
        case .inline(let html):
            web.loadHTMLString(html, baseURL: nil)
        case .url(let u):
            web.load(URLRequest(url: u))
        }
    }

    final class Coordinator { var last: PreviewSource?; var token = 0 }
}
