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
}
