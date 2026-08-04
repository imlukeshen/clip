import Foundation

/// Where a finished screen recording goes when no editor is waiting for it.
///
/// Screenshots always land in the history — they are small and the whole point
/// of the history is to have them ready to paste. Recordings are large enough
/// that copying every one of them is worth opting into, so this is a choice made
/// ahead of time and remembered.
public enum CaptureDestination: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Copy it into the capture history, ready to paste.
    case clipboard
    /// Leave it wherever the system wrote it and let Clip ignore it.
    case file

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clipboard: "Capture history"
        case .file: "Leave the file alone"
        }
    }

    /// A sentence for the settings row, since neither title says what is lost.
    public var detail: String {
        switch self {
        case .clipboard: "Recordings are copied into the history, ready to paste."
        case .file: "Recordings stay where macOS saved them and Clip ignores them."
        }
    }

    private static let storageKey = "reel.captureDestination"

    public static func restored(from defaults: UserDefaults = .standard) -> CaptureDestination {
        guard let raw = defaults.string(forKey: storageKey),
            let destination = CaptureDestination(rawValue: raw)
        else {
            return .clipboard
        }
        return destination
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
