import CoreModel
import Foundation
import Testing

@Test func unknownEffectRoundTripsByteForByte() throws {
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
    #expect(try document.encodedJSON() == original)
}
