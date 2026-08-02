import CaptureKit
import ReelAppCore
import SwiftUI

@main
struct ReelApp: App {
    @State private var model: AppModel

    init() {
        #if APPSTORE_BUILD
            let shortcutReader = ShortcutReader(sandboxed: true)
            let libraryRoot = AppModel.sandboxLibraryRoot
        #else
            let shortcutReader = ShortcutReader(sandboxed: false)
            let libraryRoot = AppModel.defaultLibraryRoot
        #endif
        _model = State(
            initialValue: AppModel(libraryRoot: libraryRoot, shortcutReader: shortcutReader)
        )
    }

    var body: some Scene {
        WindowGroup {
            MainWindow(model: model)
                .frame(minWidth: 1024, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.editor?.undo() ?? model.undoLibraryAction() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.editor == nil && !model.undoManager.canUndo)
                Button("Redo") { model.editor?.redo() ?? model.redoLibraryAction() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.editor == nil && !model.undoManager.canRedo)
            }
            CommandMenu("Assets") {
                Button("Select All") { model.selection.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") { model.selection.deselectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("Move to Trash") { model.requestTrashSelectedAssets() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.selected.isEmpty)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
