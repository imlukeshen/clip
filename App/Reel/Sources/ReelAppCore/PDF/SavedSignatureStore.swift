import Foundation

/// The signatures a user has adopted, kept across documents and launches.
///
/// Held in preferences rather than the library: a signature belongs to the
/// person, not to any one PDF, and should be available the moment another
/// document needs signing.
@MainActor
public struct SavedSignatureStore {
    private let defaults: UserDefaults
    private let key = "clip.pdf.savedSignatures"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [SavedSignature] {
        guard let data = defaults.data(forKey: key),
            let stored = try? JSONDecoder().decode([SavedSignature].self, from: data)
        else { return [] }
        return stored
    }

    public func save(_ signatures: [SavedSignature]) {
        guard let data = try? JSONEncoder().encode(signatures) else { return }
        defaults.set(data, forKey: key)
    }
}
