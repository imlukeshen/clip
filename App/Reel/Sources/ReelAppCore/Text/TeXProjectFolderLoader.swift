import Foundation
import TextEngine

public struct TeXProjectFolder: Sendable {
    public var rootURL: URL
    public var textFiles: [String: LoadedTextFile]
    public var fileURLs: [String: URL]

    public init(
        rootURL: URL,
        textFiles: [String: LoadedTextFile],
        fileURLs: [String: URL]
    ) {
        self.rootURL = rootURL
        self.textFiles = textFiles
        self.fileURLs = fileURLs
    }
}

public enum TeXProjectFolderError: Error, Sendable, Equatable {
    case tooManyFiles
    case tooLarge
    case unsafeEntry(String)
    case noTextFiles
}

public enum TeXProjectFolderLoader {
    private static let supportedTextExtensions: Set<String> = [
        "tex", "latex", "sty", "cls", "bib",
    ]
    private static let fileLimit = 10_000
    private static let byteLimit: Int64 = 500 * 1_024 * 1_024

    public static func load(rootURL: URL) throws -> TeXProjectFolder {
        let rootURL = rootURL.standardizedFileURL
        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { throw TeXProjectFolderError.noTextFiles }
        var count = 0
        var bytes: Int64 = 0
        var textFiles: [String: LoadedTextFile] = [:]
        var fileURLs: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            count += 1
            guard count <= fileLimit else { throw TeXProjectFolderError.tooManyFiles }
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                throw TeXProjectFolderError.unsafeEntry(fileURL.lastPathComponent)
            }
            guard values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            guard bytes <= byteLimit else { throw TeXProjectFolderError.tooLarge }
            let relativePath = try relativePath(for: fileURL, root: rootURL)
            fileURLs[relativePath] = fileURL.standardizedFileURL
            if supportedTextExtensions.contains(fileURL.pathExtension.lowercased()) {
                textFiles[relativePath] = try TextFileLoader.load(from: fileURL)
            }
        }
        guard !textFiles.isEmpty else { throw TeXProjectFolderError.noTextFiles }
        return TeXProjectFolder(
            rootURL: rootURL,
            textFiles: textFiles,
            fileURLs: fileURLs
        )
    }

    /// Finds the nearest ancestor whose inferred main file reaches the selected source.
    public static func loadProject(
        containing selectedURL: URL,
        boundaryURL: URL
    ) throws -> TeXProjectFolder {
        let selectedURL = selectedURL.standardizedFileURL
        let boundaryURL = boundaryURL.standardizedFileURL
        var candidate = selectedURL.deletingLastPathComponent()
        var fallback: TeXProjectFolder?
        while isContained(candidate, in: boundaryURL) {
            do {
                let project = try load(rootURL: candidate)
                if fallback == nil { fallback = project }
                let selectedPath = try relativePath(for: selectedURL, root: candidate)
                let sources = project.textFiles.mapValues(\.text)
                let analysis = TeXProjectAnalyzer.analyze(
                    sources: sources,
                    availableFiles: Set(project.fileURLs.keys)
                )
                if analysis.mainFile != nil, analysis.reachableFiles.contains(selectedPath) {
                    return project
                }
            } catch let error as TeXProjectFolderError {
                switch error {
                case .tooManyFiles, .tooLarge:
                    break
                case .unsafeEntry, .noTextFiles:
                    if candidate == selectedURL.deletingLastPathComponent() { throw error }
                }
            }
            if candidate == boundaryURL { break }
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { break }
            candidate = parent
        }
        guard let fallback else { throw TeXProjectFolderError.noTextFiles }
        return fallback
    }

    private static func relativePath(for url: URL, root: URL) throws -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw TeXProjectFolderError.unsafeEntry(url.lastPathComponent)
        }
        return String(path.dropFirst(rootPath.count))
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        url == root || url.path.hasPrefix(root.path + "/")
    }
}
