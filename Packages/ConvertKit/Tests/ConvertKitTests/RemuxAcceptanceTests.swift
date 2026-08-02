@preconcurrency import AVFoundation
import ConvertKit
import CoreMedia
import CoreModel
import CoreVideo
import Foundation
import LibraryStore
import Testing

@Suite("Native backend acceptance")
struct RemuxAcceptanceTests {
    @Test("MOV to MP4 preserves every encoded video sample byte")
    func movToMP4IsByteIdentical() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-remux-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.mov")
        let output = folder.appendingPathComponent("Exports/output.mp4")
        try await makeH264Movie(at: input)

        let source = testVideoRecord(container: "mov", codec: "h264")
        let conversion = plan(from: source, to: .mp4H264)
        let stream = await Converter().convert(conversion, input: input, output: output)
        var progress: [Double] = []
        for try await value in stream { progress.append(value) }

        #expect(conversion.backend == .remux)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try await encodedVideoSamples(at: input) == encodedVideoSamples(at: output))
        #expect(progress.first == 0)
        #expect(progress.last == 1)
    }

    @Test("MOV to WebM completes through the linked LGPL backend")
    func movToWebMUsesLinkedFFmpeg() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reel-webm-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.mov")
        let output = folder.appendingPathComponent("Exports/output.webm")
        try await makeH264Movie(at: input)

        let conversion = plan(
            from: testVideoRecord(container: "mov", codec: "h264"),
            to: .webMVP9
        )
        let stream = await Converter().convert(conversion, input: input, output: output)
        var progress: [Double] = []
        for try await value in stream { progress.append(value) }

        let bytes = try Data(contentsOf: output)
        #expect(conversion.backend == .ffmpeg(.webMVP9))
        #expect(bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]))
        #expect(progress.first == 0)
        #expect(progress.last == 1)
    }

    private func makeH264Movie(at url: URL) async throws {
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
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<6 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil,
                64,
                64,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            #expect(status == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                memset(baseAddress, Int32(frame * 24), CVPixelBufferGetDataSize(buffer))
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

    private func encodedVideoSamples(at url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        #expect(reader.canAdd(output))
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: count)
            let status = bytes.withUnsafeMutableBytes { storage in
                guard let baseAddress = storage.baseAddress else {
                    return kCMBlockBufferBadCustomBlockSourceErr
                }
                return CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: count,
                    destination: baseAddress
                )
            }
            #expect(status == kCMBlockBufferNoErr)
            samples.append(bytes)
        }
        #expect(reader.status == .completed)
        return samples
    }

    private func testVideoRecord(container: String, codec: String) -> AssetRecord {
        AssetRecord(
            id: AssetID.generate(),
            relativePath: "Assets/test.\(container)",
            displayName: "test.\(container)",
            kind: .video,
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
