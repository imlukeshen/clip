@preconcurrency import AVFoundation
import CoreMedia
import CoreModel
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Production best-effort thumbnail and 100 Hz audio-envelope generation.
public struct AVFoundationDerivativeGenerator: DerivativeGenerating {
    public init() {}

    public func generate(
        for assetURL: URL,
        assetID: AssetID,
        destinationFolder: URL,
        probe: MediaProbeResult
    ) async throws -> DerivativePaths {
        let thumbnail: URL?
        switch probe.kind {
        case .video:
            thumbnail = try await videoThumbnail(
                assetURL,
                assetID: assetID,
                destinationFolder: destinationFolder,
                duration: probe.duration
            )
        case .image:
            thumbnail = try imageThumbnail(
                assetURL,
                assetID: assetID,
                destinationFolder: destinationFolder
            )
        case .audio, .document, .text:
            thumbnail = nil
        }

        let peaks: URL?
        if probe.hasAudio {
            peaks = try await audioPeaks(
                assetURL,
                assetID: assetID,
                destinationFolder: destinationFolder
            )
        } else {
            peaks = nil
        }
        return DerivativePaths(thumbnail: thumbnail, peaks: peaks)
    }

    private func videoThumbnail(
        _ url: URL,
        assetID: AssetID,
        destinationFolder: URL,
        duration: RationalTime?
    ) async throws -> URL? {
        guard let duration else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(
            seconds: max(duration.seconds * 0.1, 0),
            preferredTimescale: RationalTime.timescale
        )
        let result = try await generator.image(at: time)
        let destination = destinationFolder.appendingPathComponent(
            "\(assetID.rawValue).thumb.heic"
        )
        try writeHEIC(result.image, to: destination)
        return destination
    }

    private func imageThumbnail(
        _ url: URL,
        assetID: AssetID,
        destinationFolder: URL
    ) throws -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
            )
        else {
            return nil
        }
        let destination = destinationFolder.appendingPathComponent(
            "\(assetID.rawValue).thumb.heic"
        )
        try writeHEIC(image, to: destination)
        return destination
    }

    private func writeHEIC(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.heic.identifier as CFString,
                1,
                nil
            )
        else {
            throw IngestError.unreadable(url, underlying: "thumbnail destination unavailable")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw IngestError.unreadable(url, underlying: "thumbnail could not be written")
        }
    }

    private func audioPeaks(
        _ url: URL,
        assetID: AssetID,
        destinationFolder: URL
    ) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else {
            return nil
        }
        let sampleRate = streamDescription.pointee.mSampleRate
        let channels = max(Int(streamDescription.pointee.mChannelsPerFrame), 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let framesPerWindow = max(Int(sampleRate * 0.01), 1)
        var sumOfSquares = 0.0
        var framesInWindow = 0
        var peaks: [Float32] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            var data = Data(count: byteCount)
            let status = data.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return kCMBlockBufferBadCustomBlockSourceErr
                }
                return CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: baseAddress
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }
            data.withUnsafeBytes { bytes in
                let values = bytes.bindMemory(to: Float32.self)
                var index = 0
                while index + channels <= values.count {
                    var frameEnergy = 0.0
                    for channel in 0..<channels {
                        let value = Double(values[index + channel])
                        frameEnergy += value * value
                    }
                    sumOfSquares += frameEnergy / Double(channels)
                    framesInWindow += 1
                    if framesInWindow == framesPerWindow {
                        peaks.append(Float32(sqrt(sumOfSquares / Double(framesInWindow))))
                        sumOfSquares = 0
                        framesInWindow = 0
                    }
                    index += channels
                }
            }
        }
        if framesInWindow > 0 {
            peaks.append(Float32(sqrt(sumOfSquares / Double(framesInWindow))))
        }

        let destination = destinationFolder.appendingPathComponent(
            "\(assetID.rawValue).peaks.bin"
        )
        try peaksData(peaks, sampleRate: Float32(sampleRate)).write(
            to: destination,
            options: .atomic
        )
        return destination
    }

    private func peaksData(_ peaks: [Float32], sampleRate: Float32) -> Data {
        var data = Data("RPKS".utf8)
        append(UInt16(1), to: &data)
        append(UInt16(10), to: &data)
        append(UInt32(peaks.count), to: &data)
        append(sampleRate.bitPattern, to: &data)
        for peak in peaks {
            append(peak.bitPattern, to: &data)
        }
        return data
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
