import AppKit
import SwiftUI

/// In-place editor for a single PDF text object.
///
/// SwiftUI's `TextField` cannot be told where to put its caret, so a click on a
/// word could only ever select the whole object and retype it. `NSTextView`
/// exposes the insertion point, which is what lets a click land between two
/// characters and makes editing a page read like editing a document.
struct PDFInlineTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// The paragraph's original styling, applied once when editing opens.
    ///
    /// A paragraph is rarely one face: the runs the PDF split apart carry their
    /// own fonts and colours. Seeding the storage with them keeps a bold phrase
    /// bold while it is being edited, and typing inherits the styling around
    /// the caret the way a word processor does.
    let attributed: NSAttributedString
    let caretOffset: Int?
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> PDFInlineTextView {
        let view = PDFInlineTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.size = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateNSView(_ view: PDFInlineTextView, context: Context) {
        view.onCommit = onCommit
        view.onCancel = onCancel

        guard !context.coordinator.hasPlacedCaret else {
            // Never restyle mid-session: replacing the storage while someone is
            // typing would drop their selection and undo stack.
            if view.string != text { view.string = text }
            view.invalidateIntrinsicContentSize()
            return
        }
        context.coordinator.hasPlacedCaret = true
        view.textStorage?.setAttributedString(attributed)
        view.invalidateIntrinsicContentSize()
        let length = (view.string as NSString).length
        let offset = min(max(caretOffset ?? length, 0), length)
        view.setSelectedRange(NSRange(location: offset, length: 0))
        Task { @MainActor in view.window?.makeFirstResponder(view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: PDFInlineTextEditor
        var hasPlacedCaret = false

        init(_ parent: PDFInlineTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}
