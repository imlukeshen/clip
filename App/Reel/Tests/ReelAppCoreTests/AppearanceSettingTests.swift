import CaptureKit
import DesignSystem
import Foundation
import Testing

@testable import ReelAppCore

@Suite("Appearance setting")
struct AppearanceSettingTests {
    @Test("A chosen appearance survives relaunch")
    @MainActor
    func choicePersists() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "reel.appearance")
        defer {
            if let previous {
                defaults.set(previous, forKey: "reel.appearance")
            } else {
                defaults.removeObject(forKey: "reel.appearance")
            }
        }

        defaults.removeObject(forKey: "reel.appearance")
        let model = makeModel()
        #expect(model.appearance == .system)

        model.appearance = .light
        #expect(defaults.string(forKey: "reel.appearance") == "light")
        #expect(makeModel().appearance == .light)
    }

    @MainActor
    private func makeModel() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-appearance-\(UUID().uuidString)",
            isDirectory: true
        )
        return AppModel(libraryRoot: root, shortcutReader: ShortcutReader(sandboxed: true))
    }
}
