import Foundation

/// What an in-app model install is doing, for the settings UI to render.
public enum LocalModelDownloadState: Equatable, Sendable {
    case running(model: String, progress: LocalModelDownloadProgress)
    case failed(model: String, message: String)

    public var model: String {
        switch self {
        case .running(let model, _), .failed(let model, _): return model
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
