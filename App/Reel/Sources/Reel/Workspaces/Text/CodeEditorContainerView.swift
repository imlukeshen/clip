import AppKit

@MainActor
final class CodeEditorContainerView: NSView {
    let scrollView: NSScrollView
    private var requestedInitialFocus = false

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
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !requestedInitialFocus else { return }
        requestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = scrollView.documentView as? NSTextView else { return }
            window?.makeFirstResponder(textView)
        }
    }
}
