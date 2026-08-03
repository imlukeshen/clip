import AIKit
import CaptureKit
import Foundation
import ReelAppCore
import SwiftUI

@main
struct ClipApp: App {
    @State private var model: AppModel

    init() {
        #if APPSTORE_BUILD
            let shortcutReader = ShortcutReader(sandboxed: true)
            let defaultLibraryRoot = AppModel.sandboxLibraryRoot
        #else
            let shortcutReader = ShortcutReader(sandboxed: false)
            let defaultLibraryRoot = AppModel.defaultLibraryRoot
        #endif
        #if DEBUG
            let libraryRoot =
                ProcessInfo.processInfo.environment["REEL_LIBRARY_ROOT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? defaultLibraryRoot
        #else
            let libraryRoot = defaultLibraryRoot
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
            CommandMenu("Navigate") {
                Button(commandTitle("app.commandPalette")) {
                    AppCommandRouter.run("app.commandPalette", in: model)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button(commandTitle("navigation.inbox")) {
                    AppCommandRouter.run("navigation.inbox", in: model)
                }
                Button(commandTitle("navigation.video")) {
                    AppCommandRouter.run("navigation.video", in: model)
                }
                Button(commandTitle("navigation.photo")) {
                    AppCommandRouter.run("navigation.photo", in: model)
                }
                Button(commandTitle("navigation.pdf")) {
                    AppCommandRouter.run("navigation.pdf", in: model)
                }
                Button(commandTitle("navigation.convert")) {
                    AppCommandRouter.run("navigation.convert", in: model)
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button(commandTitle("edit.undo")) {
                    AppCommandRouter.run("edit.undo", in: model)
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(
                    model.editor == nil && model.imageEditor == nil
                        && !model.undoManager.canUndo
                )
                Button(commandTitle("edit.redo")) {
                    AppCommandRouter.run("edit.redo", in: model)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(
                    model.editor == nil && model.imageEditor == nil
                        && !model.undoManager.canRedo
                )
            }
            CommandMenu("Assets") {
                Button(commandTitle("asset.search")) {
                    AppCommandRouter.run("asset.search", in: model)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(
                    model.editor != nil || model.imageEditor != nil || model.pdfEditor != nil
                )
                Divider()
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
            CommandMenu("Timeline") {
                Button(commandTitle("timeline.toggleSnapping")) {
                    AppCommandRouter.run("timeline.toggleSnapping", in: model)
                }
                .keyboardShortcut("s", modifiers: [])
                Button(commandTitle("timeline.razorTool")) {
                    AppCommandRouter.run("timeline.razorTool", in: model)
                }
                .keyboardShortcut("c", modifiers: [])
                Button(commandTitle("timeline.rippleDelete")) {
                    AppCommandRouter.run("timeline.rippleDelete", in: model)
                }
                .keyboardShortcut(.delete, modifiers: .shift)
                Divider()
                Button(commandTitle("timeline.roll")) {
                    AppCommandRouter.run("timeline.roll", in: model)
                }
                Button(commandTitle("timeline.slip")) {
                    AppCommandRouter.run("timeline.slip", in: model)
                }
                Button(commandTitle("timeline.slide")) {
                    AppCommandRouter.run("timeline.slide", in: model)
                }
                Button(commandTitle("timeline.crossDissolve")) {
                    AppCommandRouter.run("timeline.crossDissolve", in: model)
                }
                .keyboardShortcut("d", modifiers: .command)
                Button(commandTitle("timeline.audioFade")) {
                    AppCommandRouter.run("timeline.audioFade", in: model)
                }
                Divider()
                Button(commandTitle("timeline.shuttleBackward")) {
                    AppCommandRouter.run("timeline.shuttleBackward", in: model)
                }
                .keyboardShortcut("j", modifiers: [])
                Button(commandTitle("timeline.shuttlePause")) {
                    AppCommandRouter.run("timeline.shuttlePause", in: model)
                }
                .keyboardShortcut("k", modifiers: [])
                Button(commandTitle("timeline.shuttleForward")) {
                    AppCommandRouter.run("timeline.shuttleForward", in: model)
                }
                .keyboardShortcut("l", modifiers: [])
                Divider()
                Button(commandTitle("timeline.setIn")) {
                    AppCommandRouter.run("timeline.setIn", in: model)
                }
                .keyboardShortcut("i", modifiers: [])
                Button(commandTitle("timeline.setOut")) {
                    AppCommandRouter.run("timeline.setOut", in: model)
                }
                .keyboardShortcut("o", modifiers: [])
                Button(commandTitle("timeline.addMarker")) {
                    AppCommandRouter.run("timeline.addMarker", in: model)
                }
                .keyboardShortcut("m", modifiers: [])
                Button(commandTitle("timeline.nextMarker")) {
                    AppCommandRouter.run("timeline.nextMarker", in: model)
                }
                .keyboardShortcut("m", modifiers: .shift)
                Divider()
                Button(commandTitle("timeline.insert")) {
                    AppCommandRouter.run("timeline.insert", in: model)
                }
                Button(commandTitle("timeline.overwrite")) {
                    AppCommandRouter.run("timeline.overwrite", in: model)
                }
                Button(commandTitle("timeline.pasteAttributes")) {
                    AppCommandRouter.run("timeline.pasteAttributes", in: model)
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                Button(commandTitle("timeline.targetTrack")) {
                    AppCommandRouter.run("timeline.targetTrack", in: model)
                }
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
