import Testing

@testable import ReelAppCore

@Suite("Native text composition reconciliation")
struct TextCompositionSessionTests {
    @Test("Marked text remains local when the model has not changed")
    func localCommit() {
        let session = TextCompositionSession(baseline: "Type here: ")

        #expect(session.resolve(committedLocalText: "Type here: 日本語") == "Type here: 日本語")
    }

    @Test("An external insertion before the composition shifts and preserves the local edit")
    func mergesExternalInsertionBeforeComposition() {
        var session = TextCompositionSession(baseline: "Hello world")
        session.observeExternalText("Note: Hello world")

        #expect(
            session.resolve(committedLocalText: "Hello 世界")
                == "Note: Hello 世界"
        )
    }

    @Test("An external edit after the composition is retained")
    func mergesExternalEditAfterComposition() {
        var session = TextCompositionSession(baseline: "Title\nDraft")
        session.observeExternalText("Title\nPublished")

        #expect(
            session.resolve(committedLocalText: "見出し\nDraft")
                == "見出し\nPublished"
        )
    }

    @Test("A conflicting newer model edit wins instead of being overwritten")
    func externalWinsOverlap() {
        var session = TextCompositionSession(baseline: "Status: draft")
        session.observeExternalText("Status: published")

        #expect(
            session.resolve(committedLocalText: "Status: 下書き")
                == "Status: published"
        )
    }

    @Test("The latest external value is retained across stale baseline refreshes")
    func retainsLatestExternalValue() {
        var session = TextCompositionSession(baseline: "One")
        session.observeExternalText("One remote")
        session.observeExternalText("One")

        #expect(session.latestExternalText == "One remote")
        #expect(session.resolve(committedLocalText: "一") == "一 remote")
    }

    @Test("UTF-16 reconciliation does not split emoji or composed input")
    func reconcilesUnicode() {
        var session = TextCompositionSession(baseline: "😀 color")
        session.observeExternalText("😀 color!")

        #expect(session.resolve(committedLocalText: "😃 color") == "😃 color!")
    }

    @Test("Multiple external updates use the newest model value")
    func newestExternalValueWins() {
        var session = TextCompositionSession(baseline: "A B")
        session.observeExternalText("A B one")
        session.observeExternalText("A B two")

        #expect(session.resolve(committedLocalText: "あ B") == "あ B two")
    }
}
