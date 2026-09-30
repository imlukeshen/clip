import SwiftUI

/// Holds a short highlight just after a button is released.
///
/// Press styling only lasts while the pointer is held down, so a quick click
/// shows it for a few dozen milliseconds and reads as though nothing happened.
/// Keeping the highlight briefly after release is what makes an action feel
/// acknowledged. Reduce Motion skips it, since the state change is decorative.
struct ButtonPressFlash: ViewModifier {
    let isPressed: Bool
    @Binding var isFlashing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Long enough to register, short enough not to lag a rapid sequence.
    private static let duration = Duration.milliseconds(160)

    func body(content: Content) -> some View {
        content
            .onChange(of: isPressed) { wasPressed, pressed in
                guard wasPressed, !pressed, !reduceMotion else { return }
                isFlashing = true
                Task { @MainActor in
                    try? await Task.sleep(for: Self.duration)
                    isFlashing = false
                }
            }
    }
}

extension View {
    /// Reports a brief highlight after this button's press ends.
    func buttonPressFlash(isPressed: Bool, isFlashing: Binding<Bool>) -> some View {
        modifier(ButtonPressFlash(isPressed: isPressed, isFlashing: isFlashing))
    }
}
