import Foundation

public enum Backend: Sendable, Equatable {
    case remux
    case videoToolbox(VideoCodec)
    case imageIO(ImageFormat)
    case ffmpeg(FFmpegRecipe)
    case unsupported(String)
}

public enum Estimate: Sendable, Equatable {
    case instant
    case seconds(Int)
    case proportional(Double)
}

public struct ConversionPlan: Sendable, Equatable {
    public var backend: Backend
    public var estimate: Estimate
    public var lossless: Bool
    public var warnings: [String]

    public init(
        backend: Backend,
        estimate: Estimate,
        lossless: Bool,
        warnings: [String] = []
    ) {
        self.backend = backend
        self.estimate = estimate
        self.lossless = lossless
        self.warnings = warnings
    }
}

public struct BatchProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var itemIndex: Int
    public var itemProgress: Double

    public init(completed: Int, total: Int, itemIndex: Int, itemProgress: Double) {
        self.completed = completed
        self.total = total
        self.itemIndex = itemIndex
        self.itemProgress = itemProgress
    }
}
