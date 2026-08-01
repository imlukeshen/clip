import Foundation

/// A string identifier whose phantom tag prevents cross-domain ID mistakes.
public struct TypedID<Tag>: RawRepresentable, Codable, Sendable, Hashable {
    /// The lowercase identifier value.
    public let rawValue: String

    /// Creates an identifier and canonicalizes its casing.
    public init(rawValue: String) {
        self.rawValue = rawValue.lowercased()
    }

    /// Generates a lowercase UUID identifier.
    public static func generate() -> Self {
        Self(rawValue: UUID().uuidString)
    }

    /// Decodes an identifier from its single string value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    /// Encodes an identifier as a single string value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The phantom tag for an asset identifier.
public enum AssetTag: Sendable {}

/// Identifies an immutable imported asset.
public typealias AssetID = TypedID<AssetTag>

/// The phantom tag for a timeline item identifier.
public enum ItemTag: Sendable {}

/// Identifies a timeline item.
public typealias ItemID = TypedID<ItemTag>

/// The phantom tag for an effect identifier.
public enum EffectTag: Sendable {}

/// Identifies an effect attached to a timeline item.
public typealias EffectID = TypedID<EffectTag>

/// The phantom tag for a project identifier.
public enum ProjectTag: Sendable {}

/// Identifies a project document.
public typealias ProjectID = TypedID<ProjectTag>
