import Foundation
import Testing

@testable import ReelAppCore

@Test func captureDirectoryMonitoringPolicyIsDeterministicDuringUITests() {
    let root = URL(fileURLWithPath: "/tmp/clip-capture-policy", isDirectory: true)
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let captureDirectory = root.appendingPathComponent("Captures", isDirectory: true)

    #expect(
        AppRuntime.shouldMonitorCaptureDirectory(
            isUITesting: false,
            hasExplicitOverride: false,
            captureDirectory: captureDirectory,
            inboxDirectory: inbox
        )
    )
    #expect(
        !AppRuntime.shouldMonitorCaptureDirectory(
            isUITesting: true,
            hasExplicitOverride: false,
            captureDirectory: captureDirectory,
            inboxDirectory: inbox
        )
    )
    #expect(
        AppRuntime.shouldMonitorCaptureDirectory(
            isUITesting: true,
            hasExplicitOverride: true,
            captureDirectory: captureDirectory,
            inboxDirectory: inbox
        )
    )
    #expect(
        !AppRuntime.shouldMonitorCaptureDirectory(
            isUITesting: false,
            hasExplicitOverride: true,
            captureDirectory: inbox,
            inboxDirectory: inbox
        )
    )
}
