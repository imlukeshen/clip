import AppKit
import DesignSystem
import ReelAppCore
import SwiftUI

/// Shows the capture history in a floating panel that appears over whatever app
/// is frontmost.
///
/// The panel is **nonactivating**: it never steals focus, so after the user
/// picks an entry it lands on the pasteboard and their next paste still targets
/// the app they were in. That is the whole point of reaching it through a global
/// shortcut rather than the in-window sheet, which can only appear when Clip is
/// already frontmost.
@MainActor
final class ClipboardPanelController {
    private let model: AppModel
    private var panel: NSPanel?
    private var clickMonitor: Any?

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the panel if it is hidden, hides it if it is already showing. This
    /// is what both the global hotkey and the in-window menu item call.
    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    /// Orders the panel out and stops watching for the click that dismisses it.
    func hide() {
        panel?.orderOut(nil)
        stopMonitoringOutsideClicks()
    }

    private func show() {
        Task { await model.refreshCaptureHistory() }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: content)
        position(panel)
        // Order front without activating Clip, so the app the user copied from
        // keeps focus and their paste goes there.
        panel.orderFrontRegardless()
        startMonitoringOutsideClicks()
    }

    private var content: some View {
        let theme = model.appearance.theme(matching: resolvedColorScheme)
        return CaptureHistoryView(model: model, onClose: { [weak self] in self?.hide() })
            .environment(\.theme, theme)
            .tint(theme.palette.accent)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        return panel
    }

    /// Centres the panel on the screen the pointer is on, biased toward the top
    /// the way system pickers sit.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * 0.12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func startMonitoringOutsideClicks() {
        guard clickMonitor == nil else { return }
        // A nonactivating panel never becomes key, so a click in another app is
        // not a local event; a global monitor is what notices the user clicking
        // away and dismisses the panel the way a menu would.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func stopMonitoringOutsideClicks() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    private var resolvedColorScheme: ColorScheme {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)
        let match = appearance?.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }
}
