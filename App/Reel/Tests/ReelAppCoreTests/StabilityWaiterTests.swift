import Foundation
import Testing

@testable import ReelAppCore

@Test func stabilityWaitRequiresThreeMatchingPollsAfterBaseline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "reel-stability-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("capture.mov")
    try Data("stable".utf8).write(to: file)
    let waiter = StabilityWaiter(
        configuration: StabilityConfiguration(
            pollInterval: .milliseconds(15),
            requiredMatchingPolls: 3,
            timeout: .seconds(1)
        )
    )
    let clock = ContinuousClock()
    let start = clock.now

    let result: String = try await waiter.wait(for: file, progress: { _ in }) { _ in "ready" }
    let elapsed = start.duration(to: clock.now)

    #expect(result == "ready")
    #expect(elapsed >= .milliseconds(45))
}
