import CoreModel
import Foundation

/// An in-app drag that a library folder can receive.
///
/// The asset grid and the folder tree both drag plain text with a prefix, so
/// the receiving row has to tell the two apart. Files coming from Finder are
/// deliberately *not* modelled here: they arrive on a different pasteboard type
/// and the row reads them as URLs. Letting one representation coerce into the
/// other would be silent and wrong in both directions — `"assets:a,b"` is a
/// syntactically valid URL, and a dragged file also advertises its path as
/// text — so an import would become a move, or a move an import.
public enum LibraryFolderDrop: Equatable, Sendable {
    /// One or more library files, identified by the grid's current selection.
    case assets([AssetID])
    /// A folder, by its path relative to the media root.
    case folder(String)

    private static let assetsPrefix = "assets:"
    private static let folderPrefix = "folder:"

    /// Reads a drag payload, or returns nil when the text is not one of ours.
    public init?(payload: String) {
        if payload.hasPrefix(Self.assetsPrefix) {
            let ids =
                payload.dropFirst(Self.assetsPrefix.count)
                .split(separator: ",")
                .map { AssetID(rawValue: String($0)) }
            guard !ids.isEmpty else { return nil }
            self = .assets(ids)
        } else if payload.hasPrefix(Self.folderPrefix) {
            let path = String(payload.dropFirst(Self.folderPrefix.count))
            guard !path.isEmpty else { return nil }
            self = .folder(path)
        } else {
            return nil
        }
    }

    /// The text an asset drag carries.
    public static func payload(forAssets ids: [AssetID]) -> String {
        assetsPrefix + ids.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// The text a folder drag carries.
    public static func payload(forFolder path: String) -> String {
        folderPrefix + path
    }

    /// Whether dropping this onto `destination` would do anything.
    ///
    /// A folder cannot be dropped on itself or into its own subtree; the store
    /// rejects both, but catching them here keeps the row from flashing as a
    /// valid target for a move that is about to fail.
    public func canDrop(into destination: String) -> Bool {
        switch self {
        case .assets(let ids):
            return !ids.isEmpty
        case .folder(let path):
            return path != destination && !destination.hasPrefix(path + "/")
        }
    }
}
