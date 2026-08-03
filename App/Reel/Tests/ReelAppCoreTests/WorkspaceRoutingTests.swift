import CoreModel
import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

@Suite("Workspace routing")
struct WorkspaceRoutingTests {
    @Test(
        "Dropped files route by type instead of the active workspace",
        arguments: [
            ("walkthrough.mov", Workspace.video),
            ("capture.png", Workspace.photo),
            ("notes.pdf", Workspace.pdf),
            ("voice.m4a", Workspace.convert),
        ]
    )
    func routesByType(filename: String, expected: Workspace) {
        #expect(WorkspaceRouter.destination(forFilename: filename) == expected)
    }

    @Test("Every workspace declares a leading drop zone")
    func everyWorkspaceAcceptsDrops() {
        #expect(Workspace.allCases.allSatisfy { $0.hasDropZone })
    }

    @Test("Navigation commands keep the displayed workspace in sync")
    @MainActor
    func navigationCommands() {
        let model = AppModel(
            libraryRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("reel-navigation-tests", isDirectory: true)
        )
        model.searchQuery = "launch"

        AppCommandRouter.run("navigation.photo", in: model)
        #expect(model.selectedWorkspace == .photo)
        #expect(model.searchQuery == "launch")

        AppCommandRouter.run("navigation.pdf", in: model)
        #expect(model.selectedWorkspace == .pdf)

        AppCommandRouter.run("navigation.convert", in: model)
        #expect(model.selectedWorkspace == .convert)
        #expect(model.searchQuery.isEmpty)
    }

    @Test("Asset activation routes every editable media kind")
    func activationRoutes() {
        #expect(AssetActivationRoute(kind: .video) == .videoEditor)
        #expect(AssetActivationRoute(kind: .image) == .photoEditor)
        #expect(AssetActivationRoute(kind: .document) == .pdfEditor)
        #expect(AssetActivationRoute(kind: .audio) == .none)
    }

    @Test("Search matches names, folders, types, formats, and codecs")
    func mediaSearch() {
        let asset = AssetRecord(
            id: AssetID(rawValue: "search-fixture"),
            relativePath: "Media/Clients/Acme/Launch Walkthrough.mov",
            displayName: "Launch Walkthrough.mov",
            kind: .video,
            container: "mov",
            codec: "h264",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            importedAt: Date(timeIntervalSince1970: 1_700_000_001),
            byteSize: 42,
            contentHash: "search-hash",
            ingestState: .ready
        )

        for query in ["launch", "acme", "video", "mov", "h264"] {
            #expect(BrowserSearch.matches(asset, query: query))
        }
        #expect(!BrowserSearch.matches(asset, query: "invoice"))
    }

    @Test("Folder search includes matching nested paths")
    func folderSearch() {
        let tree = FolderNode(
            id: "",
            name: "Media",
            children: [
                FolderNode(
                    id: "Clients",
                    name: "Clients",
                    children: [
                        FolderNode(
                            id: "Clients/Acme",
                            name: "Acme",
                            children: [],
                            assetCount: 4
                        )
                    ],
                    assetCount: 0
                )
            ],
            assetCount: 0
        )

        #expect(
            BrowserSearch.matchingFolders(in: tree, query: "acme").map(\.id) == ["Clients/Acme"])
        #expect(BrowserSearch.matchingFolders(in: tree, query: "clients").count == 2)
    }
}
