import Foundation

/// Where a finished screen recording goes when no editor is waiting for it.
///
/// Screenshots always land in the history so they remain ready to paste.
/// Recordings default to the timeline because a finished screen recording is
/// normally the next edit; people can instead stage it or leave the source file
/// alone. The choice is made ahead of time and remembered.
public enum CaptureDestination: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Import it and open a new timeline, or append it to the open timeline.
    case timeline
    /// Copy it into the capture history, ready to paste.
    case clipboard
    /// Leave it wherever the system wrote it and let Clip ignore it.
    case file

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .timeline: "Open in video editor"
        case .clipboard: "Capture history"
        case .file: "Leave the file alone"
        }
    }

    /// A sentence for the settings row, since neither title says what is lost.
    public var detail: String {
        switch self {
        case .timeline:
            "Recordings open as a timeline, or append to the timeline you are editing."
        case .clipboard: "Recordings are copied into the history, ready to paste."
        case .file: "Recordings stay where macOS saved them and Clip ignores them."
        }
    }

    private static let storageKey = "reel.captureDestination"

    public static func restored(from defaults: UserDefaults = .standard) -> CaptureDestination {
        guard let raw = defaults.string(forKey: storageKey),
            let destination = CaptureDestination(rawValue: raw)
        else {
            return .timeline
        }
        return destination
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
