import Foundation

/// Width calibration for the trailing inspector column.
///
/// Finder's preview pane is narrow, draggable, and remembers where it was left;
/// these bounds give Clip the same behaviour while keeping the column wide
/// enough for the editor tool panels that share it.
public enum InspectorLayout {
    /// Below this the richer editor controls start wrapping labels and losing
    /// their trailing values. Keep the pane compact, but never let a resize
    /// collapse it into an unusable strip.
    public static let minimumWidth = 240.0
    public static let maximumWidth = 420.0
    public static let defaultWidth = 248.0

    private static let storageKey = "reel.inspectorWidth"

    public static func clamped(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minimumWidth), maximumWidth)
    }

    /// The width the user last dragged to, or the default on a fresh install.
    public static func restoredWidth(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: storageKey) != nil else { return defaultWidth }
        return clamped(defaults.double(forKey: storageKey))
    }

    public static func store(_ width: Double, in defaults: UserDefaults = .standard) {
        defaults.set(clamped(width), forKey: storageKey)
    }
}
