import Foundation

/// A named media track. Items are sorted by their explicit project start time;
/// gaps are permitted and overlapping video tracks composite bottom to top.
public struct Track: Codable, Sendable, Equatable, Identifiable {
    public var id: TrackID
    public var name: String
    public var items: [TimelineItem]
    public var isEnabled: Bool
    public var isLocked: Bool
    public var isMuted: Bool
    public var isSolo: Bool
    /// Track gain in decibels. It is meaningful for audio tracks only.
    public var gain: Double

    public init(
        id: TrackID,
        name: String,
        items: [TimelineItem] = [],
        isEnabled: Bool = true,
        isLocked: Bool = false,
        isMuted: Bool = false,
        isSolo: Bool = false,
        gain: Double = 0
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.isEnabled = isEnabled
        self.isLocked = isLocked
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.gain = gain
    }
}

/// A named project-time landmark used for navigation and snapping.
public struct Marker: Codable, Sendable, Equatable, Identifiable {
    public var id: MarkerID
    public var name: String
    public var time: RationalTime
    public var color: RGBA

    public init(
        id: MarkerID,
        name: String,
        time: RationalTime,
        color: RGBA = RGBA(r: 0.98, g: 0.67, b: 0.16, a: 1)
    ) {
        self.id = id
        self.name = name
        self.time = time
        self.color = color
    }
}

/// The ordered media tracks, project markers, and project-timed captions.
public struct Timeline: Codable, Sendable, Equatable {
    public var videoTracks: [Track]
    public var audioTracks: [Track]
    public var markers: [Marker]
    public var captions: [CaptionSegment]

    public init(
        videoTracks: [Track] = [],
        audioTracks: [Track] = [],
        markers: [Marker] = [],
        captions: [CaptionSegment] = []
    ) {
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.markers = markers
        self.captions = captions
    }

    /// Compatibility initializer for v1 callers. Starts are derived mechanically
    /// so the resulting v2 primary tracks remain gapless.
    public init(
        video: [TimelineItem] = [],
        audio: [TimelineItem] = [],
        captions: [CaptionSegment] = []
    ) {
        videoTracks = video.isEmpty ? [] : [Self.legacyTrack(video, kind: .video)]
        audioTracks = audio.isEmpty ? [] : [Self.legacyTrack(audio, kind: .audio)]
        markers = []
        self.captions = captions
    }

    /// Compatibility view of the V1 (bottom-most) video track.
    public var video: [TimelineItem] {
        get { videoTracks.first?.items ?? [] }
        set {
            if videoTracks.isEmpty {
                guard !newValue.isEmpty else { return }
                videoTracks = [Self.legacyTrack(newValue, kind: .video)]
            } else {
                videoTracks[0].items = newValue
            }
        }
    }

    /// Compatibility view of the A1 audio track.
    public var audio: [TimelineItem] {
        get { audioTracks.first?.items ?? [] }
        set {
            if audioTracks.isEmpty {
                guard !newValue.isEmpty else { return }
                audioTracks = [Self.legacyTrack(newValue, kind: .audio)]
            } else {
                audioTracks[0].items = newValue
            }
        }
    }

    /// Restores the gapless V1/A1 invariant after legacy ripple operations.
    public mutating func normalizePrimaryTrack(_ kind: TrackKind) {
        switch kind {
        case .video:
            guard !videoTracks.isEmpty else { return }
            if videoTracks[0].items.isEmpty, videoTracks[0].id == TrackID(rawValue: "v1") {
                videoTracks.removeFirst()
                return
            }
            Self.assignRunningStarts(to: &videoTracks[0].items)
        case .audio:
            guard !audioTracks.isEmpty else { return }
            if audioTracks[0].items.isEmpty, audioTracks[0].id == TrackID(rawValue: "a1") {
                audioTracks.removeFirst()
                return
            }
            Self.assignRunningStarts(to: &audioTracks[0].items)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case videoTracks
        case audioTracks
        case markers
        case captions
        case video
        case audio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.videoTracks) || container.contains(.audioTracks) {
            videoTracks = try container.decodeIfPresent([Track].self, forKey: .videoTracks) ?? []
            audioTracks = try container.decodeIfPresent([Track].self, forKey: .audioTracks) ?? []
            markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
            captions = try container.decodeIfPresent([CaptionSegment].self, forKey: .captions) ?? []
        } else {
            let video = try container.decodeIfPresent([TimelineItem].self, forKey: .video) ?? []
            let audio = try container.decodeIfPresent([TimelineItem].self, forKey: .audio) ?? []
            videoTracks = video.isEmpty ? [] : [Self.legacyTrack(video, kind: .video)]
            audioTracks = audio.isEmpty ? [] : [Self.legacyTrack(audio, kind: .audio)]
            markers = []
            captions = try container.decodeIfPresent([CaptionSegment].self, forKey: .captions) ?? []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(videoTracks, forKey: .videoTracks)
        try container.encode(audioTracks, forKey: .audioTracks)
        try container.encode(markers, forKey: .markers)
        try container.encode(captions, forKey: .captions)
    }

    private static func legacyTrack(_ source: [TimelineItem], kind: TrackKind) -> Track {
        var items = source
        assignRunningStarts(to: &items)
        return Track(
            id: TrackID(rawValue: kind == .video ? "v1" : "a1"),
            name: kind == .video ? "V1" : "A1",
            items: items
        )
    }

    private static func assignRunningStarts(to items: inout [TimelineItem]) {
        var cursor = RationalTime.zero
        for index in items.indices {
            items[index].timelineStart = cursor
            cursor = cursor + items[index].timelineDuration
        }
    }
}
