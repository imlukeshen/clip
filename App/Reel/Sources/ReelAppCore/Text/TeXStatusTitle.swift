import Foundation

/// What the LaTeX status surface says.
///
/// Two things compete to describe the same editor: the outcome of the last
/// build, and whether the source has moved on since the build that produced
/// the PDF on screen. A failed build keeps the previous PDF visible, so
/// reporting only that the changes are unbuilt would describe the source
/// while saying nothing about the build that just failed.
public enum TeXStatusTitle {
    public static func title(state: TeXCompilationState, hasUnbuiltChanges: Bool) -> String {
        switch state {
        case .compiling, .failed, .paused:
            // These describe a build the editor has just run or is running.
            // They outrank the source having moved on.
            return state.statusTitle
        case .idle, .succeeded:
            return hasUnbuiltChanges ? "Changes not built" : state.statusTitle
        }
    }
}

extension TeXCompilationState {
    /// The bare name of this state, with nothing else taken into account.
    public var statusTitle: String {
        switch self {
        case .idle: "Not built"
        case .compiling: "Building"
        case .succeeded: "PDF ready"
        case .paused: "Build paused"
        case .failed: "Build failed"
        }
    }
}
