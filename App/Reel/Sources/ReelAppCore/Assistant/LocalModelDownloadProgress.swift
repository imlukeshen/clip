import Foundation

/// How far along an in-app model install is.
public struct LocalModelDownloadProgress: Equatable, Sendable {
    /// Ollama's own wording for the current step, shown as-is.
    public let status: String
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(status: String, completedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.status = status
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    /// The fraction transferred, or nil during the steps that move no bytes.
    ///
    /// Manifest and digest-verification lines report no totals, and a
    /// determinate bar that sits at zero through them reads as a stall. Callers
    /// show an indeterminate spinner instead.
    public var fraction: Double? {
        guard totalBytes > 0, completedBytes >= 0 else { return nil }
        return min(Double(completedBytes) / Double(totalBytes), 1)
    }

    /// A short "1.2 GB of 4.9 GB", or nil when no total is known yet.
    public var byteSummary: String? {
        guard totalBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: completedBytes)) of "
            + formatter.string(fromByteCount: totalBytes)
    }
}
