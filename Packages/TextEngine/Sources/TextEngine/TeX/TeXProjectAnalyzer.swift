import Foundation

public struct TeXProjectAnalysis: Sendable, Equatable {
    public var mainFile: String?
    public var reachableFiles: Set<String>
    public var unreachableTeXFiles: Set<String>
    public var dependencies: [String: Set<String>]
    public var missingDependencies: Set<String>
    public var bibliography: BibMode

    public init(
        mainFile: String?,
        reachableFiles: Set<String>,
        unreachableTeXFiles: Set<String>,
        dependencies: [String: Set<String>],
        missingDependencies: Set<String>,
        bibliography: BibMode
    ) {
        self.mainFile = mainFile
        self.reachableFiles = reachableFiles
        self.unreachableTeXFiles = unreachableTeXFiles
        self.dependencies = dependencies
        self.missingDependencies = missingDependencies
        self.bibliography = bibliography
    }
}

/// Resolves a bounded LaTeX folder into the files required by its main source.
public enum TeXProjectAnalyzer {
    public static func analyze(
        sources: [String: String],
        availableFiles: Set<String>,
        selectedMainFile: String? = nil
    ) -> TeXProjectAnalysis {
        var normalizedSources: [String: String] = [:]
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            guard let path = safeRelativePath(path), normalizedSources[path] == nil else {
                continue
            }
            normalizedSources[path] = source
        }
        let normalizedAvailable = Set(availableFiles.compactMap(safeRelativePath))
        let mainFile = inferMainFile(
            sources: normalizedSources,
            selectedMainFile: selectedMainFile
        )
        var dependencies: [String: Set<String>] = [:]
        for (path, source) in normalizedSources {
            dependencies[path] = referencedFiles(
                in: source,
                from: path,
                availableFiles: normalizedAvailable
            )
        }
        var reachable: Set<String> = []
        var missing: Set<String> = []
        if let mainFile {
            var pending = [mainFile]
            while let path = pending.popLast() {
                guard reachable.insert(path).inserted else { continue }
                for dependency in dependencies[path] ?? [] {
                    if normalizedAvailable.contains(dependency) {
                        pending.append(dependency)
                    } else {
                        missing.insert(dependency)
                    }
                }
            }
        }
        let texSources = Set(normalizedSources.keys.filter(isTeXSource))
        let reachableSource = reachable.compactMap { normalizedSources[$0] }.joined(separator: "\n")
        let bibliography: BibMode
        if commandMatches("addbibresource", in: reachableSource).isEmpty == false {
            bibliography = .biber
        } else if commandMatches("bibliography", in: reachableSource).isEmpty == false {
            bibliography = .bibtex
        } else {
            bibliography = .none
        }
        return TeXProjectAnalysis(
            mainFile: mainFile,
            reachableFiles: reachable,
            unreachableTeXFiles: texSources.subtracting(reachable),
            dependencies: dependencies,
            missingDependencies: missing,
            bibliography: bibliography
        )
    }

    public static func inferMainFile(
        sources: [String: String],
        selectedMainFile: String? = nil
    ) -> String? {
        if let selectedMainFile = selectedMainFile.flatMap(safeRelativePath),
            sources[selectedMainFile] != nil
        {
            return selectedMainFile
        }
        return
            sources
            .filter { path, source in
                isTeXSource(path)
                    && uncommented(source).contains("\\documentclass")
            }
            .map(\.key)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
    }

    private static func referencedFiles(
        in source: String,
        from sourcePath: String,
        availableFiles: Set<String>
    ) -> Set<String> {
        let source = uncommented(source)
        var references: Set<String> = []
        for command in ["input", "include", "subfile"] {
            for value in commandMatches(command, in: source) {
                appendReference(
                    value,
                    defaultExtension: "tex",
                    sourcePath: sourcePath,
                    availableFiles: availableFiles,
                    into: &references
                )
            }
        }
        for value in commandMatches("bibliography", in: source) {
            for item in value.split(separator: ",") {
                appendReference(
                    String(item),
                    defaultExtension: "bib",
                    sourcePath: sourcePath,
                    availableFiles: availableFiles,
                    into: &references
                )
            }
        }
        for value in commandMatches("addbibresource", in: source) {
            appendReference(
                value,
                defaultExtension: "bib",
                sourcePath: sourcePath,
                availableFiles: availableFiles,
                into: &references
            )
        }
        for value in commandMatches("includegraphics", in: source) {
            appendReference(
                value,
                defaultExtension: nil,
                sourcePath: sourcePath,
                availableFiles: availableFiles,
                into: &references
            )
        }
        for value in commandMatches("usepackage", in: source) {
            for item in value.split(separator: ",") {
                appendLocalPackage(
                    String(item),
                    extension: "sty",
                    sourcePath: sourcePath,
                    availableFiles: availableFiles,
                    into: &references
                )
            }
        }
        for value in commandMatches("documentclass", in: source) {
            appendLocalPackage(
                value,
                extension: "cls",
                sourcePath: sourcePath,
                availableFiles: availableFiles,
                into: &references
            )
        }
        return references
    }

    private static func commandMatches(_ command: String, in source: String) -> [String] {
        let pattern =
            #"\\"# + NSRegularExpression.escapedPattern(for: command)
            + #"(?:\s*\[[^\]]*\])?\s*\{([^}]*)\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = source as NSString
        return expression.matches(
            in: source,
            range: NSRange(location: 0, length: string.length)
        ).compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else {
                return nil
            }
            return string.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func appendReference(
        _ rawValue: String,
        defaultExtension: String?,
        sourcePath: String,
        availableFiles: Set<String>,
        into references: inout Set<String>
    ) {
        let rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty, !rawValue.contains("\\") else { return }
        let directory = (sourcePath as NSString).deletingLastPathComponent
        let proposed = directory.isEmpty ? rawValue : "\(directory)/\(rawValue)"
        guard var path = safeRelativePath(proposed) else { return }
        if URL(fileURLWithPath: path).pathExtension.isEmpty, let defaultExtension {
            path += ".\(defaultExtension)"
        }
        if defaultExtension == nil, URL(fileURLWithPath: path).pathExtension.isEmpty {
            let supported = ["pdf", "png", "jpg", "jpeg", "eps"]
            if let match = supported.lazy.map({ "\(path).\($0)" }).first(where: {
                availableFiles.contains($0)
            }) {
                path = match
            }
        }
        references.insert(path)
    }

    private static func appendLocalPackage(
        _ rawValue: String,
        extension pathExtension: String,
        sourcePath: String,
        availableFiles: Set<String>,
        into references: inout Set<String>
    ) {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let directory = (sourcePath as NSString).deletingLastPathComponent
        let proposed =
            directory.isEmpty
            ? "\(name).\(pathExtension)" : "\(directory)/\(name).\(pathExtension)"
        guard let path = safeRelativePath(proposed), availableFiles.contains(path) else { return }
        references.insert(path)
    }

    private static func safeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let normalized = (path as NSString).standardizingPath
        guard normalized != "..", !normalized.hasPrefix("../") else { return nil }
        return normalized == "." ? nil : normalized
    }

    private static func isTeXSource(_ path: String) -> Bool {
        ["tex", "latex"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func uncommented(_ source: String) -> String {
        source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line in
                var escaped = false
                var result = ""
                for character in line {
                    if character == "%", !escaped { break }
                    result.append(character)
                    if character == "\\" {
                        escaped.toggle()
                    } else {
                        escaped = false
                    }
                }
                return result
            }
            .joined(separator: "\n")
    }
}
