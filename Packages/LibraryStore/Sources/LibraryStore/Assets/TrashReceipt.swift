import CoreModel
import Foundation

public protocol FileTrashManaging: Sendable {
    func trashItem(at url: URL) throws -> URL
}

public struct SystemTrashManager: FileTrashManaging {
    public init() {}

    public func trashItem(at url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else {
            throw LibraryError.fileOperationFailed("move item to Trash")
        }
        return result as URL
    }
}

public struct TrashReceipt: Sendable {
    public struct MovedFile: Sendable {
        public var originalURL: URL
        public var trashedURL: URL

        public init(originalURL: URL, trashedURL: URL) {
            self.originalURL = originalURL
            self.trashedURL = trashedURL
        }
    }

    public struct Item: Sendable {
        public var asset: AssetRecord
        public var movedFiles: [MovedFile]
        public var referencingProjectIDs: [ProjectID]

        public init(
            asset: AssetRecord,
            movedFiles: [MovedFile],
            referencingProjectIDs: [ProjectID]
        ) {
            self.asset = asset
            self.movedFiles = movedFiles
            self.referencingProjectIDs = referencingProjectIDs
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}
