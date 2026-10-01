import AppKit
import TextEngine
import WebKit

/// Renders Mermaid definitions to images with the bundled library, offline.
///
/// One hidden web view holds the library and renders every diagram in turn,
/// so typing in a document with several diagrams never starts more than one
/// page. Results are cached by definition, appearance, and width, so scrolling
/// and unrelated edits reuse the image instead of re-rendering it.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    /// What a definition rendered to.
    enum Outcome {
        case image(NSImage)
        /// Mermaid's own description of what is wrong with the definition.
        case failure(String)
    }

    /// Everything that changes how a definition renders.
    struct Request: Hashable {
        var source: String
        var isDark: Bool
        var maximumWidth: Int
        /// CSS colour the diagram is drawn on, matching the editor behind it.
        var background: String
    }

    static let shared = MermaidRenderer()

    private var webView: WKWebView?
    private var isLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var cache: [Request: Outcome] = [:]
    private var cacheOrder: [Request] = []
    private var tail: Task<Void, Never>?
    private var renderCount = 0
    private static let cacheLimit = 64

    /// The cached result for `request`, if it has already rendered.
    func cached(_ request: Request) -> Outcome? {
        cache[request]
    }

    /// Renders `request`, waiting for any render already in progress.
    func render(_ request: Request) async -> Outcome {
        if let cached = cache[request] { return cached }
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            if let cached = self.cache[request] { return cached }
            let outcome = await self.perform(request)
            self.store(outcome, for: request)
            return outcome
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func perform(_ request: Request) async -> Outcome {
        let webView = await loadedWebView()
        renderCount += 1
        let width = CGFloat(max(request.maximumWidth, 120))
        webView.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let script = """
            mermaid.initialize({
              startOnLoad: false, securityLevel: 'strict',
              theme: dark ? 'dark' : 'default',
              fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'
            });
            document.body.style.background = background;
            const out = document.getElementById('out');
            out.innerHTML = '';
            try {
              const { svg } = await mermaid.render('clipx-diagram-' + serial, source);
              out.innerHTML = svg;
            } finally {
              document.querySelectorAll('[id^="dclipx-diagram-"]').forEach((node) => node.remove());
            }
            const element = out.firstElementChild;
            const natural = parseFloat(element.style.maxWidth) || element.viewBox.baseVal.width;
            element.style.maxWidth = Math.min(natural, width) + 'px';
            element.style.height = 'auto';
            element.style.display = 'block';
            const box = element.getBoundingClientRect();
            return [Math.ceil(box.width), Math.ceil(box.height)];
            """
        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: [
                    "source": request.source,
                    "dark": request.isDark,
                    "background": request.background,
                    "width": Double(width),
                    "serial": renderCount,
                ],
                contentWorld: .page
            )
            guard let size = value as? [NSNumber], size.count == 2,
                size[0].doubleValue > 0, size[1].doubleValue > 0
            else { return .failure("The diagram is empty.") }
            let rect = NSRect(x: 0, y: 0, width: size[0].doubleValue, height: size[1].doubleValue)
            webView.frame = rect
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            let image = try await webView.takeSnapshot(configuration: configuration)
            image.size = rect.size
            return .image(image)
        } catch {
            let message =
                (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? "The diagram could not be rendered."
            return .failure(Self.readable(message))
        }
    }

    /// Mermaid's parse errors span several lines: where, a caret diagram, and
    /// every token it would have accepted. Keep where, and what it found.
    static func readable(_ message: String) -> String {
        let lines = message.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var headline = lines.first ?? message
        if headline.hasPrefix("Error: ") { headline.removeFirst("Error: ".count) }
        if headline.hasSuffix(":") { headline.removeLast() }
        guard let expecting = lines.first(where: { $0.hasPrefix("Expecting") }),
            let got = expecting.range(of: "got '", options: .backwards)
        else { return headline }
        let token = expecting[got.upperBound...].prefix { $0 != "'" }
        let found = token == "EOF" ? "the diagram ends too early" : "unexpected \(token)"
        return "\(headline): \(found)"
    }

    private func loadedWebView() async -> WKWebView {
        if let webView, isLoaded { return webView }
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 600, height: 10), configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            // Nothing is fetched: the library is inline and the policy forbids
            // every network source, so a definition cannot reach the internet.
            webView.loadHTMLString(
                """
                <!doctype html><html><head><meta charset="utf-8">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:">
                </head><body style="margin:0"><div id="out"></div>
                <script>\(MermaidAssets.javaScript)</script></body></html>
                """,
                baseURL: nil
            )
        }
        await withCheckedContinuation { loadWaiters.append($0) }
        // `webView` was set above and is never cleared.
        return self.webView ?? WKWebView()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isLoaded = true
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        self.webView(webView, didFinish: navigation)
    }

    private func store(_ outcome: Outcome, for request: Request) {
        cache[request] = outcome
        cacheOrder.append(request)
        if cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }
}
