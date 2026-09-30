import AppKit
import CoreModel
import SearchEngine
import SwiftUI

/// How much of the surface an overlay claims from the views behind it.
enum LiveTextSelectionMode: Equatable {
    /// Only recognized text takes the mouse, so empty canvas still reaches the
    /// layer tools underneath. Used where selection is always available.
    case overText
    /// The whole surface takes the mouse, so a drag selects text instead of
    /// moving whatever is behind it. Used where selection is explicitly armed.
    case wholeSurface
    /// Inert: clicks, hover, and the I-beam cursor all fall through.
    case off
}

/// A lightweight AppKit overlay so OCR selection participates in the native responder chain.
struct LiveTextOverlay: NSViewRepresentable {
    let spans: [OCRSpan]
    var selectionMode: LiveTextSelectionMode = .overText
    let onSearch: (String) -> Void
    let onRedact: ([NormalizedRect]) -> Void
    let onEdit: (String, [NormalizedRect]) -> Void

    func makeNSView(context: Context) -> LiveTextSelectionView {
        let view = LiveTextSelectionView()
        view.onSearch = onSearch
        view.onRedact = onRedact
        view.onEdit = onEdit
        view.selectionMode = selectionMode
        view.setSpans(spans)
        return view
    }

    func updateNSView(_ view: LiveTextSelectionView, context: Context) {
        view.onSearch = onSearch
        view.onRedact = onRedact
        view.onEdit = onEdit
        view.selectionMode = selectionMode
        // Rebuilding the text frame lays out every recognized span, and SwiftUI
        // calls this on any upstream re-evaluation — every frame while the rail
        // is being dragged. The spans only change when the frame does.
        guard view.spans != spans else { return }
        view.setSpans(spans)
    }
}

@MainActor
final class LiveTextSelectionView: NSView {
    var onSearch: (String) -> Void = { _ in }
    var onRedact: ([NormalizedRect]) -> Void = { _ in }
    var onEdit: (String, [NormalizedRect]) -> Void = { _, _ in }
    var pasteboard = NSPasteboard.general

    private var textFrame = LiveTextFrame(spans: [])
    private var selection: ClosedRange<Int>?
    private var selectionAnchor: Int?
    private var hoveredIndex: Int?
    private var tracking: NSTrackingArea?

    /// How much of the surface this overlay claims. Changing it re-evaluates the
    /// cursor, because an I-beam over text that cannot be selected reads as a bug.
    var selectionMode: LiveTextSelectionMode = .overText {
        didSet {
            guard selectionMode != oldValue else { return }
            if selectionMode == .off, hoveredIndex != nil {
                hoveredIndex = nil
                needsDisplay = true
            }
            window?.invalidateCursorRects(for: self)
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The spans this view was last given, so an unchanged update costs nothing.
    private(set) var spans: [OCRSpan] = []

    func setSpans(_ spans: [OCRSpan]) {
        self.spans = spans
        let next = LiveTextFrame(spans: spans)
        guard next != textFrame else { return }
        textFrame = next
        selection = nil
        selectionAnchor = nil
        hoveredIndex = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        setAccessibilityLabel("Live Text")
        setAccessibilityHelp(
            "Drag across recognized text to select it, then copy it or use the context menu to convert it into an editable layer."
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard selectionMode != .off, !isHidden, alphaValue > 0 else { return nil }
        // `point` arrives in the superview's coordinate space, while every rect
        // this view knows is in its own flipped bounds. Comparing the two
        // directly meant an overlay that sat anywhere but its superview's origin
        // never claimed a click, so selection fell through to the clip-drag
        // gesture behind it. Hover still worked, because tracking areas are
        // delivered to their owner without consulting hit testing.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if selectionMode == .wholeSurface { return self }
        if selectionAnchor != nil || regionIndex(at: local) != nil { return self }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard selectionMode != .off else { return }
        for index in textFrame.spans.indices {
            addCursorRect(displayRect(at: index).insetBy(dx: -2, dy: -2), cursor: .iBeam)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let next =
            selectionMode == .off
            ? nil : regionIndex(at: convert(event.locationInWindow, from: nil))
        guard next != hoveredIndex else { return }
        hoveredIndex = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        // Anchor to the nearest span even when the press lands between words, so
        // a drag that starts in whitespace still selects. The selection itself
        // only appears once the press is on text or the drag reaches some, which
        // keeps a plain click on empty canvas a deselect.
        let hit = regionIndex(at: point)
        selectionAnchor = hit ?? nearestRegionIndex(to: point)
        selection = hit.map { $0...$0 }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = selectionAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = regionIndex(at: point) ?? nearestRegionIndex(to: point)
        guard let target else { return }
        selection = min(anchor, target)...max(anchor, target)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        selectionAnchor = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.charactersIgnoringModifiers?.lowercased() == "c",
            modifiers.intersection([.command, .shift, .option, .control]) == [.command]
        else { return super.performKeyEquivalent(with: event) }
        copy(nil)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let index = regionIndex(at: point), selection?.contains(index) != true {
            selection = index...index
            needsDisplay = true
        }
        guard !selectedText.isEmpty else { return nil }

        let menu = NSMenu(title: "Live Text")
        menu.addItem(item("Copy", action: #selector(copy(_:))))
        menu.addItem(item("Copy All Text", action: #selector(copyAllText)))
        menu.addItem(item("Convert to Editable Text", action: #selector(editSelection)))
        menu.addItem(item("Search Library", action: #selector(searchSelection)))

        detectedURL = nil
        detectedEmail = nil
        let detected = LiveTextDetector.values(in: selectedText)
        if let url = detected.compactMap(\.url).first {
            menu.addItem(.separator())
            menu.addItem(item("Open Link", action: #selector(openDetectedURL)))
            detectedURL = url
        }
        if let email = detected.compactMap(\.email).first {
            if detectedURL == nil { menu.addItem(.separator()) }
            menu.addItem(item("New Email", action: #selector(composeDetectedEmail)))
            detectedEmail = email
        }
        menu.addItem(.separator())
        let redactTitle =
            detected.contains(.sensitive) ? "Redact Sensitive Text" : "Redact This Region"
        menu.addItem(item(redactTitle, action: #selector(redactSelection)))
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for index in textFrame.spans.indices {
            let isSelected = selection?.contains(index) == true
            let isHovered = hoveredIndex == index
            guard isSelected || isHovered else { continue }
            let rect = displayRect(at: index).insetBy(dx: -2, dy: -1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            (isSelected
                ? NSColor.systemBlue.withAlphaComponent(0.28)
                : NSColor.white.withAlphaComponent(0.12))
                .setFill()
            path.fill()
            (isSelected
                ? NSColor.systemBlue.withAlphaComponent(0.9)
                : NSColor.white.withAlphaComponent(0.48))
                .setStroke()
            path.lineWidth = isSelected ? 1.2 : 0.7
            path.stroke()
        }
    }

    private var detectedURL: URL?
    private var detectedEmail: String?

    private var selectedText: String {
        guard let selection else { return "" }
        return textFrame.text(in: selection)
    }

    private var selectedRegions: [NormalizedRect] {
        guard let selection else { return [] }
        return textFrame.regions(in: selection)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Standard responder-chain action used by the app's Edit > Copy command.
    @objc func copy(_ sender: Any?) {
        writeToPasteboard(selectedText)
    }

    /// Makes the standard Select All action useful while this overlay has focus.
    @objc override func selectAll(_ sender: Any?) {
        guard let first = textFrame.spans.indices.first,
            let last = textFrame.spans.indices.last
        else { return }
        selection = first...last
        needsDisplay = true
    }

    @objc private func copyAllText() {
        writeToPasteboard(textFrame.allText)
    }

    @objc private func searchSelection() {
        guard !selectedText.isEmpty else { return }
        onSearch(selectedText)
    }

    @objc private func redactSelection() {
        guard !selectedRegions.isEmpty else { return }
        onRedact(selectedRegions)
    }

    @objc private func editSelection() {
        guard !selectedText.isEmpty, !selectedRegions.isEmpty else { return }
        onEdit(selectedText, selectedRegions)
    }

    @objc private func openDetectedURL() {
        if let detectedURL { NSWorkspace.shared.open(detectedURL) }
    }

    @objc private func composeDetectedEmail() {
        guard let detectedEmail,
            let value = detectedEmail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "mailto:\(value)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func writeToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func regionIndex(at point: NSPoint) -> Int? {
        textFrame.spans.indices.first {
            displayRect(at: $0).insetBy(dx: -4, dy: -3).contains(point)
        }
    }

    private func nearestRegionIndex(to point: NSPoint) -> Int? {
        textFrame.spans.indices.min { lhs, rhs in
            distance(from: point, to: displayRect(at: lhs))
                < distance(from: point, to: displayRect(at: rhs))
        }
    }

    private func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
        let dy = max(rect.minY - point.y, point.y - rect.maxY, 0)
        return hypot(dx, dy)
    }

    private func displayRect(at index: Int) -> NSRect {
        let rect = LiveTextFrame.canvasRect(for: textFrame.spans[index].boundingBox)
        return NSRect(
            x: rect.x * bounds.width,
            y: rect.y * bounds.height,
            width: max(rect.width * bounds.width, 2),
            height: max(rect.height * bounds.height, 2)
        )
    }
}

extension LiveTextDetectedValue {
    fileprivate var url: URL? {
        guard case .url(let value) = self else { return nil }
        return value
    }

    fileprivate var email: String? {
        guard case .email(let value) = self else { return nil }
        return value
    }
}
