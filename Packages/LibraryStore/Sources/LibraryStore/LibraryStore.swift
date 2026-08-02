import CoreModel
import Foundation
import GRDB

/// Owns Reel's durable file library and its disposable SQLite index.
public actor LibraryStore {
    private let root: URL
    private let database: DatabaseQueue
    private let bookmarks: BookmarkStore
    private let changeContinuation: AsyncStream<LibraryChange>.Continuation

    /// A stream of committed library mutations.
    public nonisolated let changes: AsyncStream<LibraryChange>

    /// Opens or creates a library rooted at a user-approved directory.
    public init(root: URL, bookmarks: BookmarkStore) async throws {
        let normalizedRoot = root.standardizedFileURL
        do {
            try Self.prepareLayout(at: normalizedRoot)
        } catch {
            throw LibraryError.fileOperationFailed("prepare library layout")
        }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(
                path: normalizedRoot.appendingPathComponent("Library.sqlite").path,
                configuration: configuration
            )
            try LibrarySchema.migrate(queue)
        } catch {
            throw LibraryError.databaseOperationFailed("open library index")
        }

        let stream = AsyncStream<LibraryChange>.makeStream()
        self.root = normalizedRoot
        self.database = queue
        self.bookmarks = bookmarks
        self.changes = stream.stream
        self.changeContinuation = stream.continuation
    }

    deinit {
        changeContinuation.finish()
    }

    /// Inserts durable asset metadata and indexes its immutable media file.
    public func insert(_ asset: AssetRecord) async throws {
        let mediaURL = try resolvedURL(forRelativePath: asset.relativePath, under: assetsURL)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw LibraryError.assetFileMissing(asset.relativePath)
        }
        guard mediaURL.deletingPathExtension().lastPathComponent == asset.id.rawValue else {
            throw LibraryError.invalidRelativePath(asset.relativePath)
        }
        if try await self.asset(id: asset.id) != nil {
            throw LibraryError.duplicateAsset(asset.id)
        }
        if try await self.asset(contentHash: asset.contentHash) != nil {
            throw LibraryError.duplicateContentHash(asset.contentHash)
        }

        do {
            try MetadataCodec.encode(asset).write(
                to: metadataURL(for: mediaURL),
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o444))],
                ofItemAtPath: mediaURL.path
            )
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.fileOperationFailed("persist asset metadata")
        }

        do {
            try await database.write { db in
                try asset.insert(db)
            }
        } catch {
            throw LibraryError.databaseOperationFailed("insert asset")
        }
        changeContinuation.yield(.assetInserted(asset.id))
    }

    /// Looks up an asset by typed identifier.
    public func asset(id: AssetID) async throws -> AssetRecord? {
        do {
            return try await database.read { db in
                try AssetRecord.fetchOne(db, id: id)
            }
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.databaseOperationFailed("read asset by id")
        }
    }

    /// Looks up an asset by its content hash.
    public func asset(contentHash: String) async throws -> AssetRecord? {
        do {
            return try await database.read { db in
                try AssetRecord.fetchOne(db, contentHash: contentHash)
            }
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.databaseOperationFailed("read asset by hash")
        }
    }

    /// Returns assets newest-first with optional kind filtering and pagination.
    public func assets(
        kind: AssetKind?,
        limit: Int,
        offset: Int
    ) async throws -> [AssetRecord] {
        guard limit >= 0, offset >= 0 else {
            throw LibraryError.databaseOperationFailed("invalid asset pagination")
        }
        do {
            return try await database.read { db in
                try AssetRecord.fetchAll(db, kind: kind, limit: limit, offset: offset)
            }
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.databaseOperationFailed("list assets")
        }
    }

    /// Resolves the immutable media URL for an indexed asset.
    public func url(for id: AssetID) async throws -> URL {
        guard let asset = try await asset(id: id) else {
            throw LibraryError.assetNotFound(id)
        }
        return try resolvedURL(forRelativePath: asset.relativePath, under: assetsURL)
    }

    /// Atomically stores an event sidecar and updates its indexed asset summary.
    @discardableResult
    public func storeEventTrack(_ track: EventTrack) async throws -> AssetRecord {
        guard var asset = try await asset(id: track.assetID) else {
            throw LibraryError.assetNotFound(track.assetID)
        }
        let mediaURL = try resolvedURL(forRelativePath: asset.relativePath, under: assetsURL)
        let eventRelativePath = asset.relativePath.deletingPathExtension + ".events.json"
        let eventURL = try resolvedURL(forRelativePath: eventRelativePath, under: assetsURL)
        asset.eventTrackPath = eventRelativePath
        asset.eventAlignment = track.alignment.libraryKind
        let alignmentRawValue = asset.eventAlignment?.rawValue

        do {
            try MetadataCodec.encode(track).write(to: eventURL, options: .atomic)
            try MetadataCodec.encode(asset).write(
                to: metadataURL(for: mediaURL),
                options: .atomic
            )
        } catch {
            throw LibraryError.fileOperationFailed("persist event track")
        }
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                        UPDATE asset
                        SET event_track_path = ?, event_alignment = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        eventRelativePath,
                        alignmentRawValue,
                        track.assetID.rawValue,
                    ]
                )
            }
        } catch {
            throw LibraryError.databaseOperationFailed("update event track")
        }
        changeContinuation.yield(.assetUpdated(track.assetID))
        return asset
    }

    /// Loads the asset-owned event sidecar, when one has been associated.
    public func eventTrack(for id: AssetID) async throws -> EventTrack? {
        guard let asset = try await asset(id: id) else {
            throw LibraryError.assetNotFound(id)
        }
        guard let path = asset.eventTrackPath else { return nil }
        let url = try resolvedURL(forRelativePath: path, under: assetsURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.assetFileMissing(path)
        }
        do {
            let track = try MetadataCodec.decode(EventTrack.self, from: Data(contentsOf: url))
            guard track.assetID == id else {
                throw LibraryError.corruptMetadata(path)
            }
            return track
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.corruptMetadata(path)
        }
    }

    /// Removes an asset and its durable sidecars from the library.
    public func delete(asset id: AssetID, moveToTrash: Bool) async throws {
        guard let record = try await asset(id: id) else {
            throw LibraryError.assetNotFound(id)
        }
        let mediaURL = try resolvedURL(forRelativePath: record.relativePath, under: assetsURL)
        let paths = [
            record.eventTrackPath,
            record.thumbnailPath,
            record.peaksPath,
        ].compactMap { $0 }

        do {
            if FileManager.default.fileExists(atPath: mediaURL.path) {
                if moveToTrash {
                    var trashedURL: NSURL?
                    try FileManager.default.trashItem(at: mediaURL, resultingItemURL: &trashedURL)
                } else {
                    try FileManager.default.removeItem(at: mediaURL)
                }
            }
            let metadata = metadataURL(for: mediaURL)
            if FileManager.default.fileExists(atPath: metadata.path) {
                try FileManager.default.removeItem(at: metadata)
            }
            for path in paths {
                let sidecar = try resolvedURL(forRelativePath: path, under: assetsURL)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try FileManager.default.removeItem(at: sidecar)
                }
            }
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.fileOperationFailed("delete asset")
        }

        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [id.rawValue])
            }
        } catch {
            throw LibraryError.databaseOperationFailed("delete asset index")
        }
        changeContinuation.yield(.assetDeleted(id))
    }

    /// Loads a project document from its package.
    public func loadProject(id: ProjectID) async throws -> ProjectDocument {
        let packagePath: String?
        do {
            packagePath = try await database.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT package_path FROM project WHERE id = ?",
                    arguments: [id.rawValue]
                )
            }
        } catch {
            throw LibraryError.databaseOperationFailed("find project")
        }
        guard let packagePath else {
            throw LibraryError.projectNotFound(id)
        }
        let packageURL = try resolvedURL(forRelativePath: packagePath, under: projectsURL)
        do {
            let data = try Data(contentsOf: packageURL.appendingPathComponent("project.json"))
            return try ProjectDocument.decodeJSON(data)
        } catch let error as ModelError {
            throw error
        } catch {
            throw LibraryError.corruptMetadata(packagePath)
        }
    }

    /// Atomically saves a project package and refreshes its index summary.
    public func saveProject(_ document: ProjectDocument) async throws {
        do {
            try document.validate()
        } catch {
            throw LibraryError.corruptMetadata("project \(document.id.rawValue)")
        }
        let relativePackagePath = "Projects/\(document.id.rawValue).reelproj"
        let packageURL = root.appendingPathComponent(relativePackagePath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: packageURL.appendingPathComponent("history", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: packageURL.appendingPathComponent("renders", isDirectory: true),
                withIntermediateDirectories: true
            )
            try document.encodedJSON().write(
                to: packageURL.appendingPathComponent("project.json"),
                options: .atomic
            )
        } catch {
            throw LibraryError.fileOperationFailed("save project package")
        }

        do {
            try await database.write { db in
                try Self.upsertProject(document, path: relativePackagePath, in: db)
            }
        } catch {
            throw LibraryError.databaseOperationFailed("index project")
        }
        changeContinuation.yield(.projectSaved(document.id))
    }

    /// Appends an inverse patch and keeps the newest 200 history entries.
    public func appendHistory(_ inverse: GraphPatch, project: ProjectID) async throws {
        let packageURL = projectsURL.appendingPathComponent(
            "\(project.rawValue).reelproj",
            isDirectory: true
        )
        let historyURL = packageURL.appendingPathComponent("history", isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw LibraryError.projectNotFound(project)
        }

        do {
            try FileManager.default.createDirectory(
                at: historyURL,
                withIntermediateDirectories: true
            )
            let existing = try historyFiles(in: historyURL)
            let next = (existing.last?.index ?? 0) + 1
            let destination = historyURL.appendingPathComponent(
                String(format: "%04d.json", next)
            )
            try MetadataCodec.encode(inverse).write(to: destination, options: .atomic)

            let afterAppend = try historyFiles(in: historyURL)
            for entry in afterAppend.dropLast(200) {
                try FileManager.default.removeItem(at: entry.url)
            }
        } catch {
            throw LibraryError.fileOperationFailed("append project history")
        }
    }

    /// Returns project summaries newest-first.
    public func projects(limit: Int) async throws -> [ProjectSummary] {
        guard limit >= 0 else {
            throw LibraryError.databaseOperationFailed("invalid project limit")
        }
        do {
            return try await database.read { db in
                try ProjectSummary.fetchAll(db, limit: limit)
            }
        } catch {
            throw LibraryError.databaseOperationFailed("list projects")
        }
    }

    /// Recreates the disposable index entirely from asset and project metadata on disk.
    public func rebuildIndex(
        progress: @Sendable (Double) -> Void
    ) async throws {
        progress(0)
        let assets: [AssetRecord]
        let projects: [(ProjectDocument, String)]
        do {
            assets = try assetRecordsOnDisk()
            projects = try projectDocumentsOnDisk()
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.fileOperationFailed("scan library")
        }

        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM project_asset")
                try db.execute(sql: "DELETE FROM project")
                try db.execute(sql: "DELETE FROM asset")
                for asset in assets {
                    try asset.insert(db)
                }
                for (document, path) in projects {
                    try Self.upsertProject(document, path: path, in: db)
                }
            }
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.databaseOperationFailed("rebuild index")
        }

        let total = max(assets.count + projects.count, 1)
        for completed in 1...total {
            progress(Double(completed) / Double(total))
        }
        changeContinuation.yield(.indexRebuilt)
    }

    /// Compacts the disposable SQLite index.
    public func vacuum() async throws {
        do {
            try await database.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
            }
        } catch {
            throw LibraryError.databaseOperationFailed("vacuum index")
        }
    }
}

extension String {
    fileprivate var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}

extension Alignment {
    fileprivate var libraryKind: EventAlignmentKind {
        switch self {
        case .exact: .exact
        case .estimated: .estimated
        case .unavailable: .unavailable
        }
    }
}

extension LibraryStore {
    private static func prepareLayout(at root: URL) throws {
        for directory in ["Inbox", "Assets", "Projects", "Exports"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private var assetsURL: URL {
        root.appendingPathComponent("Assets", isDirectory: true)
    }

    private var projectsURL: URL {
        root.appendingPathComponent("Projects", isDirectory: true)
    }

    private func resolvedURL(forRelativePath path: String, under boundary: URL) throws -> URL {
        guard !path.hasPrefix("/") else {
            throw LibraryError.invalidRelativePath(path)
        }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let boundaryPath = boundary.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(boundaryPath) else {
            throw LibraryError.invalidRelativePath(path)
        }
        return candidate
    }

    private func metadataURL(for mediaURL: URL) -> URL {
        mediaURL.deletingPathExtension().appendingPathExtension("asset.json")
    }

    private func assetRecordsOnDisk() throws -> [AssetRecord] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: assetsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        var records: [AssetRecord] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".asset.json") {
            do {
                let record = try MetadataCodec.decode(
                    AssetRecord.self,
                    from: Data(contentsOf: url)
                )
                let mediaURL = try resolvedURL(
                    forRelativePath: record.relativePath,
                    under: assetsURL
                )
                guard FileManager.default.fileExists(atPath: mediaURL.path) else {
                    throw LibraryError.assetFileMissing(record.relativePath)
                }
                records.append(record)
            } catch let error as LibraryError {
                throw error
            } catch {
                throw LibraryError.corruptMetadata(url.path)
            }
        }
        return records
    }

    private func projectDocumentsOnDisk() throws -> [(ProjectDocument, String)] {
        let packages = try FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "reelproj" }
        return try packages.map { packageURL in
            let documentURL = packageURL.appendingPathComponent("project.json")
            do {
                let document = try ProjectDocument.decodeJSON(Data(contentsOf: documentURL))
                return (document, "Projects/\(packageURL.lastPathComponent)")
            } catch {
                throw LibraryError.corruptMetadata(documentURL.path)
            }
        }
    }

    private static func upsertProject(
        _ document: ProjectDocument,
        path: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO project (
                  id, name, package_path, modified_at,
                  duration_value, duration_scale, item_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  package_path = excluded.package_path,
                  modified_at = excluded.modified_at,
                  duration_value = excluded.duration_value,
                  duration_scale = excluded.duration_scale,
                  item_count = excluded.item_count
                """,
            arguments: [
                document.id.rawValue,
                document.name,
                path,
                document.modifiedAt.timeIntervalSince1970,
                document.duration.value,
                document.duration.timescale,
                document.timeline.video.count,
            ]
        )
        try db.execute(
            sql: "DELETE FROM project_asset WHERE project_id = ?",
            arguments: [document.id.rawValue]
        )
        let assetIDs = Set(
            document.timeline.video.map(\.assetID) + document.timeline.audio.map(\.assetID))
        for assetID in assetIDs {
            try db.execute(
                sql: """
                    INSERT INTO project_asset (project_id, asset_id)
                    SELECT ?, ? WHERE EXISTS (SELECT 1 FROM asset WHERE id = ?)
                    """,
                arguments: [document.id.rawValue, assetID.rawValue, assetID.rawValue]
            )
        }
    }

    private func historyFiles(in directory: URL) throws -> [(index: Int, url: URL)] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "json",
                let index = Int(url.deletingPathExtension().lastPathComponent)
            else {
                return nil
            }
            return (index, url)
        }.sorted { $0.index < $1.index }
    }
}
