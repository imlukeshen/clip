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
        public let accent: Color
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

        public struct Radius: Sendable, Equatable {
            public let timeline: CGFloat = 4
            public let input: CGFloat = 10
            public let control: CGFloat = 8
            public let card: CGFloat = 12
            public let dropZone: CGFloat = 14
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
            surfaceBase: Color(hex: 0x0D0E10),
            surfacePanel: Color(hex: 0x141619),
            surfaceRaised: Color(hex: 0x1B1E22),
            surfaceSunken: Color(hex: 0x0A0B0D),
            line: .white.opacity(0.07),
            lineStrong: .white.opacity(0.13),
            textPrimary: Color(hex: 0xE4E6E8),
            textSecondary: Color(hex: 0x9AA0A6),
            textTertiary: Color(hex: 0x5E646C),
            accent: Color(hex: 0x6F9DE0),
            accentDim: Color(hex: 0x6F9DE0).opacity(0.13),
            accentLine: Color(hex: 0x6F9DE0).opacity(0.4),
            click: Color(hex: 0xD69A45),
            success: Color(hex: 0x6FAE7C),
            danger: Color(hex: 0xD4574E)
        )
    )

    public static let light = Theme(
        palette: Palette(
            surfaceBase: Color(hex: 0xF5F5F4),
            surfacePanel: Color(hex: 0xFFFFFF),
            surfaceRaised: Color(hex: 0xEFEFED),
            surfaceSunken: Color(hex: 0x1B1E22),
            line: .black.opacity(0.09),
            lineStrong: .black.opacity(0.16),
            textPrimary: Color(hex: 0x1C1D1F),
            textSecondary: Color(hex: 0x5F656C),
            textTertiary: Color(hex: 0x8A9099),
            accent: Color(hex: 0x3B72C4),
            accentDim: Color(hex: 0x3B72C4).opacity(0.13),
            accentLine: Color(hex: 0x3B72C4).opacity(0.4),
            click: Color(hex: 0xB87B22),
            success: Color(hex: 0x3F7F52),
            danger: Color(hex: 0xC0392F)
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
