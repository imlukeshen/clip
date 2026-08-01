import CoreModel
import Foundation
import LibraryStore

/// Asynchronously loaded media metadata needed by ingest and composition.
public struct MediaProbeResult: Sendable, Equatable {
    public var kind: AssetKind
    public var container: String?
    public var codec: String?
    public var width: Int?
    public var height: Int?
    public var duration: RationalTime?
    public var nominalFPS: Double?
    public var isVariableFPS: Bool
    public var hasAudio: Bool
    public var preferredTransform: JSONValue?

    public init(
        kind: AssetKind,
        container: String?,
        codec: String?,
        width: Int?,
        height: Int?,
        duration: RationalTime?,
        nominalFPS: Double?,
        isVariableFPS: Bool,
        hasAudio: Bool,
        preferredTransform: JSONValue?
    ) {
        self.kind = kind
        self.container = container
        self.codec = codec
        self.width = width
        self.height = height
        self.duration = duration
        self.nominalFPS = nominalFPS
        self.isVariableFPS = isVariableFPS
        self.hasAudio = hasAudio
        self.preferredTransform = preferredTransform
    }
}
