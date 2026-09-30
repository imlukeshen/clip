import AppKit

/// Text view backing the in-place PDF editor.
///
/// Return commits the edit the way closing a field would, because a PDF text
/// object is usually a single run and a stray newline would be written into the
/// page. Shift-Return still inserts one for the rare multi-line object, and
/// Escape abandons the edit without touching the document.
final class PDFInlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Height of the text as actually laid out.
    ///
    /// `NSTextView` reports no intrinsic height on its own, so a SwiftUI parent
    /// asking it to size itself vertically gets a meaningless value and places
    /// the view off the line it is editing. Measuring the used rect keeps the
    /// overlay locked to the glyphs underneath and lets it grow as text wraps.
    override var intrinsicContentSize: NSSize {
        guard let textContainer, let layoutManager else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    /// Commits when focus leaves.
    ///
    /// The SwiftUI field this replaced committed through `FocusState`, which an
    /// `NSTextView` never drives: clicking anywhere outside the page left the
    /// draft uncommitted and the edit was lost on save.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onCommit?() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isEscape = event.keyCode == 53
        if isEscape {
            onCancel?()
            return
        }
        if isReturn, !event.modifierFlags.contains(.shift) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}
