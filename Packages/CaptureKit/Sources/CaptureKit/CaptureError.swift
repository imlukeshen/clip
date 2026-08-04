import Foundation

/// Failures surfaced by capture-source adapters.
public enum CaptureError: Error, Sendable, Equatable {
    case inboxUnavailable(String)
    case accessibilityDenied
    case eventTapUnavailable
    case hotKeyUnavailable
    case unsupportedCapture(String)
    case historyUnavailable(String)
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
        case .hotKeyUnavailable:
            "The global clipboard shortcut could not be registered with the system."
        case .unsupportedCapture(let name):
            "\(name) is not a format the capture history can hold."
        case .historyUnavailable(let name):
            "\(name) could not be copied into the capture history."
        }
    }
}
