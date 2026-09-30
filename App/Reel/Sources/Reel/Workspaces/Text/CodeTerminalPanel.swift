import AppKit
import DesignSystem
import ReelAppCore
import SwiftUI
import TextEngine

/// The run output below the editor, laid out like a terminal session.
///
/// Built like ``TeXDiagnosticsPanel`` so both panels share a height, a grip,
/// and a header rhythm. Each command appears as a `$` prompt, output streams
/// in as it is printed, standard error is drawn in the danger colour, and any
/// error line that names a line of the user's file jumps there when clicked.
struct CodeTerminalPanel: View {
    @Environment(\.theme) private var theme
    let session: CodeRunSession
    let height: Double
    /// The editor's own font size, so output reads like the source above it.
    let fontSize: Double
    let onGoToLine: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.palette.line)
            CodeTerminalTextView(
                transcript: session.transcript,
                footer: footer,
                placeholder: session.state == .idle
                    ? "Run the program to see its output here." : nil,
                fontSize: fontSize,
                inset: theme.metrics.spacing.lg,
                palette: CodeTerminalTextView.Palette(
                    text: NSColor(theme.palette.textPrimary),
                    secondary: NSColor(theme.palette.textSecondary),
                    tertiary: NSColor(theme.palette.textTertiary),
                    danger: NSColor(theme.palette.danger)
                ),
                errorTarget: errorTarget,
                onGoToLine: onGoToLine
            )
        }
        .frame(height: height)
        .background(theme.palette.surfaceSunken)
        .accessibilityIdentifier("code-terminal")
    }

    private var header: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            Image(systemName: "terminal")
                .foregroundStyle(theme.palette.textSecondary)
            Text("Terminal")
                .font(theme.type.label.font)
                .foregroundStyle(theme.palette.textPrimary)
            if session.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Text(statusText)
                .font(theme.type.caption.font)
                .foregroundStyle(statusColor)
                .lineLimit(1)
            if let line = session.errorLine {
                Button("Go to Line \(line)") { onGoToLine(line) }
                    .buttonStyle(ReelBorderedButtonStyle())
                    .accessibilityIdentifier("code-go-to-error")
            }
            Spacer()
            Button(action: copyTranscript) {
                Image(systemName: "doc.on.doc")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(session.transcript.isEmpty)
            .help("Copy output")
            Button(action: session.clear) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(ReelIconButtonStyle())
            .disabled(session.isRunning || session.state == .idle)
            .help("Clear terminal")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(ReelIconButtonStyle())
            .help("Close terminal")
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .frame(height: 42)
        .background(theme.palette.surfacePanel)
    }

    private var footer: (text: String, isError: Bool)? {
        switch session.state {
        case .idle, .running:
            nil
        case .finished(let status, let duration):
            ("Process exited with code \(status) in \(Self.seconds(duration))", status != 0)
        case .failed(let message):
            (message, true)
        }
    }

    private func errorTarget(in text: String) -> Int? {
        RunErrorLocator.errorLine(
            in: text,
            fileName: session.fileName,
            language: session.language
        )
    }

    private var statusText: String {
        switch session.state {
        case .idle: ""
        case .running: "Running \(session.fileName)"
        case .failed: "Did not finish"
        case .finished(let status, let duration):
            status == 0
                ? "Finished in \(Self.seconds(duration))"
                : "Exited with code \(status)"
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .idle, .running: theme.palette.textSecondary
        case .failed: theme.palette.danger
        case .finished(let status, _): status == 0 ? theme.palette.success : theme.palette.danger
        }
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.transcript.plainText, forType: .string)
    }

    private static func seconds(_ duration: Duration) -> String {
        let value =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return value.formatted(.number.precision(.fractionLength(2))) + " s"
    }
}
