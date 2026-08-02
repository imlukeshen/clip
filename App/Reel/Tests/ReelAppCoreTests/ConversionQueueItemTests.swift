import ConvertKit
import CoreModel
import Foundation
import LibraryStore
import Testing

@testable import ReelAppCore

@Suite("Conversion queue planning")
struct ConversionQueueItemTests {
    @Test("An H.264 MOV defaults to a visible lossless MP4 remux")
    func defaultsToRemux() {
        let input = URL(fileURLWithPath: "/tmp/Capture.mov")
        let item = ConversionQueueItem(
            asset: record(kind: .video, container: "mov", codec: "avc1"),
            inputURL: input
        )

        #expect(item.target == .mp4H264)
        #expect(item.plan.backend == .remux)
        #expect(item.plan.lossless)
        #expect(item.sourceDescription == "MOV · H.264")
        #expect(item.outputFilename == "Capture.mp4")
    }

    @Test("Changing the target replans the backend immediately")
    func targetReplansBackend() {
        var item = ConversionQueueItem(
            asset: record(kind: .video, container: "mov", codec: "h264"),
            inputURL: URL(fileURLWithPath: "/tmp/Capture.mov")
        )

        item.selectTarget(.webMVP9)

        #expect(item.target == .webMVP9)
        #expect(item.plan.backend == .ffmpeg(.webMVP9))
        #expect(item.outputFilename == "Capture.webm")
    }

    @Test("A target cannot change while its conversion is running")
    func convertingTargetIsStable() {
        var item = ConversionQueueItem(
            asset: record(kind: .video, container: "mov", codec: "h264"),
            inputURL: URL(fileURLWithPath: "/tmp/Capture.mov"),
            status: .converting
        )

        item.selectTarget(.webMVP9)

        #expect(item.target == .mp4H264)
        #expect(item.plan.backend == .remux)
        #expect(item.status == .converting)
    }

    @Test("Images expose ImageIO targets and PDFs route to their workspace")
    func mediaFamiliesStayTruthful() {
        let image = ConversionQueueItem(
            asset: record(kind: .image, container: "png", codec: nil),
            inputURL: URL(fileURLWithPath: "/tmp/Still.png")
        )
        let document = ConversionQueueItem(
            asset: record(kind: .document, container: "pdf", codec: nil),
            inputURL: URL(fileURLWithPath: "/tmp/Notes.pdf")
        )

        #expect(image.plan.backend == .imageIO(.jpeg))
        #expect(image.plan.estimate == .instant)
        #expect(!image.availableTargets.contains(.mp4H264))
        #expect(
            document.plan.backend
                == .unsupported("Use the PDF workspace to export Markdown or an edited PDF")
        )
    }

    private func record(
        kind: AssetKind,
        container: String,
        codec: String?
    ) -> AssetRecord {
        AssetRecord(
            id: AssetID.generate(),
            relativePath: "Assets/test.\(container)",
            displayName: "test.\(container)",
            kind: kind,
            container: container,
            codec: codec,
            createdAt: Date(timeIntervalSince1970: 1),
            importedAt: Date(timeIntervalSince1970: 2),
            byteSize: 1,
            contentHash: UUID().uuidString,
            ingestState: .ready
        )
    }
}
