import CoreModel
import Foundation
import Testing

@Test func schemaOneGoldenFileMigratesMechanicallyAndV2RoundTrips() throws {
    let data = try fixture(named: "project-v1.json")
    let document = try ProjectDocument.decodeJSON(data)

    #expect(document.schemaVersion == 2)
    #expect(document.timeline.videoTracks.map(\.id) == [TrackID(rawValue: "v1")])
    #expect(document.timeline.video.count == 1)
    #expect(document.timeline.video[0].timelineStart == .zero)
    #expect(document.timeline.video[0].transform == Animatable(constant: .identity))
    #expect(document.timeline.video[0].opacity == Animatable(constant: 1))
    #expect(document.timeline.video[0].blendMode == .normal)

    let migrated = try document.encodedJSON()
    #expect(migrated != data)
    #expect(try ProjectDocument.decodeJSON(migrated) == document)
}

@Test func newerSchemasAreRejectedBeforeDataCanBeDiscarded() throws {
    let fixtureData = try fixture(named: "project-v1.json")
    let source = try #require(String(data: fixtureData, encoding: .utf8))
    let newer = Data(
        source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":3").utf8)

    do {
        _ = try ProjectDocument.decodeJSON(newer)
        Issue.record("Expected a schema-too-new error")
    } catch let error as ModelError {
        #expect(error == .schemaTooNew(found: 3, supported: 2))
    }
}

@Test func schemaOneMigrationDerivesRunningStartsForEveryItem() throws {
    let fixtureData = try fixture(named: "project-v1.json")
    var root = try #require(
        JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
    )
    var timeline = try #require(root["timeline"] as? [String: Any])
    var video = try #require(timeline["video"] as? [[String: Any]])
    var second = try #require(video.first)
    second["id"] = "item-2"
    second["assetID"] = "asset-2"
    video.append(second)
    timeline["video"] = video
    root["timeline"] = timeline

    let migrated = try ProjectDocument.decodeJSON(
        JSONSerialization.data(withJSONObject: root)
    )
    #expect(migrated.timeline.video[0].timelineStart == .zero)
    #expect(
        migrated.timeline.video[1].timelineStart
            == migrated.timeline.video[0].timelineDuration
    )
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
