@preconcurrency import AVFoundation
import CoreModel
import CoreVideo
import Foundation
import Testing

@testable import MediaEngine

@Suite("Timeline export")
struct ExporterTests {
    @Test("An invalid preset cannot replace an existing destination")
    func invalidPresetPreservesDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-export-invalid-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("existing.mp4")
        let original = Data("original".utf8)
        try original.write(to: destination)
        let document = try emptyDocument()
        let stream = await Exporter().export(
            document,
            preset: ExportPreset(
                container: .mp4,
                codec: .proRes422,
                size: CGSize(width: 64, height: 64),
                frameRate: .fps30
            ),
            to: destination,
            resolving: { _ in URL(fileURLWithPath: "/unused") }
        )

        await #expect(throws: MediaEngineError.self) {
            for try await _ in stream {}
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("A zoomed two-clip export matches timeline duration within one frame")
    func exportsTwoClipsWithinOneFrame() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-export-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [AssetID: URL] = [:]
        var items: [TimelineItem] = []
        for index in 0..<2 {
            let assetID = AssetID(rawValue: "export-asset-\(index)")
            let input = folder.appendingPathComponent("source-\(index).mov")
            try await makeMovie(at: input, shade: UInt8(60 + index * 100))
            urls[assetID] = input
            let range = TimeRange(start: .zero, duration: RationalTime(seconds: 0.3))
            items.append(
                TimelineItem(
                    id: ItemID(rawValue: "export-item-\(index)"),
                    assetID: assetID,
                    sourceRange: range,
                    effects: [
                        .zoom(
                            ZoomEffect(
                                id: EffectID(rawValue: "zoom-\(index)"),
                                range: range,
                                center: NormalizedPoint(x: 0.5, y: 0.5),
                                scale: 1.4,
                                rampIn: .zero,
                                rampOut: .zero
                            )
                        )
                    ]
                )
            )
        }
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "export-project"),
            name: "Export acceptance",
            canvas: CanvasSpec(
                width: 64,
                height: 64,
                frameRate: .fps30,
                colorSpace: .sRGB,
                background: .black
            ),
            timeline: Timeline(video: items),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let destination = folder.appendingPathComponent("result.mp4")
        let resolvedURLs = urls
        let stream = await Exporter().export(
            document,
            preset: ExportPreset(
                container: .mp4,
                codec: .h264,
                size: CGSize(width: 64, height: 64),
                frameRate: .fps30,
                bitrate: 300_000,
                includeAudio: false
            ),
            to: destination,
            resolving: { id in try #require(resolvedURLs[id]) }
        )
        var updates: [ExportProgress] = []
        for try await update in stream { updates.append(update) }

        let exported = AVURLAsset(url: destination)
        let exportedDuration = try await exported.load(.duration).rational
        let durationDelta = abs(exportedDuration.value - document.duration.value)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let byteSize = try #require(attributes[.size] as? NSNumber).intValue

        #expect(updates.first == ExportProgress(stage: .preparing, fraction: 0))
        #expect(updates.last == ExportProgress(stage: .completed, fraction: 1))
        #expect(durationDelta <= document.canvas.frameRate.frameDuration.value)
        #expect(byteSize > 0)
    }

    @Test("Trailing audio extends a video export over background frames")
    func trailingAudioExtendsVideoExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-export-trailing-audio-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let videoID = AssetID(rawValue: "short-video")
        let audioID = AssetID(rawValue: "long-audio")
        let videoURL = folder.appendingPathComponent("video.mov")
        let audioURL = folder.appendingPathComponent("audio.wav")
        try await makeMovie(at: videoURL, shade: 100)
        try makeAudioFile(at: audioURL, duration: 0.5)

        let videoDuration = RationalTime(seconds: 0.2)
        let audioDuration = RationalTime(seconds: 0.5)
        let document = try ProjectDocument(
            id: ProjectID(rawValue: "trailing-audio-project"),
            name: "Trailing audio",
            canvas: CanvasSpec(
                width: 64,
                height: 64,
                frameRate: .fps30,
                colorSpace: .sRGB,
                background: .black
            ),
            timeline: Timeline(
                videoTracks: [
                    Track(
                        id: TrackID(rawValue: "v1"),
                        name: "V1",
                        items: [
                            TimelineItem(
                                id: ItemID(rawValue: "video-item"),
                                assetID: videoID,
                                sourceRange: TimeRange(
                                    start: .zero,
                                    duration: videoDuration
                                )
                            )
                        ]
                    )
                ],
                audioTracks: [
                    Track(
                        id: TrackID(rawValue: "a1"),
                        name: "A1",
                        items: [
                            TimelineItem(
                                id: ItemID(rawValue: "audio-item"),
                                assetID: audioID,
                                sourceRange: TimeRange(
                                    start: .zero,
                                    duration: audioDuration
                                )
                            )
                        ]
                    )
                ]
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let destination = folder.appendingPathComponent("result.mp4")
        let urls = [videoID: videoURL, audioID: audioURL]
        let stream = await Exporter().export(
            document,
            preset: ExportPreset(
                container: .mp4,
                codec: .h264,
                size: CGSize(width: 64, height: 64),
                frameRate: .fps30,
                bitrate: 300_000,
                includeAudio: true
            ),
            to: destination,
            resolving: { id in try #require(urls[id]) }
        )
        for try await _ in stream {}

        let exported = AVURLAsset(url: destination)
        let exportedDuration = try await exported.load(.duration).rational
        let videoTracks = try await exported.loadTracks(withMediaType: .video)
        let audioTracks = try await exported.loadTracks(withMediaType: .audio)

        #expect(abs(exportedDuration.value - audioDuration.value) <= 1)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)
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
        for frame in 0..<9 {
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

    private func makeAudioFile(at url: URL, duration: Double) throws {
        let sampleRate = 48_000.0
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        let frameCount = AVAudioFrameCount((sampleRate * duration).rounded())
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?[0] {
            samples.initialize(repeating: 0.1, count: Int(frameCount))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func emptyDocument() throws -> ProjectDocument {
        try ProjectDocument(
            id: ProjectID(rawValue: "invalid-export"),
            name: "Invalid",
            timeline: Timeline(),
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
