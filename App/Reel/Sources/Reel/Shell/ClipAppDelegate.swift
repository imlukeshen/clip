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
    private static var preparedModel: AppModel?

    private let hotKey = GlobalHotKey()
    private var panel: ClipboardPanelController?

    /// Bridges the model created by `ClipApp` into AppKit before any window is
    /// restored. The global clipboard belongs to the running process, not a
    /// particular window, so it must not depend on `MainWindow.onAppear`.
    static func prepare(model: AppModel) {
        preparedModel = model
        (NSApp.delegate as? ClipAppDelegate)?.install(model: model)
    }

    /// The process-shared model prepared by `ClipApp`. The delegate holds it
    /// weakly and creates the floating panel as soon as the model is available.
    weak var model: AppModel? {
        didSet {
            guard let model, panel == nil else { return }
            panel = ClipboardPanelController(model: model)
        }
    }

    /// Completes process-wide setup once SwiftUI has created the shared model.
    /// Registration is idempotent, so this also closes the launch-order gap on
    /// systems where the scene appears after `applicationDidFinishLaunching`.
    func install(model: AppModel) {
        self.model = model
        registerHotKey()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let preparedModel = Self.preparedModel {
            install(model: preparedModel)
        } else {
            registerHotKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
    }

    /// Responds to the global Command-Shift-C.
    ///
    /// A Carbon hotkey takes the key event before the responder chain, so this
    /// always uses the process-wide floating panel. That keeps the shortcut
    /// available over another app and while Clip already has an editor or sheet
    /// open. If Carbon registration is unavailable, the menu command remains a
    /// local fallback and opens the same history in-window.
    func handleHotKey() {
        guard let model else { return }
        model.isCaptureHistoryPresented = false
        panel?.toggle()
    }

    private func registerHotKey() {
        do {
            try hotKey.register {
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
