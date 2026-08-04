import AIKit
import ReelAppCore
import SwiftUI

/// The Capture menu.
///
/// Split out of `ReelApp` rather than written inline like its neighbours: the
/// top-level `commands` builder is a single expression and one more nested menu
/// tips IRGen over its argument limit. A named `Commands` type is one child.
struct CaptureCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Capture") {
            Button(title("capture.history")) {
                AppCommandRouter.run("capture.history", in: model)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button(title("capture.clearHistory"), role: .destructive) {
                AppCommandRouter.run("capture.clearHistory", in: model)
            }
            .disabled(model.captureHistory.isEmpty)
        }
    }

    private func title(_ id: CommandID) -> String {
        CommandRegistry.command(id: id)?.title ?? id.rawValue
    }
}
