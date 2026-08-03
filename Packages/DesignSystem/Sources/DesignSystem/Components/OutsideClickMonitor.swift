import AppKit
import SwiftUI

/// Observes pointer presses without participating in hit testing and invokes an action when the
/// press lands outside the view's bounds.
public struct OutsideClickMonitor: NSViewRepresentable {
    private let isActive: Bool
    private let edgeTolerance: CGFloat
    private let action: @MainActor () -> Void

    public init(
        isActive: Bool,
        edgeTolerance: CGFloat = 1,
        action: @escaping @MainActor () -> Void
    ) {
        self.isActive = isActive
        self.edgeTolerance = edgeTolerance
        self.action = action
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.observe(view)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.edgeTolerance = edgeTolerance
        context.coordinator.action = action
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    public final class Coordinator {
        fileprivate var isActive = false
        fileprivate var edgeTolerance: CGFloat = 1
        fileprivate var action: @MainActor () -> Void = {}

        private weak var observedView: NSView?
        private var eventMonitor: Any?

        fileprivate func observe(_ view: NSView) {
            observedView = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self, isActive, let observedView else { return event }
                guard event.window === observedView.window else {
                    action()
                    return event
                }
                let point = observedView.convert(event.locationInWindow, from: nil)
                if !OutsideClickBoundary.contains(
                    point,
                    in: observedView.bounds,
                    edgeTolerance: edgeTolerance
                ) {
                    action()
                }
                return event
            }
        }

        fileprivate func stop() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

    }
}

enum OutsideClickBoundary {
    static func contains(
        _ point: CGPoint,
        in bounds: CGRect,
        edgeTolerance: CGFloat
    ) -> Bool {
        bounds.insetBy(dx: -max(edgeTolerance, 0), dy: -max(edgeTolerance, 0))
            .contains(point)
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
