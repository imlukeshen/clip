import CoreModel
import Foundation
import LibraryStore

/// Coordinates stable-file detection, probing, dedupe, immutable import, and indexing.
public actor IngestPipeline {
    private let library: LibraryStore
    private let libraryRoot: URL
    private let waiter: StabilityWaiter
    private let probe: any MediaProbing
    private let derivatives: any DerivativeGenerating
    private let continuation: AsyncStream<IngestEvent>.Continuation

    /// A stream of ingest progress and outcomes.
    public nonisolated let events: AsyncStream<IngestEvent>

    /// Creates an ingest pipeline with injectable media and derivative services.
    public init(
        library: LibraryStore,
        libraryRoot: URL,
        waiter: StabilityWaiter = StabilityWaiter(),
        probe: any MediaProbing = AVFoundationMediaProbe(),
        derivatives: any DerivativeGenerating = AVFoundationDerivativeGenerator()
    ) {
        let stream = AsyncStream<IngestEvent>.makeStream()
        self.library = library
        self.libraryRoot = libraryRoot.standardizedFileURL
        self.waiter = waiter
        self.probe = probe
        self.derivatives = derivatives
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    deinit {
        continuation.finish()
    }

    /// Imports a candidate URL or returns its previously imported duplicate.
    @discardableResult
    public func ingest(_ url: URL, source: IngestSource) async throws -> AssetRecord {
        let candidate = url.standardizedFileURL
        continuation.yield(.started(candidate))
        do {
            let record = try await performIngest(candidate, source: source)
            return record
        } catch let error as IngestError {
            continuation.yield(.failed(candidate, error))
            throw error
        } catch {
            let mapped = IngestError.unreadable(
                candidate,
                underlying: "library operation failed"
            )
            continuation.yield(.failed(candidate, mapped))
            throw mapped
        }
    }

    /// Materializes pasteboard image bytes briefly, then sends them through the same pipeline.
    @discardableResult
    public func ingestImageData(
        _ data: Data,
        source: IngestSource = .pasteboard
    ) async throws -> AssetRecord {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-pasteboard-\(UUID().uuidString).png"
        )
        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            throw IngestError.unreadable(
                temporaryURL,
                underlying: "pasteboard image could not be staged"
            )
        }
        defer {
            do {
                try FileManager.default.removeItem(at: temporaryURL)
            } catch {
                // The temporary staging file contains no durable user state.
            }
        }
        return try await ingest(temporaryURL, source: source)
    }

    private func performIngest(_ url: URL, source: IngestSource) async throws -> AssetRecord {
        try ensureSupported(url)
        let probeService = probe
        let continuation = continuation
        let probed = try await waiter.wait(
            for: url,
            progress: { value in continuation.yield(.progress(url, value * 0.4)) },
            validate: { candidate in try await probeService.probe(candidate) }
        )
        let snapshot = try waiter.snapshot(of: url)
        if let duration = probed.duration, duration <= .zero {
            throw IngestError.zeroDuration(url)
        }
        continuation.yield(.progress(url, 0.5))

        let contentHash = try SampledFileHasher.hash(url)
        if let existing = try await library.asset(contentHash: contentHash) {
            continuation.yield(.duplicate(existing))
            return existing
        }
        continuation.yield(.progress(url, 0.6))

        let assetID = AssetID.generate()
        let folder = try inboxFolder()
        let fileExtension = url.pathExtension.lowercased()
        let isAlreadyInInbox = url.deletingLastPathComponent().standardizedFileURL == folder
        let destination =
            isAlreadyInInbox
            ? url
            : uniqueDestination(for: url.lastPathComponent, in: folder)
        if !isAlreadyInInbox {
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                throw IngestError.unreadable(url, underlying: "file could not be imported")
            }
        }
        continuation.yield(.progress(url, 0.72))

        let generated: DerivativePaths
        do {
            let staging = LibraryLayout.internalDirectory(in: libraryRoot)
                .appendingPathComponent("staging/\(assetID.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let staged = try await derivatives.generate(
                for: destination,
                assetID: assetID,
                destinationFolder: staging,
                probe: probed
            )
            generated = try relocateDerivatives(staged, assetID: assetID)
            try? FileManager.default.removeItem(at: staging)
        } catch {
            generated = .none
        }
        continuation.yield(.progress(url, 0.88))

        let createdAt = fileCreatedAt(url) ?? snapshot.modifiedAt
        let record = AssetRecord(
            id: assetID,
            relativePath: try relativePath(destination),
            displayName: url.lastPathComponent,
            kind: probed.kind,
            container: probed.container ?? fileExtension,
            codec: probed.codec,
            createdAt: createdAt,
            importedAt: Date(),
            byteSize: snapshot.byteSize,
            contentHash: contentHash,
            width: probed.width,
            height: probed.height,
            duration: probed.duration,
            nominalFPS: probed.nominalFPS,
            isVariableFPS: probed.isVariableFPS,
            hasAudio: probed.hasAudio,
            preferredTransform: probed.preferredTransform,
            eventTrackPath: nil,
            eventAlignment: nil,
            thumbnailPath: try generated.thumbnail.map(relativePath),
            peaksPath: try generated.peaks.map(relativePath),
            ingestState: .ready
        )

        do {
            try await library.insert(record)
        } catch {
            cleanupImportedFiles(
                destination: destination,
                derivatives: generated,
                removeDestination: !isAlreadyInInbox
            )
            throw error
        }
        guard let storedRecord = try await library.asset(id: record.id) else {
            cleanupImportedFiles(
                destination: destination,
                derivatives: generated,
                removeDestination: !isAlreadyInInbox
            )
            throw IngestError.unreadable(
                destination,
                underlying: "imported asset was not indexed"
            )
        }
        _ = source
        continuation.yield(.progress(url, 1))
        continuation.yield(.finished(storedRecord))
        return storedRecord
    }

    private func ensureSupported(_ url: URL) throws {
        let supported: Set<String> = [
            "mov", "mp4", "m4v", "webm", "mkv", "png", "jpg", "jpeg", "heic", "tif",
            "tiff", "wav", "m4a", "aac", "mp3", "flac", "pdf",
        ]
        let fileExtension = url.pathExtension.lowercased()
        guard supported.contains(fileExtension) else {
            throw IngestError.unsupportedType(fileExtension)
        }
    }

    private func inboxFolder() throws -> URL {
        let folder = LibraryLayout.inbox(in: libraryRoot)
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            return folder
        } catch {
            throw IngestError.unreadable(folder, underlying: "asset folder unavailable")
        }
    }

    private func uniqueDestination(for filename: String, in folder: URL) -> URL {
        let proposed = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let stem = proposed.deletingPathExtension().lastPathComponent
        let pathExtension = proposed.pathExtension
        var suffix = 2
        while true {
            let name =
                pathExtension.isEmpty
                ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(pathExtension)"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private func relocateDerivatives(
        _ staged: DerivativePaths,
        assetID: AssetID
    ) throws -> DerivativePaths {
        let thumbnail = try staged.thumbnail.map { source in
            let destination = LibraryLayout.thumbnails(in: libraryRoot)
                .appendingPathComponent("\(assetID.rawValue).thumb.heic")
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        let peaks = try staged.peaks.map { source in
            let destination = LibraryLayout.peaks(in: libraryRoot)
                .appendingPathComponent("\(assetID.rawValue).peaks.bin")
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        return DerivativePaths(thumbnail: thumbnail, peaks: peaks)
    }

    private func relativePath(_ url: URL) throws -> String {
        let rootPath = libraryRoot.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw IngestError.unreadable(url, underlying: "derivative escaped library")
        }
        return String(path.dropFirst(rootPath.count))
    }

    private func fileCreatedAt(_ url: URL) -> Date? {
        do {
            return try url.resourceValues(forKeys: [.creationDateKey]).creationDate
        } catch {
            return nil
        }
    }

    private func cleanupImportedFiles(
        destination: URL,
        derivatives: DerivativePaths,
        removeDestination: Bool
    ) {
        let urls = [
            removeDestination ? destination : nil, derivatives.thumbnail, derivatives.peaks,
        ]
        .compactMap { $0 }
        for url in urls {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                // Best-effort rollback; orphaned derivatives are rebuildable.
            }
        }
    }
}
