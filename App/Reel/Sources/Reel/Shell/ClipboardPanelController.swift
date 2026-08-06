import AppKit
import CaptureKit
@preconcurrency import Carbon.HIToolbox
import CoreGraphics
import DesignSystem
import ReelAppCore
import SwiftUI

/// Shows the capture history in a floating panel that appears over whatever app
/// is frontmost.
///
/// The panel is **nonactivating**: it never steals focus. It remembers the app
/// that was active when it opened, then sends Paste back there after the chosen
/// entry has been restored to the system pasteboard.
@MainActor
final class ClipboardPanelController {
    private let model: AppModel
    private let escapeHotKey = GlobalHotKey(
        keyCode: UInt32(kVK_Escape),
        modifiers: 0
    )
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var pasteTarget: NSRunningApplication?
    private weak var clipPasteResponder: NSResponder?

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
        escapeHotKey.unregister()
        stopMonitoringOutsideClicks()
    }

    private func show() {
        Task { await model.refreshCaptureHistory() }
        let isClipTarget = NSApp.isActive
        pasteTarget =
            isClipTarget
            ? NSRunningApplication(
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            ) : NSWorkspace.shared.frontmostApplication
        // A nonactivating panel normally preserves focus, but clicking one of
        // its SwiftUI buttons can still disturb AppKit's current responder.
        // Remember Clip's editor now so the selected history item returns to
        // the exact field the user was editing.
        clipPasteResponder = isClipTarget ? NSApp.keyWindow?.firstResponder : nil

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: content)
        position(panel)
        // Order front without activating Clip, so the app the user copied from
        // keeps focus and their paste goes there.
        panel.orderFrontRegardless()
        registerEscapeShortcut()
        startMonitoringOutsideClicks()
    }

    /// A nonactivating panel intentionally leaves keyboard focus in the app the
    /// user was already using. Register Escape only for the panel's visible
    /// lifetime so it can still dismiss without stealing focus or requiring
    /// Accessibility permission.
    private func registerEscapeShortcut() {
        try? escapeHotKey.register { [weak self] in
            Task { @MainActor in self?.hide() }
        }
    }

    private var content: some View {
        let theme = model.appearance.theme(matching: resolvedColorScheme)
        return CaptureHistoryView(
            model: model,
            onPaste: { [weak self] item in self?.paste(item) },
            onClose: { [weak self] in self?.hide() }
        )
        .environment(\.theme, theme)
        .tint(theme.palette.accent)
    }

    private func paste(_ item: CaptureHistoryItem) {
        let target = pasteTarget
        let responder = clipPasteResponder
        model.copyCaptureToPasteboard(item) { [weak self] in
            guard let self else { return }
            hide()
            if target?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                performClipPasteCommand(to: responder)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(70))
                pasteIntoExternalTarget(target)
            }
        }
    }

    private func pasteIntoExternalTarget(_ target: NSRunningApplication?) {
        guard let target, !target.isTerminated else { return }
        guard EventTapRecorder.isAuthorized() else {
            EventTapRecorder.requestAuthorization()
            model.reportAutomaticPasteUnavailable()
            return
        }
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
            )
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(target.processIdentifier)
        keyUp.postToPid(target.processIdentifier)
    }

    /// Preserves Clip's paste context: text goes through the active responder,
    /// while media goes through the open timeline's normal import path.
    private func performClipPasteCommand(to responder: NSResponder?) {
        if let responder,
            NSApp.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil)
        {
            return
        }
        if model.editor != nil {
            model.pasteMediaIntoTimeline()
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
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
