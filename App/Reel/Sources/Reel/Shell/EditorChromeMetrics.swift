import CoreGraphics

/// Shared geometry for the top row where an editor meets its inspector.
///
/// Keeping this value in one place prevents the horizontal divider from
/// stepping up or down at the panel boundary as workspaces evolve.
enum EditorChromeMetrics {
    static let headerHeight: CGFloat = 52
}
