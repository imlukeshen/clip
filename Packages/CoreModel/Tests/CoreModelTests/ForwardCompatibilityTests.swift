import CoreModel
import Foundation
import Testing

@Test func unknownEffectSurvivesV1MigrationAndV2RoundTrip() throws {
    let url = try #require(
        Bundle.module.url(
            forResource: "project-v1-unknown-effect.json",
            withExtension: nil,
            subdirectory: "Fixtures/golden"
        )
    )
    let original = try Data(contentsOf: url)
    let document = try ProjectDocument.decodeJSON(original)
    let effect = try #require(document.timeline.video.first?.effects.first)

    guard case .unknown(let raw) = effect else {
        Issue.record("Expected the future effect to decode as unknown")
        return
    }
    #expect(raw.type == "futureGlow")
    #expect(raw.rawValue["blend"] == .string("screen"))
    let migrated = try document.encodedJSON()
    let decoded = try ProjectDocument.decodeJSON(migrated)
    #expect(decoded == document)
    guard case .unknown(let roundTripped) = decoded.timeline.video[0].effects[0] else {
        Issue.record("Expected the migrated effect to remain unknown")
        return
    }
    #expect(roundTripped.rawValue == raw.rawValue)
}
