import AppKit
import CoreModel
import DesignSystem
import Observation
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

    @Test("LaTeX promotion preserves focus and paints visible glyphs")
    func latexPromotionPreservesNativeEditingSurface() async throws {
        let model = CodeEditorPromotionModel()
        let hostingView = NSHostingView(
            rootView: CodeEditorPromotionHarness(model: model)
                .environment(\.theme, .dark)
                .frame(width: 900, height: 560)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        await settle(hostingView)
        let textView = try #require(descendant(CodeTextView.self, in: hostingView))
        #expect(window.makeFirstResponder(textView))
        textView.insertText(
            "\\documentclass{article}",
            replacementRange: textView.selectedRange()
        )
        await settle(hostingView)
        #expect(model.text == "\\documentclass{article}")

        model.language = .latex
        await settle(hostingView)

        let promotedTextView = try #require(descendant(CodeTextView.self, in: hostingView))
        #expect(promotedTextView === textView)
        #expect(window.firstResponder === promotedTextView)

        promotedTextView.insertText(
            "\n\\begin{document}\nVisible source\n\\end{document}",
            replacementRange: promotedTextView.selectedRange()
        )
        await settle(hostingView)

        #expect(
            model.text
                == "\\documentclass{article}\n\\begin{document}\nVisible source\n\\end{document}"
        )
        let storage = try #require(promotedTextView.textStorage)
        let textContainer = try #require(promotedTextView.textContainer)
        let layoutManager = try #require(promotedTextView.layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let characterRange = NSRange(location: 0, length: storage.length)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        let glyphBounds = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        #expect(glyphRange.length > 0)
        #expect(glyphBounds.width > 0)
        #expect(glyphBounds.height > 0)

        let foreground = try #require(
            storage.attribute(
                .foregroundColor,
                at: max(storage.length - 2, 0),
                effectiveRange: nil
            ) as? NSColor
        )
        #expect(foreground.alphaComponent > 0.9)
        #expect(
            abs(luminance(foreground) - luminance(promotedTextView.backgroundColor)) > 0.35
        )
    }

    private func settle<Content: View>(_ hostingView: NSHostingView<Content>) async {
        for _ in 0..<6 {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func descendant<ViewType: NSView>(
        _ type: ViewType.Type,
        in view: NSView
    ) -> ViewType? {
        if let match = view as? ViewType { return match }
        for subview in view.subviews {
            if let match = descendant(type, in: subview) { return match }
        }
        return nil
    }

    private func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return 0.2126 * Double(rgb.redComponent)
            + 0.7152 * Double(rgb.greenComponent)
            + 0.0722 * Double(rgb.blueComponent)
    }
}

@MainActor
@Observable
private final class CodeEditorPromotionModel {
    var text = ""
    var language: LanguageID = .plainText
}

private struct CodeEditorPromotionHarness: View {
    @Bindable var model: CodeEditorPromotionModel
    private let undoManager = UndoManager()

    var body: some View {
        HSplitView {
            CodeEditor(
                text: $model.text,
                language: model.language,
                settings: EditorSettings(fontSize: 13),
                documentIdentity: CodeEditorDocumentIdentity(
                    documentID: DocumentID(rawValue: "latex-appearance-document"),
                    fileID: FileID(rawValue: "latex-appearance-file")
                ),
                fileName: model.language == .latex ? "Untitled.tex" : "Untitled.txt",
                isReadOnly: false,
                undoManager: undoManager,
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
            .frame(minWidth: model.language == .latex ? 340 : 0)

            if model.language == .latex {
                Color.black
                    .frame(minWidth: 340)
                    .accessibilityIdentifier("latex-preview-test-double")
            }
        }
    }
}
