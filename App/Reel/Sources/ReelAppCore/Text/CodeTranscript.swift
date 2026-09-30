import TextEngine

/// Everything a run printed, as terminal lines in the order they arrived.
///
/// Output arrives in arbitrary chunks from two pipes. Each stream keeps its
/// own unfinished line so a chunk boundary never splits or interleaves a
/// line, and the unfinished tail still shows, as a terminal would.
public struct CodeTranscript: Equatable, Sendable {
    /// One printed line.
    public struct Line: Identifiable, Equatable, Sendable {
        /// What kind of line this is, which decides how it is drawn.
        public enum Kind: Equatable, Sendable {
            /// A command the run executed, drawn as a prompt.
            case command
            /// Standard output.
            case output
            /// Standard error.
            case error
        }

        public let id: Int
        public let text: String
        public let kind: Kind
    }

    /// The most lines kept; older lines scroll away like a terminal's buffer.
    public static let maximumLines = 10_000

    public private(set) var lines: [Line] = []
    private var partial: [CodeOutputStream: String] = [:]
    private var nextID = 0

    public init() {}

    /// Completed lines followed by any unfinished ones.
    public var displayLines: [Line] {
        lines
            + [CodeOutputStream.standardOutput, .standardError].compactMap { stream in
                guard let text = partial[stream], !text.isEmpty else { return nil }
                let id = stream == .standardOutput ? -1 : -2
                return Line(id: id, text: text, kind: Self.kind(for: stream))
            }
    }

    /// Standard error as one string, for locating the line an error blames.
    public var errorText: String {
        displayLines.filter { $0.kind == .error }.map(\.text).joined(separator: "\n")
    }

    /// The whole transcript as plain text, for copying.
    public var plainText: String {
        displayLines.map { $0.kind == .command ? "$ \($0.text)" : $0.text }
            .joined(separator: "\n")
    }

    public var isEmpty: Bool { displayLines.isEmpty }

    public mutating func appendCommand(_ commandLine: String) {
        flush()
        appendLine(commandLine, kind: .command)
    }

    public mutating func append(_ text: String, from stream: CodeOutputStream) {
        let combined = (partial[stream] ?? "") + text
        var pieces = combined.components(separatedBy: "\n")
        partial[stream] = pieces.removeLast()
        for piece in pieces {
            appendLine(
                piece.hasSuffix("\r") ? String(piece.dropLast()) : piece,
                kind: Self.kind(for: stream))
        }
    }

    /// Ends every unfinished line, as when the program exits.
    public mutating func flush() {
        for stream in [CodeOutputStream.standardOutput, .standardError] {
            if let text = partial[stream], !text.isEmpty {
                appendLine(text, kind: Self.kind(for: stream))
            }
            partial[stream] = nil
        }
    }

    private mutating func appendLine(_ text: String, kind: Line.Kind) {
        lines.append(Line(id: nextID, text: text, kind: kind))
        nextID += 1
        if lines.count > Self.maximumLines {
            lines.removeFirst(lines.count - Self.maximumLines)
        }
    }

    private static func kind(for stream: CodeOutputStream) -> Line.Kind {
        stream == .standardOutput ? .output : .error
    }
}
