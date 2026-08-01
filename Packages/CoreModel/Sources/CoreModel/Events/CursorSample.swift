import Foundation

/// A cursor position sampled in asset-relative time.
public struct CursorSample: Codable, Sendable, Equatable {
    public var time: RationalTime
    public var point: NormalizedPoint

    public init(time: RationalTime, point: NormalizedPoint) {
        self.time = time
        self.point = point
    }
}
