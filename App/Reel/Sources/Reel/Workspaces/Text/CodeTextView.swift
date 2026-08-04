import AppKit
import ReelAppCore

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
    private var findPanelController: CodeFindPanelController?

    override var undoManager: UndoManager? { providedUndoManager ?? super.undoManager }

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
        super.paste(sender)
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
        let indentation = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indentation.isEmpty { super.insertText(indentation, replacementRange: selectedRange()) }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let inserted = insertString as? String, inserted.utf16.count == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
        if let closing = pairs[inserted] {
            let selection = selectedRange()
            let selected = (string as NSString).substring(with: selection)
            super.insertText(inserted + selected + closing, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
            return
        }
        if pairs.values.contains(inserted) {
            let selection = selectedRange()
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

    private func apply(_ result: TextEditResult) {
        guard result.text != string else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let replacement = NSAttributedString(string: result.text, attributes: typingAttributes)
        guard performValidatedReplacement(in: fullRange, with: replacement) else { return }
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
