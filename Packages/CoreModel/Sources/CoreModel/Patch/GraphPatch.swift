import Foundation

/// An atomic, labelled sequence of edit-graph operations.
public struct GraphPatch: Codable, Sendable, Equatable {
    public var ops: [GraphOp]
    public var label: String
    public var origin: Origin

    public init(ops: [GraphOp], label: String, origin: Origin) {
        self.ops = ops
        self.label = label
        self.origin = origin
    }
}
