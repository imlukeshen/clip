import ConvertKit
import CoreModel
import Foundation
import LibraryStore
import Testing

@Suite("Conversion decision table")
struct PlanningTests {
    @Test("H.264 container swaps use lossless passthrough")
    func h264Remux() {
        let movToMP4 = plan(
            from: asset(kind: .video, container: "mov", codec: "h264"), to: .mp4H264)
        let mp4ToMOV = plan(
            from: asset(kind: .video, container: "mp4", codec: "avc1"), to: .movH264)

        #expect(movToMP4.backend == .remux)
        #expect(movToMP4.lossless)
        #expect(movToMP4.estimate == .seconds(2))
        #expect(mp4ToMOV.backend == .remux)
        #expect(mp4ToMOV.lossless)
    }

    @Test("A ProRes MOV never promises an MP4 remux")
    func proResNegativeCase() {
        let result = plan(
            from: asset(kind: .video, container: "mov", codec: "apcn"),
            to: .mp4H264
        )

        #expect(result.backend == .videoToolbox(.h264))
        #expect(!result.lossless)
    }

    @Test(
        "Every conversion family selects its documented backend",
        arguments: [
            (AssetKind.video, "mov", "h264", TargetFormat.mp4HEVC, Backend.videoToolbox(.hevc)),
            (
                AssetKind.video, "mp4", "h264", TargetFormat.movProRes422,
                Backend.videoToolbox(.proRes422)
            ),
            (AssetKind.image, "png", nil, TargetFormat.jpeg, Backend.imageIO(.jpeg)),
            (AssetKind.image, "jpeg", nil, TargetFormat.heic, Backend.imageIO(.heic)),
            (AssetKind.video, "mov", "h264", TargetFormat.webMVP9, Backend.ffmpeg(.webMVP9)),
            (AssetKind.image, "png", nil, TargetFormat.animatedGIF, Backend.ffmpeg(.animatedGIF)),
            (AssetKind.audio, "wav", "lpcm", TargetFormat.flac, Backend.ffmpeg(.flac)),
        ]
    )
    func routesBackend(
        kind: AssetKind,
        container: String,
        codec: String?,
        target: TargetFormat,
        expected: Backend
    ) {
        #expect(
            plan(from: asset(kind: kind, container: container, codec: codec), to: target).backend
                == expected)
    }

    @Test("PDF files route users to the dedicated workspace")
    func pdfUnsupported() {
        for target in TargetFormat.allCases {
            let result = plan(
                from: asset(kind: .document, container: "pdf", codec: nil),
                to: target
            )
            #expect(
                result.backend
                    == .unsupported("Use the PDF workspace to export Markdown or an edited PDF")
            )
        }
    }

    @Test("Conversion failures expose useful descriptions to the queue")
    func localizedErrors() {
        #expect(
            ConversionError.conversionFailed("Encoder stopped").localizedDescription
                == "Encoder stopped"
        )
        #expect(
            ConversionError.cancelled.localizedDescription
                == "The conversion was cancelled."
        )
    }

    private func asset(kind: AssetKind, container: String, codec: String?) -> AssetRecord {
        AssetRecord(
            id: AssetID.generate(),
            relativePath: "Assets/test.input",
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
