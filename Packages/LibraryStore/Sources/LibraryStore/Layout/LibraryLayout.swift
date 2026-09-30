import CoreModel
import Foundation

/// The single source of truth for every name the library writes inside a root.
///
/// Both the absolute-URL helpers and the relative paths persisted in the
/// database, in asset metadata, and in migration plans derive from the constants
/// in the `Names` section. Spelling a directory or extension literally anywhere
/// else reintroduces the drift these constants exist to prevent: a rename then
/// silently misses the copies and strands the files they point at.
public enum LibraryLayout {
    public static let schemaVersion = 2

    // MARK: - Names

    /// Hidden directory holding everything the library derives or persists itself.
    public static let internalDirectoryName = ".reel"

    /// Imported originals, the only user-facing tree the library owns.
    public static let mediaDirectoryName = "Media"

    /// Landing folder for captures the user has not filed yet.
    public static let inboxDirectoryName = "Inbox"

    /// Saved edit graphs, stored as packages beside `Media`.
    public static let projectsDirectoryName = "Projects"

    /// Structural text-editor overlay written for each text asset.
    public static let textDocumentExtension = TextDocument.fileExtension

    /// Project package directory inside `Projects`.
    public static let projectPackageExtension = "reelproj"

    /// Persisted image-editor document, one per image asset.
    public static let imageDocumentExtension = "reelimage"

    /// Persisted PDF-editor document, one per PDF asset.
    public static let pdfDocumentExtension = "reelpdf"

    /// Suffix of a generated poster frame.
    public static let thumbnailSuffix = "thumb.heic"

    /// Suffix of a generated audio waveform cache.
    public static let peaksSuffix = "peaks.bin"

    /// Filename of the library index.
    public static let databaseName = "Library.sqlite"

    // MARK: - Directories

    public static func media(in root: URL) -> URL {
        root.appendingPathComponent(mediaDirectoryName, isDirectory: true)
    }

    public static func inbox(in root: URL) -> URL {
        media(in: root).appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    public static func projects(in root: URL) -> URL {
        root.appendingPathComponent(projectsDirectoryName, isDirectory: true)
    }

    public static func internalDirectory(in root: URL) -> URL {
        root.appendingPathComponent(internalDirectoryName, isDirectory: true)
    }

    public static func database(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent(databaseName)
    }

    public static func metadata(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("assets", isDirectory: true)
    }

    public static func thumbnails(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("thumbs", isDirectory: true)
    }

    public static func peaks(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("peaks", isDirectory: true)
    }

    public static func imageDocuments(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("images", isDirectory: true)
    }

    public static func pdfDocuments(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("pdfs", isDirectory: true)
    }

    /// Persisted text-editor documents, one per text asset.
    public static func textDocuments(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("text", isDirectory: true)
    }

    /// Untitled scratch buffers, autosaved before they are ever named or imported.
    ///
    /// Like `history`, these are not assets and the library must never index them.
    public static func scratch(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("scratch", isDirectory: true)
    }

    /// Tectonic packages fetched only after consent, kept inspectable and clearable.
    public static func texCache(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("tex-cache", isDirectory: true)
    }

    /// Verified open-font packages used to preserve editable PDF typography.
    public static func pdfFontCache(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("pdf-fonts", isDirectory: true)
    }

    /// LaTeX project metadata such as the selected main file.
    public static func texProjects(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("tex", isDirectory: true)
    }

    /// Copies of recent system captures, staged for pasting.
    ///
    /// Deliberately outside `Media/`: entries here are not assets, they expire,
    /// and the library must never index them.
    public static func captureHistory(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("history", isDirectory: true)
    }

    // MARK: - Relative paths

    /// Relative path of the library index, as stored in migration plans.
    public static var databaseRelativePath: String {
        "\(internalDirectoryName)/\(databaseName)"
    }

    /// Relative path of an asset's sidecar metadata, as stored on disk.
    public static func metadataRelativePath(forAssetID id: String) -> String {
        "\(internalDirectoryName)/assets/\(id).json"
    }

    /// Relative path of an asset's poster frame, as stored in `asset.thumb_path`.
    public static func thumbnailRelativePath(forAssetID id: String) -> String {
        "\(internalDirectoryName)/thumbs/\(thumbnailFilename(forAssetID: id))"
    }

    /// Relative path of an asset's waveform cache, as stored in `asset.peaks_path`.
    public static func peaksRelativePath(forAssetID id: String) -> String {
        "\(internalDirectoryName)/peaks/\(peaksFilename(forAssetID: id))"
    }

    /// Relative path of a project package, as stored in `project.path`.
    public static func projectPackageRelativePath(forProjectID id: String) -> String {
        "\(projectsDirectoryName)/\(id).\(projectPackageExtension)"
    }

    // MARK: - Filenames

    public static func thumbnailFilename(forAssetID id: String) -> String {
        "\(id).\(thumbnailSuffix)"
    }

    public static func peaksFilename(forAssetID id: String) -> String {
        "\(id).\(peaksSuffix)"
    }

    public static func textDocumentFilename(forKey key: String) -> String {
        "\(key).\(textDocumentExtension)"
    }

    public static func imageDocumentFilename(forAssetID id: String) -> String {
        "\(id).\(imageDocumentExtension)"
    }

    public static func pdfDocumentFilename(forAssetID id: String) -> String {
        "\(id).\(pdfDocumentExtension)"
    }
}
