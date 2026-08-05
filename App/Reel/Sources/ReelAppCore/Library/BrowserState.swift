import Foundation
import LibraryStore

public enum BrowserViewMode: String, Sendable, CaseIterable {
    case grid, list
}

public enum AssetSort: String, Sendable, CaseIterable {
    case name, kind, duration, size, modified
}

public enum AssetActivationRoute: Sendable, Equatable {
    case videoEditor
    case photoEditor
    case pdfEditor
    case textEditor
    case conversion
    case none

    public init(kind: AssetKind) {
        switch kind {
        case .video: self = .videoEditor
        case .image: self = .photoEditor
        case .document: self = .pdfEditor
        case .text: self = .textEditor
        case .audio: self = .none
        }
    }

    public init(asset: AssetRecord) {
        if asset.kind == .document, asset.container?.lowercased() != "pdf" {
            self = .conversion
        } else if asset.kind == .audio {
            self = .conversion
        } else {
            self.init(kind: asset.kind)
        }
    }
}

public enum BrowserSearch {
    public static func matches(_ asset: AssetRecord, query: String) -> Bool {
        let query = normalized(query)
        guard !query.isEmpty else { return true }
        return searchableValues(for: asset).contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    public static func matchingFolders(
        in root: FolderNode?,
        query: String
    ) -> [FolderNode] {
        let query = normalized(query)
        guard !query.isEmpty, let root else { return [] }
        return flatten(root.children ?? []).filter { folder in
            folder.name.localizedCaseInsensitiveContains(query)
                || folder.id.localizedCaseInsensitiveContains(query)
        }
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchableValues(for asset: AssetRecord) -> [String] {
        [
            asset.displayName,
            asset.relativePath,
            asset.kind.rawValue,
            asset.container ?? "",
            asset.codec ?? "",
            URL(fileURLWithPath: asset.displayName).pathExtension,
        ]
    }

    private static func flatten(_ folders: [FolderNode]) -> [FolderNode] {
        folders.flatMap { folder in
            [folder] + flatten(folder.children ?? [])
        }
    }
}
