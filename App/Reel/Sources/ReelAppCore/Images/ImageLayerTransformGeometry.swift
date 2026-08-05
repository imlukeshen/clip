import CoreGraphics
import Foundation

/// The editable geometry shared by the photo canvas and its transform overlay.
///
/// Frames use Clip's top-left, normalized canvas coordinate system. Rotation is
/// expressed clockwise in degrees, matching SwiftUI's visual coordinate space.
public struct ImageLayerTransformState: Equatable, Sendable {
    public var frame: CGRect
    public var rotationDegrees: Double

    public init(frame: CGRect, rotationDegrees: Double = 0) {
        self.frame = frame
        self.rotationDegrees = rotationDegrees
    }
}

/// The eight Photoshop-style resize anchors around a selected layer.
public enum ImageLayerResizeHandle: String, CaseIterable, Identifiable, Sendable {
    case topLeading
    case top
    case topTrailing
    case trailing
    case bottomTrailing
    case bottom
    case bottomLeading
    case leading

    public var id: String { rawValue }
}

/// Pure transform math for the photo canvas.
///
/// Keeping this independent of SwiftUI makes non-square canvases, clamping, and
/// rotated resize gestures deterministic and directly testable.
public enum ImageLayerTransformGeometry {
    public static let defaultMinimumPointSize = CGSize(width: 18, height: 18)
    public static let defaultRotationHandleOffset = 28.0

    /// Converts a normalized top-left frame into display points.
    public static func displayRect(for frame: CGRect, canvasSize: CGSize) -> CGRect {
        guard isUsable(canvasSize) else { return .zero }
        let frame = sanitized(frame)
        return CGRect(
            x: frame.minX * canvasSize.width,
            y: frame.minY * canvasSize.height,
            width: frame.width * canvasSize.width,
            height: frame.height * canvasSize.height
        )
    }

    /// Moves a frame by a display-point translation and keeps it on the canvas.
    public static func moved(
        _ state: ImageLayerTransformState,
        by translation: CGSize,
        canvasSize: CGSize
    ) -> ImageLayerTransformState {
        guard isUsable(canvasSize), isFinite(translation) else { return normalized(state) }
        let frame = sanitized(state.frame)
        let candidate = CGRect(
            x: frame.minX + translation.width / canvasSize.width,
            y: frame.minY + translation.height / canvasSize.height,
            width: frame.width,
            height: frame.height
        )
        return ImageLayerTransformState(
            frame: clamped(candidate),
            rotationDegrees: normalizedDegrees(state.rotationDegrees)
        )
    }

    /// Resizes a layer along its rotated local axes.
    ///
    /// `translation` is supplied in canvas display points. The opposite edge or
    /// corner remains anchored until the result reaches a canvas boundary.
    public static func resized(
        _ state: ImageLayerTransformState,
        from handle: ImageLayerResizeHandle,
        by translation: CGSize,
        canvasSize: CGSize,
        minimumPointSize: CGSize = defaultMinimumPointSize,
        preservingAspectRatio: Bool = false
    ) -> ImageLayerTransformState {
        guard isUsable(canvasSize), isFinite(translation) else { return normalized(state) }

        let initialRect = displayRect(for: state.frame, canvasSize: canvasSize)
        guard initialRect.width > 0, initialRect.height > 0 else { return normalized(state) }

        let signs = resizeSigns(for: handle)
        let localDelta = rotated(
            CGPoint(x: translation.width, y: translation.height),
            degrees: -state.rotationDegrees
        )
        let minimum = CGSize(
            width: min(max(finiteOrZero(minimumPointSize.width), 1), canvasSize.width),
            height: min(max(finiteOrZero(minimumPointSize.height), 1), canvasSize.height)
        )

        var width = initialRect.width
        var height = initialRect.height
        if signs.x != 0 {
            width = max(minimum.width, initialRect.width + signs.x * localDelta.x)
        }
        if signs.y != 0 {
            height = max(minimum.height, initialRect.height + signs.y * localDelta.y)
        }

        if preservingAspectRatio, signs.x != 0, signs.y != 0 {
            let widthScale = width / initialRect.width
            let heightScale = height / initialRect.height
            let scale =
                abs(widthScale - 1) >= abs(heightScale - 1) ? widthScale : heightScale
            let minimumScale = max(
                minimum.width / initialRect.width,
                minimum.height / initialRect.height
            )
            let resolvedScale = max(scale, minimumScale)
            width = initialRect.width * resolvedScale
            height = initialRect.height * resolvedScale
        }

        let effectiveLocalDelta = CGPoint(
            x: signs.x == 0 ? 0 : (width - initialRect.width) / signs.x,
            y: signs.y == 0 ? 0 : (height - initialRect.height) / signs.y
        )
        let localCenterShift = CGPoint(
            x: signs.x == 0 ? 0 : effectiveLocalDelta.x / 2,
            y: signs.y == 0 ? 0 : effectiveLocalDelta.y / 2
        )
        let canvasCenterShift = rotated(
            localCenterShift,
            degrees: state.rotationDegrees
        )
        let center = CGPoint(
            x: initialRect.midX + canvasCenterShift.x,
            y: initialRect.midY + canvasCenterShift.y
        )
        let candidate = CGRect(
            x: (center.x - width / 2) / canvasSize.width,
            y: (center.y - height / 2) / canvasSize.height,
            width: width / canvasSize.width,
            height: height / canvasSize.height
        )

        return ImageLayerTransformState(
            frame: clamped(candidate),
            rotationDegrees: normalizedDegrees(state.rotationDegrees)
        )
    }

    /// Rotates from an initial pointer position to the current pointer position.
    public static func rotated(
        _ state: ImageLayerTransformState,
        from startLocation: CGPoint,
        to location: CGPoint,
        canvasSize: CGSize
    ) -> ImageLayerTransformState {
        guard isUsable(canvasSize), isFinite(startLocation), isFinite(location) else {
            return normalized(state)
        }
        let center = displayRect(for: state.frame, canvasSize: canvasSize).center
        let startVector = CGPoint(x: startLocation.x - center.x, y: startLocation.y - center.y)
        let currentVector = CGPoint(x: location.x - center.x, y: location.y - center.y)
        guard hypot(startVector.x, startVector.y) > 0.5,
            hypot(currentVector.x, currentVector.y) > 0.5
        else { return normalized(state) }

        let startAngle = atan2(startVector.y, startVector.x)
        let currentAngle = atan2(currentVector.y, currentVector.x)
        let delta = (currentAngle - startAngle) * 180 / .pi
        return ImageLayerTransformState(
            frame: clamped(state.frame),
            rotationDegrees: normalizedDegrees(state.rotationDegrees + delta)
        )
    }

    /// Display-point location for one resize handle, including layer rotation.
    public static func position(
        of handle: ImageLayerResizeHandle,
        in state: ImageLayerTransformState,
        canvasSize: CGSize
    ) -> CGPoint {
        let rect = displayRect(for: state.frame, canvasSize: canvasSize)
        let point: CGPoint
        switch handle {
        case .topLeading: point = CGPoint(x: rect.minX, y: rect.minY)
        case .top: point = CGPoint(x: rect.midX, y: rect.minY)
        case .topTrailing: point = CGPoint(x: rect.maxX, y: rect.minY)
        case .trailing: point = CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomTrailing: point = CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: point = CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeading: point = CGPoint(x: rect.minX, y: rect.maxY)
        case .leading: point = CGPoint(x: rect.minX, y: rect.midY)
        }
        return rotated(point, around: rect.center, degrees: state.rotationDegrees)
    }

    /// Display-point location for the rotation handle above the selected layer.
    public static func rotationHandlePosition(
        in state: ImageLayerTransformState,
        canvasSize: CGSize,
        offset: Double = defaultRotationHandleOffset
    ) -> CGPoint {
        let rect = displayRect(for: state.frame, canvasSize: canvasSize)
        let point = CGPoint(x: rect.midX, y: rect.minY - max(finiteOrZero(offset), 0))
        return rotated(point, around: rect.center, degrees: state.rotationDegrees)
    }

    public static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var result = degrees.truncatingRemainder(dividingBy: 360)
        if result <= -180 { result += 360 }
        if result > 180 { result -= 360 }
        return result
    }

    private static func normalized(_ state: ImageLayerTransformState) -> ImageLayerTransformState {
        ImageLayerTransformState(
            frame: clamped(state.frame),
            rotationDegrees: normalizedDegrees(state.rotationDegrees)
        )
    }

    private static func sanitized(_ frame: CGRect) -> CGRect {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
            frame.size.width.isFinite, frame.size.height.isFinite
        else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return frame.standardized
    }

    private static func clamped(_ rawFrame: CGRect) -> CGRect {
        let frame = sanitized(rawFrame)
        let width = min(max(frame.width, 0.000_001), 1)
        let height = min(max(frame.height, 0.000_001), 1)
        return CGRect(
            x: min(max(frame.minX, 0), 1 - width),
            y: min(max(frame.minY, 0), 1 - height),
            width: width,
            height: height
        )
    }

    private static func resizeSigns(for handle: ImageLayerResizeHandle) -> CGPoint {
        switch handle {
        case .topLeading: CGPoint(x: -1, y: -1)
        case .top: CGPoint(x: 0, y: -1)
        case .topTrailing: CGPoint(x: 1, y: -1)
        case .trailing: CGPoint(x: 1, y: 0)
        case .bottomTrailing: CGPoint(x: 1, y: 1)
        case .bottom: CGPoint(x: 0, y: 1)
        case .bottomLeading: CGPoint(x: -1, y: 1)
        case .leading: CGPoint(x: -1, y: 0)
        }
    }

    private static func rotated(_ point: CGPoint, around center: CGPoint, degrees: Double)
        -> CGPoint
    {
        let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let value = rotated(translated, degrees: degrees)
        return CGPoint(x: value.x + center.x, y: value.y + center.y)
    }

    private static func rotated(_ point: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return CGPoint(
            x: point.x * cosine - point.y * sine,
            y: point.x * sine + point.y * cosine
        )
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func isFinite(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

extension CGRect {
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}
