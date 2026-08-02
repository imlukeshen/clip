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
        guard document.timeline.videoTracks.contains(where: { !$0.items.isEmpty }) else {
            throw MediaEngineError.emptyTimeline
        }
        try document.validate()

        let composition = AVMutableComposition()
        var assets: [AssetID: AVURLAsset] = [:]
        var layers: [ReelVideoLayer] = []
        var itemsByTrackID: [CMPersistentTrackID: ItemID] = [:]

        for modelTrack in document.timeline.videoTracks where modelTrack.isEnabled {
            guard
                let compositionTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else {
                throw MediaEngineError.cannotCreateTrack
            }

            for item in modelTrack.items where item.isEnabled {
                let asset = try await asset(
                    for: item.assetID,
                    cache: &assets,
                    resolving: resolving
                )
                guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                    throw MediaEngineError.assetHasNoVideo(item.assetID)
                }
                try await validateSourceRange(item, in: asset)
                do {
                    try compositionTrack.insertTimeRange(
                        item.sourceRange.cmTimeRange,
                        of: source,
                        at: item.timelineStart.cmTime
                    )
                    compositionTrack.scaleTimeRange(
                        CMTimeRange(
                            start: item.timelineStart.cmTime,
                            duration: item.sourceRange.duration.cmTime
                        ),
                        toDuration: item.timelineDuration.cmTime
                    )
                } catch {
                    throw MediaEngineError.compositionFailed(
                        item.id,
                        "The video clip could not be added to the timeline."
                    )
                }
                layers.append(
                    ReelVideoLayer(
                        item: item,
                        preferredTransform: try await source.load(.preferredTransform),
                        sourceTrackID: compositionTrack.trackID
                    )
                )
                itemsByTrackID[compositionTrack.trackID] =
                    itemsByTrackID[compositionTrack.trackID] ?? item.id
            }
        }

        if composition.tracks(withMediaType: .video).isEmpty {
            guard
                composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) != nil
            else {
                throw MediaEngineError.cannotCreateTrack
            }
        }
        if composition.duration < document.duration.cmTime {
            composition.insertEmptyTimeRange(
                CMTimeRange(
                    start: composition.duration,
                    duration: document.duration.cmTime - composition.duration
                )
            )
        }

        let instructions = makeInstructions(
            layers: layers,
            duration: document.duration,
            background: document.canvas.background
        )
        let audioMix = try await addAudio(
            from: document,
            to: composition,
            assets: &assets,
            itemsByTrackID: &itemsByTrackID,
            resolving: resolving
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = EffectCompositor.self
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize(for: document.canvas, quality: quality)
        videoComposition.frameDuration = document.canvas.frameRate.frameDuration.cmTime

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            itemsByTrackID: itemsByTrackID
        )
    }

    private func makeInstructions(
        layers: [ReelVideoLayer],
        duration: RationalTime,
        background: RGBA
    ) -> [ReelVideoInstruction] {
        var boundaries = [RationalTime.zero, duration]
        for layer in layers {
            boundaries.append(layer.item.timelineStart)
            boundaries.append(layer.item.timelineEnd)
        }
        boundaries = Array(Set(boundaries)).sorted()

        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            let active = layers.filter {
                start >= $0.item.timelineStart && start < $0.item.timelineEnd
            }
            return ReelVideoInstruction(
                timeRange: CMTimeRange(
                    start: start.cmTime,
                    duration: (end - start).cmTime
                ),
                layers: active,
                background: background
            )
        }
    }

    private func addAudio(
        from document: ProjectDocument,
        to composition: AVMutableComposition,
        assets: inout [AssetID: AVURLAsset],
        itemsByTrackID: inout [CMPersistentTrackID: ItemID],
        resolving: @Sendable (AssetID) async throws -> URL
    ) async throws -> AVMutableAudioMix {
        let usingFallback = document.timeline.audioTracks.isEmpty
        let modelTracks =
            usingFallback
            ? Array(document.timeline.videoTracks.prefix(1))
            : document.timeline.audioTracks
        let anySolo = modelTracks.contains { $0.isEnabled && $0.isSolo }
        var parameters: [AVMutableAudioMixInputParameters] = []

        // Preserve the v1 contract: even a silent primary video timeline gets
        // an aligned, empty audio composition track.
        for modelTrack in modelTracks where modelTrack.isEnabled {
            guard
                let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else {
                throw MediaEngineError.cannotCreateTrack
            }
            for item in modelTrack.items where item.isEnabled {
                let asset = try await asset(
                    for: item.assetID,
                    cache: &assets,
                    resolving: resolving
                )
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                    continue
                }
                do {
                    try compositionTrack.insertTimeRange(
                        item.sourceRange.cmTimeRange,
                        of: source,
                        at: item.timelineStart.cmTime
                    )
                    compositionTrack.scaleTimeRange(
                        CMTimeRange(
                            start: item.timelineStart.cmTime,
                            duration: item.sourceRange.duration.cmTime
                        ),
                        toDuration: item.timelineDuration.cmTime
                    )
                    itemsByTrackID[compositionTrack.trackID] =
                        itemsByTrackID[compositionTrack.trackID] ?? item.id
                } catch {
                    // Video-only media and a damaged optional audio stream do
                    // not prevent the visual edit from rendering.
                    continue
                }
            }
            let input = AVMutableAudioMixInputParameters(track: compositionTrack)
            let audible = !modelTrack.isMuted && (!anySolo || modelTrack.isSolo)
            let initialGain = linearGain(
                decibels: modelTrack.gain.value(at: .zero),
                audible: audible
            )
            input.setVolume(initialGain, at: .zero)
            if audible {
                var previousTime = RationalTime.zero
                var previousGain = initialGain
                for keyframe in modelTrack.gain.keyframes where keyframe.time > .zero {
                    let nextGain = linearGain(decibels: keyframe.value, audible: true)
                    input.setVolumeRamp(
                        fromStartVolume: previousGain,
                        toEndVolume: nextGain,
                        timeRange: CMTimeRange(
                            start: previousTime.cmTime,
                            duration: (keyframe.time - previousTime).cmTime
                        )
                    )
                    previousTime = keyframe.time
                    previousGain = nextGain
                }
                for item in modelTrack.items where item.isEnabled {
                    let fade = item.audioFade
                    if fade.fadeIn > .zero {
                        let itemGain = linearGain(
                            decibels: modelTrack.gain.value(at: item.timelineStart),
                            audible: true
                        )
                        input.setVolumeRamp(
                            fromStartVolume: 0,
                            toEndVolume: itemGain,
                            timeRange: CMTimeRange(
                                start: item.timelineStart.cmTime,
                                duration: fade.fadeIn.cmTime
                            )
                        )
                    }
                    if fade.fadeOut > .zero {
                        let fadeStart = item.timelineEnd - fade.fadeOut
                        let itemGain = linearGain(
                            decibels: modelTrack.gain.value(at: fadeStart),
                            audible: true
                        )
                        input.setVolumeRamp(
                            fromStartVolume: itemGain,
                            toEndVolume: 0,
                            timeRange: CMTimeRange(
                                start: fadeStart.cmTime,
                                duration: fade.fadeOut.cmTime
                            )
                        )
                    }
                }
            }
            parameters.append(input)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private func linearGain(decibels: Double, audible: Bool) -> Float {
        audible ? Float(pow(10, decibels / 20)) : 0
    }

    private func validateSourceRange(_ item: TimelineItem, in asset: AVURLAsset) async throws {
        let assetDuration = try await asset.load(.duration)
        guard item.sourceRange.start.cmTime >= .zero,
            item.sourceRange.end.cmTime <= assetDuration
        else {
            throw MediaEngineError.invalidSourceRange(item.id)
        }
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
