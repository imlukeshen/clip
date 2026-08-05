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
        "navigation.pdf", "navigation.text", "navigation.convert", "capture.history",
        "capture.clearHistory",
        "edit.undo", "edit.redo", "asset.selectAll",
        "asset.deselectAll", "asset.search", "asset.quickLook", "asset.reveal", "asset.delete",
        "timeline.toggleSnapping", "timeline.rippleDelete", "timeline.roll", "timeline.slip",
        "timeline.slide", "timeline.razorTool", "timeline.shuttleBackward",
        "timeline.shuttlePause", "timeline.shuttleForward", "timeline.setIn",
        "timeline.setOut", "timeline.addMarker", "timeline.nextMarker", "timeline.insert",
        "timeline.overwrite", "timeline.pasteAttributes", "timeline.targetTrack",
        "timeline.crossDissolve", "timeline.audioFade",
    ]

    public static func availability(
        of id: CommandID,
        in model: AppModel
    ) -> Availability {
        switch id.rawValue {
        case "app.commandPalette", "navigation.inbox", "navigation.video", "navigation.photo",
            "navigation.pdf", "navigation.text", "navigation.convert", "capture.history":
            return .available
        case "capture.clearHistory":
            return model.captureHistory.isEmpty
                ? .unavailable(reason: "The capture history is already empty.")
                : .available
        case "edit.undo":
            guard model.renamingAssetIDs.isEmpty else {
                return .unavailable(reason: "Wait for the file rename to finish.")
            }
            return model.textEditor?.undoManager.canUndo == true
                || model.imageEditor?.undoManager.canUndo == true
                || model.pdfEditor?.undoManager.canUndo == true
                || model.editor?.undoManager.canUndo == true || model.undoManager.canUndo
                ? .available : .unavailable(reason: "There is nothing to undo.")
        case "edit.redo":
            guard model.renamingAssetIDs.isEmpty else {
                return .unavailable(reason: "Wait for the file rename to finish.")
            }
            return model.textEditor?.undoManager.canRedo == true
                || model.imageEditor?.undoManager.canRedo == true
                || model.pdfEditor?.undoManager.canRedo == true
                || model.editor?.undoManager.canRedo == true || model.undoManager.canRedo
                ? .available : .unavailable(reason: "There is nothing to redo.")
        case "asset.selectAll":
            return model.visibleAssets.isEmpty
                ? .unavailable(reason: "This view contains no assets.") : .available
        case "asset.search":
            return model.editor == nil && model.imageEditor == nil && model.pdfEditor == nil
                && model.textEditor == nil
                ? .available
                : .unavailable(reason: "Close the editor before searching the library.")
        case "asset.deselectAll", "asset.quickLook", "asset.reveal", "asset.delete":
            return model.selection.selected.isEmpty
                ? .unavailable(reason: "No assets are selected.") : .available
        case "timeline.toggleSnapping", "timeline.razorTool", "timeline.shuttleBackward",
            "timeline.shuttlePause", "timeline.shuttleForward", "timeline.setIn",
            "timeline.setOut", "timeline.addMarker", "timeline.nextMarker",
            "timeline.targetTrack":
            return model.editor == nil
                ? .unavailable(reason: "No video project is open.") : .available
        case "timeline.rippleDelete", "timeline.roll", "timeline.slip", "timeline.slide",
            "timeline.insert", "timeline.overwrite", "timeline.pasteAttributes":
            return model.editor?.selectedItem == nil
                ? .unavailable(reason: "No timeline clip is selected.") : .available
        case "timeline.crossDissolve", "timeline.audioFade":
            return model.editor?.selectedItem == nil
                ? .unavailable(reason: "No timeline clip is selected.") : .available
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
            model.showWorkspace(.inbox)
            return .completed
        case "navigation.video":
            model.openVideoEditorFromCommandPalette()
            return .completed
        case "navigation.photo":
            model.showWorkspace(.photo)
            return .completed
        case "navigation.pdf":
            model.showWorkspace(.pdf)
            return .completed
        case "navigation.text":
            model.showWorkspace(.text)
            return .completed
        case "navigation.convert":
            model.showWorkspace(.convert)
            return .completed
        case "capture.history":
            model.isCaptureHistoryPresented = true
            Task { await model.refreshCaptureHistory() }
            return .completed
        case "capture.clearHistory":
            model.clearCaptureHistory()
            return .completed
        case "edit.undo":
            if let editor = model.textEditor {
                editor.undo()
            } else if let editor = model.imageEditor {
                editor.undo()
            } else if let editor = model.pdfEditor {
                editor.undo()
            } else if let editor = model.editor {
                editor.undo()
            } else {
                model.undoLibraryAction()
            }
            return .completed
        case "edit.redo":
            if let editor = model.textEditor {
                editor.redo()
            } else if let editor = model.imageEditor {
                editor.redo()
            } else if let editor = model.pdfEditor {
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
        case "asset.search":
            model.focusSearch()
            return .completed
        case "asset.delete":
            model.requestTrashSelectedAssets()
            return .requestedConfirmation
        case "asset.quickLook":
            model.quickLookSelection()
            return .completed
        case "asset.reveal":
            model.revealSelectionInFinder()
            return .completed
        case "timeline.toggleSnapping": model.editor?.toggleSnapping()
        case "timeline.rippleDelete": model.editor?.rippleDeleteSelected()
        case "timeline.roll": model.editor?.rollSelected()
        case "timeline.slip": model.editor?.slipSelected()
        case "timeline.slide": model.editor?.slideSelected()
        case "timeline.razorTool": model.editor?.selectTool(.razor)
        case "timeline.shuttleBackward": model.editor?.shuttleBackward()
        case "timeline.shuttlePause": model.editor?.shuttlePause()
        case "timeline.shuttleForward": model.editor?.shuttleForward()
        case "timeline.setIn": model.editor?.setInPoint()
        case "timeline.setOut": model.editor?.setOutPoint()
        case "timeline.addMarker": model.editor?.addMarkerAtPlayhead()
        case "timeline.nextMarker": model.editor?.goToNextMarker()
        case "timeline.insert": model.editor?.insertSelectedSource(overwrite: false)
        case "timeline.overwrite": model.editor?.insertSelectedSource(overwrite: true)
        case "timeline.pasteAttributes": model.editor?.pasteAttributesToSelection()
        case "timeline.targetTrack": model.editor?.cycleTargetVideoTrack()
        case "timeline.crossDissolve": model.editor?.addCrossDissolve()
        case "timeline.audioFade": model.editor?.addAudioFade()
        default:
            return .completed
        }
        return .completed
    }
}
