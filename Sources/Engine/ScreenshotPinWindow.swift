import AppKit

/// 钉在屏幕：把扁平化后的截图做成置顶浮窗，可拖动、多张并存，悬停出关闭按钮。
@MainActor
final class ScreenshotPinBoard {
    static let shared = ScreenshotPinBoard()

    private var windows: [ScreenshotPinWindow] = []

    private init() {}

    func pin(pngData: Data, near center: CGPoint, scale: CGFloat) {
        guard let image = NSImage(data: pngData) else { return }
        let window = ScreenshotPinWindow(image: image, scale: scale, center: center)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.windows.removeAll { $0 === window }
        }
        windows.append(window)
        window.showPin()
    }
}

final class ScreenshotPinWindow: NSPanel {
    var onClose: (() -> Void)?

    init(image: NSImage, scale: CGFloat, center: CGPoint) {
        let factor = max(scale, 1)
        let size = NSSize(
            width: max(40, image.size.width / factor),
            height: max(40, image.size.height / factor)
        )
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinImageView(frame: NSRect(origin: .zero, size: size), image: image)
        setFrameOrigin(NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    override var canBecomeKey: Bool { true }

    func showPin() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func closePin() {
        onClose?()
        orderOut(nil)
        contentView = nil
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 53 {
            closePin()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            closePin()
            return
        }
        super.keyDown(with: event)
    }
}

private final class PinImageView: NSView {
    private let image: NSImage
    private let closeButton = NSButton()

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        closeButton.isBordered = false
        closeButton.title = ""
        closeButton.imagePosition = .imageOnly
        closeButton.image = Self.closeImage()
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.toolTip = L10n.tr("editor.pin.close")
        closeButton.alphaValue = 0
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(
            x: bounds.width - 26, y: bounds.height - 26,
            width: 20, height: 20
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).addClip()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.animator().alphaValue = 0
    }

    @objc private func closePin() {
        (window as? ScreenshotPinWindow)?.closePin()
    }

    private static func closeImage() -> NSImage? {
        guard let base = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [NSColor.white, NSColor(white: 0.1, alpha: 0.75)]))
        return base.withSymbolConfiguration(config) ?? base
    }
}
