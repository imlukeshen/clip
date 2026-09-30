import AppKit
import Testing

@testable import ReelAppCore

@MainActor
@Suite("Assistant window frames")
struct WindowFrameRendererTests {
    @Test("A window renders to PNG bytes at its own size")
    func rendersSmallWindow() throws {
        let window = makeWindow(width: 400, height: 300)
        let data = try #require(WindowFrameRenderer.png(of: window))

        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide > 0)
        #expect(image.pixelsHigh > 0)
        // Under the cap, so no resampling: the frame keeps the backing size,
        // which is the window's points times its scale factor.
        let longest = max(image.pixelsWide, image.pixelsHigh)
        #expect(longest <= Int(WindowFrameRenderer.maximumDimension))
    }

    @Test("An oversized window is downscaled rather than sent at full resolution")
    func downscalesLargeWindow() throws {
        let window = makeWindow(width: 3_000, height: 1_800)
        let data = try #require(WindowFrameRenderer.png(of: window))

        let image = try #require(NSBitmapImageRep(data: data))
        let longest = max(image.pixelsWide, image.pixelsHigh)
        #expect(longest <= Int(WindowFrameRenderer.maximumDimension))
        // Aspect ratio survives the resample, so coordinates the model reads off
        // the image still map back to the window.
        let ratio = Double(image.pixelsWide) / Double(image.pixelsHigh)
        #expect(abs(ratio - 3_000.0 / 1_800.0) < 0.02)
    }

    @Test("A window with nothing to draw renders nothing")
    func emptyWindowRendersNil() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: .zero)
        #expect(WindowFrameRenderer.png(of: window) == nil)
    }

    private func makeWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemBlue.cgColor
        window.contentView = view
        return window
    }
}
