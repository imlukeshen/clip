import Foundation

public enum Backend: Sendable, Equatable {
    case remux
    case videoToolbox(VideoCodec)
    case imageIO(ImageFormat)
    case pdfKit
    case attributedString
    case webKit
    case markdown
    case tectonic
    case ffmpeg(FFmpegRecipe)
    case libreOffice
    case unsupported(String)
}

public enum Estimate: Sendable, Equatable {
    case instant
    case seconds(Int)
    case proportional(Double)
}

public struct ConversionPlan: Sendable, Equatable {
    public var backend: Backend
    public var steps: [PlannedStep]
    public var estimate: Estimate
    public var lossless: Bool
    public var warnings: [String]

    public var isLossless: Bool { lossless }

    public init(
        backend: Backend,
        estimate: Estimate,
        lossless: Bool,
        warnings: [String] = [],
        steps: [PlannedStep] = []
    ) {
        self.backend = backend
        self.steps = steps
        self.estimate = estimate
        self.lossless = lossless
        self.warnings = warnings
    }

    public init(steps: [PlannedStep]) {
        self.steps = steps
        self.backend = steps.first?.implementation ?? .unsupported("No conversion path")
        self.estimate = Self.estimate(for: steps)
        self.lossless = steps.allSatisfy(\.isLossless)
        var seen: Set<String> = []
        self.warnings = steps.flatMap(\.warnings).filter { seen.insert($0).inserted }
    }

    private static func estimate(for steps: [PlannedStep]) -> Estimate {
        guard !steps.isEmpty else { return .instant }
        if steps.allSatisfy({ $0.cost == .passthrough || $0.cost == .cheap }) {
            return steps.allSatisfy { $0.cost == .passthrough } ? .seconds(2) : .instant
        }
        let weight = steps.reduce(0) { $0 + Double($1.cost.rawValue) / 25 }
        return .proportional(max(weight, 1))
    }
}
