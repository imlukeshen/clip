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

    override var undoManager: UndoManager? { providedUndoManager ?? super.undoManager }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        if let currentLineRect {
            currentLineColor.setFill()
            currentLineRect.intersection(dirtyRect).fill()
        }
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
}
