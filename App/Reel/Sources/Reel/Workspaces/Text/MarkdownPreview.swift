import AppKit
import SwiftUI
import TextEngine
import UniformTypeIdentifiers
import WebKit

/// Sandboxed, offline Markdown preview with block-level source synchronization.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let baseDirectory: URL?
    let sourceLine: Int
    let onVisibleLineChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisibleLineChange: onVisibleLineChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            context.coordinator.resourceHandler,
            forURLScheme: "clip-local"
        )
        configuration.userContentController.add(context.coordinator, name: "clipScrollSync")
        installNetworkBlocker(in: configuration.userContentController)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.setAccessibilityIdentifier("markdown-preview")
        context.coordinator.webView = webView
        context.coordinator.resourceHandler.update(baseDirectory: baseDirectory)
        context.coordinator.render(markdown)
        context.coordinator.scroll(to: sourceLine)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onVisibleLineChange = onVisibleLineChange
        context.coordinator.resourceHandler.update(baseDirectory: baseDirectory)
        context.coordinator.render(markdown)
        context.coordinator.scroll(to: sourceLine)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "clipScrollSync"
        )
        webView.navigationDelegate = nil
    }

    private func installNetworkBlocker(in controller: WKUserContentController) {
        let rules = """
            [{"trigger":{"url-filter":"^(https?|ftp|ws|wss):.*"},"action":{"type":"block"}}]
            """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "clip.markdown.offline.v1",
            encodedContentRuleList: rules
        ) { ruleList, _ in
            guard let ruleList else { return }
            controller.add(ruleList)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onVisibleLineChange: (Int) -> Void
        fileprivate let resourceHandler = MarkdownPreviewResourceHandler()

        private var renderedMarkdown: String?
        private var renderTask: Task<Void, Never>?
        private var pendingSourceLine = 1
        private var loadedSourceLine: Int?
        private var ignoresNextPreviewMessage = false

        init(onVisibleLineChange: @escaping (Int) -> Void) {
            self.onVisibleLineChange = onVisibleLineChange
        }

        func render(_ markdown: String) {
            guard renderedMarkdown != markdown else { return }
            renderedMarkdown = markdown
            renderTask?.cancel()
            renderTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(140))
                } catch {
                    return
                }
                let rendered = await Task.detached(priority: .userInitiated) {
                    MarkdownHTMLRenderer.render(markdown).html
                }.value
                guard !Task.isCancelled, let self, self.renderedMarkdown == markdown else {
                    return
                }
                loadedSourceLine = nil
                webView?.loadHTMLString(rendered, baseURL: nil)
            }
        }

        func scroll(to sourceLine: Int) {
            pendingSourceLine = max(sourceLine, 1)
            guard loadedSourceLine != pendingSourceLine, let webView else { return }
            loadedSourceLine = pendingSourceLine
            ignoresNextPreviewMessage = true
            webView.evaluateJavaScript("window.clipScrollToSourceLine?.(\(pendingSourceLine));") {
                [weak self] _, _ in
                self?.ignoresNextPreviewMessage = false
            }
        }

        func stop() {
            renderTask?.cancel()
            renderTask = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadedSourceLine = nil
            scroll(to: pendingSourceLine)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "clipScrollSync", !ignoresNextPreviewMessage else { return }
            let line: Int?
            if let value = message.body as? Int {
                line = value
            } else if let value = message.body as? NSNumber {
                line = value.intValue
            } else {
                line = nil
            }
            guard let line, line > 0 else { return }
            onVisibleLineChange(line)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }
            let scheme = url.scheme?.lowercased()
            if scheme == "about" || scheme == "clip-local" {
                return .allow
            }
            if navigationAction.navigationType == .linkActivated,
                ["http", "https", "mailto"].contains(scheme ?? "")
            {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}

private final class MarkdownPreviewResourceHandler: NSObject, WKURLSchemeHandler,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var baseDirectory: URL?

    func update(baseDirectory: URL?) {
        lock.lock()
        self.baseDirectory = baseDirectory?.standardizedFileURL
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        let baseDirectory = baseDirectory
        lock.unlock()
        guard let baseDirectory,
            let url = urlSchemeTask.request.url,
            url.scheme == "clip-local",
            url.host == "asset",
            let path = String(url.path.dropFirst()).removingPercentEncoding,
            let fileURL = MarkdownLocalResourceResolver.resolve(path, below: baseDirectory),
            let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
            data.count <= 20 * 1_024 * 1_024
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType =
            UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
