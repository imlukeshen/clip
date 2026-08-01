import Foundation

/// Loads media metadata without using deprecated synchronous AVAsset properties.
public protocol MediaProbing: Sendable {
    func probe(_ url: URL) async throws -> MediaProbeResult
}
