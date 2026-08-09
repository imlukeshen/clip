import Testing

@testable import ReelAppCore

@Suite("LaTeX status title")
struct TeXStatusTitleTests {
    /// A failed build leaves the previous PDF on screen, so the source has
    /// genuinely moved on. Reporting only that would describe the source and
    /// say nothing about the build that just failed.
    @Test("A failed build is reported even though the source has moved on")
    func failureOutranksUnbuiltChanges() {
        #expect(
            TeXStatusTitle.title(state: .failed("boom"), hasUnbuiltChanges: true) == "Build failed"
        )
        #expect(
            TeXStatusTitle.title(state: .failed("boom"), hasUnbuiltChanges: false) == "Build failed"
        )
    }

    @Test("A running or paused build is reported the same way")
    func runningAndPausedOutrankUnbuiltChanges() {
        #expect(TeXStatusTitle.title(state: .compiling, hasUnbuiltChanges: true) == "Building")
        #expect(
            TeXStatusTitle.title(state: .paused("clearing"), hasUnbuiltChanges: true)
                == "Build paused"
        )
    }

    /// After a build that succeeded, the source moving on is the useful thing
    /// to say: the PDF is real, it is just behind the editor.
    @Test("A succeeded build defers to the source having moved on")
    func successDefersToUnbuiltChanges() {
        #expect(
            TeXStatusTitle.title(state: .succeeded, hasUnbuiltChanges: true) == "Changes not built"
        )
        #expect(TeXStatusTitle.title(state: .succeeded, hasUnbuiltChanges: false) == "PDF ready")
    }

    @Test("An editor that has never built says so")
    func idleReportsNotBuilt() {
        #expect(TeXStatusTitle.title(state: .idle, hasUnbuiltChanges: false) == "Not built")
        #expect(TeXStatusTitle.title(state: .idle, hasUnbuiltChanges: true) == "Changes not built")
    }
}
