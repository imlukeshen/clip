import CoreModel
import Foundation
import Testing

@testable import TextEngine

@Test func utf8IsPreferredForPlainAsciiBytes() throws {
    let data = Data("let x = 1\n".utf8)
    let decoded = try #require(TextFileLoader.decode(data))
    #expect(decoded.encoding == .utf8)
    #expect(decoded.text == "let x = 1\n")
}

@Test func byteOrderMarkSelectsUTF16AndIsConsumed() throws {
    // "Hi" little-endian UTF-16 with a leading BOM.
    let data = Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])
    let decoded = try #require(TextFileLoader.decode(data))
    #expect(decoded.encoding == .utf16LittleEndian)
    #expect(decoded.text == "Hi")
}

@Test func isoLatin1IsTheLosslessFallbackForNonUTF8Bytes() throws {
    // 0xFF is not valid standalone UTF-8 but decodes cleanly as ISO Latin-1.
    let data = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in Latin-1
    let decoded = try #require(TextFileLoader.decode(data))
    #expect(decoded.encoding == .isoLatin1)
    #expect(decoded.text == "café")
}

@Test func lineEndingDetectionDistinguishesEachStyle() {
    #expect(TextFileLoader.lineEnding(in: "a\nb\n") == .lf)
    #expect(TextFileLoader.lineEnding(in: "a\r\nb\r\n") == .crlf)
    #expect(TextFileLoader.lineEnding(in: "a\rb\r") == .cr)
    #expect(TextFileLoader.lineEnding(in: "a\r\nb\nc") == .mixed)
    #expect(TextFileLoader.lineEnding(in: "single line") == .lf)
}

@Test func loadDecodesEncodingAndLineEndingFromDisk() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("textengine-\(UUID().uuidString).txt")
    try Data("first\r\nsecond\r\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let loaded = try TextFileLoader.load(from: url)
    #expect(loaded.encoding == .utf8)
    #expect(loaded.lineEnding == .crlf)
    #expect(loaded.text == "first\r\nsecond\r\n")
}

@Test func loadRefusesFilesAboveTheSizeCeiling() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("textengine-huge-\(UUID().uuidString).bin")
    // A sparse-ish oversize file: one byte past the ceiling is enough to trip it.
    let count = Int(TextFileLoader.maximumByteSize) + 1
    try Data(repeating: 0x61, count: count).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect {
        try TextFileLoader.load(from: url)
    } throws: { error in
        guard case .tooLarge(_, let byteSize, let limit) = error as? TextEngineError else {
            return false
        }
        return byteSize == Int64(count) && limit == TextFileLoader.maximumByteSize
    }
}

@Test func unreadablePathThrows() {
    let url = URL(fileURLWithPath: "/nonexistent/textengine/\(UUID().uuidString).txt")
    #expect {
        try TextFileLoader.load(from: url)
    } throws: { error in
        error as? TextEngineError == .unreadable(url)
    }
}
