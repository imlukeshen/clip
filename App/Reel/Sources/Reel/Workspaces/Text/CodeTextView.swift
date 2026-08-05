import AppKit
import CoreModel
import ReelAppCore
import TextEngine

@MainActor
final class CodeTextView: NSTextView {
    weak var providedUndoManager: UndoManager?
    var currentLineColor = NSColor.clear
    var invisibleMarkerColor = NSColor.secondaryLabelColor
    var commentPrefix = "//"
    var commentSuffix = ""
    var tabWidth = 4
    var showsInvisibleMarkers = false
    var lineIndex = TextLineIndex()
    var onSave: (String) -> Void = { _ in }
    var onLargePaste: () -> Void = {}
    var onPasteRefused: () -> Void = {}
    var onPasteIntoEmptyBuffer: (String) -> Void = { _ in }
    var snippetLanguage: LanguageID = .plainText
    var snippetFileName = "Untitled.txt"
    var onSnippetNotice: (String) -> Void = { _ in }
    var onCompositionCommit: () -> Void = {}
    private var findPanelController: CodeFindPanelController?

    override var undoManager: UndoManager? { providedUndoManager ?? super.undoManager }

    override func unmarkText() {
        let wasComposing = hasMarkedText()
        super.unmarkText()
        guard wasComposing else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !hasMarkedText() else { return }
            onCompositionCommit()
        }
    }

    override func paste(_ sender: Any?) {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let byteCount = value.lengthOfBytes(using: .utf8)
        guard byteCount <= 20 * 1024 * 1024 else {
            NSSound.beep()
            onPasteRefused()
            return
        }
        let wasEmpty = string.isEmpty
        let selection = selectedRange()
        if byteCount <= 2 * 1024 * 1024,
            snippetLanguage == .markdown,
            !MarkdownEditingIntelligence.isInsideFencedCode(
                location: selection.location,
                in: string
            ),
            let detection = MarkdownEditingIntelligence.detectCodePaste(in: value)
        {
            apply(
                MarkdownFormattingOperations.insertingCodeBlock(
                    contents: value,
                    language: detection.language,
                    into: string,
                    selectedRange: selection
                )
            )
            onSnippetNotice(
                "Detected \(detection.language.rawValue.capitalized) and inserted a code block."
            )
        } else {
            super.paste(sender)
        }
        if wasEmpty { onPasteIntoEmptyBuffer(value) }
        if byteCount > 2 * 1024 * 1024 {
            isEditable = false
            onLargePaste()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        if let currentLineRect {
            currentLineColor.setFill()
            currentLineRect.intersection(dirtyRect).fill()
        }
        drawBracketMatches(in: dirtyRect)
        super.draw(dirtyRect)
        if showsInvisibleMarkers {
            drawInvisibleMarkers(in: dirtyRect)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: caret, length: 0))
        let beforeCaret = source.substring(
            with: NSRange(location: lineRange.location, length: caret - lineRange.location)
        )
        if snippetLanguage == .markdown, let list = markdownContinuation(for: beforeCaret) {
            if list.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let removal = NSRange(
                    location: lineRange.location + list.markerRange.location,
                    length: list.markerRange.length
                )
                let updated = source.replacingCharacters(in: removal, with: "")
                apply(
                    TextEditResult(
                        text: updated,
                        selectedRange: NSRange(location: removal.location, length: 0)
                    )
                )
                return
            }
            super.insertNewline(sender)
            super.insertText(list.continuation, replacementRange: selectedRange())
            return
        }
        let indentation = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indentation.isEmpty { super.insertText(indentation, replacementRange: selectedRange()) }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if snippetLanguage == .markdown, !hasMarkedText(), selection.length == 0 {
            let document = MarkdownBlockDocumentEngine.reconcile(source: string)
            if let block = document.block(containingUTF16: selection.location),
                block.kind.removesMarkdownMarkerOnBackspace,
                selection.location == block.contentRange.location,
                let marker = block.syntaxRanges.last,
                marker.length > 0
            {
                let source = string as NSString
                let updated = source.replacingCharacters(in: marker, with: "")
                apply(
                    TextEditResult(
                        text: updated,
                        selectedRange: NSRange(location: marker.location, length: 0)
                    )
                )
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) {
        guard snippetLanguage == .markdown, !hasMarkedText() else {
            super.insertTab(sender)
            return
        }
        apply(
            TextEditingOperations.indent(
                in: string,
                selectedRange: selectedRange(),
                width: tabWidth
            )
        )
    }

    override func insertBacktab(_ sender: Any?) {
        guard snippetLanguage == .markdown, !hasMarkedText() else {
            super.insertBacktab(sender)
            return
        }
        apply(
            TextEditingOperations.outdent(
                in: string,
                selectedRange: selectedRange(),
                width: tabWidth
            )
        )
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let inserted = insertString as? String else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard !hasMarkedText() else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard inserted.utf16.count == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let sourceLength = (string as NSString).length
        let selection =
            replacementRange.location == NSNotFound
            ? selectedRange()
            : NSRange(
                location: min(max(replacementRange.location, 0), sourceLength),
                length: min(
                    max(replacementRange.length, 0),
                    max(sourceLength - min(max(replacementRange.location, 0), sourceLength), 0)
                )
            )
        if snippetLanguage == .markdown,
            !MarkdownEditingIntelligence.isInsideFencedCode(
                location: selection.location,
                in: string
            ),
            let prepared = MarkdownFormattingOperations.preparingTypedInsertion(
                inserted,
                in: string,
                selectedRange: selection
            )
        {
            apply(prepared)
            return
        }
        let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
        if let closing = pairs[inserted] {
            let selected = (string as NSString).substring(with: selection)
            super.insertText(inserted + selected + closing, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
            return
        }
        if pairs.values.contains(inserted) {
            let source = string as NSString
            if selection.length == 0, selection.location < source.length,
                source.substring(with: NSRange(location: selection.location, length: 1)) == inserted
            {
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                return
            }
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if snippetLanguage == .markdown, flags == .command, key == "b" {
            performMarkdown(.bold, notice: "Bold formatting applied.")
            return true
        }
        if snippetLanguage == .markdown, flags == .command, key == "i" {
            performMarkdown(.italic, notice: "Italic formatting applied.")
            return true
        }
        if snippetLanguage == .markdown, flags == [.command, .shift], key == "x" {
            performMarkdown(.strikethrough, notice: "Strikethrough formatting applied.")
            return true
        }
        if flags == .command, key == "f" {
            presentFindReplace()
            return true
        }
        if flags == .command, key == "g" {
            presentFindReplace()
            findPanelController?.findNextFromEditor()
            return true
        }
        if flags == .command, key == "s" {
            onSave(string)
            return true
        }
        if flags == .command, key == "/" {
            apply(
                TextEditingOperations.toggleComment(
                    in: string,
                    selectedRange: selectedRange(),
                    prefix: commentPrefix,
                    suffix: commentSuffix
                ))
            return true
        }
        if flags == .command, key == "]" {
            apply(
                TextEditingOperations.indent(
                    in: string,
                    selectedRange: selectedRange(),
                    width: tabWidth
                ))
            return true
        }
        if flags == .command, key == "[" {
            apply(
                TextEditingOperations.outdent(
                    in: string,
                    selectedRange: selectedRange(),
                    width: tabWidth
                ))
            return true
        }
        if flags == [.command, .shift], key == "d" {
            apply(
                TextEditingOperations.duplicateLine(
                    in: string,
                    selectedRange: selectedRange()
                ))
            return true
        }
        if flags == .option, event.keyCode == 126 {
            apply(
                TextEditingOperations.moveLine(
                    in: string,
                    selectedRange: selectedRange(),
                    direction: .up
                ))
            return true
        }
        if flags == .option, event.keyCode == 125 {
            apply(
                TextEditingOperations.moveLine(
                    in: string,
                    selectedRange: selectedRange(),
                    direction: .down
                ))
            return true
        }
        if flags == .command, key == "l" {
            presentGoToLine()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if snippetLanguage == .markdown {
            menu.addItem(.separator())
            addSnippetItem("Bold", action: #selector(markdownBold(_:)), to: menu)
            addSnippetItem("Italic", action: #selector(markdownItalic(_:)), to: menu)
            addSnippetItem("Add Link", action: #selector(markdownLink(_:)), to: menu)
            addSnippetItem("Turn into Heading", action: #selector(markdownHeading2(_:)), to: menu)
        }
        menu.addItem(.separator())
        addSnippetItem("Copy as Rich Text", action: #selector(copyAsRichText(_:)), to: menu)
        addSnippetItem("Copy as HTML", action: #selector(copyAsHTML(_:)), to: menu)
        addSnippetItem(
            "Copy with Line Numbers", action: #selector(copyWithLineNumbers(_:)), to: menu)
        addSnippetItem("Copy with File and Lines", action: #selector(copyAnnotated(_:)), to: menu)
        menu.addItem(.separator())
        addSnippetItem("Wrap in Code Fence", action: #selector(wrapInCodeFence(_:)), to: menu)
        return menu
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyAsRichText(_:)),
            #selector(copyAsHTML(_:)),
            #selector(copyWithLineNumbers(_:)),
            #selector(copyAnnotated(_:)):
            return selectedRange().length > 0
        case #selector(wrapInCodeFence(_:)):
            return isEditable && selectedRange().length > 0
        case #selector(markdownBody(_:)),
            #selector(markdownHeading1(_:)),
            #selector(markdownHeading2(_:)),
            #selector(markdownHeading3(_:)),
            #selector(markdownHeading4(_:)),
            #selector(markdownHeading5(_:)),
            #selector(markdownHeading6(_:)),
            #selector(markdownBold(_:)),
            #selector(markdownItalic(_:)),
            #selector(markdownStrikethrough(_:)),
            #selector(markdownInlineCode(_:)),
            #selector(markdownLink(_:)),
            #selector(markdownBulletedList(_:)),
            #selector(markdownNumberedList(_:)),
            #selector(markdownChecklist(_:)),
            #selector(markdownQuote(_:)),
            #selector(markdownCodeBlock(_:)),
            #selector(markdownImage(_:)),
            #selector(markdownTable(_:)),
            #selector(markdownFootnote(_:)),
            #selector(markdownInlineMath(_:)),
            #selector(markdownMathBlock(_:)),
            #selector(markdownDivider(_:)):
            return isEditable && snippetLanguage == .markdown
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    @objc func markdownBody(_ sender: Any?) {
        performMarkdown(.body, notice: "Changed to body text.")
    }

    @objc func markdownHeading1(_ sender: Any?) {
        performMarkdown(.heading1, notice: "Changed to heading 1.")
    }

    @objc func markdownHeading2(_ sender: Any?) {
        performMarkdown(.heading2, notice: "Changed to heading 2.")
    }

    @objc func markdownHeading3(_ sender: Any?) {
        performMarkdown(.heading3, notice: "Changed to heading 3.")
    }

    @objc func markdownHeading4(_ sender: Any?) {
        performMarkdown(.heading4, notice: "Changed to heading 4.")
    }

    @objc func markdownHeading5(_ sender: Any?) {
        performMarkdown(.heading5, notice: "Changed to heading 5.")
    }

    @objc func markdownHeading6(_ sender: Any?) {
        performMarkdown(.heading6, notice: "Changed to heading 6.")
    }

    @objc func markdownBold(_ sender: Any?) {
        performMarkdown(.bold, notice: "Bold formatting applied.")
    }

    @objc func markdownItalic(_ sender: Any?) {
        performMarkdown(.italic, notice: "Italic formatting applied.")
    }

    @objc func markdownStrikethrough(_ sender: Any?) {
        performMarkdown(.strikethrough, notice: "Strikethrough formatting applied.")
    }

    @objc func markdownInlineCode(_ sender: Any?) {
        performMarkdown(.inlineCode, notice: "Inline code formatting applied.")
    }

    @objc func markdownLink(_ sender: Any?) {
        performMarkdown(.link, notice: "Link inserted. Paste or type its destination.")
    }

    @objc func markdownBulletedList(_ sender: Any?) {
        performMarkdown(.bulletedList, notice: "Bulleted list formatting applied.")
    }

    @objc func markdownNumberedList(_ sender: Any?) {
        performMarkdown(.numberedList, notice: "Numbered list formatting applied.")
    }

    @objc func markdownChecklist(_ sender: Any?) {
        performMarkdown(.checklist, notice: "Checklist formatting applied.")
    }

    @objc func markdownQuote(_ sender: Any?) {
        performMarkdown(.quote, notice: "Quote formatting applied.")
    }

    @objc func markdownCodeBlock(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0 {
            let contents = (string as NSString).substring(with: selection)
            if let detection = MarkdownEditingIntelligence.detectCodePaste(in: contents) {
                apply(
                    MarkdownFormattingOperations.insertingCodeBlock(
                        contents: contents,
                        language: detection.language,
                        into: string,
                        selectedRange: selection
                    )
                )
                onSnippetNotice(
                    "Inserted a \(detection.language.rawValue.capitalized) code block."
                )
                window?.makeFirstResponder(self)
                return
            }
        }
        performMarkdown(.codeBlock, notice: "Code block inserted.")
    }

    @objc func markdownImage(_ sender: Any?) {
        performMarkdown(.image, notice: "Image reference inserted.")
    }

    @objc func markdownTable(_ sender: Any?) {
        performMarkdown(.table, notice: "Table inserted.")
    }

    @objc func markdownFootnote(_ sender: Any?) {
        performMarkdown(.footnote, notice: "Footnote inserted.")
    }

    @objc func markdownInlineMath(_ sender: Any?) {
        performMarkdown(.inlineMath, notice: "Inline math formatting applied.")
    }

    @objc func markdownMathBlock(_ sender: Any?) {
        performMarkdown(.mathBlock, notice: "Math block inserted.")
    }

    @objc func markdownDivider(_ sender: Any?) {
        performMarkdown(.divider, notice: "Divider inserted.")
    }

    @objc func copyAsRichText(_ sender: Any?) {
        guard let attributed = selectedAttributedString(),
            let data = TextSnippetOperations.richTextData(
                from: attributed,
                backgroundColor: backgroundColor
            )
        else {
            rejectEmptySnippet()
            return
        }
        writeToPasteboard(string: attributed.string, data: data, type: .rtf)
        onSnippetNotice("Copied rich text with syntax colors.")
    }

    @objc func copyAsHTML(_ sender: Any?) {
        guard let attributed = selectedAttributedString() else {
            rejectEmptySnippet()
            return
        }
        let html = TextSnippetOperations.htmlFragment(
            from: attributed,
            backgroundColor: backgroundColor
        )
        writeToPasteboard(
            string: attributed.string,
            data: Data(html.utf8),
            type: .html
        )
        onSnippetNotice("Copied an inline-styled HTML snippet.")
    }

    @objc func copyWithLineNumbers(_ sender: Any?) {
        guard
            let value = TextSnippetOperations.copyWithLineNumbers(
                in: string,
                selectedRange: selectedRange()
            )
        else {
            rejectEmptySnippet()
            return
        }
        writePlainText(value)
        onSnippetNotice("Copied with line numbers.")
    }

    @objc func copyAnnotated(_ sender: Any?) {
        guard
            let value = TextSnippetOperations.annotatedSelection(
                in: string,
                selectedRange: selectedRange(),
                fileName: snippetFileName
            )
        else {
            rejectEmptySnippet()
            return
        }
        writePlainText(value)
        onSnippetNotice("Copied with file and line context.")
    }

    @objc func wrapInCodeFence(_ sender: Any?) {
        guard isEditable,
            let result = TextSnippetOperations.wrappingSelectionInCodeFence(
                in: string,
                selectedRange: selectedRange(),
                language: snippetLanguage
            )
        else {
            rejectEmptySnippet()
            return
        }
        apply(result)
        onSnippetNotice("Wrapped the selection in a code fence.")
    }

    private var currentLineRect: NSRect? {
        guard let window else { return nil }
        let source = string as NSString
        let location = min(selectedRange().location, source.length)
        let characterRange = NSRange(
            location: location,
            length: location < source.length ? 1 : 0
        )
        var actual = NSRange()
        let screenRect = firstRect(forCharacterRange: characterRange, actualRange: &actual)
        let local = convert(window.convertFromScreen(screenRect), from: nil)
        return NSRect(x: 0, y: local.minY, width: bounds.width, height: local.height)
    }

    private func addSnippetItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func selectedAttributedString() -> NSAttributedString? {
        let selection = selectedRange()
        guard selection.length > 0, let textStorage,
            NSMaxRange(selection) <= textStorage.length
        else { return nil }
        return textStorage.attributedSubstring(from: selection)
    }

    private func writePlainText(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func writeToPasteboard(
        string: String,
        data: Data,
        type: NSPasteboard.PasteboardType
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setData(data, forType: type)
    }

    private func rejectEmptySnippet() {
        NSSound.beep()
        onSnippetNotice("Select text before using a snippet command.")
    }

    private func performMarkdown(_ action: MarkdownFormattingAction, notice: String) {
        guard isEditable, snippetLanguage == .markdown else {
            NSSound.beep()
            return
        }
        apply(
            MarkdownFormattingOperations.apply(
                action,
                to: string,
                selectedRange: selectedRange()
            )
        )
        onSnippetNotice(notice)
        window?.makeFirstResponder(self)
    }

    private func markdownContinuation(
        for line: String
    ) -> (continuation: String, markerRange: NSRange, content: String)? {
        let patterns: [(String, (NSTextCheckingResult, NSString) -> String)] = [
            (
                "^([ \\t]*)[-+*][ \\t]+\\[[ xX]\\][ \\t]+(.*)$",
                { match, source in
                    source.substring(with: match.range(at: 1)) + "- [ ] "
                }
            ),
            (
                "^([ \\t]*)([0-9]+)\\.[ \\t]+(.*)$",
                { match, source in
                    let indentation = source.substring(with: match.range(at: 1))
                    let number = Int(source.substring(with: match.range(at: 2))) ?? 0
                    return indentation + "\(number + 1). "
                }
            ),
            (
                "^([ \\t]*)[-+*][ \\t]+(.*)$",
                { match, source in
                    source.substring(with: match.range(at: 1)) + "- "
                }
            ),
            (
                "^([ \\t]*)>[ \\t]+(.*)$",
                { match, source in
                    source.substring(with: match.range(at: 1)) + "> "
                }
            ),
        ]
        let source = line as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        for (pattern, continuation) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                let match = expression.firstMatch(in: line, range: fullRange)
            else { continue }
            let contentGroup = match.numberOfRanges - 1
            let contentRange = match.range(at: contentGroup)
            let indentationRange = match.range(at: 1)
            let markerRange = NSRange(
                location: NSMaxRange(indentationRange),
                length: contentRange.location - NSMaxRange(indentationRange)
            )
            return (
                continuation(match, source),
                markerRange,
                source.substring(with: contentRange)
            )
        }
        return nil
    }

    private func apply(_ result: TextEditResult) {
        guard result.text != string else { return }
        let current = string as NSString
        let updated = result.text as NSString
        var commonPrefix = 0
        while commonPrefix < current.length, commonPrefix < updated.length,
            current.character(at: commonPrefix) == updated.character(at: commonPrefix)
        {
            commonPrefix += 1
        }
        var commonSuffix = 0
        while commonSuffix < current.length - commonPrefix,
            commonSuffix < updated.length - commonPrefix,
            current.character(at: current.length - commonSuffix - 1)
                == updated.character(at: updated.length - commonSuffix - 1)
        {
            commonSuffix += 1
        }
        let changedRange = NSRange(
            location: commonPrefix,
            length: current.length - commonPrefix - commonSuffix
        )
        let replacementRange = NSRange(
            location: commonPrefix,
            length: updated.length - commonPrefix - commonSuffix
        )
        let replacement = NSAttributedString(
            string: updated.substring(with: replacementRange),
            attributes: typingAttributes
        )
        guard performValidatedReplacement(in: changedRange, with: replacement) else { return }
        setSelectedRange(result.selectedRange)
    }

    private func presentGoToLine() {
        guard let window else { return }
        let field = NSTextField(string: "")
        field.placeholderString = "Line number"
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let line = Int(field.stringValue) else {
                return
            }
            self?.moveCaret(toLine: line)
        }
    }

    private func presentFindReplace() {
        guard let window else { return }
        if findPanelController == nil {
            findPanelController = CodeFindPanelController(textView: self)
        }
        findPanelController?.show(relativeTo: window)
    }

    private func moveCaret(toLine requestedLine: Int) {
        let location = lineIndex.location(ofLine: requestedLine)
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private func drawInvisibleMarkers(in dirtyRect: NSRect) {
        guard let window, let font else { return }
        let source = string as NSString
        let visible = visibleRect.intersection(dirtyRect)
        let first = min(
            characterIndexForInsertion(at: NSPoint(x: visible.minX, y: visible.minY)),
            source.length
        )
        let last = min(
            characterIndexForInsertion(at: NSPoint(x: visible.maxX, y: visible.maxY)) + 1,
            min(source.length, first + 8_000)
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: invisibleMarkerColor,
        ]
        var markersDrawn = 0
        for location in first..<last {
            let scalar = source.character(at: location)
            let marker: NSString
            switch scalar {
            case 0x20: marker = "·"
            case 0x09: marker = "→"
            case 0x0A, 0x0D: marker = "↵"
            default: continue
            }
            var actual = NSRange()
            let screenRect = firstRect(
                forCharacterRange: NSRange(location: location, length: 1),
                actualRange: &actual
            )
            let localRect = convert(window.convertFromScreen(screenRect), from: nil)
            guard localRect.intersects(visible) else { continue }
            marker.draw(at: localRect.origin, withAttributes: attributes)
            markersDrawn += 1
            if markersDrawn == 1_200 { break }
        }
    }

    private func drawBracketMatches(in dirtyRect: NSRect) {
        guard window != nil else { return }
        let ranges = TextEditingOperations.matchingBracketRanges(
            in: string,
            caretLocation: selectedRange().location
        )
        guard !ranges.isEmpty else { return }
        insertionPointColor.withAlphaComponent(0.22).setFill()
        for range in ranges {
            guard let rect = localRect(for: range) else { continue }
            rect.insetBy(dx: -1, dy: 0).intersection(dirtyRect).fill()
        }
    }

    private func localRect(for range: NSRange) -> NSRect? {
        guard let window else { return nil }
        var actual = NSRange()
        let screenRect = firstRect(forCharacterRange: range, actualRange: &actual)
        return convert(window.convertFromScreen(screenRect), from: nil)
    }
}

extension MarkdownBlockKind {
    fileprivate var removesMarkdownMarkerOnBackspace: Bool {
        switch self {
        case .heading, .bulletedListItem, .numberedListItem, .taskItem, .quote, .paragraph:
            true
        case .fencedCode, .math, .divider, .table, .empty, .raw:
            false
        }
    }
}

@MainActor
private final class CodeFindPanelController: NSObject, NSWindowDelegate {
    private weak var textView: CodeTextView?
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let regexButton = NSButton(
        checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var panel = makePanel()

    init(textView: CodeTextView) {
        self.textView = textView
        super.init()
    }

    func show(relativeTo parent: NSWindow) {
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(findField)
    }

    func findNextFromEditor() {
        findNext(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel.parent?.removeChildWindow(panel)
        textView?.window?.makeFirstResponder(textView)
    }

    @objc private func findNext(_ sender: Any?) {
        guard let textView, let matches = matches(in: textView.string), !matches.isEmpty else {
            return
        }
        let selectionEnd = NSMaxRange(textView.selectedRange())
        let match = matches.first { $0.location >= selectionEnd } ?? matches[0]
        textView.setSelectedRange(match)
        textView.scrollRangeToVisible(match)
        textView.showFindIndicator(for: match)
        let position = (matches.firstIndex(of: match) ?? 0) + 1
        setStatus("\(position) of \(matches.count)", isError: false)
    }

    @objc private func replaceSelection(_ sender: Any?) {
        guard let textView, let matches = matches(in: textView.string) else { return }
        let selection = textView.selectedRange()
        guard matches.contains(selection) else {
            findNext(sender)
            return
        }
        guard let replacement = replacement(for: selection, in: textView.string) else { return }
        let attributed = NSAttributedString(
            string: replacement, attributes: textView.typingAttributes)
        guard textView.performValidatedReplacement(in: selection, with: attributed) else { return }
        textView.setSelectedRange(
            NSRange(location: selection.location + replacement.utf16.count, length: 0)
        )
        findNext(sender)
    }

    @objc private func replaceAll(_ sender: Any?) {
        guard let textView, let ranges = matches(in: textView.string), !ranges.isEmpty else {
            return
        }
        let source = textView.string
        let updated: String
        if usesRegularExpression {
            guard let expression = expression() else { return }
            updated = expression.stringByReplacingMatches(
                in: source,
                range: NSRange(location: 0, length: (source as NSString).length),
                withTemplate: replaceField.stringValue
            )
        } else {
            let mutable = NSMutableString(string: source)
            for range in ranges.reversed() {
                mutable.replaceCharacters(in: range, with: replaceField.stringValue)
            }
            updated = mutable as String
        }
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let attributed = NSAttributedString(string: updated, attributes: textView.typingAttributes)
        guard textView.performValidatedReplacement(in: fullRange, with: attributed) else { return }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setStatus("Replaced \(ranges.count) matches", isError: false)
    }

    @objc private func closePanel(_ sender: Any?) {
        panel.close()
    }

    private var usesRegularExpression: Bool { regexButton.state == .on }

    private func matches(in text: String) -> [NSRange]? {
        do {
            let matches = try TextEditingOperations.matchingRanges(
                in: text,
                query: findField.stringValue,
                usesRegularExpression: usesRegularExpression
            )
            if matches.isEmpty {
                setStatus(
                    findField.stringValue.isEmpty ? "Enter text to find" : "No matches",
                    isError: false)
            }
            return matches
        } catch {
            setStatus("Invalid regular expression", isError: true)
            return nil
        }
    }

    private func replacement(for range: NSRange, in source: String) -> String? {
        guard usesRegularExpression else { return replaceField.stringValue }
        guard let expression = expression(),
            let match = expression.firstMatch(in: source, range: range), match.range == range
        else { return nil }
        return expression.replacementString(
            for: match,
            in: source,
            offset: 0,
            template: replaceField.stringValue
        )
    }

    private func expression() -> NSRegularExpression? {
        do {
            return try NSRegularExpression(
                pattern: findField.stringValue,
                options: [.caseInsensitive]
            )
        } catch {
            setStatus("Invalid regular expression", isError: true)
            return nil
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 198),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Find and Replace"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.setAccessibilityIdentifier("text-find-replace-panel")

        findField.placeholderString = "Find"
        findField.setAccessibilityIdentifier("text-find-field")
        replaceField.placeholderString = "Replace with"
        replaceField.setAccessibilityIdentifier("text-replace-field")
        regexButton.setAccessibilityIdentifier("text-find-regex")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        let findRow = fieldRow(title: "Find", field: findField)
        let replaceRow = fieldRow(title: "Replace", field: replaceField)
        let buttons = NSStackView(views: [
            actionButton("Find Next", action: #selector(findNext(_:)), keyEquivalent: "\r"),
            actionButton("Replace", action: #selector(replaceSelection(_:))),
            actionButton("Replace All", action: #selector(replaceAll(_:))),
            actionButton("Done", action: #selector(closePanel(_:)), keyEquivalent: "\u{1b}"),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let footer = NSStackView(views: [statusLabel, NSView(), buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [findRow, replaceRow, regexButton, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let contentView = panel.contentView else { return panel }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            findRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            replaceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return panel
    }

    private func fieldRow(title: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        return row
    }

    private func actionButton(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = keyEquivalent
        return button
    }
}
