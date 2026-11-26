import AppKit

/// 临时截图 / 标注会话结束后，把前台还给会话前最前台的应用。
///
/// 不还给前台的后果（RDP 客户端最典型）：它失活期间不转发鼠标给远端会话——
/// 单击被 macOS 截去激活本窗口（所以「点一下没用、双下才行」），滚轮退回
/// 客户端本地的缩放手势（远端里本该是滚动）。
///
/// 收尾时 PasteMemo 自己还可能被再次激活（setActivationPolicy 切换、剪贴板监听、
/// Toast 上屏等），一次同步 activate 会被压过——所以「延迟 → 校验 → 重试」：
/// 先等收尾动作落地，确认前台还没归位就再 activate，最多重试几轮。
enum AppFocusRestorer {
    static func restore(
        _ app: NSRunningApplication,
        delay: TimeInterval = 0.25,
        attempts: Int = 3
    ) {
        guard app.processIdentifier != NSRunningApplication.current.processIdentifier,
              attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 可能已经被别的收尾动作推回前台，没必要再抢
            let front = NSWorkspace.shared.frontmostApplication
            guard front?.processIdentifier != app.processIdentifier else { return }
            app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
            // activate 生效有轻微延迟：目标应用此刻还没接管前台就多安排一轮
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                Self.restore(app, delay: 0.4, attempts: attempts - 1)
            }
        }
    }
}
