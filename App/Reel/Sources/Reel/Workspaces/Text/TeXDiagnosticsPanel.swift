import DesignSystem
import SwiftUI
import TextEngine

enum TeXOutputTab: String, CaseIterable {
    case problems = "Problems"
    case log = "Build Log"
}

struct TeXDiagnosticsPanel: View {
    @Environment(\.theme) private var theme
    let diagnostics: [TeXDiagnostic]
    let log: String
    @Binding var selectedTab: TeXOutputTab
    let onSelectDiagnostic: (TeXDiagnostic) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: theme.metrics.spacing.md) {
                Picker("Build output", selection: $selectedTab) {
                    ForEach(TeXOutputTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                if selectedTab == .problems {
                    Text(problemSummary)
                        .font(theme.type.caption.font)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ReelIconButtonStyle())
                .help("Close build output")
            }
            .padding(.horizontal, theme.metrics.spacing.lg)
            .frame(height: 42)
            .background(theme.palette.surfacePanel)

            Divider().overlay(theme.palette.line)

            switch selectedTab {
            case .problems:
                problems
            case .log:
                rawLog
            }
        }
        .frame(minHeight: 150, idealHeight: 210, maxHeight: 280)
        .background(theme.palette.surfaceSunken)
        .accessibilityIdentifier("latex-build-output")
    }

    private var problems: some View {
        Group {
            if diagnostics.isEmpty {
                ContentUnavailableView(
                    "No diagnostics",
                    systemImage: "checkmark.circle",
                    description: Text("The engine did not report an error or warning.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedDiagnostics, id: \.file) { group in
                            Text(group.file)
                                .font(theme.type.label.font)
                                .foregroundStyle(theme.palette.textSecondary)
                                .padding(.horizontal, theme.metrics.spacing.lg)
                                .padding(.top, theme.metrics.spacing.md)
                                .padding(.bottom, theme.metrics.spacing.sm)
                            ForEach(group.items) { diagnostic in
                                Button {
                                    onSelectDiagnostic(diagnostic)
                                } label: {
                                    diagnosticRow(diagnostic)
                                }
                                .buttonStyle(.plain)
                                .disabled(diagnostic.line == nil)
                            }
                        }
                    }
                    .padding(.bottom, theme.metrics.spacing.md)
                }
            }
        }
    }

    private var rawLog: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(log.isEmpty ? "The engine has not produced output yet." : log)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.metrics.spacing.lg)
        }
        .accessibilityIdentifier("latex-raw-log")
    }

    private func diagnosticRow(_ diagnostic: TeXDiagnostic) -> some View {
        HStack(alignment: .top, spacing: theme.metrics.spacing.md) {
            Image(systemName: diagnostic.severity.symbol)
                .foregroundStyle(diagnostic.severity.color)
                .frame(width: 16)
            Text(diagnostic.message)
                .font(theme.type.caption.font)
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)
            Spacer(minLength: theme.metrics.spacing.lg)
            if let line = diagnostic.line {
                Text("Line \(line)")
                    .font(theme.type.numeric.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .padding(.horizontal, theme.metrics.spacing.lg)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var groupedDiagnostics: [(file: String, items: [TeXDiagnostic])] {
        Dictionary(grouping: diagnostics) { diagnostic in
            diagnostic.file.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Main document"
        }
        .map { (file: $0.key, items: $0.value) }
        .sorted { $0.file.localizedStandardCompare($1.file) == .orderedAscending }
    }

    private var problemSummary: String {
        let errors = diagnostics.count { $0.severity == .error }
        let warnings = diagnostics.count { $0.severity == .warning }
        return
            "\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")"
    }
}

extension TeXDiagnosticSeverity {
    fileprivate var symbol: String {
        switch self {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .information: .blue
        }
    }
}
