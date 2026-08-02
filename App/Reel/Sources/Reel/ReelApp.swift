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

        Settings {
            SettingsView(model: model)
        }
    }
}
