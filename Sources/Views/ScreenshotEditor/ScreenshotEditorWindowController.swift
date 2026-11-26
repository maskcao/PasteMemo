import AppKit
import SwiftUI

/// 截图标注编辑器宿主窗口（非模态，可复用单例）。
/// 保存路径：把结果 PNG 写进 NSPasteboard 且不带 self-write 标记，
/// ClipboardManager.checkClipboard 会照常捕获 → 生成新条目，原条目不动。
@MainActor
final class ScreenshotEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = ScreenshotEditorWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var currentImage: NSImage?
    /// 每次展示的唯一标识：.id 变化会强制 SwiftUI 重建视图树，
    /// 让 ScreenshotEditorView 的 @State（viewModel/图片）重新用新图初始化——
    /// 否则单例窗口复用旧 state，窗口关闭过一次后再打开就是空图（0×0）
    private var sessionID = UUID()
    /// 会话前最前台应用：编辑器 show() 会激活本应用，「复制到剪贴板」收尾时
    /// 把焦点还回去（RDP 客户端失活期间单击被吞、滚轮变缩放）
    private var restoredApp: NSRunningApplication?

    static func present(item: ClipItem) {
        guard let data = item.imageData, let image = NSImage(data: data) else { return }
        shared.show(image: image)
    }

    static func present(imageData: Data) {
        guard let image = NSImage(data: imageData) else { return }
        shared.show(image: image)
    }

    private func show(image: NSImage) {
        restoredApp = NSWorkspace.shared.frontmostApplication
        currentImage = image
        let window = ensureWindow()
        sessionID = UUID()
        hostingView?.rootView = AnyView(ScreenshotEditorView(
            image: image,
            onSave: { [weak self] pngData in self?.saveToClipboard(pngData: pngData) },
            onClose: { [weak self] in self?.window?.close() }
        ).id(sessionID))
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
        let hosting = NSHostingView(rootView: AnyView(ScreenshotEditorView(
            image: NSImage(),
            onSave: { _ in },
            onClose: {}
        ).id(UUID())))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        // 单行工具条比部分小图宽：窗口别缩到工具条以下
        window.contentMinSize = NSSize(width: 780, height: 240)
        window.delegate = self
        self.window = window
        self.hostingView = hosting
        return window
    }

    private func fitWindow(to imageSize: NSSize) {
        // 工具条悬浮在图片区域底部：给底部留 ~60pt 余量，图片基本不被遮挡
        let bottomSlack: CGFloat = 60
        let maxArea = NSSize(width: 1080, height: 660)
        let scale = min(1, maxArea.width / imageSize.width, maxArea.height / imageSize.height)
        let area = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        window?.setContentSize(NSSize(width: area.width, height: area.height + bottomSlack))
        window?.center()
    }

    private func saveToClipboard(pngData: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
        if let app = restoredApp {
            AppFocusRestorer.restore(app)
        }
        restoredApp = nil
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        hostingView?.rootView = AnyView(ScreenshotEditorView(
            image: NSImage(),
            onSave: { _ in },
            onClose: {}
        ).id(UUID()))
        currentImage = nil
    }
}
