import CoreModel
import Foundation

/// Persists unnamed text buffers outside the immutable asset library.
public actor ScratchTextStore {
    private let directory: URL

    /// Creates a scratch store rooted at the supplied private library directory.
    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// Creates an empty scratch buffer and writes both halves immediately.
    public func create() throws -> ScratchTextBuffer {
        try prepareDirectory()
        let file = TextFile(relativePath: "Untitled.txt")
        let document = try TextDocument(files: [file])
        let contents = LoadedTextFile(text: "", encoding: .utf8, lineEnding: .lf)
        try save(document: document)
        try save(contents: Data(), for: document.id)
        return ScratchTextBuffer(document: document, contents: contents)
    }

    /// Returns existing buffers, newest first, without decoding their contents.
    public func records() throws -> [ScratchTextRecord] {
        try prepareDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "reeltext" }
        var records: [ScratchTextRecord] = []
        records.reserveCapacity(urls.count)
        for url in urls {
            let document: TextDocument
            do {
                document = try JSONDecoder().decode(
                    TextDocument.self,
                    from: Data(contentsOf: url)
                )
            } catch {
                throw TextEngineError.invalidScratchBuffer(url)
            }
            guard let file = document.files.first else {
                throw TextEngineError.invalidScratchBuffer(url)
            }
            let contentsURL = contentURL(for: document.id)
            guard FileManager.default.fileExists(atPath: contentsURL.path) else { continue }
            let structureValues: URLResourceValues
            let contentValues: URLResourceValues
            do {
                structureValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
                contentValues = try contentsURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                )
            } catch {
                throw TextEngineError.invalidScratchBuffer(url)
            }
            let structureDate = structureValues.contentModificationDate ?? .distantPast
            let contentDate = contentValues.contentModificationDate ?? .distantPast
            records.append(
                ScratchTextRecord(
                    id: document.id,
                    name: file.relativePath,
                    modifiedAt: max(structureDate, contentDate)
                )
            )
        }
        return records.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Restores one scratch buffer, or returns `nil` after either half is removed.
    public func load(_ id: DocumentID) throws -> ScratchTextBuffer? {
        let documentURL = structureURL(for: id)
        let contentsURL = contentURL(for: id)
        guard FileManager.default.fileExists(atPath: documentURL.path),
            FileManager.default.fileExists(atPath: contentsURL.path)
        else { return nil }
        let document = try JSONDecoder().decode(
            TextDocument.self,
            from: Data(contentsOf: documentURL)
        )
        return ScratchTextBuffer(
            document: document,
            contents: try TextFileLoader.load(from: contentsURL)
        )
    }

    /// Atomically persists the structural half of a scratch buffer.
    public func save(document: TextDocument) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        try data.write(to: structureURL(for: document.id), options: .atomic)
    }

    /// Atomically persists the editable content half of a scratch buffer.
    public func save(contents: Data, for id: DocumentID) throws {
        try prepareDirectory()
        try contents.write(to: contentURL(for: id), options: .atomic)
    }

    /// The private content URL used by the AppKit editor for status only.
    public func contentURL(for id: DocumentID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).txt")
    }

    private func structureURL(for id: DocumentID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).reeltext")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }
}
