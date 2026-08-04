import AppKit
import CaptureKit
import ReelAppCore
import os

/// Owns the process-wide clipboard affordances that outlive any one window: the
/// global Command-Shift-C hotkey and the floating panel it opens.
///
/// These cannot live in a SwiftUI `Scene`. The hotkey must register once at
/// launch regardless of which window is frontmost, and the panel must appear
/// over other apps — both are AppKit concerns the `App` protocol does not model,
/// so they hang off an application delegate.
@MainActor
final class ClipAppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "app.reel.editor", category: "clipboard-hotkey")

    private let hotKey = GlobalHotKey()
    private var panel: ClipboardPanelController?

    /// Set by `MainWindow` once the model exists. The delegate is created before
    /// the model, so it holds the reference weakly and builds the panel when the
    /// model arrives.
    weak var model: AppModel? {
        didSet {
            guard let model, panel == nil else { return }
            panel = ClipboardPanelController(model: model)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await registerHotKey() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await hotKey.unregister() }
    }

    /// Responds to the global Command-Shift-C.
    ///
    /// A Carbon hotkey takes the key event before the responder chain, so when
    /// Clip is frontmost this shadows the identical menu shortcut rather than
    /// racing it. That makes this the single owner of the shortcut: it shows the
    /// history as the in-window sheet when Clip is focused, and as the floating
    /// panel over another app when it is not. Either way one press opens one
    /// surface.
    func handleHotKey() {
        guard let model else { return }
        if NSApp.isActive {
            panel?.hide()
            if !model.isCaptureHistoryPresented {
                Task { await model.refreshCaptureHistory() }
            }
            model.isCaptureHistoryPresented.toggle()
        } else {
            model.isCaptureHistoryPresented = false
            panel?.toggle()
        }
    }

    private func registerHotKey() async {
        do {
            try await hotKey.register {
                // Carbon delivers hotkey events on the main run loop. The
                // `@Sendable` closure cannot capture the main-actor delegate, so
                // it hops back onto the main actor and reads it from `NSApp`.
                Task { @MainActor in
                    (NSApp.delegate as? ClipAppDelegate)?.handleHotKey()
                }
            }
        } catch {
            Self.log.error("Global clipboard hotkey could not be registered.")
        }
    }
}
