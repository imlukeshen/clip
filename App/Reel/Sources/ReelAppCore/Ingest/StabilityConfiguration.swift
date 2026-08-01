import Foundation

/// Polling parameters for files that may still be growing.
public struct StabilityConfiguration: Sendable {
    public var pollInterval: Duration
    public var requiredMatchingPolls: Int
    public var timeout: Duration

    public init(
        pollInterval: Duration = .milliseconds(250),
        requiredMatchingPolls: Int = 3,
        timeout: Duration = .seconds(600)
    ) {
        self.pollInterval = pollInterval
        self.requiredMatchingPolls = requiredMatchingPolls
        self.timeout = timeout
    }
}
