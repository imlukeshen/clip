import CoreModel
import Foundation

/// The decoded contents of a text file, with the on-disk facts the editor must
/// preserve so a save round-trips byte-for-byte where possible.
public struct LoadedTextFile: Sendable, Equatable {
    /// The decoded text, with line endings left exactly as written.
    public let text: String
    /// The encoding the bytes were decoded with.
    public let encoding: TextEncoding
    /// The line terminator style detected in the bytes.
    public let lineEnding: LineEnding

    /// Creates a decoded text file.
    public init(text: String, encoding: TextEncoding, lineEnding: LineEnding) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

/// Reads text files off disk, detecting their encoding and line endings.
///
/// Detection is deliberately conservative: a byte-order mark decides UTF-16
/// unambiguously, otherwise UTF-8 is tried first and ISO Latin-1 is the
/// lossless single-byte fallback that decodes any byte sequence. Nothing here
/// rewrites the file; the detected facts travel with the buffer so a later save
/// can reproduce the original bytes.
public enum TextFileLoader {
    /// The largest file the editor opens into a single editable buffer.
    ///
    /// Files above this are refused rather than silently truncated; the T0
    /// acceptance target is a 5 MB file, so the ceiling sits comfortably above it.
    public static let maximumByteSize: Int64 = 50 * 1024 * 1024

    /// Loads and decodes the file at `url`.
    ///
    /// - Parameter url: The file to read.
    /// - Returns: The decoded text with its detected encoding and line ending.
    /// - Throws: ``TextEngineError`` if the file is unreadable, too large, or
    ///   cannot be decoded with any candidate encoding.
    public static func load(from url: URL) throws -> LoadedTextFile {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw TextEngineError.unreadable(url)
        }
        if data.count > maximumByteSize {
            throw TextEngineError.tooLarge(
                url,
                byteSize: Int64(data.count),
                limit: maximumByteSize
            )
        }
        guard let decoded = decode(data) else {
            throw TextEngineError.undecodable(url)
        }
        return LoadedTextFile(
            text: decoded.text,
            encoding: decoded.encoding,
            lineEnding: lineEnding(in: decoded.text)
        )
    }

    /// Decodes raw bytes, trying encodings in the documented order.
    ///
    /// Exposed for tests and for callers that already hold the bytes (a paste,
    /// a scratch buffer). Returns `nil` only if every candidate fails, which in
    /// practice means the ISO Latin-1 catch-all itself failed.
    public static func decode(_ data: Data) -> (text: String, encoding: TextEncoding)? {
        if let bom = decodeByteOrderMark(data) {
            return bom
        }
        for candidate in orderedCandidates {
            if let text = String(data: data, encoding: candidate.stringEncoding) {
                return (text, candidate)
            }
        }
        return nil
    }

    /// Encodings tried in order when no byte-order mark is present.
    private static let orderedCandidates: [TextEncoding] = [
        .utf8, .isoLatin1,
    ]

    /// Resolves a leading byte-order mark to its UTF-16 flavour, if present.
    private static func decodeByteOrderMark(_ data: Data) -> (String, TextEncoding)? {
        let bytes = [UInt8](data.prefix(2))
        guard bytes.count == 2 else { return nil }
        let encoding: TextEncoding
        switch (bytes[0], bytes[1]) {
        case (0xFF, 0xFE): encoding = .utf16LittleEndian
        case (0xFE, 0xFF): encoding = .utf16BigEndian
        default: return nil
        }
        // `.utf16` (rather than the explicit-endian encoding) consumes the BOM
        // so it does not survive as a U+FEFF at the head of the decoded string.
        guard let text = String(data: data, encoding: .utf16) else { return nil }
        return (text, encoding)
    }

    /// Classifies the line terminators used in already-decoded text.
    ///
    /// Reports `.mixed` when more than one style appears, so the editor can
    /// surface the ambiguity rather than pick one and rewrite the file.
    public static func lineEnding(in text: String) -> LineEnding {
        var sawCRLF = false
        var sawLF = false
        var sawCR = false
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\r" {
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    sawCRLF = true
                    index += 2
                    continue
                }
                sawCR = true
            } else if scalar == "\n" {
                sawLF = true
            }
            index += 1
        }
        let styles = [sawCRLF, sawLF, sawCR].filter { $0 }.count
        if styles > 1 { return .mixed }
        if sawCRLF { return .crlf }
        if sawCR { return .cr }
        // A file with no terminator at all is treated as LF; it is the default
        // the editor writes and imposes no rewrite on a single-line file.
        return .lf
    }
}
