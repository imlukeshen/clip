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

        // Reproduce the AppKit split-reparent failure directly: typing attributes
        // can be cleared between key events even though the bound source keeps
        // changing. LaTeX insertion must repair the new attributed run before
        // the asynchronous syntax pass or another SwiftUI update can help it.
        var resetTypingAttributes = promotedTextView.typingAttributes
        resetTypingAttributes[.foregroundColor] = NSColor.clear
        promotedTextView.typingAttributes = resetTypingAttributes
        let newlyTypedLocation = promotedTextView.string.utf16.count
        promotedTextView.insertText(
            "\n\\begin{document}\nVisible source\n\\end{document}",
            replacementRange: promotedTextView.selectedRange()
        )
        let immediateForeground = try #require(
            promotedTextView.textStorage?.attribute(
                .foregroundColor,
                at: newlyTypedLocation,
                effectiveRange: nil
            ) as? NSColor
        )
        #expect(immediateForeground.alphaComponent > 0.9)
        #expect(
            abs(luminance(immediateForeground) - luminance(promotedTextView.backgroundColor)) > 0.35
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

    @Test("Nonfocused LaTeX promotion lays out and paints the source pane")
    func nonfocusedLatexPromotionPaintsVisibleSource() async throws {
        let model = CodeEditorPromotionModel()
        let hostingView = NSHostingView(
            rootView: CodeEditorPromotionHarness(model: model)
                .environment(\.theme, .dark)
                .frame(width: 760, height: 560)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
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
        let originalTextView = try #require(descendant(CodeTextView.self, in: hostingView))

        // Choosing LaTeX from the header menu moves focus away from the source
        // before the split preview is inserted. Exercise that path instead of
        // the already-covered active-editor transition.
        let menuFocusProxy = NSTextField(
            frame: NSRect(x: hostingView.bounds.maxX - 2, y: 0, width: 1, height: 1)
        )
        hostingView.addSubview(menuFocusProxy)
        #expect(window.makeFirstResponder(menuFocusProxy))
        await settle(hostingView)

        model.language = .latex
        await settle(hostingView)

        let container = try #require(
            descendant(CodeEditorContainerView.self, in: hostingView)
        )
        let promotedTextView = try #require(descendant(CodeTextView.self, in: hostingView))
        #expect(promotedTextView === originalTextView)
        #expect(container.bounds.width > 0)
        #expect(container.bounds.height > 0)
        #expect(container.scrollView.contentView.documentVisibleRect.width > 0)
        #expect(container.scrollView.contentView.documentVisibleRect.height > 0)

        #expect(window.makeFirstResponder(promotedTextView))
        promotedTextView.insertText(
            "Visible LaTeX source",
            replacementRange: promotedTextView.selectedRange()
        )
        await settle(hostingView)

        let storage = try #require(promotedTextView.textStorage)
        let textContainer = try #require(promotedTextView.textContainer)
        let layoutManager = try #require(promotedTextView.layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: storage.length),
            actualCharacterRange: nil
        )
        var glyphRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        glyphRect.origin.x += promotedTextView.textContainerOrigin.x
        glyphRect.origin.y += promotedTextView.textContainerOrigin.y
        let visibleSourceRect = container.scrollView.contentView.documentVisibleRect
        let visibleGlyphRect = glyphRect.intersection(visibleSourceRect)

        #expect(glyphRange.length > 0)
        #expect(visibleGlyphRect.width > 0)
        #expect(visibleGlyphRect.height > 0)
        #expect(renderedForegroundPixelCount(in: promotedTextView, rect: visibleGlyphRect) > 20)
    }

    @Test("Initially LaTeX source remains painted after workspace layout changes")
    func initiallyLatexSourceSurvivesBuildOutputLayoutChange() async throws {
        let model = CodeEditorPromotionModel()
        model.language = .latex
        let hostingView = NSHostingView(
            rootView: CodeEditorPromotionHarness(model: model)
                .environment(\.theme, .dark)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
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

        let source = """
            \\documentclass{article}
            \\begin{document}
            SOURCE GLYPHS MUST REMAIN VISIBLE
            \\end{document}
            """
        for character in source {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
        }
        await settle(hostingView)

        #expect(model.text == source)
        let initialPixels = compositedForegroundPixelCount(
            in: textView,
            ancestor: hostingView
        )
        #expect(initialPixels > 80)

        // A build result adds a lower output pane while inspector or window
        // changes can resize the source half of the split. Exercise both in
        // one update and rasterize the complete hosting hierarchy, rather than
        // asking NSTextView to render itself in isolation.
        model.showsBuildOutput = true
        window.setContentSize(NSSize(width: 760, height: 560))
        await settle(hostingView)

        let resizedTextView = try #require(descendant(CodeTextView.self, in: hostingView))
        let resizedPixels = compositedForegroundPixelCount(
            in: resizedTextView,
            ancestor: hostingView
        )
        #expect(resizedTextView.string == source)
        #expect(
            (resizedTextView.enclosingScrollView?.contentView.documentVisibleRect.width ?? 0) > 0
        )
        #expect(resizedPixels > 80)
        #expect(resizedPixels > initialPixels / 3)
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

    private func renderedForegroundPixelCount(
        in textView: NSTextView,
        rect: NSRect
    ) -> Int {
        let renderRect = rect.insetBy(dx: -2, dy: -2).intersection(textView.bounds)
        guard !renderRect.isEmpty,
            let bitmap = textView.bitmapImageRepForCachingDisplay(in: renderRect),
            let foreground = textView.textStorage?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor,
            let foregroundRGB = foreground.usingColorSpace(.sRGB),
            let backgroundRGB = textView.backgroundColor.usingColorSpace(.sRGB)
        else { return 0 }

        textView.displayIfNeeded()
        textView.cacheDisplay(in: renderRect, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let distanceFromForeground = colorDistance(pixel, foregroundRGB)
                let distanceFromBackground = colorDistance(pixel, backgroundRGB)
                if distanceFromBackground > 0.18,
                    distanceFromForeground < distanceFromBackground
                {
                    count += 1
                }
            }
        }
        return count
    }

    private func compositedForegroundPixelCount(
        in textView: NSTextView,
        ancestor: NSView
    ) -> Int {
        guard let storage = textView.textStorage, storage.length > 0,
            let textContainer = textView.textContainer,
            let layoutManager = textView.layoutManager,
            let backgroundRGB = textView.backgroundColor.usingColorSpace(.sRGB)
        else { return 0 }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: storage.length),
            actualCharacterRange: nil
        )
        var glyphRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        glyphRect.origin.x += textView.textContainerOrigin.x
        glyphRect.origin.y += textView.textContainerOrigin.y
        let visibleRect = glyphRect.intersection(textView.visibleRect).insetBy(dx: -2, dy: -2)
        let renderRect = textView.convert(visibleRect, to: ancestor).intersection(ancestor.bounds)
        var foregroundColors: [NSColor] = []
        storage.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: storage.length),
            options: [.longestEffectiveRangeNotRequired]
        ) { value, _, _ in
            guard let color = value as? NSColor,
                let rgb = color.usingColorSpace(.sRGB),
                rgb.alphaComponent > 0.5,
                self.colorDistance(rgb, backgroundRGB) > 0.3
            else { return }
            if !foregroundColors.contains(where: { self.colorDistance($0, rgb) < 0.01 }) {
                foregroundColors.append(rgb)
            }
        }
        guard !renderRect.isEmpty,
            !foregroundColors.isEmpty,
            let bitmap = ancestor.bitmapImageRepForCachingDisplay(in: renderRect)
        else { return 0 }

        ancestor.displayIfNeeded()
        ancestor.cacheDisplay(in: renderRect, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let distanceFromBackground = colorDistance(pixel, backgroundRGB)
                let distanceFromForeground =
                    foregroundColors.map { colorDistance(pixel, $0) }.min() ?? .infinity
                if distanceFromBackground > 0.18,
                    distanceFromForeground < distanceFromBackground * 0.9
                {
                    count += 1
                }
            }
        }
        return count
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let red = Double(lhs.redComponent - rhs.redComponent)
        let green = Double(lhs.greenComponent - rhs.greenComponent)
        let blue = Double(lhs.blueComponent - rhs.blueComponent)
        return (red * red + green * green + blue * blue).squareRoot()
    }
}

@MainActor
@Observable
private final class CodeEditorPromotionModel {
    var text = ""
    var language: LanguageID = .plainText
    var showsBuildOutput = false
}

private struct CodeEditorPromotionHarness: View {
    @Bindable var model: CodeEditorPromotionModel
    private let undoManager = UndoManager()

    var body: some View {
        VStack(spacing: 0) {
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

            if model.showsBuildOutput {
                Color(nsColor: .controlBackgroundColor)
                    .overlay(alignment: .topLeading) {
                        Text("Build output")
                            .padding(12)
                    }
                    .frame(height: 150)
                    .accessibilityIdentifier("latex-build-output-test-double")
            }
        }
    }
}
