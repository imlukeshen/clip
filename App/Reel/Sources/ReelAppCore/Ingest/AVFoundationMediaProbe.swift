@preconcurrency import AVFoundation
import CoreMedia
import CoreModel
import Foundation
import ImageIO
import LibraryStore

/// Production media probing backed by asynchronous AVFoundation and ImageIO APIs.
public struct AVFoundationMediaProbe: MediaProbing {
    public init() {}

    public func probe(_ url: URL) async throws -> MediaProbeResult {
        let fileExtension = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(fileExtension) {
            return try probeImage(url, fileExtension: fileExtension)
        }
        return try await probeMedia(url, fileExtension: fileExtension)
    }

    private func probeImage(_ url: URL, fileExtension: String) throws -> MediaProbeResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            throw IngestError.unreadable(url, underlying: "image metadata unavailable")
        }
        return MediaProbeResult(
            kind: .image,
            container: fileExtension,
            codec: nil,
            width: width,
            height: height,
            duration: nil,
            nominalFPS: nil,
            isVariableFPS: false,
            hasAudio: false,
            preferredTransform: nil
        )
    }

    private func probeMedia(_ url: URL, fileExtension: String) async throws -> MediaProbeResult {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard duration.isValid,
                !duration.isIndefinite,
                duration.seconds.isFinite,
                duration.seconds > 0
            else {
                throw IngestError.zeroDuration(url)
            }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let video = videoTracks.first else {
                guard !audioTracks.isEmpty else {
                    throw IngestError.unsupportedType(fileExtension)
                }
                return MediaProbeResult(
                    kind: .audio,
                    container: fileExtension,
                    codec: try await codec(of: audioTracks[0]),
                    width: nil,
                    height: nil,
                    duration: RationalTime(seconds: duration.seconds),
                    nominalFPS: nil,
                    isVariableFPS: false,
                    hasAudio: true,
                    preferredTransform: nil
                )
            }

            let naturalSize = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let nominalFPS = try await video.load(.nominalFrameRate)
            let minimumFrameDuration = try await video.load(.minFrameDuration)
            let fps = nominalFPS > 0 ? Double(nominalFPS) : nil
            let isVariable: Bool
            if let fps, minimumFrameDuration.isValid, minimumFrameDuration.seconds > 0 {
                let expected = 1 / fps
                isVariable = abs(minimumFrameDuration.seconds - expected) / expected > 0.05
            } else {
                isVariable = true
            }

            return MediaProbeResult(
                kind: .video,
                container: fileExtension,
                codec: try await codec(of: video),
                width: Int(naturalSize.width.rounded()),
                height: Int(naturalSize.height.rounded()),
                duration: RationalTime(seconds: duration.seconds),
                nominalFPS: fps,
                isVariableFPS: isVariable,
                hasAudio: !audioTracks.isEmpty,
                preferredTransform: transformJSON(transform)
            )
        } catch let error as IngestError {
            throw error
        } catch {
            throw IngestError.unreadable(url, underlying: "media metadata unavailable")
        }
    }

    private func codec(of track: AVAssetTrack) async throws -> String? {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else { return nil }
        let value = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [CChar] = [
            CChar((value >> 24) & 0xFF),
            CChar((value >> 16) & 0xFF),
            CChar((value >> 8) & 0xFF),
            CChar(value & 0xFF),
            0,
        ]
        return bytes.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return String(cString: baseAddress).trimmingCharacters(in: .whitespaces)
        }
    }

    private func transformJSON(_ transform: CGAffineTransform) -> JSONValue {
        .object([
            "a": .number(transform.a),
            "b": .number(transform.b),
            "c": .number(transform.c),
            "d": .number(transform.d),
            "tx": .number(transform.tx),
            "ty": .number(transform.ty),
        ])
    }
}
