import Foundation
import ReelAppCore
import Testing

@Test func exportDestinationValidatesTokensAndResolvesExactPath() throws {
    let destination = ExportDestination(
        bookmarkKey: "downloads",
        subpathTemplate: "Exports/{date}",
        filenameTemplate: "{project}-{preset}"
    )
    let date = try #require(
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 8, day: 2))
    )
    let url = try destination.resolve(
        in: URL(fileURLWithPath: "/tmp/Reel Exports"),
        context: ExportTemplateContext(
            project: "Onboarding",
            date: date,
            preset: "1080p",
            codec: "h264",
            resolution: "1920x1080",
            duration: "84.2"
        ),
        extension: "mp4"
    )
    #expect(url.path == "/tmp/Reel Exports/Exports/2026-08-02/Onboarding-1080p.mp4")

    let invalid = ExportDestination(
        bookmarkKey: "x",
        filenameTemplate: "{project}-{unknown}"
    )
    #expect(throws: ExportDestinationError.invalidToken("unknown")) { try invalid.validate() }
}
