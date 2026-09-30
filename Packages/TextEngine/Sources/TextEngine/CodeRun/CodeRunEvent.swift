/// Something a running program did, delivered as it happens.
public enum CodeRunEvent: Sendable, Equatable {
    /// A step started, shown as the command a user would type in Terminal.
    case started(commandLine: String)
    /// The program wrote `text` to `stream`.
    case output(String, CodeOutputStream)
    /// The run ended with `exitStatus` after `duration`. Always last. A failed
    /// build step ends the run with the compiler's status.
    case finished(exitStatus: Int32, duration: Duration)
}
