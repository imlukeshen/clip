import CoreGraphics
import CoreModel
import Foundation

public struct ExportPreset: Sendable, Equatable {
    public enum Container: String, Sendable, CaseIterable {
        case mp4
        case mov
    }

    public enum Codec: String, Sendable, CaseIterable {
        case h264
        case hevc
        case proRes422
    }

    public var container: Container
    public var codec: Codec
    public var size: CGSize
    public var frameRate: FrameRate
    public var bitrate: Int?
    public var includeAudio: Bool
    public var burnCaptions: Bool

    public init(
        container: Container,
        codec: Codec,
        size: CGSize,
        frameRate: FrameRate,
        bitrate: Int? = nil,
        includeAudio: Bool = true,
        burnCaptions: Bool = false
    ) {
        self.container = container
        self.codec = codec
        self.size = size
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.includeAudio = includeAudio
        self.burnCaptions = burnCaptions
    }

    public static let h264FullHD = ExportPreset(
        container: .mp4,
        codec: .h264,
        size: CGSize(width: 1_920, height: 1_080),
        frameRate: .fps60,
        bitrate: 12_000_000
    )
}

public struct ExportProgress: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case preparing
        case rendering
        case finalizing
        case completed
    }

    public var stage: Stage
    public var fraction: Double

    public init(stage: Stage, fraction: Double) {
        self.stage = stage
        self.fraction = min(max(fraction, 0), 1)
    }
}
