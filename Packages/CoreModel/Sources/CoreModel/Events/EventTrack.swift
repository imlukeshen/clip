import Foundation

/// Cursor movement and clicks associated with one immutable asset.
public struct EventTrack: Codable, Sendable, Equatable {
    public var assetID: AssetID
    public var alignment: Alignment
    public var samples: [CursorSample]
    public var clicks: [ClickEvent]

    public init(
        assetID: AssetID,
        alignment: Alignment,
        samples: [CursorSample],
        clicks: [ClickEvent]
    ) {
        self.assetID = assetID
        self.alignment = alignment
        self.samples = samples
        self.clicks = clicks
    }
}
