import Foundation

public struct FolderNode: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var children: [FolderNode]?
    public var assetCount: Int

    public init(id: String, name: String, children: [FolderNode]?, assetCount: Int) {
        self.id = id
        self.name = name
        self.children = children
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
