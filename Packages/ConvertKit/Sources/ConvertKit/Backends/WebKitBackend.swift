import Foundation
import WebKit

/// Sandboxed document rendering. A content blocker prevents HTTP(S) resources
/// from being fetched while user-authored HTML is converted.
public struct WebKitBackend: ConversionBackend {
    public init() {}

    public var id: BackendID { .webKit }
    public var isAvailable: Bool { true }

    public func edges() -> [ConversionEdge] {
        [
            ConversionEdge(
                from: .exact(ConversionFormats.html),
                to: ConversionFormats.pdf,
                backend: id,
                implementation: .webKit,
                cost: .cheap,
                isLossless: false,
                warnings: ["Document layout may change during PDF rendering."],
                supportedOptions: [.stripMetadata]
            )
        ]
    }

    public func run(
        _ step: PlannedStep,
        input: URL,
        output: URL
    ) async -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    continuation.yield(0)
                    let data: Data
                    guard step.from.type == ConversionFormats.html.type,
                        step.to.type == ConversionFormats.pdf.type
                    else {
                        throw ConversionError.unsupported("Unsupported WebKit conversion")
                    }
                    data = try await Self.renderPDF(input)
                    try Task.checkCancellation()
                    let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try data.write(to: temporary, options: .atomic)
                    try AtomicOutput.commit(temporary, to: output)
                    continuation.yield(1)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ConversionError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    private static func renderPDF(_ input: URL) async throws -> Data {
        let configuration = try await offlineConfiguration()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 612, height: 792),
            configuration: configuration
        )
        let html = try String(contentsOf: input, encoding: .utf8)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: input.deletingLastPathComponent())
        try await waiter.wait()
        try Task.checkCancellation()
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = webView.bounds
        return try await webView.pdf(configuration: pdfConfiguration)
    }

    @MainActor
    private static func offlineConfiguration() async throws -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let source = """
            [
              {"trigger":{"url-filter":"^http://.*"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^https://.*"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^ftp://.*"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^ws://.*"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^wss://.*"},"action":{"type":"block"}}
            ]
            """
        let ruleList = try await WKContentRuleListStore.default().compile(
            identifier: "app.clip.convert.offline",
            source: source
        )
        configuration.userContentController.add(ruleList)
        return configuration
    }

}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result {
            return try result.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension WKContentRuleListStore {
    @MainActor
    fileprivate func compile(identifier: String, source: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: source
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(
                        throwing: error
                            ?? ConversionError.backendUnavailable("Content blocker unavailable"))
                }
            }
        }
    }
}
