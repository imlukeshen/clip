import CoreModel
import Foundation

/// Generates rebuildable thumbnails and audio envelopes.
public protocol DerivativeGenerating: Sendable {
    func generate(
        for assetURL: URL,
        assetID: AssetID,
        destinationFolder: URL,
        probe: MediaProbeResult
    ) async throws -> DerivativePaths
}
