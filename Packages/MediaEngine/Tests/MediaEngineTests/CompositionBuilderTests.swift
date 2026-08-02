@preconcurrency import AVFoundation
import CoreMedia
import CoreModel
import CoreVideo
import Foundation
import Testing

@testable import MediaEngine

@Suite("Composition building")
struct CompositionBuilderTests {
    @Test("Three clips form one gapless video track and aligned silent audio timeline")
    func threeClipsAreGapless() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-composition-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [AssetID: URL] = [:]
        var items: [TimelineItem] = []
        for index in 0..<3 {
            let id = AssetID(rawValue: "asset-\(index)")
            let url = folder.appendingPathComponent("clip-\(index).mov")
            try await makeMovie(at: url, shade: UInt8(index * 50))
            urls[id] = url
            items.append(
                TimelineItem(
                    id: ItemID(rawValue: "item-\(index)"),
                    assetID: id,
                    sourceRange: TimeRange(
                        start: .zero,
                        duration: RationalTime(seconds: 0.2)
                    )
                )
            )
        }
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "project"),
            name: "Three clips",
            canvas: CanvasSpec(
                width: 640,
                height: 360,
                frameRate: .fps30,
                colorSpace: .sRGB,
                background: .black
            ),
            timeline: Timeline(video: items),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )

        let resolvedURLs = urls
        let built = try await CompositionBuilder().build(
            document,
            resolving: { id in try #require(resolvedURLs[id]) },
            quality: .proxy(180)
        )
        let tracks = built.composition.tracks(withMediaType: .video)
        let audioTracks = built.composition.tracks(withMediaType: .audio)
        let videoTrack = try #require(tracks.first)
        let audioTrack = try #require(audioTracks.first)
        let segments = try #require(videoTrack.segments)

        #expect(tracks.count == 1)
        #expect(audioTracks.count == 1)
        #expect(audioTrack.segments?.isEmpty == true)
        #expect(segments.count == 3)
        #expect(segments[0].timeMapping.target.start == .zero)
        #expect(segments[1].timeMapping.target.start == RationalTime(seconds: 0.2).cmTime)
        #expect(segments[2].timeMapping.target.start == RationalTime(seconds: 0.4).cmTime)
        #expect(built.composition.duration.rational == document.duration)
        #expect(built.videoComposition.instructions.count == 3)
        #expect(built.videoComposition.renderSize == CGSize(width: 320, height: 180))
    }

    @Test("Core Media conversion preserves canonical ticks")
    func timeBridge() {
        let time = RationalTime(value: 123_456)
        #expect(time.cmTime.rational == time)
    }

    @Test("The compositor creates one reusable CI context")
    func compositorContextIsShared() {
        let compositor = EffectCompositor()
        #expect(compositor.contextCreationCount == 1)
    }

    private func makeMovie(at url: URL, shade: UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<6 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixelBuffer: CVPixelBuffer?
            #expect(
                CVPixelBufferCreate(
                    nil,
                    64,
                    64,
                    kCVPixelFormatType_32BGRA,
                    nil,
                    &pixelBuffer
                ) == kCVReturnSuccess
            )
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) {
                memset(address, Int32(shade), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
                )
            )
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
    }
}
