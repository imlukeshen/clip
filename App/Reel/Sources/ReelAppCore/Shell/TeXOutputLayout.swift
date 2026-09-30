import Foundation

/// Height calibration for the LaTeX output panel below the editor.
///
/// Mirrors ``InspectorLayout``: the panel is draggable and remembers where it
/// was left, while never growing so tall that the source it reports on stops
/// being usable.
public enum TeXOutputLayout {
    /// Below this the tab strip and a single diagnostic stop fitting together.
    public static let minimumHeight = 120.0
    public static let maximumHeight = 520.0
    public static let defaultHeight = 210.0

    /// Editor height defended when the window is short. The source outranks its
    /// build log, so the panel yields first.
    public static let minimumEditorHeight = 220.0

    private static let storageKey = "clip.tex.outputHeight"

    public static func clamped(_ height: Double) -> Double {
        guard height.isFinite else { return defaultHeight }
        return min(max(height, minimumHeight), maximumHeight)
    }

    /// The height that fits without squeezing the editor, leaving the persisted
    /// request untouched so the panel returns to its preferred size.
    public static func displayedHeight(
        requestedHeight: Double,
        availableWindowHeight: Double
    ) -> Double {
        guard availableWindowHeight.isFinite else { return clamped(requestedHeight) }
        let availableForPanel = max(
            minimumHeight,
            availableWindowHeight - minimumEditorHeight
        )
        return min(clamped(requestedHeight), availableForPanel)
    }

    public static func restoredHeight(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: storageKey) != nil else { return defaultHeight }
        return clamped(defaults.double(forKey: storageKey))
    }

    public static func store(_ height: Double, in defaults: UserDefaults = .standard) {
        defaults.set(clamped(height), forKey: storageKey)
    }
}
