import Foundation
import TextEngine
import UniformTypeIdentifiers

/// Selects a workspace from the dropped file's type, independent of the visible tab.
public enum WorkspaceRouter {
    public static func destination(for url: URL) -> Workspace {
        destination(forFilename: url.lastPathComponent)
    }

    public static func destination(forFilename filename: String) -> Workspace {
        let pathExtension = URL(fileURLWithPath: filename).pathExtension
        // A recognized text or code extension routes to the text workspace even
        // when its UTType also conforms to a broader type, so ingest and routing
        // agree on the same set.
        if LanguageDetector.recognizedExtensions.contains(pathExtension.lowercased()) {
            return .text
        }
        guard let type = UTType(filenameExtension: pathExtension) else {
            return .convert
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) { return .video }
        return .convert
    }
}
