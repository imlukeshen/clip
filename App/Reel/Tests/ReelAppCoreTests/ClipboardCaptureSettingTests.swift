import CaptureKit
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Clipboard capture privacy setting", .serialized)
struct ClipboardCaptureSettingTests {
    @Test("New installs do not watch the system clipboard and the choice persists")
    @MainActor
    func defaultsOffAndPersists() {
        let defaults = UserDefaults.standard
        let key = "clip.clipboardCaptureEnabled"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(makeModel().isClipboardCaptureEnabled == false)

        let model = makeModel()
        model.setClipboardCaptureEnabled(true)
        #expect(defaults.bool(forKey: key))
        #expect(makeModel().isClipboardCaptureEnabled)
    }

    @MainActor
    private func makeModel() -> AppModel {
        AppModel(
            libraryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(
                "clip-clipboard-setting-\(UUID().uuidString)",
                isDirectory: true
            ),
            shortcutReader: ShortcutReader(sandboxed: true)
        )
    }
}
