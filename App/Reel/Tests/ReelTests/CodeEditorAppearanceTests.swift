import AppKit
import CoreModel
import DesignSystem
import SwiftUI
import Testing

@testable import Reel

@Suite("Code editor presentation")
@MainActor
struct CodeEditorAppearanceTests {
    @Test("An identical appearance update preserves rendered Markdown attributes")
    func identicalAppearanceUpdateIsAttributeIdempotent() throws {
        var source = "# Heading"
        let editor = CodeEditor(
            text: Binding(
                get: { source },
                set: { source = $0 }
            ),
            language: .markdown,
            settings: EditorSettings(fontSize: 13),
            documentIdentity: CodeEditorDocumentIdentity(
                documentID: .init(rawValue: "appearance-document"),
                fileID: .init(rawValue: "appearance-file")
            ),
            fileName: "Untitled.md",
            isReadOnly: false,
            undoManager: UndoManager(),
            onSave: {},
            onLongLineModeChange: { _ in },
            onLargePaste: {},
            onPasteRefused: {},
            onPasteIntoEmptyBuffer: { _ in },
            onSnippetNotice: { _ in },
            diagnostics: [],
            scrollToLine: nil,
            navigation: nil,
            onVisibleLineChange: { _ in },
            onSelectionChange: { _ in },
            onMarkdownDocumentChange: { _, _ in },
            onCursorChange: { _, _ in }
        )
        let coordinator = editor.makeCoordinator()
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.isRichText = false
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView

        coordinator.updateAppearance(
            textView: textView,
            scrollView: scrollView,
            theme: .dark,
            language: .markdown,
            settings: EditorSettings(fontSize: 13)
        )

        textView.string = source
        let markerRange = NSRange(location: 0, length: 2)
        let headingRange = NSRange(location: 2, length: 7)
        let headingFont = NSFont.systemFont(ofSize: 24, weight: .bold)
        textView.textStorage?.addAttributes(
            [
                .foregroundColor: NSColor.clear,
                .font: NSFont.systemFont(ofSize: 13),
                .kern: -6.0,
            ],
            range: markerRange
        )
        textView.textStorage?.addAttribute(.font, value: headingFont, range: headingRange)
        let selection = NSRange(location: (source as NSString).length, length: 0)
        textView.setSelectedRange(selection)

        // Save state, cursor state, and Markdown snapshot publications all
        // produce this same no-op representable update.
        coordinator.updateAppearance(
            textView: textView,
            scrollView: scrollView,
            theme: .dark,
            language: .markdown,
            settings: EditorSettings(fontSize: 13)
        )

        let markerColor = try #require(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: markerRange.location,
                effectiveRange: nil
            ) as? NSColor
        )
        let markerKern = try #require(
            textView.textStorage?.attribute(
                .kern,
                at: markerRange.location,
                effectiveRange: nil
            ) as? NSNumber
        )
        let renderedHeadingFont = try #require(
            textView.textStorage?.attribute(
                .font,
                at: headingRange.location,
                effectiveRange: nil
            ) as? NSFont
        )

        #expect(textView.string == source)
        #expect(textView.selectedRange() == selection)
        #expect(markerColor.alphaComponent == 0)
        #expect(markerKern.doubleValue < 0)
        #expect(renderedHeadingFont.pointSize == headingFont.pointSize)
        #expect(renderedHeadingFont.fontDescriptor.symbolicTraits.contains(.bold))
    }
}
