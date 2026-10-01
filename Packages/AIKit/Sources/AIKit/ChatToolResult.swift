import Foundation

/// The outcome of one tool call, as it is reported back to the model.
public struct ChatToolResult: Codable, Sendable, Equatable {
    /// The ID of the call this answers.
    public var callID: String
    /// The tool that ran. Some providers match results by name rather than ID.
    public var name: String
    public var content: String

    public init(callID: String, name: String, content: String) {
        self.callID = callID
        self.name = name
        self.content = content
    }
}
