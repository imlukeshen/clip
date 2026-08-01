import CoreGraphics
import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

@Test func imageProbeReadsDimensionsWithoutAVAssetSynchronousAccess() async throws {
    let encoded =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    let data = try #require(Data(base64Encoded: encoded))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-probe-\(UUID().uuidString).png"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)

    let result = try await AVFoundationMediaProbe().probe(url)

    #expect(result.kind == .image)
    #expect(result.width == 1)
    #expect(result.height == 1)
    #expect(result.duration == nil)
}

@Test func pdfProbeAcceptsAndHoldsDocumentMetadata() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-probe-\(UUID().uuidString).pdf"
    )
    defer { try? FileManager.default.removeItem(at: url) }

    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()

    let result = try await AVFoundationMediaProbe().probe(url)

    #expect(result.kind == .document)
    #expect(result.width == 612)
    #expect(result.height == 792)
    #expect(result.duration == nil)
}
