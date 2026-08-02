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
