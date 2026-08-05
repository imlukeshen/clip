@preconcurrency import AVFoundation
import Foundation

enum AVExport {
    static func run(
        input: URL,
        output: URL,
        preset: String,
        fileType: AVFileType,
        options: ConversionOptions = ConversionOptions()
    ) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.invalidInput
        }
        let temporary = try AtomicOutput.prepareTemporaryURL(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }

        if options.removesMetadata { session.metadata = [] }
        if let trim = options.video?.trim {
            guard trim.startSeconds >= 0, trim.endSeconds > trim.startSeconds else {
                throw ConversionError.invalidInput
            }
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: trim.startSeconds, preferredTimescale: 600),
                end: CMTime(seconds: trim.endSeconds, preferredTimescale: 600)
            )
        }

        if #available(macOS 15.0, *) {
            do {
                try await session.export(to: temporary, as: fileType)
            } catch is CancellationError {
                session.cancelExport()
                throw ConversionError.cancelled
            } catch {
                throw ConversionError.conversionFailed("AVFoundation export failed")
            }
        } else {
            session.outputURL = temporary
            session.outputFileType = fileType
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            switch session.status {
            case .completed: break
            case .cancelled: throw ConversionError.cancelled
            default: throw ConversionError.conversionFailed("AVFoundation export failed")
            }
        }
        try AtomicOutput.commit(temporary, to: output)
    }

    static func fileType(for output: URL) throws -> AVFileType {
        switch output.pathExtension.lowercased() {
        case "mp4": .mp4
        case "mov": .mov
        case "m4a": .m4a
        default: throw ConversionError.cannotCreateOutput
        }
    }
}
