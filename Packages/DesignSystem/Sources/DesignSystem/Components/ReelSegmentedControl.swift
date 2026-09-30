import SwiftUI

/// A segmented selector shaped and animated like the rest of the app.
///
/// The stock segmented picker brings its own corner radius, its own colours and
/// its own motion, so every one of them read as a control borrowed from another
/// application. This one is built from the shared tokens, and its indicator
/// slides between segments with the same spring the buttons use instead of
/// cross-fading.
///
/// Radii follow the nested scale: the track takes the input radius and the
/// indicator inside it takes the next step down, so the corners stay
/// concentric.
public struct ReelSegmentedControl<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    @Binding private var selection: Value
    private let options: [Option]

    public struct Option: Identifiable {
        public let value: Value
        public let title: String

        public var id: Value { value }

        public init(value: Value, title: String) {
            self.value = value
            self.title = title
        }
    }

    public init(selection: Binding<Value>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(theme.metrics.hairline * 4)
        .background(theme.palette.surfaceRaised)
        .clipShape(
            RoundedRectangle(cornerRadius: theme.metrics.radius.input, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.radius.input, style: .continuous)
                .strokeBorder(theme.palette.line, lineWidth: theme.metrics.hairline)
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            guard !isSelected else { return }
            if reduceMotion {
                selection = option.value
            } else {
                withAnimation(ReelMotion.buttonHover) { selection = option.value }
            }
        } label: {
            Text(option.title)
                .font(theme.type.label.font)
                .foregroundStyle(
                    isSelected ? theme.palette.textPrimary : theme.palette.textSecondary
                )
                .lineLimit(1)
                .padding(.vertical, theme.metrics.spacing.xs)
                .padding(.horizontal, theme.metrics.spacing.md)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        RoundedRectangle(
                            cornerRadius: theme.metrics.radius.control,
                            style: .continuous
                        )
                        .fill(theme.palette.surfacePanel)
                        .matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(ReelPlainButtonStyle())
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Segmented control") {
    struct Harness: View {
        @State private var value = "Inspector"
        var body: some View {
            ReelSegmentedControl(
                selection: $value,
                options: [
                    .init(value: "Inspector", title: "Inspector"),
                    .init(value: "Chat", title: "Chat"),
                ]
            )
            .frame(width: 240)
            .padding()
            .background(Theme.dark.palette.surfacePanel)
            .environment(\.theme, Theme.dark)
        }
    }
    return Harness()
}
