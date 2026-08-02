import CoreModel
import Foundation
import LibraryStore
import Testing

@Test func twoHundredAssetMigrationPreservesProjectsAndRevertsExactly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-migration-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyFolder = root.appendingPathComponent("Assets/2026-08-01", isDirectory: true)
    let projectsFolder = root.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectsFolder, withIntermediateDirectories: true)

    var records: [AssetRecord] = []
    for index in 0..<200 {
        let id = AssetID(rawValue: String(format: "asset-%03d", index))
        let media = legacyFolder.appendingPathComponent("\(id.rawValue).mov")
        try Data("media-\(index)".utf8).write(to: media)
        var record = AssetRecord(
            id: id,
            relativePath: "Assets/2026-08-01/\(id.rawValue).mov",
            displayName: "Dashboard walkthrough.mov",
            kind: .video,
            createdAt: Date(timeIntervalSince1970: Double(index + 1)),
            importedAt: Date(timeIntervalSince1970: Double(index + 2)),
            byteSize: Int64(index + 1),
            contentHash: "hash-\(index)",
            duration: RationalTime(seconds: 2),
            ingestState: .ready
        )
        if index.isMultiple(of: 2) {
            let event = legacyFolder.appendingPathComponent("\(id.rawValue).events.json")
            let thumbnail = legacyFolder.appendingPathComponent("\(id.rawValue).thumb.heic")
            let peaks = legacyFolder.appendingPathComponent("\(id.rawValue).peaks.bin")
            for url in [event, thumbnail, peaks] { try Data("sidecar".utf8).write(to: url) }
            record.eventTrackPath = "Assets/2026-08-01/\(id.rawValue).events.json"
            record.thumbnailPath = "Assets/2026-08-01/\(id.rawValue).thumb.heic"
            record.peaksPath = "Assets/2026-08-01/\(id.rawValue).peaks.bin"
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(
            to: legacyFolder.appendingPathComponent("\(id.rawValue).asset.json")
        )
        records.append(record)
    }

    for projectIndex in 0..<10 {
        let item = TimelineItem(
            id: ItemID(rawValue: "item-\(projectIndex)"),
            assetID: records[projectIndex].id,
            sourceRange: TimeRange(start: .zero, duration: RationalTime(seconds: 2))
        )
        let project = try ProjectDocument(
            id: ProjectID(rawValue: "project-\(projectIndex)"),
            name: "Project \(projectIndex)",
            timeline: Timeline(video: [item]),
            createdAt: .now,
            modifiedAt: .now
        )
        let package = projectsFolder.appendingPathComponent(
            "project-\(projectIndex).reelproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try project.encodedJSON().write(to: package.appendingPathComponent("project.json"))
    }

    let before = try relativeFilesystemSnapshot(root)
    let planned = try LibraryMigration.plan(at: root)
    let plan = try #require(planned)
    #expect(plan.records.count == 200)
    #expect(Set(plan.records.map { $0.migrated.relativePath }).count == 200)
    #expect(plan.records.map { $0.original.id } == plan.records.map { $0.migrated.id })

    try LibraryMigration.execute(plan, at: root)
    for migration in plan.records {
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(migration.migrated.relativePath).path
            )
        )
    }
    for projectIndex in 0..<10 {
        let data = try Data(
            contentsOf: projectsFolder.appendingPathComponent(
                "project-\(projectIndex).reelproj/project.json"
            )
        )
        let project = try ProjectDocument.decodeJSON(data)
        #expect(project.timeline.video.first?.assetID == records[projectIndex].id)
    }
    #expect(LibraryMigration.canRevert(at: root))

    try LibraryMigration.revert(at: root)
    #expect(try relativeFilesystemSnapshot(root) == before)
}

private func relativeFilesystemSnapshot(_ root: URL) throws -> Set<String> {
    guard
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
    else { return [] }
    return Set(
        enumerator.compactMap { value in
            guard let url = value as? URL else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        })
}
