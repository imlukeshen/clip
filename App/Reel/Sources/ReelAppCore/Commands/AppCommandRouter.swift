import AIKit
import Foundation

public enum AppCommandOutcome: Sendable, Equatable {
    case selectionChanged
    case requestedConfirmation
    case completed
}

@MainActor
public enum AppCommandRouter {
    public static let menuCommandIDs: [CommandID] = [
        "app.commandPalette", "navigation.inbox", "navigation.video", "navigation.photo",
        "navigation.pdf", "navigation.convert", "edit.undo", "edit.redo", "asset.selectAll",
        "asset.deselectAll", "asset.quickLook", "asset.reveal", "asset.delete",
    ]

    public static func availability(
        of id: CommandID,
        in model: AppModel
    ) -> Availability {
        switch id.rawValue {
        case "app.commandPalette", "navigation.inbox", "navigation.video", "navigation.photo",
            "navigation.pdf", "navigation.convert":
            return .available
        case "edit.undo":
            return model.imageEditor?.undoManager.canUndo == true
                || model.editor?.undoManager.canUndo == true || model.undoManager.canUndo
                ? .available : .unavailable(reason: "There is nothing to undo.")
        case "edit.redo":
            return model.imageEditor?.undoManager.canRedo == true
                || model.editor?.undoManager.canRedo == true || model.undoManager.canRedo
                ? .available : .unavailable(reason: "There is nothing to redo.")
        case "asset.selectAll":
            return model.visibleAssets.isEmpty
                ? .unavailable(reason: "This view contains no assets.") : .available
        case "asset.deselectAll", "asset.quickLook", "asset.reveal", "asset.delete":
            return model.selection.selected.isEmpty
                ? .unavailable(reason: "No assets are selected.") : .available
        default:
            return .unavailable(reason: "This command is not available in the current view.")
        }
    }

    @discardableResult
    public static func run(
        _ id: CommandID,
        in model: AppModel
    ) -> AppCommandOutcome {
        guard availability(of: id, in: model) == .available else { return .completed }
        switch id.rawValue {
        case "app.commandPalette":
            model.isCommandPalettePresented = true
            return .completed
        case "navigation.inbox":
            model.selectedWorkspace = .inbox
            return .completed
        case "navigation.video":
            model.selectedWorkspace = .video
            return .completed
        case "navigation.photo":
            model.selectedWorkspace = .photo
            return .completed
        case "navigation.pdf":
            model.selectedWorkspace = .pdf
            return .completed
        case "navigation.convert":
            model.selectedWorkspace = .convert
            return .completed
        case "edit.undo":
            if let editor = model.imageEditor {
                editor.undo()
            } else if let editor = model.editor {
                editor.undo()
            } else {
                model.undoLibraryAction()
            }
            return .completed
        case "edit.redo":
            if let editor = model.imageEditor {
                editor.redo()
            } else if let editor = model.editor {
                editor.redo()
            } else {
                model.redoLibraryAction()
            }
            return .completed
        case "asset.selectAll":
            model.selection.selectAll()
            return .selectionChanged
        case "asset.deselectAll":
            model.selection.deselectAll()
            return .selectionChanged
        case "asset.delete":
            model.requestTrashSelectedAssets()
            return .requestedConfirmation
        case "asset.quickLook":
            model.quickLookSelection()
            return .completed
        case "asset.reveal":
            model.revealSelectionInFinder()
            return .completed
        default:
            return .completed
        }
    }
}
