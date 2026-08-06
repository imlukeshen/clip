import CryptoKit
import Foundation

/// The capped, on-disk staging area for system captures.
///
/// Clip copies captures here instead of importing them into the library, so a
/// screenshot taken while the app happens to be open does not silently become a
/// permanent asset. Two rules make that safe to rely on: nothing outside
/// `directory` is ever deleted, so the file the system wrote stays exactly where
/// the user left it; and entries only leave via the limit, an explicit delete,
/// or a clear.
public actor CaptureHistory {
    public static let maximumClipboardTextBytes = 1 * 1_024 * 1_024
    public static let maximumClipboardImageBytes = 25 * 1_024 * 1_024
    public static let maximumClipboardFileListBytes = 1 * 1_024 * 1_024
    private let directory: URL
    private let limit: CaptureHistoryLimit
    private let indexURL: URL
    private var cached: [CaptureHistoryItem]?
    private var isClipboardRecordingEnabled = false

    public init(directory: URL, limit: CaptureHistoryLimit = .standard) {
        self.directory = directory.standardizedFileURL
        self.limit = limit
        self.indexURL = directory.appendingPathComponent("index.json")
    }

    /// Linearization point shared by preference changes and clipboard writes.
    /// Because both run on this actor, disabling cannot interleave between a
    /// clipboard entry's insertion and limit pruning.
    public func setClipboardRecordingEnabled(_ isEnabled: Bool) {
        isClipboardRecordingEnabled = isEnabled
    }

    @discardableResult
    public func recordClipboard(text: String) throws -> CaptureHistoryItem {
        guard isClipboardRecordingEnabled else { throw CancellationError() }
        return try record(text: text)
    }

    @discardableResult
    public func recordClipboard(
        imageData: Data,
        pathExtension: String,
        displayName: String
    ) throws -> CaptureHistoryItem {
        guard isClipboardRecordingEnabled else { throw CancellationError() }
        return try record(
            imageData: imageData,
            pathExtension: pathExtension,
            displayName: displayName
        )
    }

    @discardableResult
    public func recordClipboard(fileURLs: [URL]) throws -> CaptureHistoryItem {
        guard isClipboardRecordingEnabled else { throw CancellationError() }
        return try record(fileURLs: fileURLs)
    }

    /// Entries still within the limit, newest first. Anything that has aged out
    /// is discarded on the way, so opening the panel is also what prunes.
    public func items() -> [CaptureHistoryItem] {
        let (kept, expired) = limit.apply(to: stored())
        guard !expired.isEmpty else { return kept }
        discardFiles(for: expired)
        write(kept)
        return kept
    }

    /// Where an entry's file lives.
    public nonisolated func url(for item: CaptureHistoryItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    /// Copies a capture into the history and returns the entry.
    ///
    /// The source is read, never moved: the system already wrote it wherever the
    /// user's screenshot preference points, and taking it from there would be a
    /// surprise that Clip could not undo.
    @discardableResult
    public func adopt(_ source: URL, capturedAt: Date = Date()) throws -> CaptureHistoryItem {
        let standardized = source.standardizedFileURL
        guard let kind = CaptureHistoryItem.kind(forPathExtension: standardized.pathExtension)
        else {
            throw CaptureError.unsupportedCapture(standardized.lastPathComponent)
        }
        let id = UUID()
        let fileName = "\(id.uuidString).\(standardized.pathExtension.lowercased())"
        let destination = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: standardized, to: destination)
        } catch {
            throw CaptureError.historyUnavailable(standardized.lastPathComponent)
        }
        let item = CaptureHistoryItem(
            id: id,
            fileName: fileName,
            displayName: standardized.lastPathComponent,
            kind: kind,
            capturedAt: capturedAt,
            byteSize: byteSize(of: destination)
        )
        return insert(item)
    }

    /// Records a run of copied text.
    ///
    /// The text is written to a backing `.txt` file so it lives by the same
    /// one-file-per-entry rule as a screenshot; a repeat of the text already at
    /// the top of the history bumps that entry instead of adding a duplicate.
    @discardableResult
    public func record(text: String, capturedAt: Date = Date()) throws -> CaptureHistoryItem {
        let data = Data(text.utf8)
        guard data.count <= Self.maximumClipboardTextBytes else {
            throw CaptureError.payloadTooLarge("Copied text")
        }
        let hash = Self.digest(of: data)
        if let renewed = renewHead(matching: hash, at: capturedAt) { return renewed }
        let id = UUID()
        let fileName = "\(id.uuidString).txt"
        try writeBacking(data, named: fileName)
        let item = CaptureHistoryItem(
            id: id,
            fileName: fileName,
            displayName: Self.singleLine(text),
            kind: .text,
            capturedAt: capturedAt,
            byteSize: Int64(data.count),
            preview: Self.previewSnippet(text),
            contentHash: hash
        )
        return insert(item)
    }

    /// Records copied image bytes — a screenshot placed on the pasteboard rather
    /// than written to a file, say.
    @discardableResult
    public func record(
        imageData: Data,
        pathExtension: String,
        displayName: String,
        capturedAt: Date = Date()
    ) throws -> CaptureHistoryItem {
        guard imageData.count <= Self.maximumClipboardImageBytes else {
            throw CaptureError.payloadTooLarge("Copied image")
        }
        let hash = Self.digest(of: imageData)
        if let renewed = renewHead(matching: hash, at: capturedAt) { return renewed }
        let id = UUID()
        let fileName = "\(id.uuidString).\(pathExtension.lowercased())"
        try writeBacking(imageData, named: fileName)
        let item = CaptureHistoryItem(
            id: id,
            fileName: fileName,
            displayName: displayName,
            kind: .image,
            capturedAt: capturedAt,
            byteSize: Int64(imageData.count),
            contentHash: hash
        )
        return insert(item)
    }

    /// Records a set of copied file locations.
    ///
    /// Only the paths are stored — Clip does not copy the files themselves — so
    /// the entry stays small and reading the originals stays the user's choice.
    @discardableResult
    public func record(fileURLs: [URL], capturedAt: Date = Date()) throws -> CaptureHistoryItem {
        let paths = fileURLs.map { $0.standardizedFileURL.path }
        let joined = paths.joined(separator: "\n")
        let data = Data(joined.utf8)
        guard data.count <= Self.maximumClipboardFileListBytes else {
            throw CaptureError.payloadTooLarge("Copied file list")
        }
        let hash = Self.digest(of: data)
        if let renewed = renewHead(matching: hash, at: capturedAt) { return renewed }
        let id = UUID()
        let fileName = "\(id.uuidString).filelist"
        try writeBacking(data, named: fileName)
        let names = fileURLs.map { $0.lastPathComponent }
        let item = CaptureHistoryItem(
            id: id,
            fileName: fileName,
            displayName: Self.fileListLabel(count: fileURLs.count, names: names),
            kind: .fileList,
            capturedAt: capturedAt,
            byteSize: Int64(data.count),
            preview: names.joined(separator: ", "),
            contentHash: hash
        )
        return insert(item)
    }

    /// Files an entry into the history: applies the limit, deletes the backing
    /// files of anything that aged off the end, and persists the result. The
    /// single place an entry is added, so the limit and pruning are enforced
    /// once — including on the new entry itself, whose file `discardFiles` will
    /// remove if the limit expires it immediately.
    @discardableResult
    private func insert(_ item: CaptureHistoryItem) -> CaptureHistoryItem {
        let (kept, expired) = limit.apply(to: [item] + stored())
        discardFiles(for: expired)
        write(kept)
        return item
    }

    /// Writes an entry's own backing file into the history directory.
    private func writeBacking(_ data: Data, named fileName: String) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            throw CaptureError.historyUnavailable(fileName)
        }
    }

    /// If the newest entry carries the same content hash, bumps it to now and
    /// returns it; otherwise `nil`. This collapses a repeated copy of the same
    /// content — where macOS bumps `changeCount` without the content actually
    /// changing — into one entry.
    private func renewHead(matching hash: String, at capturedAt: Date) -> CaptureHistoryItem? {
        var items = stored()
        guard let head = items.first, head.contentHash == hash else { return nil }
        let renewed = head.renewed(at: capturedAt)
        items[0] = renewed
        write(items)
        return renewed
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func remove(_ id: UUID) {
        let remaining = stored().filter { $0.id != id }
        discardFiles(for: stored().filter { $0.id == id })
        write(remaining)
    }

    /// Empties the history, including the copied files.
    public func clear() {
        discardFiles(for: stored())
        write([])
    }

    private func stored() -> [CaptureHistoryItem] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([CaptureHistoryItem].self, from: data)
        else {
            cached = []
            return []
        }
        // An entry whose file went missing — a manual clean-out of the folder,
        // say — is dropped rather than shown as a broken row.
        let present = decoded.filter {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        }
        cached = present
        return present
    }

    private func write(_ items: [CaptureHistoryItem]) {
        cached = items
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: indexURL, options: .atomic)
        } catch {
            // The index is a cache of the folder's contents; a failed write
            // costs ordering, not the captures themselves.
        }
    }

    private func discardFiles(for items: [CaptureHistoryItem]) {
        for item in items {
            let target = url(for: item)
            // Belt and braces: this actor must never delete outside its own
            // directory, whatever ends up in the index. Compare by path so a
            // trailing slash — which `deletingLastPathComponent()` always adds —
            // does not read as a different location.
            guard target.deletingLastPathComponent().standardizedFileURL.path == directory.path
            else {
                continue
            }
            try? FileManager.default.removeItem(at: target)
        }
    }

    private func byteSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// The first non-empty line of copied text, trimmed and clipped, for the row
    /// title. Falls back to a fixed label for whitespace-only copies.
    private static func singleLine(_ text: String, limit: Int = 60) -> String {
        let line =
            text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Copied text" }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// A longer snippet of copied text for the row subtitle.
    private static func previewSnippet(_ text: String, limit: Int = 200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    /// A row title for a set of files: the single name, or a count.
    private static func fileListLabel(count: Int, names: [String]) -> String {
        switch count {
        case 1: names.first ?? "1 file"
        default: "\(count) files"
        }
    }
}
