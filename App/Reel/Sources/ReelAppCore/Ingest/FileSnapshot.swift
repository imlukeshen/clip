import Foundation

/// The file attributes used to detect completion of a progressive write.
public struct FileSnapshot: Sendable, Equatable {
    public var byteSize: Int64
    public var modifiedAt: Date

    public init(byteSize: Int64, modifiedAt: Date) {
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
    }
}
