import Foundation

public enum CompletionAction: String, Codable, Sendable, CaseIterable {
    case reveal, copyPath, nothing
}

public struct ExportDestination: Codable, Sendable, Equatable {
    public var bookmarkKey: String
    public var subpathTemplate: String
    public var filenameTemplate: String
    public var onCompletion: CompletionAction

    public init(
        bookmarkKey: String,
        subpathTemplate: String = "Exports/{date}",
        filenameTemplate: String = "{project}-{preset}",
        onCompletion: CompletionAction = .reveal
    ) {
        self.bookmarkKey = bookmarkKey
        self.subpathTemplate = subpathTemplate
        self.filenameTemplate = filenameTemplate
        self.onCompletion = onCompletion
    }

    public func validate() throws {
        let allowed = Set([
            "project", "date", "time", "preset", "codec", "resolution", "duration", "index",
        ])
        for template in [subpathTemplate, filenameTemplate] {
            var remainder = template[...]
            while let open = remainder.firstIndex(of: "{") {
                guard let close = remainder[open...].firstIndex(of: "}") else {
                    throw ExportDestinationError.unclosedToken
                }
                let name = String(remainder[remainder.index(after: open)..<close])
                guard allowed.contains(name) else {
                    throw ExportDestinationError.invalidToken(name)
                }
                remainder = remainder[remainder.index(after: close)...]
            }
        }
        guard !subpathTemplate.hasPrefix("/"),
            !subpathTemplate.split(separator: "/").contains(".."),
            !filenameTemplate.isEmpty, !filenameTemplate.contains("/")
        else { throw ExportDestinationError.invalidPath }
    }

    public func resolve(
        in folder: URL,
        context: ExportTemplateContext,
        extension pathExtension: String
    ) throws -> URL {
        try validate()
        let values = context.values
        let subpath = try render(subpathTemplate, values: values)
        let filename = try render(filenameTemplate, values: values)
        return folder.appendingPathComponent(subpath, isDirectory: true)
            .appendingPathComponent(filename)
            .appendingPathExtension(pathExtension)
    }

    private func render(_ template: String, values: [String: String]) throws -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: sanitize(value))
        }
        guard !result.contains("{") && !result.contains("}") else {
            throw ExportDestinationError.invalidPath
        }
        return result
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

public struct ExportTemplateContext: Sendable, Equatable {
    public var project: String
    public var date: Date
    public var preset: String
    public var codec: String
    public var resolution: String
    public var duration: String
    public var index: Int

    public init(
        project: String,
        date: Date = .now,
        preset: String,
        codec: String,
        resolution: String,
        duration: String,
        index: Int = 1
    ) {
        self.project = project
        self.date = date
        self.preset = preset
        self.codec = codec
        self.resolution = resolution
        self.duration = duration
        self.index = index
    }

    fileprivate var values: [String: String] {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH-mm-ss"
        return [
            "project": project,
            "date": dateFormatter.string(from: date),
            "time": timeFormatter.string(from: date),
            "preset": preset,
            "codec": codec,
            "resolution": resolution,
            "duration": duration,
            "index": String(index),
        ]
    }
}

public enum ExportDestinationError: Error, Sendable, Equatable, LocalizedError {
    case invalidToken(String)
    case unclosedToken
    case invalidPath

    public var errorDescription: String? {
        switch self {
        case .invalidToken(let token): "Unknown template token {\(token)}."
        case .unclosedToken: "A template token is missing its closing brace."
        case .invalidPath: "The export template does not form a safe path."
        }
    }
}
