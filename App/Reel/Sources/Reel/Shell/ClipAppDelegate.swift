import AppKit
import CaptureKit
import ReelAppCore
import SwiftUI
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
    private static weak var activeDelegate: ClipAppDelegate?

    private let hotKey = GlobalHotKey()
    private var panel: ClipboardPanelController?
    private var mainWindowController: NSWindowController?
    private var lastHotKeyToggleUptime: TimeInterval = 0

    override init() {
        super.init()
        Self.activeDelegate = self
    }

    /// Bridges the model created by `ClipApp` into AppKit before any window is
    /// restored. The global clipboard belongs to the running process, not a
    /// particular window, so it must not depend on `MainWindow.onAppear`.
    static func prepare(model: AppModel) {
        preparedModel = model
    }

    /// Toggles the process-wide clipboard without relying on `NSApp.delegate`.
    /// SwiftUI may wrap its adapted delegate, so casting the application
    /// delegate can fail even though this object is alive and registered.
    static func toggleClipboard() {
        activeDelegate?.handleHotKey()
    }

    /// Applies the current Settings preference immediately. The shortcut is
    /// registered process-wide only while enabled; disabling it gives the key
    /// combination back to Maccy or any other clipboard manager.
    static func refreshClipboardShortcutRegistration() {
        activeDelegate?.syncHotKeyRegistration()
    }

    /// Ensures a foreground library window exists even when macOS restores an
    /// empty SwiftUI scene session.
    static func ensureMainWindow() {
        activeDelegate?.showOrCreateMainWindow(in: NSApp)
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
        syncHotKeyRegistration()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let preparedModel = Self.preparedModel {
            install(model: preparedModel)
        }

        // A SwiftUI `WindowGroup` can restore the valid state "no windows".
        // That is useful for document apps, but Clip is a library app: launching
        // it should always reveal the library. Wait until SwiftUI has installed
        // its scene commands, then use the scene's own New Window command when
        // restoration did not create a window.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            showOrCreateMainWindow(in: NSApp)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return true }
        showOrCreateMainWindow(in: sender)
        return false
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
        // `NSApplication` and SwiftUI can finish their launch callbacks in
        // either order. Resolve the prepared process model lazily as a final
        // guard so the very first shortcut never depends on a window callback.
        if model == nil, let preparedModel = Self.preparedModel {
            model = preparedModel
        }
        guard let model else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHotKeyToggleUptime > 0.15 else { return }
        lastHotKeyToggleUptime = now
        model.isCaptureHistoryPresented = false
        panel?.toggle()
    }

    private func registerHotKey() {
        do {
            try hotKey.register {
                // Carbon delivers hotkey events on the main run loop. The
                // `@Sendable` closure cannot capture the main-actor delegate, so
                // it hops back onto the main actor and uses the instance retained
                // by SwiftUI's application-delegate adaptor.
                Task { @MainActor in
                    Self.toggleClipboard()
                }
            }
        } catch {
            Self.log.error("Global clipboard hotkey could not be registered.")
        }
    }

    private func syncHotKeyRegistration() {
        guard model?.isGlobalClipboardShortcutEnabled == true else {
            hotKey.unregister()
            return
        }
        registerHotKey()
    }

    private func showOrCreateMainWindow(in application: NSApplication) {
        if let window = mainWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            return
        }

        if let window = application.windows.first(where: { window in
            !(window is NSPanel) && window.canBecomeMain && window.isVisible
        }) {
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            return
        }

        guard let model else { return }

        // SwiftUI can restore a scene session with no windows, and its New
        // Window menu action is not available until a scene is already active.
        // Keep a native host as the reliable launch/reopen path so Clip never
        // becomes an invisible background process.
        let rootView = MainWindow(model: model)
            .frame(minWidth: 1024, minHeight: 680)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Clip"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1024, height: 680)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()

        let controller = NSWindowController(window: window)
        mainWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }
}
