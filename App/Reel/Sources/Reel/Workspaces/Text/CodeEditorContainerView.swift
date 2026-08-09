import AppKit

@MainActor
final class CodeEditorContainerView: NSView {
    let scrollView: NSScrollView
    let gutter: LineNumberGutterView
    private var requestedInitialFocus = false
    private var viewportRepairScheduled = false

    /// Whether the line-number gutter takes space beside the source.
    var showsGutter = true {
        didSet {
            guard showsGutter != oldValue else { return }
            gutter.isHidden = !showsGutter
            needsLayout = true
        }
    }

    init(scrollView: NSScrollView, gutter: LineNumberGutterView) {
        self.scrollView = scrollView
        self.gutter = gutter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        // Repaint through a resize rather than reusing rendered contents, and
        // stand behind the scroll view with the editor's own background so a
        // pane that is briefly mis-sized cannot reveal what was on screen
        // before it.
        layerContentsRedrawPolicy = .duringViewResize
        layer?.backgroundColor = scrollView.backgroundColor.cgColor
        addSubview(gutter)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Keeps the backing colour in step with the theme the editor paints with.
    func applyBackground(_ color: NSColor) {
        guard layer?.backgroundColor != color.cgColor else { return }
        layer?.backgroundColor = color.cgColor
    }

    override func layout() {
        super.layout()
        let gutterWidth = showsGutter ? LineNumberGutterView.thickness : 0
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(
            x: gutterWidth,
            y: 0,
            width: max(bounds.width - gutterWidth, 0),
            height: bounds.height
        )
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let viewport = scrollView.contentSize
        var documentSize = textView.frame.size
        if textView.isHorizontallyResizable {
            documentSize.width = max(documentSize.width, viewport.width)
        } else {
            documentSize.width = viewport.width
        }
        documentSize.height = max(documentSize.height, viewport.height)
        if textView.frame.size != documentSize {
            textView.setFrameSize(documentSize)
        }
        if let textContainer = textView.textContainer {
            let width =
                textView.isHorizontallyResizable
                ? CGFloat.greatestFiniteMagnitude
                : max(documentSize.width - textView.textContainerInset.width * 2, 1)
            let desiredContainerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            if textContainer.containerSize != desiredContainerSize {
                textContainer.containerSize = desiredContainerSize
            }
            repairVisibleViewport(in: textView, textContainer: textContainer)
        }
        gutter.needsDisplay = true
    }

    func scheduleViewportRepair() {
        guard !viewportRepairScheduled else { return }
        viewportRepairScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            viewportRepairScheduled = false
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    private func repairVisibleViewport(
        in textView: NSTextView,
        textContainer: NSTextContainer
    ) {
        guard let layoutManager = textView.layoutManager else { return }
        let origin = textView.textContainerOrigin
        let visibleInContainer = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        guard !visibleInContainer.isEmpty else { return }
        let repairRect = visibleInContainer.insetBy(dx: 0, dy: -32)
        layoutManager.ensureLayout(forBoundingRect: repairRect, in: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: repairRect,
            in: textContainer
        )
        if glyphRange.length > 0 {
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            layoutManager.invalidateDisplay(forCharacterRange: characterRange)
        }
        textView.setNeedsDisplay(textView.visibleRect)
        scrollView.contentView.needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else { return }
        scheduleViewportRepair()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            scheduleViewportRepair()
        }
        guard window != nil, !requestedInitialFocus else { return }
        requestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = scrollView.documentView as? NSTextView else { return }
            window?.makeFirstResponder(textView)
        }
    }
}
