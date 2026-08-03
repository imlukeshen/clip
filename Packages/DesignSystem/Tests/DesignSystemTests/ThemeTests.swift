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
        #expect(Theme.dark.metrics.radius.input == 10)
        #expect(Theme.dark.metrics.radius.card == 12)
        #expect(Theme.dark.metrics.radius.dropZone == 14)
    }

    @Test("Typography uses only regular and medium weights")
    func typography() {
        #expect(Theme.dark.type.title.size == 15)
        #expect(Theme.dark.type.title.weight == .medium)
        #expect(Theme.dark.type.body.size == 13)
        #expect(Theme.dark.type.body.weight == .regular)
        #expect(Theme.dark.type.numeric.isMonospaced)
    }
}
