/// Marker for an invertible mutation accepted by an editable document.
public protocol DocumentPatch: Codable, Sendable, Equatable {}

/// The shared mutation contract for every non-destructive Clip document.
public protocol EditableDocument: Codable, Sendable, Equatable {
    associatedtype Patch: DocumentPatch

    var schemaVersion: Int { get }

    /// Applies one mutation transactionally and returns its exact inverse.
    @discardableResult
    mutating func apply(_ patch: Patch) throws -> Patch

    func validate() throws
}

extension GraphPatch: DocumentPatch {}
extension ProjectDocument: EditableDocument {}
