import AppKit
import SwiftUI

/// 截图标注编辑器宿主窗口（非模态，可复用单例）。
/// 保存路径：把结果 PNG 写进 NSPasteboard 且不带 self-write 标记，
/// ClipboardManager.checkClipboard 会照常捕获 → 生成新条目，原条目不动。
@MainActor
final class ScreenshotEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = ScreenshotEditorWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<ScreenshotEditorView>?
    private var currentImage: NSImage?

    static func present(item: ClipItem) {
        guard let data = item.imageData, let image = NSImage(data: data) else { return }
        shared.show(image: image)
    }

    static func present(imageData: Data) {
        guard let image = NSImage(data: imageData) else { return }
        shared.show(image: image)
    }

    private func show(image: NSImage) {
        currentImage = image
        let window = ensureWindow()
        hostingView?.rootView = ScreenshotEditorView(
            image: image,
            onSave: { [weak self] pngData in self?.saveToClipboard(pngData: pngData) },
            onClose: { [weak self] in self?.window?.close() }
        )
        window.title = L10n.tr("action.annotate")
        fitWindow(to: image.size)

        if !UserDefaults.standard.bool(forKey: "hideDockIcon") {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingView(rootView: ScreenshotEditorView(
            image: NSImage(),
            onSave: { _ in },
            onClose: {}
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        self.hostingView = hosting
        return window
    }

    private func fitWindow(to imageSize: NSSize) {
        let toolbarHeight: CGFloat = 78
        let maxArea = NSSize(width: 1080, height: 660)
        let scale = min(1, maxArea.width / imageSize.width, maxArea.height / imageSize.height)
        let area = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        window?.setContentSize(NSSize(width: area.width, height: area.height + toolbarHeight))
        window?.center()
    }

    private func saveToClipboard(pngData: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        hostingView?.rootView = ScreenshotEditorView(image: NSImage(), onSave: { _ in }, onClose: {})
        currentImage = nil
    }
}
