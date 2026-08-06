import AppKit
import DesignSystem
import SwiftUI

/// A Finder-style editable title used by editor headers and breadcrumbs.
/// Clicking the title begins editing; Return or an outside click commits and
/// Escape restores the current persisted name.
struct EditableFileTitle: View {
    @Environment(\.theme) private var theme

    let name: String
    let accessibilityIdentifier: String
    let renameKind: String
    let onCommit: (String) -> Void

    @State private var draft: String
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    init(
        name: String,
        accessibilityIdentifier: String,
        renameKind: String = "file",
        onCommit: @escaping (String) -> Void
    ) {
        self.name = name
        self.accessibilityIdentifier = accessibilityIdentifier
        self.renameKind = renameKind
        self.onCommit = onCommit
        _draft = State(initialValue: name)
    }

    @ViewBuilder var body: some View {
        if isEditing {
            TextField("File name", text: $draft)
                .textFieldStyle(.plain)
                .font(theme.type.label.font)
                .lineLimit(1)
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .padding(.horizontal, 8)
                .frame(width: editorWidth, height: 28)
                .background {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: theme.metrics.radius.control,
                            style: .continuous
                        )
                        .fill(theme.palette.surfaceSunken)
                        OutsideClickMonitor(isActive: isEditing, action: commit)
                    }
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: theme.metrics.radius.control,
                        style: .continuous
                    )
                    .strokeBorder(theme.palette.accentLine, lineWidth: 1)
                }
                .accessibilityIdentifier("\(accessibilityIdentifier)-field")
        } else {
            Button(action: beginEditing) {
                HStack(spacing: 5) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .font(theme.type.label.font)
                .contentShape(Rectangle())
            }
            .buttonStyle(ReelPlainButtonStyle())
            .help("Rename \(renameKind) \(name)")
            .accessibilityLabel("Rename \(renameKind) \(name)")
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var editorWidth: CGFloat {
        min(max(CGFloat(draft.count) * 7.5 + 30, 150), 360)
    }

    private func beginEditing() {
        draft = name
        isEditing = true
        Task { @MainActor in
            await Task.yield()
            isFocused = true
            await Task.yield()
            (NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView)?.selectAll(nil)
        }
    }

    private func commit() {
        guard isEditing else { return }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isFocused = true
            return
        }
        let proposedName = draft
        isEditing = false
        isFocused = false
        onCommit(proposedName)
    }

    private func cancel() {
        guard isEditing else { return }
        draft = name
        isEditing = false
        isFocused = false
    }
}
