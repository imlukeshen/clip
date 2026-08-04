import ConvertKit
import CoreModel
import Foundation
import LibraryStore
import Testing

@Suite("Conversion graph planning")
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

    @Test("PDF to PNG is reachable through its declared native edge")
    func pdfToPNG() {
        let result = plan(
            from: asset(kind: .document, container: "pdf", codec: nil),
            to: .png
        )
        #expect(result.backend == .pdfKit)
        #expect(result.steps.map(\.backend) == [.pdfKit])
    }

    @Test("DOCX to PDF is a visible two-step native route")
    func docxToPDF() throws {
        let result = try #require(
            ConversionPlanner().plan(
                from: ConversionFormats.docx,
                to: ConversionFormats.pdf
            )
        )

        #expect(result.steps.map(\.backend) == [.attributedString, .webKit])
        #expect(result.steps.map(\.to) == [.init(type: .html), .init(type: .pdf)])
        #expect(!result.isLossless)
        #expect(result.warnings == ["Document layout may change during PDF rendering."])
    }

    @Test("Reachability is derived from the graph and paths stop at three hops")
    func reachableAndBounded() {
        let a = FormatID(type: ConversionFormats.type("graph-a"))
        let b = FormatID(type: ConversionFormats.type("graph-b"))
        let c = FormatID(type: ConversionFormats.type("graph-c"))
        let d = FormatID(type: ConversionFormats.type("graph-d"))
        let e = FormatID(type: ConversionFormats.type("graph-e"))
        let edges = [(a, b), (b, c), (c, d), (d, e)].map { source, target in
            ConversionEdge(
                from: .exact(source),
                to: target,
                backend: .markdown,
                implementation: .markdown,
                cost: .cheap,
                isLossless: true
            )
        }
        let planner = ConversionPlanner(edges: edges)

        #expect(planner.plan(from: a, to: d)?.steps.count == 3)
        #expect(planner.plan(from: a, to: e) == nil)
        #expect(Set(planner.reachableTargets(from: a)) == Set([b, c, d]))
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
