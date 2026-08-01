import Foundation

/// The ordered, gapless media tracks and project-timed captions.
public struct Timeline: Codable, Sendable, Equatable {
    public var video: [TimelineItem]
    public var audio: [TimelineItem]
    public var captions: [CaptionSegment]

    public init(
        video: [TimelineItem] = [],
        audio: [TimelineItem] = [],
        captions: [CaptionSegment] = []
    ) {
        self.video = video
        self.audio = audio
        self.captions = captions
    }
}
