import Foundation

/// Zoom calibration for the image canvas, kept out of the view so the feel can
/// be tuned and tested on its own.
public enum CanvasZoom {
    public static let minimum = 0.25
    public static let maximum = 4.0
    /// The zoom at which the artboard exactly fits its container.
    public static let fit = 1.0

    /// A trackpad reports raw magnification, which on a large artboard moves
    /// far more than the fingers do. Damping on the log scale keeps the pinch
    /// proportional in both directions while taking roughly half the travel out
    /// of it.
    public static let pinchDamping = 0.55

    /// Each press of the zoom controls multiplies rather than adds, so a step
    /// feels the same at 25% as it does at 400%.
    public static let step = 1.25

    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return fit }
        return min(max(value, minimum), maximum)
    }

    /// Applies a live pinch to the zoom recorded when the gesture began.
    public static func pinched(from start: Double, magnification: Double) -> Double {
        guard magnification > 0, magnification.isFinite else { return clamped(start) }
        return clamped(clamped(start) * pow(magnification, pinchDamping))
    }

    public static func zoomedIn(from value: Double) -> Double {
        clamped(clamped(value) * step)
    }

    public static func zoomedOut(from value: Double) -> Double {
        clamped(clamped(value) / step)
    }

    /// The slider travels in octaves so that 100% sits at its midpoint instead
    /// of being crowded into the first eighth of the track.
    public static var exponentRange: ClosedRange<Double> {
        log2(minimum)...log2(maximum)
    }

    public static func exponent(for value: Double) -> Double {
        log2(clamped(value))
    }

    public static func value(forExponent exponent: Double) -> Double {
        guard exponent.isFinite else { return fit }
        return clamped(pow(2, exponent))
    }
}
