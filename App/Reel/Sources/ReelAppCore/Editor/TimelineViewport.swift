import Foundation

/// Shared timeline zoom rules. A zoom of 1 fits the complete project in the
/// available viewport; larger values expand it horizontally for frame-level
/// editing while keeping the same predictable limits across input methods.
public enum TimelineViewport {
    public static let fitZoom = 1.0
    public static let maximumZoom = 12.0
    public static let minimumEditingTail = 10.0
    public static let editingTailRatio = 0.25

    public static func clampedZoom(_ zoom: Double) -> Double {
        min(max(zoom, fitZoom), maximumZoom)
    }

    public static func contentWidth(viewportWidth: Double, zoom: Double) -> Double {
        max(viewportWidth, viewportWidth * clampedZoom(zoom))
    }

    /// Extends the ruler beyond the final item so a clip can be dropped into
    /// future project time. The proportional tail remains visibly useful on a
    /// long project while the minimum keeps short projects practical.
    public static func editingDuration(projectDuration: Double) -> Double {
        let duration = projectDuration.isFinite ? max(projectDuration, 0) : 0
        return duration + max(minimumEditingTail, duration * editingTailRatio)
    }

    public static func zooming(_ zoom: Double, by factor: Double) -> Double {
        guard factor.isFinite, factor > 0 else { return clampedZoom(zoom) }
        return clampedZoom(zoom * factor)
    }

    public static func stepping(_ zoom: Double, direction: Int) -> Double {
        let step = zoom < 2 ? 0.25 : zoom < 5 ? 0.5 : 1
        return clampedZoom(zoom + Double(direction) * step)
    }
}
