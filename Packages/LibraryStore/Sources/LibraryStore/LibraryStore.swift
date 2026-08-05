import CoreModel
import Foundation
import GRDB

/// Owns Clip's durable file library and its disposable SQLite index.
public actor LibraryStore {
    private let root: URL
    let database: DatabaseQueue
    private let bookmarks: BookmarkStore
    private let trashManager: any FileTrashManaging
    private let changeContinuation: AsyncStream<LibraryChange>.Continuation

    /// A stream of committed library mutations.
    public nonisolated let changes: AsyncStream<LibraryChange>

    /// Opens or creates a library rooted at a user-approved directory.
    public init(
        root: URL,
        bookmarks: BookmarkStore,
        trashManager: any FileTrashManaging = SystemTrashManager()
    ) async throws {
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
                path: LibraryLayout.database(in: normalizedRoot).path,
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
        self.trashManager = trashManager
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
        if try await self.asset(id: asset.id) != nil {
            throw LibraryError.duplicateAsset(asset.id)
        }
        if try await self.asset(contentHash: asset.contentHash) != nil {
            throw LibraryError.duplicateContentHash(asset.contentHash)
        }

        do {
            try MetadataCodec.encode(asset).write(
                to: metadataURL(for: asset.id),
                options: .atomic
            )
            // Text assets are the one editable kind (invariant I5's documented
            // exception, ADR-0009): the edited file on disk *is* the deliverable,
            // so it stays user-writable. Every other kind is frozen read-only.
            let permissions = asset.kind == .text ? Int16(0o644) : Int16(0o444)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: mediaURL.path
            )
            try? await bookmarks.storeFileReference(mediaURL, key: bookmarkKey(for: asset.id))
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

    /// Atomically updates indexed paths after a Clip-owned filesystem move.
    public func updateLocations(_ records: [AssetRecord]) async throws {
        guard !records.isEmpty else { return }
        var originals: [AssetRecord] = []
        for record in records {
            guard let original = try await asset(id: record.id) else {
                throw LibraryError.assetNotFound(record.id)
            }
            originals.append(original)
        }
        do {
            for record in records {
                try MetadataCodec.encode(record).write(
                    to: metadataURL(for: record.id),
                    options: .atomic
                )
            }
            try await database.write { db in
                for record in records {
                    try db.execute(
                        sql: """
                            UPDATE asset SET relative_path = ?, display_name = ?,
                              event_track_path = ? WHERE id = ?
                            """,
                        arguments: [
                            record.relativePath, record.displayName,
                            record.eventTrackPath, record.id.rawValue,
                        ]
                    )
                }
            }
        } catch {
            for original in originals {
                try? MetadataCodec.encode(original).write(
                    to: metadataURL(for: original.id),
                    options: .atomic
                )
            }
            throw LibraryError.databaseOperationFailed("update asset locations")
        }
        for record in records {
            let url = root.appendingPathComponent(record.relativePath)
            try? await bookmarks.storeFileReference(url, key: bookmarkKey(for: record.id))
            changeContinuation.yield(.assetUpdated(record.id))
        }
    }

    /// Resolves the immutable media URL for an indexed asset.
    public func url(for id: AssetID) async throws -> URL {
        guard let asset = try await asset(id: id) else {
            throw LibraryError.assetNotFound(id)
        }
        if let bookmarked = try? await bookmarks.resolveFileReference(
            key: bookmarkKey(for: id),
            searching: assetsURL
        ),
            FileManager.default.fileExists(atPath: bookmarked.path)
        {
            if asset.isMissing { try? await setMissing(nil, for: asset) }
            return bookmarked
        }
        let recorded = try resolvedURL(forRelativePath: asset.relativePath, under: assetsURL)
        if FileManager.default.fileExists(atPath: recorded.path) {
            if asset.isMissing { try? await setMissing(nil, for: asset) }
            try? await bookmarks.storeFileReference(recorded, key: bookmarkKey(for: id))
            return recorded
        }
        try? await setMissing(asset.missingSince ?? .now, for: asset)
        throw LibraryError.assetFileMissing(asset.relativePath)
    }

    /// Resolves bookmarks after launch and marks records that can no longer be found.
    public func refreshLocations() async {
        guard let records = try? await assets(kind: nil, limit: Int.max, offset: 0) else { return }
        for var record in records {
            if let bookmarked = try? await bookmarks.resolveFileReference(
                key: bookmarkKey(for: record.id),
                searching: assetsURL
            ),
                FileManager.default.fileExists(atPath: bookmarked.path)
            {
                let boundary = assetsURL.path + "/"
                let resolved = bookmarked.standardizedFileURL
                if resolved.path.hasPrefix(boundary),
                    resolved.path
                        != root.appendingPathComponent(record.relativePath).standardizedFileURL.path
                {
                    record.relativePath = relativePath(resolved)
                    record.displayName = resolved.lastPathComponent
                    record.missingSince = nil
                    try? await updateLocations([record])
                } else if record.isMissing {
                    try? await setMissing(nil, for: record)
                }
                continue
            }
            let recorded = root.appendingPathComponent(record.relativePath)
            if FileManager.default.fileExists(atPath: recorded.path) {
                try? await bookmarks.storeFileReference(recorded, key: bookmarkKey(for: record.id))
                if record.isMissing { try? await setMissing(nil, for: record) }
            } else if !record.isMissing {
                try? await setMissing(.now, for: record)
            }
        }
    }

    public func relink(assetID: AssetID, to url: URL) async throws {
        guard let record = try await asset(id: assetID) else {
            throw LibraryError.assetNotFound(assetID)
        }
        try await bookmarks.storeFileReference(url, key: bookmarkKey(for: assetID))
        try await setMissing(nil, for: record)
    }

    /// Overwrites the on-disk bytes of an editable text asset for subsequent re-indexing.
    ///
    /// This is the **only** sanctioned write into `Media/`. It exists because
    /// text assets are invariant I5's documented exception (ADR-0009): unlike
    /// video, image, and PDF assets — which stay frozen while edits accumulate in
    /// a `.reel/` overlay — an edited text file *is* the deliverable, so the file
    /// on disk must reflect what the user typed for external tools and indexing. The
    /// App-layer indexing coordinator requeues direct-text and embedding stages after
    /// this atomic write completes.
    ///
    /// The caller supplies the freshly hashed content (using the same sampled
    /// SHA-256 as ingest) so `LibraryStore` need not depend on the hasher; this
    /// method owns the atomic file write and the metadata/index update together.
    ///
    /// - Parameters:
    ///   - data: The new UTF-8 (or otherwise encoded) file bytes.
    ///   - assetID: The text asset to overwrite.
    ///   - contentHash: The sampled SHA-256 of `data`, precomputed by the caller.
    /// - Returns: The updated asset record.
    /// - Throws: ``LibraryError`` if the asset is missing, not text, or the write
    ///   or index update fails.
    @discardableResult
    public func saveTextContents(
        _ data: Data,
        for assetID: AssetID,
        contentHash: String
    ) async throws -> AssetRecord {
        guard var asset = try await asset(id: assetID) else {
            throw LibraryError.assetNotFound(assetID)
        }
        guard asset.kind == .text else {
            throw LibraryError.fileOperationFailed("save non-text asset in place")
        }
        let mediaURL = try resolvedURL(forRelativePath: asset.relativePath, under: assetsURL)
        let byteSize = Int64(data.count)
        asset.contentHash = contentHash
        asset.byteSize = byteSize

        do {
            try data.write(to: mediaURL, options: .atomic)
            // `.atomic` replaces the file via a rename, which can reset the mode
            // to the process umask; restore the editable bit the exception grants.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o644))],
                ofItemAtPath: mediaURL.path
            )
            try MetadataCodec.encode(asset).write(
                to: metadataURL(for: asset.id),
                options: .atomic
            )
        } catch {
            throw LibraryError.fileOperationFailed("save text contents")
        }
        do {
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE asset SET content_hash = ?, byte_size = ? WHERE id = ?",
                    arguments: [contentHash, byteSize, assetID.rawValue]
                )
            }
        } catch {
            throw LibraryError.databaseOperationFailed("update text contents")
        }
        changeContinuation.yield(.assetUpdated(assetID))
        return asset
    }

    /// Atomically stores an event sidecar and updates its indexed asset summary.
    @discardableResult
    public func storeEventTrack(_ track: EventTrack) async throws -> AssetRecord {
        guard var asset = try await asset(id: track.assetID) else {
            throw LibraryError.assetNotFound(track.assetID)
        }
        let eventRelativePath = asset.relativePath.deletingPathExtension + ".events.json"
        let eventURL = try resolvedURL(forRelativePath: eventRelativePath, under: assetsURL)
        asset.eventTrackPath = eventRelativePath
        asset.eventAlignment = track.alignment.libraryKind
        let alignmentRawValue = asset.eventAlignment?.rawValue

        do {
            try MetadataCodec.encode(track).write(to: eventURL, options: .atomic)
            try MetadataCodec.encode(asset).write(
                to: metadataURL(for: asset.id),
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

    /// Moves assets and every durable sidecar to the system Trash as one reversible operation.
    public func trash(assetIDs: [AssetID]) async throws -> TrashReceipt {
        let uniqueIDs = Array(Set(assetIDs))
        guard !uniqueIDs.isEmpty else { return TrashReceipt(items: []) }

        var receiptItems: [TrashReceipt.Item] = []
        do {
            for id in uniqueIDs {
                guard let record = try await asset(id: id) else {
                    throw LibraryError.assetNotFound(id)
                }
                let projectIDs = try await referencingProjectIDs(for: id)
                let urls = try durableURLs(for: record).filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                var moved: [TrashReceipt.MovedFile] = []
                for url in urls {
                    let trashed = try trashManager.trashItem(at: url)
                    moved.append(.init(originalURL: url, trashedURL: trashed))
                }
                receiptItems.append(
                    .init(asset: record, movedFiles: moved, referencingProjectIDs: projectIDs)
                )
            }
        } catch {
            try? restoreFiles(in: TrashReceipt(items: receiptItems))
            throw error
        }

        do {
            try await database.write { db in
                for id in uniqueIDs {
                    try db.execute(
                        sql: "DELETE FROM project_asset WHERE asset_id = ?",
                        arguments: [id.rawValue]
                    )
                    try db.execute(
                        sql: "DELETE FROM asset WHERE id = ?",
                        arguments: [id.rawValue]
                    )
                }
            }
        } catch {
            try? restoreFiles(in: TrashReceipt(items: receiptItems))
            throw LibraryError.databaseOperationFailed("trash asset index")
        }

        for id in uniqueIDs {
            changeContinuation.yield(.assetDeleted(id))
        }
        return TrashReceipt(items: receiptItems)
    }

    /// Restores a prior Trash operation and its project-reference index entries.
    public func restore(_ receipt: TrashReceipt) async throws {
        do {
            try restoreFiles(in: receipt)
        } catch {
            throw LibraryError.fileOperationFailed("restore asset from Trash")
        }
        do {
            try await database.write { db in
                for item in receipt.items {
                    try item.asset.insert(db)
                    for projectID in item.referencingProjectIDs {
                        try db.execute(
                            sql: """
                                INSERT OR IGNORE INTO project_asset (project_id, asset_id)
                                SELECT ?, ? WHERE EXISTS (SELECT 1 FROM project WHERE id = ?)
                                """,
                            arguments: [
                                projectID.rawValue,
                                item.asset.id.rawValue,
                                projectID.rawValue,
                            ]
                        )
                    }
                }
            }
        } catch {
            throw LibraryError.databaseOperationFailed("restore asset index")
        }
        for item in receipt.items {
            changeContinuation.yield(.assetInserted(item.asset.id))
        }
    }

    /// Returns projects that reference any of the supplied assets.
    public func projectsReferencing(assetIDs: [AssetID]) async throws -> [ProjectSummary] {
        let ids = Set(assetIDs)
        guard !ids.isEmpty else { return [] }
        let summaries = try await projects(limit: Int.max)
        var matches: [ProjectSummary] = []
        for summary in summaries {
            let document = try await loadProject(id: summary.id)
            let referenced = Set(
                document.timeline.video.map(\.assetID) + document.timeline.audio.map(\.assetID)
            )
            if !ids.isDisjoint(with: referenced) {
                matches.append(summary)
            }
        }
        return matches
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
    private func durableURLs(for record: AssetRecord) throws -> [URL] {
        let mediaURL = try resolvedURL(forRelativePath: record.relativePath, under: assetsURL)
        let sidecars = try [record.eventTrackPath, record.thumbnailPath, record.peaksPath]
            .compactMap { $0 }
            .map { try resolvedURL(forRelativePath: $0, under: root) }
        return [mediaURL, metadataURL(for: record.id)] + sidecars
    }

    private func referencingProjectIDs(for assetID: AssetID) async throws -> [ProjectID] {
        do {
            return try await database.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT project_id FROM project_asset WHERE asset_id = ?",
                    arguments: [assetID.rawValue]
                )
                return rows.map { ProjectID(rawValue: $0["project_id"]) }
            }
        } catch {
            throw LibraryError.databaseOperationFailed("find asset references")
        }
    }

    private func restoreFiles(in receipt: TrashReceipt) throws {
        for item in receipt.items.reversed() {
            for file in item.movedFiles.reversed() {
                guard FileManager.default.fileExists(atPath: file.trashedURL.path) else {
                    throw LibraryError.assetFileMissing(file.trashedURL.path)
                }
                guard !FileManager.default.fileExists(atPath: file.originalURL.path) else {
                    throw LibraryError.fileOperationFailed("restore destination already exists")
                }
                try FileManager.default.createDirectory(
                    at: file.originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: file.trashedURL, to: file.originalURL)
            }
        }
    }

    private static func prepareLayout(at root: URL) throws {
        for directory in [
            LibraryLayout.inbox(in: root),
            root.appendingPathComponent("Projects", isDirectory: true),
            LibraryLayout.metadata(in: root),
            LibraryLayout.thumbnails(in: root),
            LibraryLayout.peaks(in: root),
            LibraryLayout.imageDocuments(in: root),
        ] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    private var assetsURL: URL {
        LibraryLayout.media(in: root)
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

    private func metadataURL(for assetID: AssetID) -> URL {
        LibraryLayout.metadata(in: root).appendingPathComponent("\(assetID.rawValue).json")
    }

    private func bookmarkKey(for assetID: AssetID) -> String {
        "asset.\(assetID.rawValue)"
    }

    private func relativePath(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
    }

    private func setMissing(_ date: Date?, for record: AssetRecord) async throws {
        var updated = record
        updated.missingSince = date
        try MetadataCodec.encode(updated).write(
            to: metadataURL(for: record.id),
            options: .atomic
        )
        try await database.write { db in
            try db.execute(
                sql: "UPDATE asset SET missing_since = ? WHERE id = ?",
                arguments: [date?.timeIntervalSince1970, record.id.rawValue]
            )
        }
        changeContinuation.yield(.assetUpdated(record.id))
    }

    private func assetRecordsOnDisk() throws -> [AssetRecord] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: LibraryLayout.metadata(in: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        var records: [AssetRecord] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
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
