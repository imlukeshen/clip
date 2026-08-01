import CoreModel
import Foundation

/// Indexed project information used by library lists.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public var id: ProjectID
    public var name: String
    public var packagePath: String
    public var modifiedAt: Date
    public var duration: RationalTime
    public var itemCount: Int

    public init(
        id: ProjectID,
        name: String,
        packagePath: String,
        modifiedAt: Date,
        duration: RationalTime,
        itemCount: Int
    ) {
        self.id = id
        self.name = name
        self.packagePath = packagePath
        self.modifiedAt = modifiedAt
        self.duration = duration
        self.itemCount = itemCount
    }
}
