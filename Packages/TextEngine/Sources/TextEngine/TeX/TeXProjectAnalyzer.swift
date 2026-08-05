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
        var normalizedSources: [String: String] = [:]
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            guard let path = safeRelativePath(path), normalizedSources[path] == nil else {
                continue
            }
            normalizedSources[path] = source
        }

        if let selectedMainFile = selectedMainFile.flatMap(safeRelativePath),
            normalizedSources[selectedMainFile] != nil
        {
            return selectedMainFile
        }

        // TeX root magic comments are useful in projects where a chapter is opened
        // independently. Treat them as an explicit project-level hint, but only when
        // they resolve to another source inside the supplied project.
        let directedRoots = Set(
            normalizedSources.flatMap { sourcePath, source in
                rootDirectives(in: source).compactMap { directive in
                    resolveRootDirective(
                        directive,
                        from: sourcePath,
                        sources: normalizedSources
                    )
                }
            }
        )
        if let root = rankedMainFile(in: directedRoots, sources: normalizedSources) {
            return root
        }

        let documentCandidates = Set(
            normalizedSources
                .filter { path, source in
                    isTeXSource(path)
                        && uncommented(source).contains("\\documentclass")
                }
                .map(\.key)
        )
        return rankedMainFile(in: documentCandidates, sources: normalizedSources)
    }

    /// Produces a stable project-root choice independent of dictionary ordering and
    /// the host's current locale. Shallower files are more likely to be project roots;
    /// `main.tex` then wins conventional projects, followed by smaller sources.
    private static func rankedMainFile(
        in candidates: Set<String>,
        sources: [String: String]
    ) -> String? {
        candidates.sorted { lhs, rhs in
            let lhsDepth = pathDepth(lhs)
            let rhsDepth = pathDepth(rhs)
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }

            let lhsIsMain = URL(fileURLWithPath: lhs).lastPathComponent.lowercased() == "main.tex"
            let rhsIsMain = URL(fileURLWithPath: rhs).lastPathComponent.lowercased() == "main.tex"
            if lhsIsMain != rhsIsMain { return lhsIsMain }

            let lhsSize = sources[lhs]?.utf8.count ?? 0
            let rhsSize = sources[rhs]?.utf8.count ?? 0
            if lhsSize != rhsSize { return lhsSize < rhsSize }

            let lhsFolded = lhs.precomposedStringWithCanonicalMapping.lowercased()
            let rhsFolded = rhs.precomposedStringWithCanonicalMapping.lowercased()
            if lhsFolded != rhsFolded { return lhsFolded < rhsFolded }
            return lhs.precomposedStringWithCanonicalMapping
                < rhs.precomposedStringWithCanonicalMapping
        }.first
    }

    private static func rootDirectives(in source: String) -> [String] {
        let pattern = #"^\s*%\s*!\s*tex\s+root\s*=\s*(.+?)\s*$"#
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            )
        else { return [] }

        return source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .compactMap { line in
                let line = String(line)
                let string = line as NSString
                let range = NSRange(location: 0, length: string.length)
                guard
                    let match = expression.firstMatch(in: line, range: range),
                    match.numberOfRanges > 1,
                    match.range(at: 1).location != NSNotFound
                else { return nil }
                return unquoteRootDirective(string.substring(with: match.range(at: 1)))
            }
    }

    private static func unquoteRootDirective(_ directive: String) -> String {
        let value = directive.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, let first = value.first, let last = value.last else {
            return value
        }
        let isWrapped =
            (first == "\"" && last == "\"")
            || (first == "'" && last == "'")
            || (first == "{" && last == "}")
        return isWrapped
            ? String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            : value
    }

    private static func resolveRootDirective(
        _ directive: String,
        from sourcePath: String,
        sources: [String: String]
    ) -> String? {
        guard
            !directive.isEmpty,
            !directive.hasPrefix("/"),
            !directive.hasPrefix("~"),
            !directive.contains("\0")
        else { return nil }
        let directory = (sourcePath as NSString).deletingLastPathComponent
        let proposed = directory.isEmpty ? directive : "\(directory)/\(directive)"
        guard let normalized = safeRelativePath(proposed) else { return nil }

        let candidates: [String]
        if URL(fileURLWithPath: normalized).pathExtension.isEmpty {
            candidates = ["\(normalized).tex", "\(normalized).latex", normalized]
        } else {
            candidates = [normalized]
        }
        return candidates.first { isTeXSource($0) && sources[$0] != nil }
    }

    private static func pathDepth(_ path: String) -> Int {
        max(0, path.split(separator: "/", omittingEmptySubsequences: true).count - 1)
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
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasPrefix("~"),
            !path.contains("\0")
        else { return nil }

        // `NSString.standardizingPath` intentionally leaves `folder/../file`
        // untouched for relative paths. Resolve components lexically so a valid
        // chapter-to-root directive works without ever escaping the project root.
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
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
