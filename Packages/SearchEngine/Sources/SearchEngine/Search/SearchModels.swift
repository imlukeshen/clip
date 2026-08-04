import CoreModel
import Foundation
import LibraryStore

public enum SearchMode: String, Sendable, Equatable {
    case auto
    case keyword
    case semantic
}

public struct SearchFilters: Sendable, Equatable {
    public var kind: AssetKind?
    public var after: Date?
    public var before: Date?
    public var folder: String?
    public var minimumDuration: RationalTime?
    public var maximumDuration: RationalTime?
    public var hasAudio: Bool?

    public init(
        kind: AssetKind? = nil,
        after: Date? = nil,
        before: Date? = nil,
        folder: String? = nil,
        minimumDuration: RationalTime? = nil,
        maximumDuration: RationalTime? = nil,
        hasAudio: Bool? = nil
    ) {
        self.kind = kind
        self.after = after
        self.before = before
        self.folder = folder
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        self.hasAudio = hasAudio
    }
}

public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var filters: SearchFilters
    public var mode: SearchMode
    public var limit: Int

    public init(
        text: String,
        filters: SearchFilters = SearchFilters(),
        mode: SearchMode = .auto,
        limit: Int = 50
    ) {
        self.text = text
        self.filters = filters
        self.mode = mode
        self.limit = limit
    }
}

public struct SearchMoment: Sendable, Equatable, Identifiable {
    public var assetID: AssetID
    public var start: RationalTime
    public var end: RationalTime?
    public var snippet: AttributedString
    public var source: SearchHitSource

    public var id: String {
        "\(assetID.rawValue):\(source.rawValue):\(start.value)"
    }

    public init(
        assetID: AssetID,
        start: RationalTime,
        end: RationalTime?,
        snippet: AttributedString,
        source: SearchHitSource
    ) {
        self.assetID = assetID
        self.start = start
        self.end = end
        self.snippet = snippet
        self.source = source
    }
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var assetID: AssetID
    public var score: Double
    public var moments: [SearchMoment]
    public var snippet: AttributedString
    public var sources: Set<SearchHitSource>
    public var isUnavailable: Bool

    public var id: AssetID { assetID }

    public init(
        assetID: AssetID,
        score: Double,
        moments: [SearchMoment],
        snippet: AttributedString,
        sources: Set<SearchHitSource>,
        isUnavailable: Bool
    ) {
        self.assetID = assetID
        self.score = score
        self.moments = moments
        self.snippet = snippet
        self.sources = sources
        self.isUnavailable = isUnavailable
    }
}

public struct SearchResponse: Sendable, Equatable {
    public var hits: [SearchHit]
    public var isComplete: Bool

    public init(hits: [SearchHit], isComplete: Bool) {
        self.hits = hits
        self.isComplete = isComplete
    }
}

public struct ParsedSearchQuery: Sendable, Equatable {
    public var terms: [String]
    public var phrases: [String]
    public var filters: SearchFilters
    public var mode: SearchMode

    public var isEmpty: Bool { terms.isEmpty && phrases.isEmpty }

    public init(
        terms: [String],
        phrases: [String],
        filters: SearchFilters,
        mode: SearchMode
    ) {
        self.terms = terms
        self.phrases = phrases
        self.filters = filters
        self.mode = mode
    }
}

public enum SearchError: Error, Sendable, Equatable, LocalizedError {
    case queryTooLong
    case invalidFilter(String)

    public var errorDescription: String? {
        switch self {
        case .queryTooLong: "Search queries are limited to 512 characters."
        case .invalidFilter(let filter): "The search filter “\(filter)” is invalid."
        }
    }
}
