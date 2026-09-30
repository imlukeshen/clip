/// Where the current run stands.
public enum CodeRunState: Equatable, Sendable {
    /// Nothing has run yet in this editor.
    case idle
    /// A build or program is running.
    case running
    /// The run ended with `exitStatus` after `duration`.
    case finished(exitStatus: Int32, duration: Duration)
    /// The run could not start or was stopped; the message says why.
    case failed(String)
}
