import Foundation

public struct FolderNode: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// Child folders, loaded only while this folder is expanded.
    public var children: [FolderNode]?
    /// Whether this folder contains subfolders, known whether or not it is
    /// expanded.
    ///
    /// `children` is nil both for a folder with nothing inside it and for one
    /// that simply has not been loaded, so it cannot answer this. A disclosure
    /// control that reads it directly disappears the moment its folder is
    /// collapsed, leaving no way to expand the folder again.
    public var hasChildren: Bool
    public var assetCount: Int

    public init(
        id: String,
        name: String,
        children: [FolderNode]?,
        hasChildren: Bool? = nil,
        assetCount: Int
    ) {
        self.id = id
        self.name = name
        self.children = children
        self.hasChildren = hasChildren ?? !(children ?? []).isEmpty
        self.assetCount = assetCount
    }
}

public struct FolderTrashReceipt: Sendable {
    public var assets: TrashReceipt
    public var originalURL: URL
    public var trashedURL: URL

    public init(assets: TrashReceipt, originalURL: URL, trashedURL: URL) {
        self.assets = assets
        self.originalURL = originalURL
        self.trashedURL = trashedURL
    }
}
