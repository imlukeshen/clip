@preconcurrency import AVFoundation
import CoreModel
import Foundation

public struct CompositionBuilder: Sendable {
    public init() {}

    public func build(
        _ document: ProjectDocument,
        resolving: @Sendable (AssetID) async throws -> URL,
        quality: RenderQuality
    ) async throws -> sending BuiltComposition {
        guard !document.timeline.video.isEmpty else {
            throw MediaEngineError.emptyTimeline
        }
        try document.validate()

        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw MediaEngineError.cannotCreateTrack
        }

        var assets: [AssetID: AVURLAsset] = [:]
        var instructions: [ReelVideoInstruction] = []
        var itemsByTrackID: [CMPersistentTrackID: ItemID] = [:]
        var videoCursor = CMTime.zero

        for item in document.timeline.video {
            let asset = try await asset(for: item.assetID, cache: &assets, resolving: resolving)
            let targetDuration = item.timelineDuration.cmTime
            let targetRange = CMTimeRange(start: videoCursor, duration: targetDuration)
            var sourceTrackID: CMPersistentTrackID?
            var transform = CGAffineTransform.identity

            if item.isEnabled {
                guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                    throw MediaEngineError.assetHasNoVideo(item.assetID)
                }
                let assetDuration = try await asset.load(.duration)
                guard item.sourceRange.start.cmTime >= .zero,
                    item.sourceRange.end.cmTime <= assetDuration
                else {
                    throw MediaEngineError.invalidSourceRange(item.id)
                }
                do {
                    try videoTrack.insertTimeRange(
                        item.sourceRange.cmTimeRange,
                        of: source,
                        at: videoCursor
                    )
                    videoTrack.scaleTimeRange(
                        CMTimeRange(start: videoCursor, duration: item.sourceRange.duration.cmTime),
                        toDuration: targetDuration
                    )
                } catch {
                    throw MediaEngineError.compositionFailed(
                        item.id,
                        "The video clip could not be added to the timeline."
                    )
                }
                transform = try await source.load(.preferredTransform)
                sourceTrackID = videoTrack.trackID
                itemsByTrackID[videoTrack.trackID] = itemsByTrackID[videoTrack.trackID] ?? item.id
            } else {
                videoTrack.insertEmptyTimeRange(targetRange)
            }

            instructions.append(
                ReelVideoInstruction(
                    timeRange: targetRange,
                    item: item,
                    preferredTransform: transform,
                    background: document.canvas.background,
                    sourceTrackID: sourceTrackID
                )
            )
            videoCursor = videoCursor + targetDuration
        }

        let audioItems =
            document.timeline.audio.isEmpty
            ? document.timeline.video : document.timeline.audio
        var audioCursor = CMTime.zero
        for item in audioItems {
            let asset = try await asset(for: item.assetID, cache: &assets, resolving: resolving)
            let targetDuration = item.timelineDuration.cmTime
            let targetRange = CMTimeRange(start: audioCursor, duration: targetDuration)
            if item.isEnabled,
                let source = try await asset.loadTracks(withMediaType: .audio).first
            {
                do {
                    try audioTrack.insertTimeRange(
                        item.sourceRange.cmTimeRange,
                        of: source,
                        at: audioCursor
                    )
                    audioTrack.scaleTimeRange(
                        CMTimeRange(start: audioCursor, duration: item.sourceRange.duration.cmTime),
                        toDuration: targetDuration
                    )
                    itemsByTrackID[audioTrack.trackID] =
                        itemsByTrackID[audioTrack.trackID] ?? item.id
                } catch {
                    audioTrack.insertEmptyTimeRange(targetRange)
                }
            } else {
                audioTrack.insertEmptyTimeRange(targetRange)
            }
            audioCursor = audioCursor + targetDuration
        }
        if audioCursor < videoCursor {
            audioTrack.insertEmptyTimeRange(
                CMTimeRange(start: audioCursor, duration: videoCursor - audioCursor)
            )
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = EffectCompositor.self
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize(for: document.canvas, quality: quality)
        videoComposition.frameDuration = document.canvas.frameRate.frameDuration.cmTime

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = []
        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            itemsByTrackID: itemsByTrackID
        )
    }

    private func asset(
        for id: AssetID,
        cache: inout [AssetID: AVURLAsset],
        resolving: @Sendable (AssetID) async throws -> URL
    ) async throws -> AVURLAsset {
        if let cached = cache[id] { return cached }
        let asset = AVURLAsset(url: try await resolving(id))
        cache[id] = asset
        return asset
    }

    private func renderSize(for canvas: CanvasSpec, quality: RenderQuality) -> CGSize {
        let full = CGSize(width: canvas.width, height: canvas.height)
        guard case .proxy(let maximumHeight) = quality,
            maximumHeight > 0,
            canvas.height > maximumHeight
        else {
            return full
        }
        let factor = Double(maximumHeight) / Double(canvas.height)
        let width = max(2, Int((Double(canvas.width) * factor).rounded()) / 2 * 2)
        let height = max(2, maximumHeight / 2 * 2)
        return CGSize(width: width, height: height)
    }
}
