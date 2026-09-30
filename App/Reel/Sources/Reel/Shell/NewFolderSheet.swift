import DesignSystem
import SwiftUI

/// Names a new folder, and says where it will go.
///
/// A system alert cannot be themed and shows the app icon rather than anything
/// about the task, so it read as an interruption from somewhere else. This uses
/// the same surfaces, radii and buttons as the rest of the app, and names the
/// destination, which the alert never did.
struct NewFolderSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let destinationName: String
    @Binding var name: String
    let onCreate: () -> Void

    @FocusState private var isNameFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                Text("New Folder")
                    .font(theme.type.title.font)
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Inside \(destinationName)")
                    .font(theme.type.caption.font)
                    .foregroundStyle(theme.palette.textTertiary)
            }

            TextField("Folder name", text: $name)
                .textFieldStyle(.plain)
                .font(theme.type.body.font)
                .foregroundStyle(theme.palette.textPrimary)
                .padding(theme.metrics.spacing.md)
                .background(theme.palette.surfaceRaised)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.input,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.input,
                        style: .continuous
                    )
                    .strokeBorder(
                        isNameFocused ? theme.palette.accentLine : theme.palette.line,
                        lineWidth: theme.metrics.hairline
                    )
                }
                .focused($isNameFocused)
                .onSubmit(create)
                .accessibilityIdentifier("new-folder-name")

            HStack(spacing: theme.metrics.spacing.sm) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(ReelBorderedButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .buttonStyle(ReelProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(theme.metrics.spacing.xl)
        .frame(width: 340)
        .background(theme.palette.surfacePanel)
        .onAppear { isNameFocused = true }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate()
        dismiss()
    }
}
