@preconcurrency import AVFoundation
import ConvertKit
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("V2 conversion options and presets", .serialized)
struct V2OptionsTests {
    @Test("Five built-in presets are stable and Codable")
    func builtInPresets() throws {
        #expect(ConversionPreset.builtIns.count == 5)
        #expect(Set(ConversionPreset.builtIns.map(\.id)).count == 5)
        let data = try JSONEncoder().encode(ConversionPreset.builtIns)
        #expect(
            try JSONDecoder().decode([ConversionPreset].self, from: data)
                == ConversionPreset.builtIns)
    }

    @Test("Requested options travel through the selected path")
    func plannedOptions() throws {
        let options = ConversionPreset.webReadyMP4.options
        let plan = try #require(
            ConversionPlanner().plan(
                from: ConversionFormats.movH264,
                to: ConversionFormats.mp4H264,
                options: options
            )
        )
        #expect(plan.backend == .videoToolbox(.h264))
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].options == options)
        #expect(!plan.isLossless)

        let lossless = try #require(
            ConversionPlanner().plan(
                from: ConversionFormats.movH264,
                to: ConversionFormats.mp4H264,
                options: ConversionPreset.losslessShrink.options
            )
        )
        #expect(lossless.backend == .remux)
        #expect(lossless.isLossless)
    }

    @Test("Image conversion removes GPS and source EXIF metadata")
    func stripsImageMetadata() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("located.tiff")
        let output = folder.appendingPathComponent("private.jpg")
        try makeLocatedImage(at: input)
        let options = ConversionOptions(
            image: ImageConversionOptions(
                quality: 0.8,
                resize: .exact(width: 24, height: 18),
                stripMetadata: true
            )
        )
        let plan = try #require(
            ConversionPlanner().plan(
                from: ConversionFormats.tiff,
                to: ConversionFormats.jpeg,
                options: options
            )
        )
        let stream = await Converter().convert(plan, input: input, output: output)
        for try await _ in stream {}

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 24)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 18)
    }

    @Test("Custom presets persist beside immutable built-ins")
    func customPresetStore() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConversionPresetStore(url: folder.appendingPathComponent("presets.json"))
        let custom = ConversionPreset(
            id: "tiny-jpeg",
            name: "Tiny JPEG",
            target: .jpeg,
            options: ConversionOptions(
                image: ImageConversionOptions(
                    quality: 0.55,
                    resize: .longestSide(640),
                    stripMetadata: true
                )
            )
        )
        try await store.save(custom)
        #expect(try await store.presets().last == custom)
        try await store.remove(custom.id)
        #expect(try await store.presets() == ConversionPreset.builtIns)
    }

    @Test("Slack GIF preset keeps a 30-second 1080p60 source below 8 MB")
    func slackGIFSizeLimit() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("thirty-seconds-1080p60.mov")
        let output = folder.appendingPathComponent("slack.gif")
        try await makeLongVideo(at: input)

        let asset = AVURLAsset(url: input)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await asset.load(.duration).seconds >= 29.9)
        #expect(try await track.load(.nominalFrameRate) == 60)

        let preset = ConversionPreset.slackGIF
        let plan = try #require(
            ConversionPlanner().plan(
                from: ConversionFormats.movH264,
                to: preset.target.formatID,
                options: preset.options
            )
        )
        let stream = await Converter().convert(plan, input: input, output: output)
        for try await _ in stream {}

        let byteSize = try #require(output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(byteSize <= 8 * 1_024 * 1_024)
        let image = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(image) >= 449)
        let firstFrame = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        #expect(firstFrame.width == 854)
        #expect(firstFrame.height == 480)
    }

    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-v2-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeLocatedImage(at url: URL) throws {
        guard
            let context = CGContext(
                data: nil,
                width: 48,
                height: 36,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.tiff.identifier as CFString,
                1,
                nil
            )
        else { throw ConversionError.cannotCreateOutput }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.3349,
                kCGImagePropertyGPSLongitude: -122.009,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "private fixture metadata"
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.cannotCreateOutput
        }
    }

    private func makeLongVideo(at url: URL) async throws {
        let width = 1_920
        let height = 1_080
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_000_000,
                    AVVideoExpectedSourceFrameRateKey: 60,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw ConversionError.cannotCreateOutput }
        writer.add(input)
        guard writer.startWriting() else { throw ConversionError.cannotCreateOutput }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ConversionError.cannotCreateOutput
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            memset(baseAddress, 42, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        for frame in 0..<(30 * 60) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 60)
                )
            else { throw ConversionError.conversionFailed("Video fixture append failed") }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw ConversionError.conversionFailed("Video fixture export failed")
        }
    }
}
