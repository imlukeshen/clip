import AppKit
import Foundation
import OSLog

/// Renders one of clipx's own windows to PNG bytes for the assistant to look at.
///
/// This is deliberately not screen capture. Drawing a view hierarchy the process
/// already owns needs no Screen Recording permission, works under the App
/// Sandbox, and cannot see anything outside clipx — not the desktop, not another
/// app's window, not a password field in a browser behind ours. That containment
/// is the whole reason Stage 1 of ADR-0014 exists, so the renderer takes a
/// window rather than a screen rectangle and there is no code path that widens.
@MainActor
public enum WindowFrameRenderer {
    private static let log = Logger(subsystem: "app.reel.editor", category: "assistant")

    /// The longest edge of a rendered frame, in pixels.
    ///
    /// Vision models downscale their input anyway, and a Retina window is around
    /// 2880 points wide — sending that is several megabytes of base64 for detail
    /// no model reads. This is large enough that UI text stays legible.
    public static let maximumDimension: CGFloat = 1_536

    /// Renders `window`'s content, or nil when it has nothing to draw.
    public static func png(of window: NSWindow) -> Data? {
        guard let view = window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        guard let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            log.error("Could not allocate a bitmap for the assistant frame")
            return nil
        }
        view.cacheDisplay(in: bounds, to: representation)
        return downscaledPNG(from: representation, bounds: bounds)
    }

    /// Renders the app's key window, falling back to its frontmost one.
    ///
    /// Panels and sheets are skipped: the assistant should see the document the
    /// person is working in, and a transient panel on top of it is rarely what
    /// the question is about.
    public static func pngOfActiveWindow(in application: NSApplication? = nil) -> Data? {
        let application = application ?? NSApplication.shared
        let candidates = application.windows.filter { $0.isVisible && $0.canBecomeMain }
        guard let window = application.keyWindow ?? candidates.first else { return nil }
        return png(of: window)
    }

    private static func downscaledPNG(
        from representation: NSBitmapImageRep,
        bounds: CGRect
    ) -> Data? {
        let longestEdge = max(
            CGFloat(representation.pixelsWide), CGFloat(representation.pixelsHigh))
        guard longestEdge > maximumDimension else {
            return representation.representation(using: .png, properties: [:])
        }
        let scale = maximumDimension / longestEdge
        let size = NSSize(
            width: (CGFloat(representation.pixelsWide) * scale).rounded(),
            height: (CGFloat(representation.pixelsHigh) * scale).rounded()
        )
        guard
            let scaled = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return representation.representation(using: .png, properties: [:]) }

        scaled.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: scaled) else {
            return representation.representation(using: .png, properties: [:])
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        representation.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        return scaled.representation(using: .png, properties: [:])
    }
}
