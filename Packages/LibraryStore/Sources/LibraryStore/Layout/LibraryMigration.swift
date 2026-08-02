import CoreModel
import Foundation
import GRDB

public struct LibraryMigrationMove: Codable, Sendable, Equatable {
    public var sourceRelativePath: String
    public var destinationRelativePath: String

    public init(sourceRelativePath: String, destinationRelativePath: String) {
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
    }
}

public struct LibraryMigrationRecord: Codable, Sendable, Equatable {
    public var original: AssetRecord
    public var migrated: AssetRecord

    public init(original: AssetRecord, migrated: AssetRecord) {
        self.original = original
        self.migrated = migrated
    }
}

public struct LibraryMigrationPlan: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "v1-v2" }
    public var createdAt: Date
    public var moves: [LibraryMigrationMove]
    public var records: [LibraryMigrationRecord]

    public init(
        createdAt: Date = .now,
        moves: [LibraryMigrationMove],
        records: [LibraryMigrationRecord]
    ) {
        self.createdAt = createdAt
        self.moves = moves
        self.records = records
    }
}

public struct LibraryMigrationManifest: Codable, Sendable, Equatable {
    public var executedAt: Date
    public var plan: LibraryMigrationPlan

    public init(executedAt: Date, plan: LibraryMigrationPlan) {
        self.executedAt = executedAt
        self.plan = plan
    }
}

public enum LibraryMigration {
    public static let revertWindow: TimeInterval = 30 * 24 * 60 * 60

    public static func plan(at root: URL) throws -> LibraryMigrationPlan? {
        let root = root.standardizedFileURL
        let legacyDatabase = root.appendingPathComponent("Library.sqlite")
        let legacyAssets = root.appendingPathComponent("Assets", isDirectory: true)
        guard
            FileManager.default.fileExists(atPath: legacyDatabase.path)
                || FileManager.default.fileExists(atPath: legacyAssets.path)
        else { return nil }
        guard !FileManager.default.fileExists(atPath: LibraryLayout.database(in: root).path) else {
            return nil
        }

        let records = try legacyRecords(at: legacyAssets)
        var reservedNames = Set<String>()
        var migrations: [LibraryMigrationRecord] = []
        var moves: [LibraryMigrationMove] = []

        for original in records.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let sourceMedia = original.relativePath
            let sourceURL = root.appendingPathComponent(sourceMedia)
            let fallback = sourceURL.lastPathComponent
            let requested = validFilename(original.displayName, fallback: fallback)
            let filename = uniqueFilename(requested, reserved: &reservedNames)
            let destinationMedia = "Media/Inbox/\(filename)"
            var migrated = original
            migrated.relativePath = destinationMedia

            moves.append(
                .init(sourceRelativePath: sourceMedia, destinationRelativePath: destinationMedia))

            if let event = original.eventTrackPath,
                FileManager.default.fileExists(atPath: root.appendingPathComponent(event).path)
            {
                let destination =
                    "Media/Inbox/\((filename as NSString).deletingPathExtension).events.json"
                migrated.eventTrackPath = destination
                moves.append(.init(sourceRelativePath: event, destinationRelativePath: destination))
            }
            if let thumbnail = original.thumbnailPath,
                FileManager.default.fileExists(atPath: root.appendingPathComponent(thumbnail).path)
            {
                let destination = ".reel/thumbs/\(original.id.rawValue).thumb.heic"
                migrated.thumbnailPath = destination
                moves.append(
                    .init(sourceRelativePath: thumbnail, destinationRelativePath: destination))
            }
            if let peaks = original.peaksPath,
                FileManager.default.fileExists(atPath: root.appendingPathComponent(peaks).path)
            {
                let destination = ".reel/peaks/\(original.id.rawValue).peaks.bin"
                migrated.peaksPath = destination
                moves.append(.init(sourceRelativePath: peaks, destinationRelativePath: destination))
            }

            let legacyMetadata = sourceURL.deletingPathExtension().appendingPathExtension(
                "asset.json")
            if FileManager.default.fileExists(atPath: legacyMetadata.path) {
                moves.append(
                    .init(
                        sourceRelativePath: relativePath(legacyMetadata, root: root),
                        destinationRelativePath: ".reel/assets/\(original.id.rawValue).json"
                    )
                )
            }
            migrations.append(.init(original: original, migrated: migrated))
        }

        if FileManager.default.fileExists(atPath: legacyDatabase.path) {
            moves.append(
                .init(
                    sourceRelativePath: "Library.sqlite",
                    destinationRelativePath: ".reel/Library.sqlite"
                )
            )
        }
        return LibraryMigrationPlan(moves: moves, records: migrations)
    }

    public static func execute(_ plan: LibraryMigrationPlan, at root: URL) throws {
        let root = root.standardizedFileURL
        try prepareNewLayout(root)
        var completed: [LibraryMigrationMove] = []
        do {
            for move in plan.moves {
                let source = root.appendingPathComponent(move.sourceRelativePath)
                let destination = root.appendingPathComponent(move.destinationRelativePath)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw LibraryError.fileOperationFailed("migration destination exists")
                }
                try FileManager.default.moveItem(at: source, to: destination)
                completed.append(move)
            }
            for migration in plan.records {
                try MetadataCodec.encode(migration.migrated).write(
                    to: LibraryLayout.metadata(in: root).appendingPathComponent(
                        "\(migration.migrated.id.rawValue).json"
                    ),
                    options: .atomic
                )
            }
            try updateDatabase(
                at: LibraryLayout.database(in: root), records: plan.records.map(\.migrated))
            let manifest = LibraryMigrationManifest(executedAt: .now, plan: plan)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL(root), options: .atomic)
        } catch {
            for move in completed.reversed() {
                let source = root.appendingPathComponent(move.destinationRelativePath)
                let destination = root.appendingPathComponent(move.sourceRelativePath)
                try? FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.moveItem(at: source, to: destination)
            }
            throw error
        }
    }

    public static func canRevert(at root: URL, now: Date = .now) -> Bool {
        guard let manifest = try? loadManifest(at: root) else { return false }
        return now.timeIntervalSince(manifest.executedAt) <= revertWindow
    }

    public static func revert(at root: URL, now: Date = .now) throws {
        let root = root.standardizedFileURL
        let manifest = try loadManifest(at: root)
        guard now.timeIntervalSince(manifest.executedAt) <= revertWindow else {
            throw LibraryError.fileOperationFailed("migration revert window expired")
        }
        try updateDatabase(
            at: LibraryLayout.database(in: root),
            records: manifest.plan.records.map(\.original)
        )
        for move in manifest.plan.moves.reversed() {
            let source = root.appendingPathComponent(move.destinationRelativePath)
            let destination = root.appendingPathComponent(move.sourceRelativePath)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw LibraryError.fileOperationFailed("revert destination exists")
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        for migration in manifest.plan.records {
            let media = root.appendingPathComponent(migration.original.relativePath)
            try MetadataCodec.encode(migration.original).write(
                to: media.deletingPathExtension().appendingPathExtension("asset.json"),
                options: .atomic
            )
        }
        try? FileManager.default.removeItem(at: manifestURL(root))
        removeIfEmpty(LibraryLayout.metadata(in: root))
        removeIfEmpty(LibraryLayout.thumbnails(in: root))
        removeIfEmpty(LibraryLayout.peaks(in: root))
        removeIfEmpty(LibraryLayout.internalDirectory(in: root))
        removeIfEmpty(LibraryLayout.inbox(in: root))
        removeIfEmpty(LibraryLayout.media(in: root))
    }

    private static func legacyRecords(at assets: URL) throws -> [AssetRecord] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: assets,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return try enumerator.compactMap { value in
            guard let url = value as? URL, url.lastPathComponent.hasSuffix(".asset.json") else {
                return nil
            }
            return try MetadataCodec.decode(AssetRecord.self, from: Data(contentsOf: url))
        }
    }

    private static func updateDatabase(at url: URL, records: [AssetRecord]) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        UPDATE asset SET relative_path = ?, event_track_path = ?,
                          thumb_path = ?, peaks_path = ? WHERE id = ?
                        """,
                    arguments: [
                        record.relativePath, record.eventTrackPath, record.thumbnailPath,
                        record.peaksPath, record.id.rawValue,
                    ]
                )
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('schemaVersion', ?)",
                arguments: [LibraryLayout.schemaVersion]
            )
        }
    }

    private static func validFilename(_ requested: String, fallback: String) -> String {
        let value = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate =
            value.isEmpty || value.contains("/") || value == "." || value == ".."
            ? fallback : value
        let requestedExtension = (candidate as NSString).pathExtension
        let fallbackExtension = (fallback as NSString).pathExtension
        if requestedExtension.isEmpty && !fallbackExtension.isEmpty {
            return candidate + "." + fallbackExtension
        }
        return candidate
    }

    private static func uniqueFilename(_ requested: String, reserved: inout Set<String>) -> String {
        if reserved.insert(requested.lowercased()).inserted { return requested }
        let ns = requested as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if reserved.insert(candidate.lowercased()).inserted { return candidate }
            index += 1
        }
    }

    private static func prepareNewLayout(_ root: URL) throws {
        for directory in [
            LibraryLayout.inbox(in: root), LibraryLayout.metadata(in: root),
            LibraryLayout.thumbnails(in: root), LibraryLayout.peaks(in: root),
        ] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    private static func manifestURL(_ root: URL) -> URL {
        LibraryLayout.internalDirectory(in: root).appendingPathComponent("migration-v1.json")
    }

    private static func loadManifest(at root: URL) throws -> LibraryMigrationManifest {
        try JSONDecoder().decode(
            LibraryMigrationManifest.self,
            from: Data(contentsOf: manifestURL(root.standardizedFileURL))
        )
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
    }

    private static func removeIfEmpty(_ url: URL) {
        guard let values = try? FileManager.default.contentsOfDirectory(atPath: url.path),
            values.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
