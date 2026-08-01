import Foundation

/// A mouse click captured in asset-relative time.
public struct ClickEvent: Codable, Sendable, Equatable {
    public var time: RationalTime
    public var point: NormalizedPoint
    public var button: MouseButton
    public var clickCount: Int

    public init(
        time: RationalTime,
        point: NormalizedPoint,
        button: MouseButton,
        clickCount: Int
    ) {
        self.time = time
        self.point = point
        self.button = button
        self.clickCount = clickCount
    }
}
