import Foundation
import Testing

@testable import CaptureKit

@Suite("Capture destination")
struct CaptureDestinationTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "capture-destination-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A fresh install stages recordings in the history")
    func defaultsToClipboard() throws {
        #expect(CaptureDestination.restored(from: try makeDefaults()) == .clipboard)
    }

    @Test("The choice survives a relaunch")
    func roundTrips() throws {
        let defaults = try makeDefaults()
        CaptureDestination.file.store(in: defaults)
        #expect(CaptureDestination.restored(from: defaults) == .file)
    }

    @Test("A value written by a newer build falls back instead of crashing")
    func ignoresUnknownValues() throws {
        let defaults = try makeDefaults()
        defaults.set("airdrop", forKey: "reel.captureDestination")
        #expect(CaptureDestination.restored(from: defaults) == .clipboard)
    }
}
