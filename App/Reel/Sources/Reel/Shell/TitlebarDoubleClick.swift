import AppKit
import DesignSystem
import SwiftUI

/// Gives Clip's custom title bar the double-click behaviour the system one has.
///
/// The window is `.hiddenTitleBar`, so this strip is ordinary content and the
/// gesture never reaches AppKit on its own. Controls inside the bar keep their
/// own clicks; only the space between them lands here.
struct TitlebarDoubleClick: ViewModifier {
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: run)
    }

    /// Follows "Double-click a window's title bar to" in Desktop & Dock instead
    /// of assuming zoom, so the gesture matches every other window on the Mac.
    /// `performZoom` toggles, so a second double-click restores the old frame.
    private func run() {
        guard let window else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

extension View {
    func titlebarDoubleClick() -> some View {
        modifier(TitlebarDoubleClick())
    }
}

/// Hands back the window hosting this view. It never takes a hit, so it cannot
/// shadow the SwiftUI controls drawn over it.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        // The view has no window until it is inserted, which happens after
        // this returns, so the callback has to wait for the move.
        view.onMove = onResolve
        return view
    }

    func updateNSView(_ view: PassthroughView, context: Context) {
        view.onMove = onResolve
    }

    final class PassthroughView: NSView {
        var onMove: ((NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [onMove] in onMove?(window) }
        }
    }
}
