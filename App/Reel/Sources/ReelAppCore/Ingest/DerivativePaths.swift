import Foundation

/// Best-effort derivative files generated for an imported asset.
public struct DerivativePaths: Sendable, Equatable {
    public var thumbnail: URL?
    public var peaks: URL?

    public init(thumbnail: URL?, peaks: URL?) {
        self.thumbnail = thumbnail
        self.peaks = peaks
    }

    public static let none = DerivativePaths(thumbnail: nil, peaks: nil)
}
