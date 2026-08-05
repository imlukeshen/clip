import AppKit
import CoreModel
import Foundation
import LibraryStore
import SearchEngine
import Testing

@Suite("On-device OCR indexing")
struct OCRTests {
    @Test("Five minutes sample to at most sixty representative frames")
    func fiveMinuteSamplingBound() {
        let duration = 5.0 * 60
        let bucketDuration = OCRFrameSelectionPolicy.bucketDuration(for: duration)
        let bucketCount = Int(ceil(duration / bucketDuration))

        #expect(bucketDuration == 5)
        #expect(bucketCount <= 60)
        #expect(bucketCount < 80)
    }

    @Test("The absolute frame cap distributes long recordings")
    func longRecordingFrameCap() {
        let duration = 4.0 * 60 * 60
        let bucketDuration = OCRFrameSelectionPolicy.bucketDuration(for: duration)
        let bucketCount = Int(ceil(duration / bucketDuration))

        #expect(bucketDuration == duration / 400)
        #expect(bucketCount == 400)
    }

    @Test("Click anchors survive an unchanged perceptual hash")
    func clickAnchorOverridesChangeThreshold() {
        let unchanged = PerceptualHash(words: [UInt64](repeating: 0, count: 16))
        #expect(
            OCRFrameSelectionPolicy.shouldAccept(
                hash: unchanged,
                after: unchanged,
                isFirstFrame: false,
                isClickAnchor: true
            )
        )
        #expect(
            !OCRFrameSelectionPolicy.shouldAccept(
                hash: unchanged,
                after: unchanged,
                isFirstFrame: false,
                isClickAnchor: false
            )
        )
    }

    @Test("Static text becomes one temporal span")
    func temporalDeduplication() {
        let assetID = AssetID(rawValue: "video")
        let block = RecognizedTextBlock(
            text: "Billing table",
            boundingBox: NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
            confidence: 0.9
        )
        let frames = stride(from: 0.0, to: 300, by: 5).map {
            OCRFrame(
                time: RationalTime(seconds: $0),
                end: RationalTime(seconds: $0 + 5),
                blocks: [block]
            )
        }

        let spans = OCRTemporalDeduplicator.spans(
            assetID: assetID,
            frames: frames,
            revision: 3
        )
        #expect(spans.count == 1)
        #expect(spans[0].start == .zero)
        #expect(spans[0].end == RationalTime(seconds: 300))
    }

    @Test("CJK and mixed text route to the trigram index")
    func scriptDetection() {
        #expect(OCRScriptDetector.detect(in: "請求設定") == .cjk)
        #expect(OCRScriptDetector.detect(in: "billing table") == .alphabetic)
        #expect(OCRScriptDetector.detect(in: "請求 Billing") == .mixed)
    }

    @Test("An image is indexed in one Vision pass and survives a store reopen")
    func imageIndexesInOnePass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-ocr-image-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        let imageURL = LibraryLayout.inbox(in: root).appendingPathComponent("billing.png")
        let data = try await makeTextImage("BILLING TABLE")
        try data.write(to: imageURL)
        let asset = AssetRecord(
            id: AssetID(rawValue: "billing-image"),
            relativePath: "Media/Inbox/billing.png",
            displayName: "billing.png",
            kind: .image,
            container: "png",
            createdAt: .now,
            importedAt: .now,
            byteSize: Int64(data.count),
            contentHash: "billing-hash",
            width: 800,
            height: 240,
            ingestState: .ready
        )
        try await store.insert(asset)

        let processor = LocalIndexStageProcessor(store: store)
        let outcome = try await processor.process(assetID: asset.id, stage: .ocr)
        let reopened = try await LibraryStore(
            root: root,
            bookmarks: BookmarkStore(storageURL: root.appendingPathComponent("bookmarks.json"))
        )
        let spans = try await reopened.ocrSpans(for: asset.id)

        #expect(outcome == .completed)
        #expect(
            spans.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("billing"))
        #expect(spans.allSatisfy { $0.revision == VisionTextRecognizer.revision })
    }
}

@MainActor
private func makeTextImage(_ text: String) throws -> Data {
    let image = NSImage(size: NSSize(width: 800, height: 240))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 800, height: 240).fill()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 72, weight: .bold),
        .foregroundColor: NSColor.black,
    ]
    NSString(string: text).draw(
        in: NSRect(x: 40, y: 70, width: 720, height: 100),
        withAttributes: attributes
    )
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return data
}
