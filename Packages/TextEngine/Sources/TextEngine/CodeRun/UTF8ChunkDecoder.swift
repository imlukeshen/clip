import Foundation

/// Decodes UTF-8 that arrives in arbitrary pieces from a pipe.
///
/// A read can end partway through a multi-byte character. Those trailing
/// bytes are held back for the next chunk instead of being decoded into a
/// replacement character.
struct UTF8ChunkDecoder: Sendable {
    private var pending = Data()

    mutating func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        let complete = pending.count - incompleteSuffixLength(of: pending)
        let text = String(decoding: pending.prefix(complete), as: UTF8.self)
        pending = Data(pending.suffix(from: pending.startIndex + complete))
        return text
    }

    /// Whatever is left once the stream has ended.
    mutating func flush() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }

    private func incompleteSuffixLength(of data: Data) -> Int {
        // Look back at most three bytes for the start of an unfinished character.
        for back in 1...min(3, data.count) {
            let byte = data[data.endIndex - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }  // continuation byte
            let needed =
                byte & 0b1110_0000 == 0b1100_0000
                ? 2
                : byte & 0b1111_0000 == 0b1110_0000
                    ? 3
                    : byte & 0b1111_1000 == 0b1111_0000 ? 4 : 1
            return needed > back ? back : 0
        }
        return 0
    }
}
