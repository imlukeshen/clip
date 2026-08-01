import AppKit
import Foundation
import Testing

@testable import CaptureKit

@Suite("Screenshot shortcut reader")
struct ShortcutReaderTests {
    @Test("Decodes the configured and disabled screenshot actions")
    func decodesDefaultFixture() throws {
        let result = try ShortcutReader.decode(propertyListData: fixture(named: "default"))

        guard case .available(let shortcuts) = result else {
            Issue.record("Expected readable shortcut preferences")
            return
        }

        #expect(shortcuts[.fullScreenToFile]??.characters == "3")
        #expect(shortcuts[.fullScreenToFile]??.modifiers == [.shift, .command])
        #expect(shortcuts[.areaToClipboard]??.characters == "4")
        #expect(shortcuts[.areaToClipboard]??.modifiers == [.control, .shift, .command])
        #expect(shortcuts.keys.contains(.capturePanel))
        #expect(shortcuts[.capturePanel] == .some(nil))
    }

    @Test("Uses the actual remapped character and modifiers")
    func decodesRemappedFixture() throws {
        let result = try ShortcutReader.decode(propertyListData: fixture(named: "remapped"))

        guard case .available(let shortcuts) = result else {
            Issue.record("Expected readable shortcut preferences")
            return
        }

        #expect(shortcuts[.capturePanel]??.characters == "R")
        #expect(shortcuts[.capturePanel]??.modifiers == [.option, .shift])
    }

    @Test("An unreadable domain produces a neutral unavailable result")
    func missingDomain() throws {
        let result = try ShortcutReader.decode(propertyListData: fixture(named: "missing-domain"))
        #expect(result == .unavailable(reason: .missingDomain))
    }

    @Test("A sandboxed channel never attempts a preference read")
    func sandboxedBuild() {
        let reader = ShortcutReader(sandboxed: true)
        #expect(reader.read() == .unavailable(reason: .sandboxed))
    }

    @Test("A direct build exercises the real preference domain")
    func realPreferenceDomain() {
        let result = ShortcutReader(sandboxed: false).read()

        switch result {
        case .available(let shortcuts):
            #expect(shortcuts.keys.contains(.fullScreenToFile))
        case .unavailable(let reason):
            #expect(reason == .missingDomain)
        }
    }

    private func fixture(named name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "plist"))
        return try Data(contentsOf: url)
    }
}
