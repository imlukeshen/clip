import AIKit
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
                Button(commandTitle("edit.undo")) {
                    AppCommandRouter.run("edit.undo", in: model)
                }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.editor == nil && !model.undoManager.canUndo)
                Button(commandTitle("edit.redo")) {
                    AppCommandRouter.run("edit.redo", in: model)
                }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.editor == nil && !model.undoManager.canRedo)
            }
            CommandMenu("Assets") {
                Button(commandTitle("asset.selectAll")) {
                    AppCommandRouter.run("asset.selectAll", in: model)
                }
                    .keyboardShortcut("a", modifiers: .command)
                Button(commandTitle("asset.deselectAll")) {
                    AppCommandRouter.run("asset.deselectAll", in: model)
                }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button(commandTitle("asset.quickLook")) {
                    AppCommandRouter.run("asset.quickLook", in: model)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selection.selected.isEmpty)
                Button(commandTitle("asset.reveal")) {
                    AppCommandRouter.run("asset.reveal", in: model)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selection.selected.isEmpty)
                Divider()
                Button(commandTitle("asset.delete")) {
                    AppCommandRouter.run("asset.delete", in: model)
                }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.selected.isEmpty)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }

    private func commandTitle(_ id: CommandID) -> String {
        CommandRegistry.command(id: id)?.title ?? id.rawValue
    }
}
