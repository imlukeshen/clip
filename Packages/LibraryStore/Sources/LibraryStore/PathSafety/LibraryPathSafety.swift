import Foundation

/// Central path validation for files managed by a library. Managed paths are
/// relative, canonical descendants and may not traverse symbolic links. This
/// keeps writes and Trash operations inside the user-selected library even when
/// its metadata has been tampered with.
enum LibraryPathSafety {
    static func resolve(
        _ relativePath: String,
        root: URL,
        boundary: URL,
        allowBoundary: Bool = false
    ) throws -> URL {
        guard relativePath.utf8.count <= 4_096, !relativePath.hasPrefix("/") else {
            throw LibraryError.invalidRelativePath(relativePath)
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw LibraryError.invalidRelativePath(relativePath)
        }

        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalBoundary = boundary.resolvingSymlinksInPath().standardizedFileURL
        guard contains(canonicalBoundary, within: canonicalRoot, allowBoundary: true) else {
            throw LibraryError.invalidRelativePath(relativePath)
        }

        var candidate = canonicalRoot
        for component in components {
            candidate.appendPathComponent(String(component))
            if isSymbolicLink(candidate) {
                throw LibraryError.invalidRelativePath(relativePath)
            }
        }
        candidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard contains(candidate, within: canonicalBoundary, allowBoundary: allowBoundary) else {
            throw LibraryError.invalidRelativePath(relativePath)
        }
        return candidate
    }

    static func validateIdentifier(_ rawValue: String) throws {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 200,
            rawValue != ".", rawValue != "..",
            rawValue.unicodeScalars.allSatisfy({ scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || CharacterSet(charactersIn: "-_").contains(scalar)
            })
        else {
            throw LibraryError.invalidRelativePath(rawValue)
        }
    }

    private static func contains(
        _ candidate: URL,
        within boundary: URL,
        allowBoundary: Bool
    ) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let boundaryPath = boundary.standardizedFileURL.path
        return (allowBoundary && candidatePath == boundaryPath)
            || candidatePath.hasPrefix(boundaryPath + "/")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
