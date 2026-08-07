import AppKit
import CoreModel
import SearchEngine
import Testing

@testable import Reel

@MainActor
@Suite("Live Text overlay")
struct LiveTextOverlayTests {
    @Test("Copy participates in the standard responder chain")
    func responderChainCopy() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("clip-live-text-tests-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let view = LiveTextSelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.pasteboard = pasteboard
        view.setSpans([
            span("first", x: 0.1),
            span("second", x: 0.5),
        ])
        view.selectAll(nil)

        #expect(view.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        #expect(pasteboard.string(forType: .string) == "first\nsecond")
    }

    @Test("Index progress invalidates the open photo Live Text request")
    func delayedIndexProgressChangesRefreshIdentity() {
        let assetID = AssetID(rawValue: "delayed-live-text")
        let before = PhotoLiveTextRefreshID(
            assetID: assetID,
            indexProgress: IndexProgress(
                completed: 0,
                total: 1,
                currentAssetID: assetID,
                currentStage: .text
            )
        )
        let after = PhotoLiveTextRefreshID(
            assetID: assetID,
            indexProgress: IndexProgress(completed: 1, total: 1)
        )

        #expect(before != after)
    }

    @Test("Other assets do not invalidate an open photo Live Text request")
    func unrelatedIndexProgressKeepsRefreshIdentity() {
        let assetID = AssetID(rawValue: "open-photo")
        let unrelated = AssetID(rawValue: "background-video")
        let idle = PhotoLiveTextRefreshID(
            assetID: assetID,
            indexProgress: IndexProgress()
        )
        let backgroundWork = PhotoLiveTextRefreshID(
            assetID: assetID,
            indexProgress: IndexProgress(
                completed: 2,
                total: 7,
                currentAssetID: unrelated,
                currentStage: .ocr
            )
        )

        #expect(idle == backgroundWork)
    }

    @Test("Live Text is hidden when source geometry no longer matches the rendered image")
    func geometryAlignment() {
        #expect(PhotoLiveTextGeometry.isSourceAligned(Geometry()))
        #expect(
            !PhotoLiveTextGeometry.isSourceAligned(
                Geometry(crop: CGRect(x: 0.1, y: 0, width: 0.9, height: 1))
            )
        )
        #expect(!PhotoLiveTextGeometry.isSourceAligned(Geometry(rotationDegrees: 90)))
        #expect(!PhotoLiveTextGeometry.isSourceAligned(Geometry(scale: 1.25)))
    }

    private func span(_ text: String, x: Double) -> OCRSpan {
        OCRSpan(
            assetID: AssetID(rawValue: "live-text-copy"),
            text: text,
            boundingBox: NormalizedRect(x: x, y: 0.5, width: 0.2, height: 0.1),
            confidence: 0.95,
            revision: 1,
            script: .alphabetic
        )
    }
}
