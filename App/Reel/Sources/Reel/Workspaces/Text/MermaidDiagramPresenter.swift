import AppKit
import TextEngine

/// Shows each Mermaid block's rendered diagram directly under its closing fence.
///
/// The source stays plain text the person edits. Below it, the closing fence
/// line gets extra paragraph spacing exactly as tall as the diagram, and an
/// image view is placed in that gap, so the text above and below flows around
/// the diagram without the document ever containing it. A definition that
/// does not parse shows Mermaid's error in the same place instead.
@MainActor
final class MermaidDiagramPresenter {
    /// Colours and shape taken from the editor's theme.
    struct Style: Equatable {
        var card: NSColor
        var error: NSColor
        var muted: NSColor
        var cornerRadius: CGFloat
        var font: NSFont
    }

    var style: Style?
    private var views: [NSView] = []
    private var pendingRequests: Set<MermaidRenderer.Request> = []
    private static let gap: CGFloat = 10
    private static let cardPadding: CGFloat = 12
    private static let pendingHeight: CGFloat = 28

    /// Reserves space for every diagram in `textView` and positions its view.
    ///
    /// - Parameter applyAttributes: Runs a storage edit the way the caller's
    ///   own styling pass does, so it is not mistaken for a user edit.
    func layout(
        in textView: NSTextView,
        isMarkdown: Bool,
        applyAttributes: (() -> Void) -> Void
    ) {
        guard isMarkdown, let style, let storage = textView.textStorage,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else {
            removeViews(from: 0)
            return
        }
        let diagrams = MermaidDiagram.diagrams(in: textView.string)
        guard !diagrams.isEmpty else {
            removeViews(from: 0)
            return
        }
        let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contentWidth = container.size.width - container.lineFragmentPadding * 2
        let maximumWidth = Int(max(contentWidth - Self.cardPadding * 2, 120))
        let background = Self.css(for: style.card, in: textView.effectiveAppearance)

        var placements: [(diagram: MermaidDiagram, outcome: MermaidRenderer.Outcome?)] = []
        for diagram in diagrams {
            let request = MermaidRenderer.Request(
                source: diagram.source,
                isDark: isDark,
                maximumWidth: maximumWidth,
                background: background
            )
            let outcome = MermaidRenderer.shared.cached(request)
            if outcome == nil { scheduleRender(request, for: textView) }
            placements.append((diagram, outcome))
        }

        applyAttributes {
            for placement in placements {
                let range = placement.diagram.closingFenceRange
                guard NSMaxRange(range) <= storage.length else { continue }
                let spacing = Self.cardHeight(for: placement.outcome, style: style) + Self.gap * 2
                let current =
                    storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle ?? NSParagraphStyle.default
                guard abs(current.paragraphSpacing - spacing) > 0.5,
                    let paragraph = current.mutableCopy() as? NSMutableParagraphStyle
                else { continue }
                paragraph.paragraphSpacing = spacing
                let line = (storage.string as NSString).lineRange(for: range)
                storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
            }
        }
        layoutManager.ensureLayout(for: container)

        let origin = textView.textContainerOrigin
        for (index, placement) in placements.enumerated() {
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: placement.diagram.closingFenceRange,
                actualCharacterRange: nil
            )
            guard glyphs.length > 0 else { continue }
            let used = layoutManager.lineFragmentUsedRect(
                forGlyphAt: NSMaxRange(glyphs) - 1,
                effectiveRange: nil
            )
            let height = Self.cardHeight(for: placement.outcome, style: style)
            let frame = NSRect(
                x: origin.x + container.lineFragmentPadding,
                y: origin.y + used.maxY + Self.gap,
                width: contentWidth,
                height: height
            )
            let view = view(at: index, in: textView)
            view.frame = frame
            configure(
                view, for: placement.outcome, style: style, appearance: textView.effectiveAppearance
            )
        }
        removeViews(from: placements.count)
    }

    private func scheduleRender(_ request: MermaidRenderer.Request, for textView: NSTextView) {
        guard pendingRequests.insert(request).inserted else { return }
        Task { [weak self, weak textView] in
            _ = await MermaidRenderer.shared.render(request)
            guard let self else { return }
            pendingRequests.remove(request)
            guard let textView else { return }
            // Ask the editor for a fresh pass so spacing and position follow.
            textView.needsLayout = true
            NotificationCenter.default.post(
                name: Self.diagramDidRender,
                object: textView
            )
        }
    }

    /// Posted with the text view as its object when a diagram finishes rendering.
    static let diagramDidRender = Notification.Name("MermaidDiagramPresenter.diagramDidRender")

    private static func cardHeight(for outcome: MermaidRenderer.Outcome?, style: Style) -> CGFloat {
        switch outcome {
        case .image(let image): image.size.height + cardPadding * 2
        case .failure: ceil(style.font.boundingRectForFont.height * 1.4) + cardPadding
        case nil: pendingHeight
        }
    }

    private func view(at index: Int, in textView: NSTextView) -> MermaidDiagramCard {
        if index < views.count, let card = views[index] as? MermaidDiagramCard {
            if card.superview !== textView { textView.addSubview(card) }
            return card
        }
        let card = MermaidDiagramCard()
        textView.addSubview(card)
        views.append(card)
        return card
    }

    private func configure(
        _ view: MermaidDiagramCard,
        for outcome: MermaidRenderer.Outcome?,
        style: Style,
        appearance: NSAppearance
    ) {
        view.wantsLayer = true
        // A layer colour is a fixed value, so resolve the dynamic theme colour
        // in the editor's appearance rather than whatever is current.
        var card = style.card.cgColor
        appearance.performAsCurrentDrawingAppearance { card = style.card.cgColor }
        view.layer?.backgroundColor = card
        view.layer?.cornerRadius = style.cornerRadius
        switch outcome {
        case .image(let image):
            view.show(image: image, padding: Self.cardPadding)
        case .failure(let message):
            view.show(
                message: "Diagram error: \(message)",
                color: style.error,
                font: style.font,
                padding: Self.cardPadding
            )
        case nil:
            view.show(
                message: "Rendering diagram…", color: style.muted, font: style.font,
                padding: Self.cardPadding)
        }
    }

    private func removeViews(from index: Int) {
        guard index < views.count else { return }
        views[index...].forEach { $0.removeFromSuperview() }
        views.removeSubrange(index...)
    }

    /// An opaque CSS colour for `color` as it appears in `appearance`.
    private static func css(for color: NSColor, in appearance: NSAppearance) -> String {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        let red = Int((resolved.redComponent * 255).rounded())
        let green = Int((resolved.greenComponent * 255).rounded())
        let blue = Int((resolved.blueComponent * 255).rounded())
        return "rgb(\(red), \(green), \(blue))"
    }
}
