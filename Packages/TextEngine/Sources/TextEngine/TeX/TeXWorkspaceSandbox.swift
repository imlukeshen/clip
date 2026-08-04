import Foundation

struct TeXWorkspaceSandbox {
    static let maximumInputBytes: Int64 = 500 * 1_024 * 1_024
    static let maximumFileCount = 10_000

    let root: URL
    let source: URL
    let output: URL
    let mainRelativePath: String

    static func prepare(_ job: TeXJob) throws -> Self {
        let manager = FileManager.default
        let projectRoot = job.workingDirectory.resolvingSymlinksInPath()
        guard let mainRelativePath = safeRelativePath(for: job.mainFile, below: projectRoot) else {
            throw TeXEngineError.invalidMainFile
        }

        let root = manager.temporaryDirectory.appendingPathComponent(
            "clip-tex-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        do {
            try manager.createDirectory(at: source, withIntermediateDirectories: true)
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            try copyProjectFiles(
                job.projectFiles,
                projectRoot: projectRoot,
                destinationRoot: source
            )
            try applyOverrides(job.sourceOverrides, destinationRoot: source)
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }

        let stagedMain = source.appendingPathComponent(mainRelativePath)
        guard manager.isReadableFile(atPath: stagedMain.path) else {
            try? manager.removeItem(at: root)
            throw TeXEngineError.invalidMainFile
        }
        return Self(
            root: root,
            source: source,
            output: output,
            mainRelativePath: mainRelativePath
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func copyProjectFiles(
        _ files: [URL],
        projectRoot: URL,
        destinationRoot: URL
    ) throws {
        guard files.count <= maximumFileCount else {
            throw TeXEngineError.unsafeProjectEntry("too many project files")
        }
        let manager = FileManager.default
        var copiedBytes: Int64 = 0
        for file in Set(files.map(\.standardizedFileURL)) {
            guard let relativePath = safeRelativePath(for: file, below: projectRoot) else {
                throw TeXEngineError.unsafeProjectEntry(file.lastPathComponent)
            }
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw TeXEngineError.unsafeProjectEntry(relativePath)
            }
            copiedBytes += Int64(values.fileSize ?? 0)
            guard copiedBytes <= maximumInputBytes else {
                throw TeXEngineError.unsafeProjectEntry("project exceeds 500 MB")
            }
            if file.pathExtension.lowercased() == "tex" {
                try TeXSourceSecurity.validate(Data(contentsOf: file, options: [.mappedIfSafe]))
            }
            let destination = destinationRoot.appendingPathComponent(relativePath)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try manager.copyItem(at: file, to: destination)
        }
    }

    private static func applyOverrides(
        _ overrides: [String: Data],
        destinationRoot: URL
    ) throws {
        let manager = FileManager.default
        for (relativePath, data) in overrides {
            guard let destination = safeDestination(relativePath, below: destinationRoot) else {
                throw TeXEngineError.unsafeProjectEntry(relativePath)
            }
            try TeXSourceSecurity.validate(data)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        }
    }

    private static func safeRelativePath(for file: URL, below root: URL) -> String? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix =
            resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedFile.path.hasPrefix(rootPrefix) else { return nil }
        let relativePath = String(resolvedFile.path.dropFirst(rootPrefix.count))
        guard !relativePath.isEmpty, safeDestination(relativePath, below: resolvedRoot) != nil
        else {
            return nil
        }
        return relativePath
    }

    private static func safeDestination(_ relativePath: String, below root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
            URL(string: relativePath)?.scheme == nil
        else { return nil }
        let destination = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else { return nil }
        return destination
    }
}

enum TeXSourceSecurity {
    static func validate(_ data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else { return }
        let uncommented = source.components(separatedBy: .newlines).map(stripComment).joined(
            separator: "\n"
        )
        let patterns = [
            #"\\(?:immediate\s*)?write\s*18\b"#,
            #"\\csname\s*write\s*18\s*\\endcsname"#,
        ]
        for pattern in patterns {
            guard
                let expression = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                )
            else { continue }
            let range = NSRange(uncommented.startIndex..., in: uncommented)
            if expression.firstMatch(in: uncommented, range: range) != nil {
                throw TeXEngineError.unsafeSource("shell escape is disabled")
            }
        }
    }

    private static func stripComment(_ line: String) -> String {
        var slashCount = 0
        for index in line.indices {
            if line[index] == "\\" {
                slashCount += 1
                continue
            }
            if line[index] == "%", slashCount.isMultiple(of: 2) {
                return String(line[..<index])
            }
            slashCount = 0
        }
        return line
    }
}
