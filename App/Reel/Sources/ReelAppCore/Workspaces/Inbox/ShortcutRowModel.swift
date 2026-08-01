import CaptureKit
import Foundation

public struct ShortcutItem: Sendable, Equatable, Identifiable {
    public let action: ScreenshotAction
    public let display: String?

    public var id: ScreenshotAction { action }

    public var title: String {
        switch action {
        case .fullScreenToFile: "Full screen to file"
        case .fullScreenToClipboard: "Full screen to clipboard"
        case .areaToFile: "Area to file"
        case .areaToClipboard: "Area to clipboard"
        case .capturePanel: "Capture panel"
        }
    }
}

/// A lossless presentation projection of `ShortcutReadResult`.
public struct ShortcutRowModel: Sendable, Equatable {
    public let items: [ShortcutItem]
    public let guidance: String?
    public let settingsURL: URL?

    public init(result: ShortcutReadResult) {
        switch result {
        case .available(let shortcuts):
            self.items = ScreenshotAction.allCases.compactMap { action in
                guard shortcuts.keys.contains(action) else { return nil }
                let combination = shortcuts[action] ?? nil
                return ShortcutItem(action: action, display: combination?.display)
            }
            self.guidance = nil
            self.settingsURL = nil
        case .unavailable:
            self.items = []
            self.guidance =
                "Screenshot shortcuts are managed in System Settings under Keyboard Shortcuts."
            self.settingsURL = URL(
                string:
                    "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts"
            )
        }
    }
}
