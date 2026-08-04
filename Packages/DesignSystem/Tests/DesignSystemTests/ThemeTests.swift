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
