import CoreModel
import Foundation
import Testing

@Test func schemaOneGoldenFileRoundTripsByteForByte() throws {
    let data = try fixture(named: "project-v1.json")
    let document = try ProjectDocument.decodeJSON(data)

    #expect(document.schemaVersion == 1)
    #expect(document.timeline.video.count == 1)
    #expect(try document.encodedJSON() == data)
}

@Test func newerSchemasAreRejectedBeforeDataCanBeDiscarded() throws {
    let fixtureData = try fixture(named: "project-v1.json")
    let source = try #require(String(data: fixtureData, encoding: .utf8))
    let newer = Data(
        source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)

    do {
        _ = try ProjectDocument.decodeJSON(newer)
        Issue.record("Expected a schema-too-new error")
    } catch let error as ModelError {
        #expect(error == .schemaTooNew(found: 2, supported: 1))
    }
}

private func fixture(named name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures/golden"
        )
    )
    return try Data(contentsOf: url)
}
