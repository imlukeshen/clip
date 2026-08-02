import CoreGraphics
import Foundation

/// An unaligned mouse event in the system mach-host-time domain.
public struct RawEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case mouseMoved
        case leftMouseDown
        case leftMouseUp
        case rightMouseDown
        case rightMouseUp
        case scrollWheel
    }

    public var machHostTime: UInt64
    public var wallTime: Date
    public var location: CGPoint
    public var kind: Kind
    public var clickCount: Int

    public init(
        machHostTime: UInt64,
        wallTime: Date,
        location: CGPoint,
        kind: Kind,
        clickCount: Int = 0
    ) {
        self.machHostTime = machHostTime
        self.wallTime = wallTime
        self.location = location
        self.kind = kind
        self.clickCount = clickCount
    }

    public var isClick: Bool {
        kind == .leftMouseDown || kind == .rightMouseDown
    }
}
