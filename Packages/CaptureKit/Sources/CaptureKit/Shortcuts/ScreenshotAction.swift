import Foundation

/// Screenshot commands stored in the system symbolic-hot-key preference domain.
public enum ScreenshotAction: Int, Sendable, CaseIterable, Hashable {
    case fullScreenToFile = 28
    case fullScreenToClipboard = 29
    case areaToFile = 30
    case areaToClipboard = 31
    case capturePanel = 184
}
