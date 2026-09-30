/// Which of a program's output streams some text came from.
public enum CodeOutputStream: Sendable, Hashable {
    /// Standard output: what `print` writes.
    case standardOutput
    /// Standard error: warnings, compiler errors, and tracebacks.
    case standardError
}
