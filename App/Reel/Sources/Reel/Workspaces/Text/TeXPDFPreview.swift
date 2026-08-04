import DesignSystem
import PDFKit
import ReelAppCore
import SwiftUI

struct TeXPDFPreview: View {
    @Environment(\.theme) private var theme
    @Bindable var editor: TextEditorViewModel

    var body: some View {
        ZStack(alignment: .top) {
            theme.palette.surfaceSunken
            if let url = editor.texPDFURL {
                TeXPDFKitView(url: url)
            } else {
                emptyState
            }
            if case .failed(let message) = editor.texCompilationState,
                editor.texPDFURL != nil
            {
                buildBanner(
                    title: "Showing last successful build",
                    detail: message,
                    symbol: "exclamationmark.triangle"
                )
            } else if case .paused(let message) = editor.texCompilationState {
                buildBanner(
                    title: "Automatic build paused",
                    detail: message,
                    symbol: "pause.circle"
                )
            }
        }
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
                Button("Build Now", action: editor.requestTeXCompile)
                    .buttonStyle(ReelBorderedButtonStyle())
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
                    .disabled(editor.sourceURL == nil)
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

    func makeNSView(context: Context) -> PDFKit.PDFView {
        let view = PDFKit.PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        view.setAccessibilityIdentifier("latex-pdf-document")
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFKit.PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
        view.autoScales = true
    }
}
