import Foundation

/// The complete result of one editor command, including where selection should land.
public struct TextEditResult: Sendable, Equatable {
    /// The transformed buffer contents.
    public var text: String
    /// The UTF-16 selection to apply after replacing the buffer.
    public var selectedRange: NSRange

    /// Creates a transformed buffer result and its resulting selection.
    public init(text: String, selectedRange: NSRange) {
        self.text = text
        self.selectedRange = selectedRange
    }
}
