import Foundation

/// Failures surfaced by capture-source adapters.
public enum CaptureError: Error, Sendable, Equatable {
    case inboxUnavailable(String)
}
