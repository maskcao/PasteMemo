import AppKit
import CoreGraphics

/// 截图入口：热键触发后优先走浮引式自绘框选（冻结帧 + 放大镜 + 就地标注 + 玻璃工具条），
/// 确认后扁平化直接进剪贴板由 ClipboardManager 常规监听接住。
/// 冻结帧拿不到时回退 `screencapture -i -c`（系统框选，结果同样进剪贴板）。
@MainActor
final class ScreenshotCapture {
    static let shared = ScreenshotCapture()

    private var isCapturing = false
    private var countdownWindows: [NSWindow] = []
    private var countdownRemaining = 0

    /// 延时截图秒数（0 = 关闭），More 菜单设置（对齐 FloGravity CaptureDelayDurationPicker）
    static var delaySeconds: Int {
        get { UserDefaults.standard.integer(forKey: "screenshotDelaySeconds") }
        set { UserDefaults.standard.set(newValue, forKey: "screenshotDelaySeconds") }
    }

    static func setDelayPreset(_ index: Int) {
        delaySeconds = [0, 3, 5, 10][min(max(index, 0), 3)]
    }

    func trigger() {
        guard !isCapturing else { return }
        if CGPreflightScreenCaptureAccess() {
            let delay = Self.delaySeconds
            if delay > 0 {
                isCapturing = true
                showCountdown(seconds: delay)
            } else {
                // 自绘框选：确认后直接复制；begin 失败（拿不到冻结帧）回退系统框选
                if ScreenshotSelectionController.shared.begin() {
                    return
                }
                launchCapture()
            }
        } else {
            CGRequestScreenCaptureAccess()
            showPermissionAlert()
        }
    }

    /// 延时倒计时：全屏半透明遮罩 + 中央大数字，结束后自动进入框选（对齐 FloGravity 延时截图）
    private func showCountdown(seconds: Int) {
        countdownWindows.removeAll()
        countdownRemaining = seconds
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.25).cgColor

            let label = NSTextField(labelWithString: String(seconds))
            label.font = .monospacedDigitSystemFont(ofSize: 140, weight: .bold)
            label.textColor = .white
            label.frame = NSRect(
                x: 0, y: 0,
                width: screen.frame.width,
                height: screen.frame.height
            )
            label.autoresizingMask = [.width, .height]
            label.textAlignment = .center
            container.addSubview(label)
            window.contentView = container
            window.makeKeyAndOrderFront(nil)
            countdownWindows.append(window)
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                self?.tickCountdown(timer)
            }
        }
    }

    private func tickCountdown(_ timer: Timer) {
        countdownRemaining -= 1
        if countdownRemaining <= 0 {
            timer.invalidate()
            countdownWindows.forEach { $0.orderOut(nil) }
            countdownWindows.removeAll()
            isCapturing = false
            if ScreenshotSelectionController.shared.begin() {
                return
            }
            launchCapture()
        } else {
            for window in countdownWindows {
                (window.contentView?.subviews.compactMap { $0 as? NSTextField }.first)?.stringValue = String(countdownRemaining)
            }
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
