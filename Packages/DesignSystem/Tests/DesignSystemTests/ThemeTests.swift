import AppKit
import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Design system theme")
struct ThemeTests {
    @Test("Dark and light themes share the specified geometry")
    func metrics() {
        #expect(Theme.dark.metrics == Theme.light.metrics)
        #expect(Theme.dark.metrics.hairline == 0.5)
        #expect(Theme.dark.metrics.spacing.xs == 4)
        #expect(Theme.dark.metrics.spacing.xxl == 28)
        #expect(Theme.dark.metrics.radius.control == 8)
        #expect(Theme.dark.metrics.radius.input == 10)
        #expect(Theme.dark.metrics.radius.card == 12)
        #expect(Theme.dark.metrics.radius.dropZone == 12)
    }

    @Test("Radii step up so nested corners stay concentric")
    func radiiNest() {
        let radius = Theme.dark.metrics.radius
        let scale = [radius.small, radius.control, radius.input, radius.card, radius.sheet]
        #expect(scale == scale.sorted())
        #expect(Set(scale).count == scale.count)
    }

    @Test("Typography uses only regular and medium weights")
    func typography() {
        #expect(Theme.dark.type.title.size == 15)
        #expect(Theme.dark.type.title.weight == .medium)
        #expect(Theme.dark.type.body.size == 13)
        #expect(Theme.dark.type.body.weight == .regular)
        #expect(Theme.dark.type.numeric.isMonospaced)
    }

    @Test("The accent is neutral rather than tinted")
    func accentIsMonochrome() {
        for theme in [Theme.dark, Theme.light] {
            let (red, green, blue) = components(of: theme.palette.accent)
            let spread = max(red, green, blue) - min(red, green, blue)
            #expect(spread < 0.04)
        }
    }

    @Test("Content on an accent fill contrasts with it")
    func accentOnIsLegible() {
        for theme in [Theme.dark, Theme.light] {
            let fill = components(of: theme.palette.accent)
            let content = components(of: theme.palette.accentOn)
            #expect(abs(luminance(fill) - luminance(content)) > 0.5)
        }
    }

    /// Every surface in a theme has to sit on the same side of the divide as
    /// the theme itself. A dark value among the light surfaces renders a whole
    /// pane near-black under near-black text, which is how the light theme's
    /// build output, PDF and photo canvases, and inspector well went blank.
    @Test("Surfaces stay on the light or dark side their theme is named for")
    func surfacesMatchTheirTheme() {
        for surface in surfaces(of: Theme.light) {
            #expect(luminance(components(of: surface.color)) > 0.5, "\(surface.name) is not light")
        }
        for surface in surfaces(of: Theme.dark) {
            #expect(luminance(components(of: surface.color)) < 0.5, "\(surface.name) is not dark")
        }
    }

    @Test("Body text is legible on every surface it can be drawn on")
    func textContrastsWithEverySurface() {
        for theme in [Theme.dark, Theme.light] {
            for surface in surfaces(of: theme) {
                let background = components(of: surface.color)
                #expect(
                    contrast(components(of: theme.palette.textPrimary), background) >= 4.5,
                    "primary text on \(surface.name)"
                )
                #expect(
                    contrast(components(of: theme.palette.textSecondary), background) >= 3,
                    "secondary text on \(surface.name)"
                )
            }
        }
    }

    /// Recessed reads as recessed: a sunken surface is never lighter than the
    /// panel that sits above it, in either theme.
    @Test("The surface ramp is ordered")
    func surfaceRampIsOrdered() {
        for theme in [Theme.dark, Theme.light] {
            let panel = luminance(components(of: theme.palette.surfacePanel))
            let sunken = luminance(components(of: theme.palette.surfaceSunken))
            #expect(sunken <= panel)
        }
    }

    private func surfaces(of theme: Theme) -> [(name: String, color: Color)] {
        [
            ("surfaceBase", theme.palette.surfaceBase),
            ("surfacePanel", theme.palette.surfacePanel),
            ("surfaceRaised", theme.palette.surfaceRaised),
            ("surfaceSunken", theme.palette.surfaceSunken),
        ]
    }

    /// WCAG relative-contrast ratio between two opaque colours.
    private func contrast(
        _ lhs: (Double, Double, Double),
        _ rhs: (Double, Double, Double)
    ) -> Double {
        func relative(_ rgb: (Double, Double, Double)) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
        }
        let first = relative(lhs)
        let second = relative(rhs)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func components(of color: Color) -> (Double, Double, Double) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (
            Double(resolved.redComponent),
            Double(resolved.greenComponent),
            Double(resolved.blueComponent)
        )
    }

    private func luminance(_ rgb: (Double, Double, Double)) -> Double {
        0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
    }
}
