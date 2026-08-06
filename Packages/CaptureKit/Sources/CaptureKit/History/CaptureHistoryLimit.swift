import Foundation

/// How much of the capture history is kept.
///
/// The history is a staging area, not an archive — the library is the archive.
/// Both bounds apply, and whichever drops an entry first wins, so a burst of
/// screenshots cannot push out a week's worth and a quiet week cannot hoard.
public struct CaptureHistoryLimit: Sendable, Equatable {
    public let maximumCount: Int
    public let maximumAge: TimeInterval
    public let maximumBytes: Int64

    /// Fifty entries or seven days.
    public static let standard = CaptureHistoryLimit(
        maximumCount: 50,
        maximumAge: 7 * 24 * 60 * 60,
        maximumBytes: 512 * 1_024 * 1_024
    )

    /// Two hundred entries or seven days, for the system-wide clipboard history.
    ///
    /// Text and file-set copies are small and arrive far more often than
    /// screenshots, so the count is raised well above `standard` to keep a
    /// useful backlog; the seven-day age bound is unchanged.
    public static let clipboard = CaptureHistoryLimit(
        maximumCount: 200,
        maximumAge: 7 * 24 * 60 * 60,
        maximumBytes: 512 * 1_024 * 1_024
    )

    public init(
        maximumCount: Int,
        maximumAge: TimeInterval,
        maximumBytes: Int64 = .max
    ) {
        self.maximumCount = maximumCount
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
    }

    /// Splits entries into the ones still within both bounds, newest first, and
    /// the ones that have aged out or fallen off the end.
    public func apply(
        to items: [CaptureHistoryItem],
        now: Date = Date()
    ) -> (kept: [CaptureHistoryItem], expired: [CaptureHistoryItem]) {
        var kept: [CaptureHistoryItem] = []
        var expired: [CaptureHistoryItem] = []
        var keptBytes: Int64 = 0
        for item in items.sorted(by: { $0.capturedAt > $1.capturedAt }) {
            // A capture dated in the future — a clock change, say — reads as
            // age zero rather than as instantly stale.
            let age = now.timeIntervalSince(item.capturedAt)
            let itemBytes = max(item.byteSize, 0)
            let exceedsByteLimit =
                itemBytes > maximumBytes || keptBytes > maximumBytes - itemBytes
            if age > maximumAge || kept.count >= maximumCount || exceedsByteLimit {
                expired.append(item)
            } else {
                kept.append(item)
                keptBytes += itemBytes
            }
        }
        return (kept, expired)
    }
}
