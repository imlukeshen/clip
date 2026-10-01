import AppKit

/// The card under a Mermaid block: the rendered diagram, or a one-line message.
///
/// It passes clicks through to the text so the caret can still be placed
/// around a diagram. VoiceOver reads it as an image, or as the error text.
final class MermaidDiagramCard: NSView {
    private let imageView = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        addSubview(imageView)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityIdentifier("mermaid-diagram")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(image: NSImage, padding: CGFloat) {
        label.isHidden = true
        imageView.isHidden = false
        imageView.image = image
        imageView.frame = bounds.insetBy(dx: padding, dy: padding)
        imageView.autoresizingMask = [.width, .height]
        setAccessibilityRole(.image)
        setAccessibilityLabel("Rendered Mermaid diagram")
    }

    func show(message: String, color: NSColor, font: NSFont, padding: CGFloat) {
        imageView.isHidden = true
        imageView.image = nil
        label.isHidden = false
        label.stringValue = message
        label.textColor = color
        label.font = font
        label.frame = bounds.insetBy(dx: padding, dy: padding / 2)
        label.autoresizingMask = [.width, .height]
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(message)
    }
}
