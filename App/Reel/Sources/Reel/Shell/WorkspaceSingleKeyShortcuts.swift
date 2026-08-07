import AppKit
import SwiftUI

enum WorkspaceSingleKeyCommand: Equatable {
    case selectTool
    case razorTool
    case toggleSnapping
    case deleteSelected
    case rippleDelete
    case togglePlayback
    case shuttleBackward
    case shuttlePause
    case shuttleForward
    case setInPoint
    case setOutPoint
    case addMarker
    case nextMarker
}

enum WorkspaceSingleKeyShortcut {
    static func command(
        charactersIgnoringModifiers characters: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> WorkspaceSingleKeyCommand? {
        let semanticModifiers = modifiers.intersection([.command, .control, .option, .shift])
        guard semanticModifiers.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        let shifted = semanticModifiers.contains(.shift)

        if keyCode == 51 || keyCode == 117 {
            return shifted ? .rippleDelete : .deleteSelected
        }
        guard let character = characters?.lowercased(), character.count == 1 else { return nil }
        if shifted {
            return character == "m" ? .nextMarker : nil
        }
        switch character {
        case " ": return .togglePlayback
        case "v": return .selectTool
        case "c": return .razorTool
        case "s": return .toggleSnapping
        case "j": return .shuttleBackward
        case "k": return .shuttlePause
        case "l": return .shuttleForward
        case "i": return .setInPoint
        case "o": return .setOutPoint
        case "m": return .addMarker
        default: return nil
        }
    }
}

enum SingleKeyShortcutInputGate {
    static func allowsShortcut(firstResponder: NSResponder?) -> Bool {
        guard let firstResponder else { return true }
        if firstResponder is NSTextView || firstResponder is NSTextField { return false }
        return !(firstResponder is any NSTextInputClient)
    }
}

struct WorkspaceSingleKeyShortcutMonitor: NSViewRepresentable {
    let onCommand: @MainActor (WorkspaceSingleKeyCommand) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommand: onCommand)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onCommand = onCommand
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var onCommand: @MainActor (WorkspaceSingleKeyCommand) -> Bool
        private weak var view: NSView?
        private var monitor: Any?

        init(onCommand: @escaping @MainActor (WorkspaceSingleKeyCommand) -> Bool) {
            self.onCommand = onCommand
        }

        func install(for view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard !event.isARepeat, event.window === view?.window else { return event }
            guard
                SingleKeyShortcutInputGate.allowsShortcut(
                    firstResponder: event.window?.firstResponder
                )
            else {
                return event
            }
            guard
                let command = WorkspaceSingleKeyShortcut.command(
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags
                ), onCommand(command)
            else {
                return event
            }
            return nil
        }

    }
}
