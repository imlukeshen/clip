import Foundation

/// User-facing availability of the optional rolling click buffer.
public enum ClickTrackingState: Sendable, Equatable {
    case checking
    case enabled(bufferDurationSeconds: Int)
    case disabled(reason: String)

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}
