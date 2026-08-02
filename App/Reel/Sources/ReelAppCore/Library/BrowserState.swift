import Foundation

public enum BrowserViewMode: String, Sendable, CaseIterable {
    case grid, list
}

public enum AssetSort: String, Sendable, CaseIterable {
    case name, kind, duration, size, modified
}
