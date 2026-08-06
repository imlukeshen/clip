import CoreModel
import Foundation
import Testing

@testable import LibraryStore

@Suite("Managed library path safety")
struct PathSafetyTests {
    @Test("Asset paths cannot traverse outside Media")
    func rejectsTraversal() async throws {
        let root = try makeRoot("traversal")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        let store = try await makeStore(root)
        let asset = textAsset(id: "safe-id", relativePath: "Media/../outside.md")

        await #expect(throws: LibraryError.self) {
            try await store.insert(asset)
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    }

    @Test("Intermediate symbolic links cannot escape Media")
    func rejectsIntermediateSymlink() async throws {
        let root = try makeRoot("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeRoot("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("target.md")
        try Data("outside".utf8).write(to: target)
        let link = LibraryLayout.media(in: root).appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = try await makeStore(root)

        await #expect(throws: LibraryError.self) {
            try await store.insert(
                textAsset(id: "linked-id", relativePath: "Media/Linked/target.md")
            )
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "outside")
    }

    @Test("A library opened through a symbolic-link root remains usable")
    func acceptsCanonicalizedRootSymlink() async throws {
        let root = try makeRoot("canonical-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.deletingLastPathComponent().appendingPathComponent(
            "clip-path-safety-root-link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let media = LibraryLayout.inbox(in: root).appendingPathComponent("linked.md")
        try Data("text".utf8).write(to: media)
        let store = try await makeStore(link)
        let asset = textAsset(id: "linked-root", relativePath: "Media/Inbox/linked.md")

        try await store.insert(asset)

        #expect(try await store.asset(id: asset.id)?.relativePath == asset.relativePath)
    }

    @Test("Path-derived asset and project identifiers reject separators")
    func rejectsUnsafeIdentifiers() async throws {
        let root = try makeRoot("identifiers")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = LibraryLayout.inbox(in: root)
        try Data("text".utf8).write(to: inbox.appendingPathComponent("text.md"))
        let store = try await makeStore(root)

        await #expect(throws: LibraryError.self) {
            try await store.insert(
                textAsset(id: "../metadata-escape", relativePath: "Media/Inbox/text.md")
            )
        }
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "../project-escape"),
            name: "Unsafe",
            createdAt: .now,
            modifiedAt: .now
        )
        await #expect(throws: LibraryError.self) {
            try await store.saveProject(document)
        }
    }

    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-path-safety-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: LibraryLayout.inbox(in: root),
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeStore(_ root: URL) async throws -> LibraryStore {
        try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
    }

    private func textAsset(id: String, relativePath: String) -> AssetRecord {
        AssetRecord(
            id: AssetID(rawValue: id),
            relativePath: relativePath,
            displayName: "text.md",
            kind: .text,
            container: "md",
            createdAt: .now,
            importedAt: .now,
            byteSize: 4,
            contentHash: "hash-\(id)",
            ingestState: .ready
        )
    }
}
