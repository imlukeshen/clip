import CoreModel
import Foundation

/// Runs an editor buffer and streams what it prints.
///
/// Only the direct-download build supplies a runner: the App Store sandbox
/// cannot launch toolchains installed outside the app. See ADR 0015.
public protocol CodeRunning: Sendable {
    /// Whether an installed toolchain can run `language`.
    func canRun(_ language: LanguageID) -> Bool

    /// Starts `request`, delivering output as the program writes it and ending
    /// with ``CodeRunEvent/finished(exitStatus:duration:)``.
    ///
    /// The stream throws ``TextEngineError`` when no toolchain is installed, a
    /// tool cannot start, the run times out, or it floods its output.
    /// Cancelling iteration stops the program.
    func run(_ request: CodeRunRequest) -> AsyncThrowingStream<CodeRunEvent, any Error>
}
