import DesignSystem
import PDFKit
import ReelAppCore
import SwiftUI
import TextEngine

struct TeXForwardSearchRequest: Equatable {
    let id = UUID()
    var location: SyncTeXPDFLocation
}

struct TeXPDFPreview: View {
    @Environment(\.theme) private var theme
    @Bindable var editor: TextEditorViewModel
    let forwardSearch: TeXForwardSearchRequest?
    let onInverseSearch: (Int, Double, Double) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            theme.palette.surfaceSunken
            if let url = editor.texPDFURL {
                TeXPDFKitView(
                    url: url,
                    forwardSearch: forwardSearch,
                    onInverseSearch: onInverseSearch
                )
            } else {
                emptyState
            }
            if case .paused(let message) = editor.texCompilationState,
                editor.texPDFURL != nil
            {
                buildBanner(
                    title: "Build paused",
                    detail: message,
                    symbol: "shippingbox"
                )
            } else if case .failed(let message) = editor.texCompilationState,
                editor.texPDFURL != nil
            {
                buildBanner(
                    title: "Showing last successful build",
                    detail: message,
                    symbol: "exclamationmark.triangle"
                )
            } else if editor.texHasUnbuiltChanges, editor.texPDFURL != nil {
                buildBanner(
                    title: "Preview needs a rebuild",
                    detail:
                        "Showing the last successful PDF. Build to include your latest source changes.",
                    symbol: "arrow.clockwise"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("latex-pdf-preview")
    }

    @ViewBuilder private var emptyState: some View {
        switch editor.texCompilationState {
        case .compiling:
            VStack(spacing: theme.metrics.spacing.md) {
                ProgressView().controlSize(.small)
                Text("Compiling LaTeX…")
                    .font(theme.type.label.font)
                Text("The source is isolated in a temporary workspace.")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        case .failed(let message):
            VStack(spacing: theme.metrics.spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(theme.palette.textSecondary)
                Text("Build failed")
                    .font(theme.type.title.font)
                Text(message)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Build Again", action: editor.requestTeXCompile)
                    .buttonStyle(ReelBorderedButtonStyle())
                    .disabled(editor.isTeXPackageCacheResetting)
            }
        case .paused(let message):
            VStack(spacing: theme.metrics.spacing.md) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(theme.palette.textSecondary)
                Text(message)
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Build", action: editor.requestTeXCompile)
                    .buttonStyle(ReelBorderedButtonStyle())
                    .disabled(editor.isTeXPackageCacheResetting)
            }
        case .idle, .succeeded:
            VStack(spacing: theme.metrics.spacing.md) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(theme.palette.textTertiary)
                Text("LaTeX preview")
                    .font(theme.type.title.font)
                Text("Build the document to preview its PDF.")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textSecondary)
                Button("Build", action: editor.requestTeXCompile)
                    .buttonStyle(ReelBorderedButtonStyle())
                    .disabled(editor.isTeXPackageCacheResetting)
            }
        }
    }

    private func buildBanner(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: theme.metrics.spacing.md) {
            Image(systemName: symbol)
                .foregroundStyle(theme.palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.type.label.font)
                Text(detail)
                    .font(theme.type.micro.font)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Build Again", action: editor.requestTeXCompile)
                .buttonStyle(ReelBorderedButtonStyle())
                .disabled(editor.isTeXPackageCacheResetting)
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(minHeight: 54)
        .background(theme.palette.surfaceRaised.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.palette.line).frame(height: theme.metrics.hairline)
        }
    }
}

private struct TeXPDFKitView: NSViewRepresentable {
    let url: URL
    let forwardSearch: TeXForwardSearchRequest?
    let onInverseSearch: (Int, Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFKit.PDFView {
        let view = CommandClickPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        view.setAccessibilityIdentifier("latex-pdf-document")
        view.document = PDFDocument(url: url)
        view.onCommandClick = onInverseSearch
        context.coordinator.apply(forwardSearch, to: view)
        return view
    }

    func updateNSView(_ view: PDFKit.PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            view.autoScales = true
            context.coordinator.reset()
        }
        (view as? CommandClickPDFView)?.onCommandClick = onInverseSearch
        context.coordinator.apply(forwardSearch, to: view)
    }

    @MainActor
    final class Coordinator {
        private var lastRequestID: UUID?
        private weak var highlightedPage: PDFPage?
        private var highlight: PDFAnnotation?

        func reset() {
            removeHighlight()
            lastRequestID = nil
        }

        func apply(_ request: TeXForwardSearchRequest?, to view: PDFKit.PDFView) {
            guard let request, request.id != lastRequestID,
                let document = view.document,
                let page = document.page(at: request.location.page - 1)
            else { return }
            lastRequestID = request.id
            removeHighlight()
            let bounds = page.bounds(for: .cropBox)
            let location = request.location
            let rectangle = CGRect(
                x: bounds.minX + location.x,
                y: bounds.maxY - location.y - location.height,
                width: location.width,
                height: location.height
            ).intersection(bounds)
            guard !rectangle.isNull, !rectangle.isEmpty else { return }
            let annotation = PDFAnnotation(
                bounds: rectangle.insetBy(dx: -3, dy: -2),
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = NSColor.systemBlue.withAlphaComponent(0.38)
            page.addAnnotation(annotation)
            highlightedPage = page
            highlight = annotation
            view.go(to: rectangle.insetBy(dx: -28, dy: -36), on: page)
            Task { [weak self, weak page, weak annotation] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, self.highlight === annotation else { return }
                if let annotation { page?.removeAnnotation(annotation) }
                self.highlight = nil
                self.highlightedPage = nil
            }
        }

        private func removeHighlight() {
            if let highlight { highlightedPage?.removeAnnotation(highlight) }
            highlight = nil
            highlightedPage = nil
        }
    }
}

@MainActor
private final class CommandClickPDFView: PDFKit.PDFView {
    var onCommandClick: (Int, Double, Double) -> Void = { _, _, _ in }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, let document else {
            super.mouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        let bounds = page.bounds(for: .cropBox)
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }
        onCommandClick(
            pageIndex + 1,
            pagePoint.x - bounds.minX,
            bounds.maxY - pagePoint.y
        )
    }
}
