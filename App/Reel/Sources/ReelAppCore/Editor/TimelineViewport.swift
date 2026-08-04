import Foundation

/// Shared timeline zoom rules. A zoom of 1 fits the complete project in the
/// available viewport; larger values expand it horizontally for frame-level
/// editing while keeping the same predictable limits across input methods.
public enum TimelineViewport {
    public static let fitZoom = 1.0
    public static let maximumZoom = 12.0

    public static func clampedZoom(_ zoom: Double) -> Double {
        min(max(zoom, fitZoom), maximumZoom)
    }

    public static func contentWidth(viewportWidth: Double, zoom: Double) -> Double {
        max(viewportWidth, viewportWidth * clampedZoom(zoom))
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
