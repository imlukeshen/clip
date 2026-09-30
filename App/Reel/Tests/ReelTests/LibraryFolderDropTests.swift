import CoreModel
import Testing

@testable import ReelAppCore

@Suite("Library folder drop")
struct LibraryFolderDropTests {
    @Test("An asset drag round-trips through its payload")
    func assetPayloadRoundTrip() throws {
        let ids = [AssetID(rawValue: "b"), AssetID(rawValue: "a")]
        let payload = LibraryFolderDrop.payload(forAssets: ids)
        #expect(
            LibraryFolderDrop(payload: payload)
                == .assets([
                    AssetID(rawValue: "a"), AssetID(rawValue: "b"),
                ]))
    }

    @Test("A folder drag round-trips through its payload")
    func folderPayloadRoundTrip() throws {
        let payload = LibraryFolderDrop.payload(forFolder: "Papers/Drafts")
        #expect(LibraryFolderDrop(payload: payload) == .folder("Papers/Drafts"))
    }

    @Test("Text that is not one of ours is not a drag payload")
    func foreignTextIsRejected() {
        // A file dragged from Finder also offers its path as plain text. Reading
        // that as a move instead of an import would file an asset that does not
        // exist yet, so anything unprefixed has to be refused outright.
        #expect(LibraryFolderDrop(payload: "/Users/someone/paper.tex") == nil)
        #expect(LibraryFolderDrop(payload: "file:///Users/someone/paper.tex") == nil)
        #expect(LibraryFolderDrop(payload: "") == nil)
        #expect(LibraryFolderDrop(payload: "assets:") == nil)
        #expect(LibraryFolderDrop(payload: "folder:") == nil)
    }

    @Test("A folder cannot be dropped into itself or its own subtree")
    func folderCannotSwallowItself() {
        let drop = LibraryFolderDrop.folder("Papers")
        #expect(!drop.canDrop(into: "Papers"))
        #expect(!drop.canDrop(into: "Papers/Drafts"))
        #expect(drop.canDrop(into: "Inbox"))
        // A sibling whose name merely starts with the same characters is a
        // different folder, not a descendant.
        #expect(drop.canDrop(into: "PapersArchive"))
    }

    @Test("Assets can be dropped into any folder")
    func assetsDropAnywhere() {
        let drop = LibraryFolderDrop.assets([AssetID(rawValue: "a")])
        #expect(drop.canDrop(into: "Inbox"))
        #expect(drop.canDrop(into: "Papers/Drafts"))
        #expect(!LibraryFolderDrop.assets([]).canDrop(into: "Inbox"))
    }
}
