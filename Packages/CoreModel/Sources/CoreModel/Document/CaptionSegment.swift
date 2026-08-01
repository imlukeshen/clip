import Foundation

/// A timed caption in project timeline time.
public struct CaptionSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var range: TimeRange
    public var text: String

    public init(id: String, range: TimeRange, text: String) {
        self.id = id
        self.range = range
        self.text = text
    }
}
