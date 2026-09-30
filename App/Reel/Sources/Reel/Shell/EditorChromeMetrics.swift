import CoreGraphics

/// Shared geometry for the top row where an editor meets its inspector.
///
/// Keeping this value in one place prevents the horizontal divider from
/// stepping up or down at the panel boundary as workspaces evolve.
enum EditorChromeMetrics {
    /// Trimmed from 52: the row holds a switch and a few controls, and the
    /// extra height read as dead space above every editor and inspector.
    static let headerHeight: CGFloat = 44
}
