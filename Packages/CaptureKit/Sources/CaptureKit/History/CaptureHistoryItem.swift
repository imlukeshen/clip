import Foundation

/// One entry in the clipboard history: something Clip copied — a screenshot, a
/// recording, a run of text, or a set of files — kept on disk so it can be put
/// back on the pasteboard later.
public struct CaptureHistoryItem: Codable, Sendable, Equatable, Identifiable {
    /// What the entry holds, which decides how it previews and how it pastes.
    public enum Kind: String, Codable, Sendable {
        case image
        case video
        case text
        case fileList
    }

    public let id: UUID
    /// The entry's file name inside the history directory.
    public let fileName: String
    /// A short label for the entry, shown as the row's title.
    public let displayName: String
    public let kind: Kind
    public let capturedAt: Date
    public let byteSize: Int64
    /// A longer snippet shown alongside the title — the text itself, or the
    /// names in a file set. `nil` for entries a thumbnail already speaks for.
    public let preview: String?
    /// A digest of the entry's content, used to collapse a copy that repeats
    /// what is already at the top of the history. `nil` when hashing was skipped.
    public let contentHash: String?

    public init(
        id: UUID = UUID(),
        fileName: String,
        displayName: String,
        kind: Kind,
        capturedAt: Date,
        byteSize: Int64,
        preview: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.kind = kind
        self.capturedAt = capturedAt
        self.byteSize = byteSize
        self.preview = preview
        self.contentHash = contentHash
    }

    /// Whether the entry is media the library can hold. Text and file-set
    /// entries are pasteboard-only; their backing file is a sidecar, not an
    /// asset, so they are never offered for saving.
    public var canSaveToLibrary: Bool {
        switch kind {
        case .image, .video: true
        case .text, .fileList: false
        }
    }

    /// The same entry marked as freshly copied, used when a repeat copy bumps an
    /// existing entry to the top instead of adding a duplicate.
    func renewed(at capturedAt: Date) -> CaptureHistoryItem {
        CaptureHistoryItem(
            id: id,
            fileName: fileName,
            displayName: displayName,
            kind: kind,
            capturedAt: capturedAt,
            byteSize: byteSize,
            preview: preview,
            contentHash: contentHash
        )
    }

    /// The kind a file extension implies for a *system capture*, or `nil` for
    /// anything the capture folder has no business staging.
    ///
    /// This classifies files macOS writes for screenshots and recordings, so it
    /// is deliberately media-only: text and file-set entries are created by the
    /// clipboard watcher with their kind set directly, never inferred from a
    /// path here.
    public static func kind(forPathExtension pathExtension: String) -> Kind? {
        switch pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "tif", "tiff": .image
        case "mov", "mp4", "m4v": .video
        case _: nil
        }
    }
}
