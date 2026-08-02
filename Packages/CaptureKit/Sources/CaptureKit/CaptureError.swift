import Foundation

/// Failures surfaced by capture-source adapters.
public enum CaptureError: Error, Sendable, Equatable {
    case inboxUnavailable(String)
    case accessibilityDenied
    case eventTapUnavailable
}

extension CaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .inboxUnavailable(let reason):
            "The capture inbox is unavailable: \(reason)"
        case .accessibilityDenied:
            "Click tracking is off because Accessibility access has not been granted."
        case .eventTapUnavailable:
            "Click tracking could not connect to the macOS event stream."
        }
    }
}
