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
        "edit.undo", "edit.redo", "asset.selectAll", "asset.deselectAll", "asset.delete",
    ]

    public static func availability(
        of id: CommandID,
        in model: AppModel
    ) -> Availability {
        switch id.rawValue {
        case "edit.undo":
            return model.editor?.undoManager.canUndo == true || model.undoManager.canUndo
                ? .available : .unavailable(reason: "There is nothing to undo.")
        case "edit.redo":
            return model.editor?.undoManager.canRedo == true || model.undoManager.canRedo
                ? .available : .unavailable(reason: "There is nothing to redo.")
        case "asset.selectAll":
            return model.visibleAssets.isEmpty
                ? .unavailable(reason: "This view contains no assets.") : .available
        case "asset.deselectAll", "asset.delete":
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
        case "edit.undo":
            if let editor = model.editor { editor.undo() } else { model.undoLibraryAction() }
            return .completed
        case "edit.redo":
            if let editor = model.editor { editor.redo() } else { model.redoLibraryAction() }
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
        default:
            return .completed
        }
    }
}
