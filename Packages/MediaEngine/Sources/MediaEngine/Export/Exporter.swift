@preconcurrency import AVFoundation
import CoreMedia
import CoreModel
import Foundation

public actor Exporter {
    public init() {}

    public func export(
        _ document: ProjectDocument,
        preset: ExportPreset,
        to outputURL: URL,
        resolving: @escaping @Sendable (AssetID) async throws -> URL
    ) -> AsyncThrowingStream<ExportProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(ExportProgress(stage: .preparing, fraction: 0))
                    try validate(preset)
                    let built = try await CompositionBuilder().build(
                        document,
                        resolving: resolving,
                        quality: .full
                    )
                    built.videoComposition.renderSize = preset.size
                    built.videoComposition.frameDuration = preset.frameRate.frameDuration.cmTime
                    if !preset.includeAudio {
                        for track in built.composition.tracks(withMediaType: .audio) {
                            built.composition.removeTrack(track)
                        }
                    }

                    let temporary = try prepareTemporaryURL(for: outputURL, preset: preset)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try await render(
                        built,
                        preset: preset,
                        to: temporary,
                        duration: document.duration,
                        continuation: continuation
                    )
                    try commit(temporary, to: outputURL)
                    continuation.yield(ExportProgress(stage: .completed, fraction: 1))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: MediaEngineError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func validate(_ preset: ExportPreset) throws {
        guard preset.size.width >= 2,
            preset.size.height >= 2,
            Int(preset.size.width).isMultiple(of: 2),
            Int(preset.size.height).isMultiple(of: 2)
        else {
            throw MediaEngineError.invalidExportPreset(
                "Export dimensions must be positive even numbers."
            )
        }
        if let bitrate = preset.bitrate, bitrate <= 0 {
            throw MediaEngineError.invalidExportPreset("Export bitrate must be positive.")
        }
        guard preset.codec != .proRes422 || preset.container == .mov else {
            throw MediaEngineError.invalidExportPreset("ProRes 422 requires a MOV container.")
        }
    }

    private func render(
        _ built: BuiltComposition,
        preset: ExportPreset,
        to url: URL,
        duration: RationalTime,
        continuation: AsyncThrowingStream<ExportProgress, Error>.Continuation
    ) async throws {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: built.composition)
            writer = try AVAssetWriter(outputURL: url, fileType: preset.fileType)
        } catch {
            throw MediaEngineError.exportFailed("The media pipeline could not be opened.")
        }

        let videoTracks = built.composition.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MediaEngineError.emptyTimeline }
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: preset.videoSettings
        )
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw MediaEngineError.exportFailed("The video export settings are unsupported.")
        }
        reader.add(videoOutput)
        writer.add(videoInput)

        let audioTracks = built.composition.tracks(withMediaType: .audio).filter {
            $0.segments?.isEmpty == false
        }
        let audioPair: (AVAssetReaderAudioMixOutput, AVAssetWriterInput)?
        if preset.includeAudio, !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            output.audioMix = built.audioMix
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ]
            )
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw MediaEngineError.exportFailed("The audio export settings are unsupported.")
            }
            reader.add(output)
            writer.add(input)
            audioPair = (output, input)
        } else {
            audioPair = nil
        }

        guard writer.startWriting(), reader.startReading() else {
            throw MediaEngineError.exportFailed(
                reader.error?.localizedDescription
                    ?? writer.error?.localizedDescription
                    ?? "The export could not start."
            )
        }
        writer.startSession(atSourceTime: .zero)
        continuation.yield(ExportProgress(stage: .rendering, fraction: 0.01))

        var videoFinished = false
        var audioFinished = audioPair == nil
        var lastProgress = 0.0
        do {
            while !videoFinished || !audioFinished {
                try Task.checkCancellation()
                var advanced = false
                if !videoFinished, videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        guard videoInput.append(sample) else {
                            throw MediaEngineError.exportFailed(
                                "A video frame could not be encoded."
                            )
                        }
                        advanced = true
                        let presentationTime =
                            CMSampleBufferGetPresentationTimeStamp(sample).rational
                        let fraction = min(
                            presentationTime.seconds / max(duration.seconds, 0.001), 0.98)
                        if fraction - lastProgress >= 0.01 {
                            lastProgress = fraction
                            continuation.yield(
                                ExportProgress(stage: .rendering, fraction: fraction)
                            )
                        }
                    } else {
                        videoInput.markAsFinished()
                        videoFinished = true
                    }
                }
                if !audioFinished, let (audioOutput, audioInput) = audioPair,
                    audioInput.isReadyForMoreMediaData
                {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        guard audioInput.append(sample) else {
                            throw MediaEngineError.exportFailed(
                                "An audio sample could not be encoded."
                            )
                        }
                        advanced = true
                    } else {
                        audioInput.markAsFinished()
                        audioFinished = true
                    }
                }
                if !advanced { try await Task.sleep(for: .milliseconds(2)) }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            throw MediaEngineError.exportFailed(
                reader.error?.localizedDescription ?? "The timeline could not be read."
            )
        }
        continuation.yield(ExportProgress(stage: .finalizing, fraction: 0.99))
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw MediaEngineError.exportFailed(
                writer.error?.localizedDescription ?? "The output could not be finalized."
            )
        }
    }

    private func prepareTemporaryURL(
        for output: URL,
        preset: ExportPreset
    ) throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw MediaEngineError.cannotCreateOutput
        }
        return output.deletingLastPathComponent().appendingPathComponent(
            ".reel-export-\(UUID().uuidString).\(preset.container.rawValue)"
        )
    }

    private func commit(_ temporary: URL, to output: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: output)
            }
        } catch {
            throw MediaEngineError.cannotCreateOutput
        }
    }
}

extension ExportPreset {
    fileprivate var fileType: AVFileType {
        switch container {
        case .mp4: .mp4
        case .mov: .mov
        }
    }

    fileprivate var videoSettings: [String: Any] {
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: frameRate.framesPerSecond
        ]
        if let bitrate { compression[AVVideoAverageBitRateKey] = bitrate }
        return [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
    }
}

extension ExportPreset.Codec {
    fileprivate var avCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        }
    }
}
