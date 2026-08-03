import Foundation
import Testing

@testable import CaptureKit

@Suite("System capture destination")
struct SystemCaptureDestinationTests {
    @Test("Falls back to Desktop when macOS has no custom location")
    func desktopFallback() {
        let desktop = URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true)
        #expect(
            SystemCaptureDestination.resolve(configuredLocation: nil, desktop: desktop) == desktop)
        #expect(
            SystemCaptureDestination.resolve(configuredLocation: "  ", desktop: desktop) == desktop)
    }

    @Test("Resolves custom paths and file URLs")
    func customLocation() {
        let desktop = URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true)
        #expect(
            SystemCaptureDestination.resolve(
                configuredLocation: "/Users/example/Captures",
                desktop: desktop
            ).path == "/Users/example/Captures")
        #expect(
            SystemCaptureDestination.resolve(
                configuredLocation: "file:///Users/example/Screen%20Captures",
                desktop: desktop
            ).path == "/Users/example/Screen Captures")
    }
}
