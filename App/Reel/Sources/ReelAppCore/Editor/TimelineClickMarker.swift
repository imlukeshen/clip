import CoreModel
import Foundation

/// A recorded click mapped from asset time into project timeline time.
public struct TimelineClickMarker: Sendable, Equatable, Identifiable {
    public let id: String
    public let itemID: ItemID
    public let timelineTime: RationalTime
    public let sourceTime: RationalTime
    public let point: NormalizedPoint
    public let button: MouseButton
    public let clickCount: Int

    public init(
        id: String,
        itemID: ItemID,
        timelineTime: RationalTime,
        sourceTime: RationalTime,
        point: NormalizedPoint,
        button: MouseButton,
        clickCount: Int
    ) {
        self.id = id
        self.itemID = itemID
        self.timelineTime = timelineTime
        self.sourceTime = sourceTime
        self.point = point
        self.button = button
        self.clickCount = clickCount
    }
}
