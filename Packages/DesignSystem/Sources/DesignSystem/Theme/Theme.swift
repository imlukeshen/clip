import SwiftUI

/// Clip's complete visual token set.
public struct Theme: Sendable {
    public struct Palette: Sendable {
        public let surfaceBase: Color
        public let surfacePanel: Color
        public let surfaceRaised: Color
        public let surfaceSunken: Color
        public let line: Color
        public let lineStrong: Color
        public let textPrimary: Color
        public let textSecondary: Color
        public let textTertiary: Color
        /// Neutral emphasis colour. Clip keeps its accent monochrome, so
        /// emphasis reads as contrast rather than hue.
        public let accent: Color
        /// Content drawn on top of an `accent` fill.
        public let accentOn: Color
        public let accentDim: Color
        public let accentLine: Color
        public let click: Color
        public let success: Color
        public let danger: Color
    }

    public struct Metrics: Sendable, Equatable {
        public struct Spacing: Sendable, Equatable {
            public let xs: CGFloat = 4
            public let sm: CGFloat = 6
            public let md: CGFloat = 10
            public let lg: CGFloat = 14
            public let xl: CGFloat = 20
            public let xxl: CGFloat = 28

            public init() {}
        }

        /// A single nested scale: anything drawn inside something else takes the
        /// next step down, so corners stay concentric instead of fighting.
        public struct Radius: Sendable, Equatable {
            /// Badges, thumbnails, timeline clips — anything that sits on top of
            /// another surface and would look bloated at the control radius.
            public let small: CGFloat = 5
            public let control: CGFloat = 8
            public let input: CGFloat = 10
            public let card: CGFloat = 12
            public let dropZone: CGFloat = 12
            public let sheet: CGFloat = 16

            public init() {}
        }

        public let spacing = Spacing()
        public let radius = Radius()
        public let hairline: CGFloat = 0.5

        public init() {}
    }

    public struct Typography: Sendable, Equatable {
        public enum Weight: Sendable, Equatable {
            case regular
            case medium

            fileprivate var swiftUIValue: Font.Weight {
                switch self {
                case .regular: .regular
                case .medium: .medium
                }
            }
        }

        public struct Style: Sendable, Equatable {
            public let size: CGFloat
            public let weight: Weight
            public let isMonospaced: Bool

            public init(size: CGFloat, weight: Weight, isMonospaced: Bool = false) {
                self.size = size
                self.weight = weight
                self.isMonospaced = isMonospaced
            }

            public var font: Font {
                if isMonospaced {
                    return .system(size: size, weight: weight.swiftUIValue, design: .monospaced)
                }
                return .system(size: size, weight: weight.swiftUIValue)
            }
        }

        public let title = Style(size: 15, weight: .medium)
        public let body = Style(size: 13, weight: .regular)
        public let label = Style(size: 12, weight: .regular)
        public let caption = Style(size: 11, weight: .regular)
        public let micro = Style(size: 10, weight: .regular)
        public let numeric = Style(size: 10.5, weight: .regular, isMonospaced: true)
        public let sectionLabel = Style(size: 10, weight: .regular)

        public init() {}
    }

    public let palette: Palette
    public let metrics: Metrics
    public let type: Typography

    public init(palette: Palette, metrics: Metrics = Metrics(), type: Typography = Typography()) {
        self.palette = palette
        self.metrics = metrics
        self.type = type
    }

    public static let dark = Theme(
        palette: Palette(
            surfaceBase: Color(hex: 0x0B0B0C),
            surfacePanel: Color(hex: 0x121213),
            surfaceRaised: Color(hex: 0x1C1C1E),
            surfaceSunken: Color(hex: 0x08080A),
            line: .white.opacity(0.06),
            lineStrong: .white.opacity(0.12),
            textPrimary: Color(hex: 0xEDEDEF),
            textSecondary: Color(hex: 0x9B9BA3),
            textTertiary: Color(hex: 0x6A6A72),
            accent: Color(hex: 0xF2F2F5),
            accentOn: Color(hex: 0x0B0B0C),
            accentDim: .white.opacity(0.10),
            accentLine: .white.opacity(0.30),
            click: Color(hex: 0xD99B4A),
            success: Color(hex: 0x4FAF77),
            danger: Color(hex: 0xE5534B)
        )
    )

    public static let light = Theme(
        palette: Palette(
            surfaceBase: Color(hex: 0xF7F7F8),
            surfacePanel: Color(hex: 0xFFFFFF),
            surfaceRaised: Color(hex: 0xF0F0F2),
            surfaceSunken: Color(hex: 0x1B1B1E),
            line: .black.opacity(0.08),
            lineStrong: .black.opacity(0.14),
            textPrimary: Color(hex: 0x18181B),
            textSecondary: Color(hex: 0x5C5C66),
            textTertiary: Color(hex: 0x8A8A94),
            accent: Color(hex: 0x1A1A1E),
            accentOn: Color(hex: 0xFFFFFF),
            accentDim: .black.opacity(0.06),
            accentLine: .black.opacity(0.22),
            click: Color(hex: 0xB0761F),
            success: Color(hex: 0x2F7D50),
            danger: Color(hex: 0xC8372D)
        )
    )
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
