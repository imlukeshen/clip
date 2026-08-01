import AppKit
import CaptureKit
import Testing

@testable import ReelAppCore

@Suite("Shortcut row presentation")
struct ShortcutRowModelTests {
    @Test("Unavailable preferences render only neutral guidance")
    func unavailable() {
        let model = ShortcutRowModel(result: .unavailable(reason: .sandboxed))

        #expect(model.items.isEmpty)
        #expect(model.guidance != nil)
        #expect(model.settingsURL?.scheme == "x-apple.systempreferences")
    }

    @Test("Available preferences preserve only decoded combinations")
    func available() {
        let combo = KeyCombo(characters: "R", modifiers: [.option, .shift])
        let result = ShortcutReadResult.available([
            .capturePanel: combo,
            .fullScreenToFile: nil,
        ])
        let model = ShortcutRowModel(result: result)

        #expect(model.guidance == nil)
        #expect(model.items.count == 2)
        #expect(model.items.first(where: { $0.action == .capturePanel })?.display == combo.display)
        #expect(model.items.first(where: { $0.action == .fullScreenToFile })?.display == nil)
    }
}
