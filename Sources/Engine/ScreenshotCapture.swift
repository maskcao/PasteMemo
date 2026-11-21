import AppKit
import CoreGraphics

/// 截图入口：热键触发后优先走浮引式自绘框选（冻结帧 + 放大镜 + 窗口吸附），
/// 冻结帧拿不到时回退 `screencapture -i -c`，结果进剪贴板由 ClipboardManager 常规监听接住。
@MainActor
final class ScreenshotCapture {
    static let shared = ScreenshotCapture()

    private var isCapturing = false
    private var pasteboardChangeCountBeforeCapture = 0

    /// 截图完成后自动弹标注编辑器（CleanShot 式）。默认开，设置里可关。
    private var autoOpenEditorEnabled: Bool {
        UserDefaults.standard.object(forKey: "screenshotAutoOpenEditor") as? Bool ?? true
    }

    func trigger() {
        guard !isCapturing else { return }
        if CGPreflightScreenCaptureAccess() {
            // 自绘框选：确认后按「自动弹编辑器」偏好进编辑器或剪贴板；
            // begin 失败（拿不到冻结帧）回退系统框选
            if ScreenshotSelectionController.shared.begin() {
                return
            }
            launchCapture()
        } else {
            CGRequestScreenCaptureAccess()
            showPermissionAlert()
        }
    }

    private func launchCapture() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-c"]
        // Esc 取消时 screencapture 不写剪贴板；用 changeCount 区分「真的截了」和「取消了」，
        // 取消时不能弹编辑器——否则会把取消前剪贴板里的旧图弹出来。
        pasteboardChangeCountBeforeCapture = NSPasteboard.general.changeCount
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isCapturing = false
                self?.openEditorIfEnabled()
            }
        }
        do {
            try process.run()
            isCapturing = true
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.tr("screenshot.failed.title")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.tr("action.confirm"))
            alert.runModal()
        }
    }

    private func openEditorIfEnabled() {
        guard autoOpenEditorEnabled else { return }
        guard NSPasteboard.general.changeCount != pasteboardChangeCountBeforeCapture else { return }
        Task { @MainActor in
            // screencapture 在退出前才写剪贴板，等一拍确保 PNG 落盘可读。
            try? await Task.sleep(nanoseconds: 150_000_000)
            let pasteboard = NSPasteboard.general
            if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                ScreenshotEditorWindowController.present(imageData: data)
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("screenshot.permission.title")
        alert.informativeText = L10n.tr("screenshot.permission.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("screenshot.permission.openSettings"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
        if !hideDock {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if !hideDock {
            NSApp.setActivationPolicy(.accessory)
        }
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
