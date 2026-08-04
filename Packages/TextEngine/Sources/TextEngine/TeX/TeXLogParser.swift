import Foundation

public enum TeXLogParser {
    public static func diagnostics(in log: String) -> [TeXDiagnostic] {
        let lines = log.components(separatedBy: .newlines)
        var diagnostics: [TeXDiagnostic] = []
        var pendingError: (message: String, file: String?)?
        var currentFile: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let tracedFile = tracedFile(in: trimmed) { currentFile = tracedFile }
            if let diagnostic = fileLineDiagnostic(trimmed) {
                diagnostics.append(diagnostic)
                pendingError = nil
                continue
            }
            if trimmed.hasPrefix("! ") {
                pendingError = (String(trimmed.dropFirst(2)), currentFile)
                continue
            }
            if let lineNumber = texLineNumber(trimmed), let error = pendingError {
                diagnostics.append(
                    TeXDiagnostic(
                        severity: .error,
                        message: error.message,
                        file: error.file,
                        line: lineNumber
                    )
                )
                pendingError = nil
                continue
            }
            if let warning = warningDiagnostic(trimmed) {
                diagnostics.append(warning)
                continue
            }
            if let box = boxDiagnostic(trimmed) {
                diagnostics.append(box)
            }
        }
        if let pendingError {
            diagnostics.append(
                TeXDiagnostic(
                    severity: .error,
                    message: pendingError.message,
                    file: pendingError.file
                )
            )
        }
        var seen: Set<String> = []
        return diagnostics.filter { diagnostic in
            let key =
                "\(diagnostic.severity.rawValue)|\(diagnostic.file ?? "")|\(diagnostic.line ?? 0)|\(diagnostic.message)"
            return seen.insert(key).inserted
        }
    }

    private static func fileLineDiagnostic(_ line: String) -> TeXDiagnostic? {
        let severity: TeXDiagnosticSeverity
        let remainder: Substring
        if line.hasPrefix("error: ") {
            severity = .error
            remainder = line.dropFirst(7)
        } else if line.hasPrefix("warning: ") {
            severity = .warning
            remainder = line.dropFirst(9)
        } else {
            return nil
        }
        let fields = remainder.split(separator: ":", maxSplits: 2)
        guard fields.count == 3, let lineNumber = Int(fields[1]) else {
            return TeXDiagnostic(severity: severity, message: String(remainder))
        }
        return TeXDiagnostic(
            severity: severity,
            message: fields[2].trimmingCharacters(in: .whitespaces),
            file: String(fields[0]),
            line: lineNumber
        )
    }

    private static func warningDiagnostic(_ line: String) -> TeXDiagnostic? {
        guard line.hasPrefix("LaTeX Warning:") || line.hasPrefix("Package ") else { return nil }
        guard line.contains("Warning:") else { return nil }
        let lineNumber = referencedLine(in: line)
        return TeXDiagnostic(
            severity: .warning,
            message: line,
            line: lineNumber
        )
    }

    private static func boxDiagnostic(_ line: String) -> TeXDiagnostic? {
        guard
            line.hasPrefix("Overfull \\hbox") || line.hasPrefix("Underfull \\hbox")
                || line.hasPrefix("Overfull \\vbox") || line.hasPrefix("Underfull \\vbox")
        else { return nil }
        return TeXDiagnostic(
            severity: .warning,
            message: line,
            line: referencedLine(in: line)
        )
    }

    private static func texLineNumber(_ line: String) -> Int? {
        guard line.hasPrefix("l.") else { return nil }
        return Int(line.dropFirst(2).prefix { $0.isNumber })
    }

    private static func referencedLine(in line: String) -> Int? {
        guard let range = line.range(of: "line ") ?? line.range(of: "lines ") else { return nil }
        let tail = line[range.upperBound...]
        return Int(tail.prefix { $0.isNumber })
    }

    private static func tracedFile(in line: String) -> String? {
        guard let open = line.lastIndex(of: "(") else { return nil }
        let path = line[line.index(after: open)...]
            .prefix { !$0.isWhitespace && $0 != ")" }
        return path.hasSuffix(".tex") ? String(path) : nil
    }
}
