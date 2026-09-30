import AppKit
import DesignSystem
import SwiftUI

/// Gives clipx's custom bars the double-click behaviour of the system title
/// bar.
///
/// The window is `.hiddenTitleBar`, so these bars are ordinary content. Below
/// the native title-bar strip, SwiftUI's hosting view keeps mouse-downs for its
/// own gesture system: neither a double-tap gesture nor a background view's
/// `mouseDown` ever fired there. So a view behind the bar watches the window's
/// mouse-downs instead, and acts only when the window's own hit test lands on
/// it, which means no control is drawn over that point.
struct TitlebarDoubleClick: ViewModifier {
    func body(content: Content) -> some View {
        content.background(TitlebarMouseArea())
    }
}

extension View {
    func titlebarDoubleClick() -> some View {
        modifier(TitlebarDoubleClick())
    }
}

private struct TitlebarMouseArea: NSViewRepresentable {
    func makeNSView(context: Context) -> MouseView { MouseView() }

    func updateNSView(_ view: MouseView, context: Context) {}

    static func dismantleNSView(_ view: MouseView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MouseView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                guard let self, let window = self.window, self.isUncovered(at: event) else {
                    return event
                }
                // Take the click before the window server's own drag loop does:
                // that loop swallows the second click, so a double-click on
                // the bar never arrives otherwise.
                if event.clickCount >= 2 {
                    Self.performDoubleClickAction(in: window)
                } else {
                    window.performDrag(with: event)
                }
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Whether `event` lands on this view with nothing drawn over it.
        private func isUncovered(at event: NSEvent) -> Bool {
            guard let window, event.window === window, let contentView = window.contentView,
                !isHiddenOrHasHiddenAncestor
            else { return false }
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return false }
            let point =
                contentView.superview?.convert(event.locationInWindow, from: nil)
                ?? event.locationInWindow
            return contentView.hitTest(point) === self
        }

        /// Follows "Double-click a window's title bar to" in Desktop & Dock
        /// instead of assuming zoom, so the gesture matches every other window
        /// on the Mac. `performZoom` toggles, so a second double-click restores
        /// the old frame.
        private static func performDoubleClickAction(in window: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }
}
