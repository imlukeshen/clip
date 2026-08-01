import Foundation

/// Frame rates supported by a Reel canvas.
public enum FrameRate: String, Codable, Sendable, CaseIterable {
    case fps24
    case fps25
    case fps30
    case ntsc30
    case fps50
    case fps60

    /// Frames per second as a display value.
    public var framesPerSecond: Double {
        switch self {
        case .fps24: 24
        case .fps25: 25
        case .fps30: 30
        case .ntsc30: 30_000.0 / 1_001.0
        case .fps50: 50
        case .fps60: 60
        }
    }

    /// The exact duration of one frame in canonical ticks.
    public var frameDuration: RationalTime {
        switch self {
        case .fps24: RationalTime(value: 3_750)
        case .fps25: RationalTime(value: 3_600)
        case .fps30: RationalTime(value: 3_000)
        case .ntsc30: RationalTime(value: 3_003)
        case .fps50: RationalTime(value: 1_800)
        case .fps60: RationalTime(value: 1_500)
        }
    }
}
