import Foundation

/// One character edit expressed in the editor's UTF-16 coordinate space.
public struct SyntaxEdit: Sendable, Equatable {
    /// The replaced range in the previous buffer.
    public var previousRange: NSRange
    /// The replacement range in the current buffer.
    public var currentRange: NSRange

    /// Creates an incremental syntax edit.
    public init(previousRange: NSRange, currentRange: NSRange) {
        self.previousRange = previousRange
        self.currentRange = currentRange
    }
}
