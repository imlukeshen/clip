import Foundation

public enum LibraryLayout {
    public static let schemaVersion = 2

    public static func media(in root: URL) -> URL {
        root.appendingPathComponent("Media", isDirectory: true)
    }

    public static func inbox(in root: URL) -> URL {
        media(in: root).appendingPathComponent("Inbox", isDirectory: true)
    }

    public static func internalDirectory(in root: URL) -> URL {
        root.appendingPathComponent(".reel", isDirectory: true)
    }

    public static func database(in root: URL) -> URL {
        internalDirectory(in: root).appendingPathComponent("Library.sqlite")
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

    /// Persisted text-editor documents (`<assetID>.reeltext`), one per text asset.
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
}
