import AppKit

@MainActor
final class CodeEditorContainerView: NSView {
    let scrollView: NSScrollView
    private var requestedInitialFocus = false
    private var viewportRepairScheduled = false

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
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
