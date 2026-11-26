import AppKit

/// 临时截图 / 标注会话结束后，把前台还给会话前最前台的应用。
///
/// 不还给前台的后果（RDP 客户端最典型）：它失活期间不转发鼠标给远端会话——
/// 单击被 macOS 截去激活本窗口（「点一下没用、双击才行」），滚轮退回客户端
/// 本地的缩放手势（远端里本该是滚动）。
///
/// 判定用 `app.isActive` 而不是 `frontmostApplication`：全屏 RDP 空间里
/// 「窗口服务器报谁在前台」和「该应用的输入通道是否激活」是解耦的——
/// frontmostApplication 可能已经报 RDP，但它的远端输入通道仍是释放态，
/// 早退会漏掉那次唯一能重新捕获输入的 activate。activate 对已激活的应用
/// 是 no-op，幂等，所以「延迟 → 校验 isActive → 重试」直到真正激活为止。
enum AppFocusRestorer {
    static func restore(
        _ app: NSRunningApplication,
        delay: TimeInterval = 0.25,
        attempts: Int = 4
    ) {
        guard app.processIdentifier != NSRunningApplication.current.processIdentifier,
              attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !app.isActive else {
                DiagnosticLog.log("FOCUS restore: \(app.localizedName ?? "?") already active, done")
                return
            }
            // 收尾时可能还有别的动作（剪贴板监听、policy 切换）试图激活 PasteMemo，
            // 所以每一轮都幂等地再发一次 activate，直到 app.isActive 为 true
            app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
            DiagnosticLog.log("FOCUS restore: activated \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")), isActive=\(app.isActive)")
            if !app.isActive {
                Self.restore(app, delay: 0.4, attempts: attempts - 1)
            }
        }
    }
}
