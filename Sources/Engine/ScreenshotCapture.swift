import AppKit
import CoreGraphics

/// 截图入口：热键触发后优先走浮引式自绘框选（冻结帧 + 放大镜 + 就地标注 + 玻璃工具条），
/// 确认后扁平化直接进剪贴板由 ClipboardManager 常规监听接住。
/// 冻结帧拿不到时回退 `screencapture -i -c`（系统框选，结果同样进剪贴板）。
@MainActor
final class ScreenshotCapture {
    static let shared = ScreenshotCapture()

    private var isCapturing = false

    func trigger() {
        guard !isCapturing else { return }
        if CGPreflightScreenCaptureAccess() {
            // 自绘框选：确认后直接复制；begin 失败（拿不到冻结帧）回退系统框选
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
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isCapturing = false
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
