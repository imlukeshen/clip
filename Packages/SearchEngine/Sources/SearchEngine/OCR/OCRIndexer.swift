@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreModel
import Foundation
import ImageIO
import LibraryStore

/// Produces searchable OCR spans for still images and screen recordings.
public actor OCRIndexer {
    private let recognizer: VisionTextRecognizer
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init(recognizer: VisionTextRecognizer = VisionTextRecognizer()) {
        self.recognizer = recognizer
    }

    public func index(
        asset: AssetRecord,
        url: URL,
        eventTrack: EventTrack?
    ) async throws -> [OCRSpan] {
        switch asset.kind {
        case .image:
            return try await indexImage(assetID: asset.id, url: url)
        case .video:
            return try await indexVideo(asset: asset, url: url, eventTrack: eventTrack)
        case .audio, .document, .text:
            return []
        }
    }

    private func indexImage(assetID: AssetID, url: URL) async throws -> [OCRSpan] {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw OCRIndexError.unreadableImage }
        return try await recognizer.recognize(image).map { block in
            OCRSpan(
                assetID: assetID,
                text: block.text,
                boundingBox: block.boundingBox,
                confidence: block.confidence,
                revision: VisionTextRecognizer.revision,
                script: block.script
            )
        }
    }

    private func indexVideo(
        asset: AssetRecord,
        url: URL,
        eventTrack: EventTrack?
    ) async throws -> [OCRSpan] {
        let avAsset = AVURLAsset(url: url)
        guard let track = try await avAsset.loadTracks(withMediaType: .video).first else {
            throw OCRIndexError.missingVideoTrack
        }
        let duration = try await avAsset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw OCRIndexError.invalidDuration }
        let transform = try await track.load(.preferredTransform)
        let orientation = imageOrientation(for: transform)
        let reader = try AVAssetReader(asset: avAsset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw OCRIndexError.readerSetupFailed }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? OCRIndexError.readerSetupFailed
        }

        let clickTimes = (eventTrack?.clicks ?? []).map(\.time.seconds).sorted()
        let bucketDuration = OCRFrameSelectionPolicy.bucketDuration(for: duration)
        var lastSampledSecond = -1
        var lastAcceptedHash: PerceptualHash?
        var currentBucket = -1
        var candidate: VideoFrameCandidate?
        var frames: [OCRFrame] = []

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard seconds.isFinite, seconds >= 0 else { continue }
            let wholeSecond = Int(seconds.rounded(.down))
            let anchorDistance = clickTimes.map { abs($0 - seconds) }.min() ?? .infinity
            let isClickAnchor = anchorDistance <= 0.15
            guard wholeSecond != lastSampledSecond || isClickAnchor else { continue }
            lastSampledSecond = wholeSecond
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                let image = cgImage(from: buffer),
                let hash = PerceptualHash(image: image)
            else { continue }

            let bucket = min(
                Int(seconds / bucketDuration),
                OCRFrameSelectionPolicy.maximumFramesPerAsset - 1
            )
            if bucket != currentBucket {
                if let candidate {
                    try await append(
                        candidate,
                        assetID: asset.id,
                        duration: duration,
                        bucketDuration: bucketDuration,
                        orientation: orientation,
                        previousHash: &lastAcceptedHash,
                        frames: &frames
                    )
                }
                currentBucket = bucket
                candidate = nil
            }
            let distance =
                lastAcceptedHash.map { hash.hammingDistance(to: $0) }
                ?? PerceptualHash.bitCount
            let next = VideoFrameCandidate(
                time: seconds,
                image: image,
                hash: hash,
                isClickAnchor: isClickAnchor,
                anchorDistance: anchorDistance,
                changeDistance: distance
            )
            if next.isPreferred(over: candidate) { candidate = next }
        }

        if let candidate {
            try await append(
                candidate,
                assetID: asset.id,
                duration: duration,
                bucketDuration: bucketDuration,
                orientation: orientation,
                previousHash: &lastAcceptedHash,
                frames: &frames
            )
        }
        if reader.status == .failed { throw reader.error ?? OCRIndexError.readerFailed }
        return OCRTemporalDeduplicator.spans(
            assetID: asset.id,
            frames: frames,
            revision: VisionTextRecognizer.revision
        )
    }

    private func append(
        _ candidate: VideoFrameCandidate,
        assetID: AssetID,
        duration: Double,
        bucketDuration: Double,
        orientation: CGImagePropertyOrientation,
        previousHash: inout PerceptualHash?,
        frames: inout [OCRFrame]
    ) async throws {
        guard
            OCRFrameSelectionPolicy.shouldAccept(
                hash: candidate.hash,
                after: previousHash,
                isFirstFrame: frames.isEmpty,
                isClickAnchor: candidate.isClickAnchor
            )
        else { return }
        let blocks = try await recognizer.recognize(candidate.image, orientation: orientation)
        previousHash = candidate.hash
        guard !blocks.isEmpty else { return }
        frames.append(
            OCRFrame(
                time: RationalTime(seconds: candidate.time),
                end: RationalTime(seconds: min(duration, candidate.time + bucketDuration)),
                blocks: blocks
            )
        )
    }

    private func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return context.createCGImage(image, from: image.extent)
    }

    private func imageOrientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let rounded = (
            Int(transform.a.rounded()),
            Int(transform.b.rounded()),
            Int(transform.c.rounded()),
            Int(transform.d.rounded())
        )
        switch rounded {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }
}

private struct VideoFrameCandidate {
    var time: Double
    var image: CGImage
    var hash: PerceptualHash
    var isClickAnchor: Bool
    var anchorDistance: Double
    var changeDistance: Int

    func isPreferred(over current: Self?) -> Bool {
        guard let current else { return true }
        if isClickAnchor != current.isClickAnchor { return isClickAnchor }
        if isClickAnchor { return anchorDistance < current.anchorDistance }
        return changeDistance > current.changeDistance
    }
}

public enum OCRIndexError: Error, Sendable, Equatable {
    case unreadableImage
    case missingVideoTrack
    case invalidDuration
    case readerSetupFailed
    case readerFailed
}
