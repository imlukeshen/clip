import Foundation

/// The user-visible reason for an outbound request.
public enum EgressPurpose: String, Codable, Sendable, Equatable {
    case chat, transcribe, vision, caption, texPackage
}

/// Non-sensitive metadata recorded before a provider request leaves the device.
public struct EgressEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var provider: ProviderID
    public var model: String
    public var purpose: EgressPurpose
    public var mediaAttached: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        provider: ProviderID,
        model: String,
        purpose: EgressPurpose,
        mediaAttached: Bool
    ) {
        self.id = id
        self.date = date
        self.provider = provider
        self.model = model
        self.purpose = purpose
        self.mediaAttached = mediaAttached
    }
}

/// Aggregate request counts containing no prompt or credential data.
public struct EgressSummary: Codable, Sendable, Equatable {
    public var requestCount: Int
    public var mediaRequestCount: Int
    public var byProvider: [ProviderID: Int]

    public init(requestCount: Int, mediaRequestCount: Int, byProvider: [ProviderID: Int]) {
        self.requestCount = requestCount
        self.mediaRequestCount = mediaRequestCount
        self.byProvider = byProvider
    }
}

/// A durable, inspectable log of outbound request metadata.
public actor EgressLedger {
    private let storageURL: URL?
    private var values: [EgressEntry]

    public init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL, let data = try? Data(contentsOf: storageURL),
            let decoded = try? JSONDecoder().decode([EgressEntry].self, from: data)
        {
            self.values = decoded
        } else {
            self.values = []
        }
    }

    public func record(_ entry: EgressEntry) async {
        values.append(entry)
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(values)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Ledger persistence is best effort; the in-memory entry remains inspectable.
        }
    }

    public func entries(since date: Date = .distantPast, limit: Int = 500) async -> [EgressEntry] {
        Array(values.filter { $0.date >= date }.suffix(max(0, limit)).reversed())
    }

    public func summary(since date: Date = .distantPast) async -> EgressSummary {
        let selected = values.filter { $0.date >= date }
        return EgressSummary(
            requestCount: selected.count,
            mediaRequestCount: selected.count(where: \.mediaAttached),
            byProvider: Dictionary(grouping: selected, by: \.provider).mapValues(\.count)
        )
    }
}
