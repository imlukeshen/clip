import Foundation

/// One command in a run: a compile, or the program itself.
struct CodeRunStep: Sendable, Equatable {
    var executableURL: URL
    var arguments: [String]

    /// The step as a Terminal command, with staged paths shortened to the
    /// names the user recognises.
    func commandLine(replacing stagingRoot: URL) -> String {
        let root = stagingRoot.path + "/"
        let parts = [executableURL.lastPathComponent] + arguments
        return parts.map { $0.replacingOccurrences(of: root, with: "") }.joined(separator: " ")
    }
}
