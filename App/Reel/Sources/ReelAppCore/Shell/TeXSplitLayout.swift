import Foundation

/// Width calibration for the PDF preview beside the LaTeX source.
///
/// The split is stored as the preview's share of the editor surface rather
/// than a point width, so the page and the source keep their proportions when
/// the window or the inspector is resized. Mirrors ``TeXOutputLayout``: the
/// divider is draggable and remembers where it was left.
public enum TeXSplitLayout {
    /// Opens with the source a little wider than the page, so a letter page
    /// fits to width and stays readable without starving long source lines.
    public static let defaultPreviewFraction = 0.41
    public static let minimumPreviewFraction = 0.2
    public static let maximumPreviewFraction = 0.8

    /// Below this the source gutter and a useful line of TeX stop fitting.
    public static let minimumSourceWidth = 300.0
    /// Below this a rendered page is too small to read.
    public static let minimumPreviewWidth = 280.0

    /// Fixed width of the project navigator shown for multi-file projects.
    public static let projectNavigatorWidth = 160.0

    private static let storageKey = "clip.tex.previewFraction"

    public static func clamped(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultPreviewFraction }
        return min(max(fraction, minimumPreviewFraction), maximumPreviewFraction)
    }

    /// The preview width for `fraction` of `availableWidth`, keeping both panes
    /// usable. When there is no room for both minimums the source wins, since
    /// it is what the user is typing into.
    public static func previewWidth(fraction: Double, availableWidth: Double) -> Double {
        guard availableWidth.isFinite, availableWidth > 0 else { return minimumPreviewWidth }
        let requested = clamped(fraction) * availableWidth
        let maximum = availableWidth - minimumSourceWidth
        guard maximum >= minimumPreviewWidth else {
            return max(0, min(minimumPreviewWidth, maximum))
        }
        return min(max(requested, minimumPreviewWidth), maximum)
    }

    /// The fraction a dragged preview width represents.
    public static func fraction(previewWidth: Double, availableWidth: Double) -> Double {
        guard availableWidth.isFinite, availableWidth > 0 else { return defaultPreviewFraction }
        return clamped(previewWidth / availableWidth)
    }

    public static func restoredFraction(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: storageKey) != nil else { return defaultPreviewFraction }
        return clamped(defaults.double(forKey: storageKey))
    }

    public static func store(_ fraction: Double, in defaults: UserDefaults = .standard) {
        defaults.set(clamped(fraction), forKey: storageKey)
    }
}
