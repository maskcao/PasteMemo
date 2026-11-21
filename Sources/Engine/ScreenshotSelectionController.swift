import AppKit
import CoreGraphics

/// 浮引式自绘框选：触发热键后逐屏开全屏透明面板，先用 CGDisplayCreateImage 冻结当前画面，
/// 之后的框选/标注都在冻结帧上做——不存在「截到自己的遮罩」的问题。
/// 确认后从冻结帧裁出选区 → 走既有的标注编辑器管线。
@MainActor
final class ScreenshotSelectionController: NSObject {
    static let shared = ScreenshotSelectionController()

    private var panels: [SelectionPanel] = []
    private(set) var isActive = false

    /// 返回 false 表示冻结帧拿不到（无权限/显示错误），调用方应回退系统框选。
    @discardableResult
    func begin() -> Bool {
        guard !isActive else { return true }
        var frozen: [(NSScreen, NSImage, CGFloat)] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let cg = CGDisplayCreateImage(displayID) else {
                return false
            }
            let pixels = CGFloat(cg.width)
            let scale = screen.frame.width > 0 ? pixels / screen.frame.width : screen.backingScaleFactor
            let image = NSImage(
                cgImage: cg,
                size: NSSize(width: screen.frame.width, height: screen.frame.height)
            )
            frozen.append((screen, image, scale))
        }
        guard !frozen.isEmpty else { return false }

        isActive = true
        let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
        if !hideDock {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)
        for (screen, image, scale) in frozen {
            let panel = SelectionPanel(screen: screen, image: image, pixelScale: scale, owner: self)
            panels.append(panel)
            panel.showPanel()
        }
        return true
    }

    func confirmSelection(image: NSImage) {
        closeAll()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let autoOpenEditor = UserDefaults.standard.object(forKey: "screenshotAutoOpenEditor") as? Bool ?? true
        if autoOpenEditor {
            ScreenshotEditorWindowController.present(imageData: png)
        } else {
            // 不带 markAsPasteMemoWrite 写剪贴板 → ClipboardManager 照常捕获成新条目
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
        }
    }

    func cancel() {
        closeAll()
    }

    private func closeAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        isActive = false
        if !UserDefaults.standard.bool(forKey: "hideDockIcon") {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Panel

    private final class SelectionPanel: NSPanel {
        override var canBecomeKey: Bool { true }

        init(screen: NSScreen, image: NSImage, pixelScale: CGFloat, owner: ScreenshotSelectionController) {
            let surface = ScreenshotSelectionSurfaceView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                image: image,
                pixelScale: pixelScale,
                screen: screen,
                owner: owner
            )
            super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            level = .screenSaver
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            hidesOnDeactivate = false
            ignoresMouseEvents = false
            acceptsMouseMovedEvents = true
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            contentView = surface
        }

        func showPanel() {
            makeKeyAndOrderFront(nil)
            contentView?.needsDisplay = true
        }
    }
}

/// 冻结帧选区面。坐标系 = 视图自身（flipped，左上原点 = 屏幕左上），尺寸标注用像素。
final class ScreenshotSelectionSurfaceView: NSView {
    private let image: NSImage
    private let pixelScale: CGFloat
    private let screen: NSScreen
    private weak var owner: ScreenshotSelectionController?

    // 供复现 harness 注入状态
    var selection: CGRect?
    var candidate: CGRect?
    var magnifierPoint: CGPoint?
    private enum DragMode { case none, drawing, moving, resizing }
    private var dragMode: DragMode = .none
    private var dragOrigin: CGPoint = .zero
    private var rectAtDragStart: CGRect = .zero
    private var resizeEdge: ResizeEdge = .none
    // 候选窗口上的按下：未拖动 = 整窗选中，拖出去 = 从该点重新框选
    private var windowPickOrigin: CGPoint?
    private var windowPickRect: CGRect?
    private var cachedWindows: [(rect: CGRect, area: CGFloat)] = []

    private enum ResizeEdge { case none, topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight }

    private let magnifierDiameter: CGFloat = 88
    private let magnifierZoom: CGFloat = 8
    private let handleSize: CGFloat = 9

    init(frame: NSRect, image: NSImage, pixelScale: CGFloat, screen: NSScreen, owner: ScreenshotSelectionController) {
        self.image = image
        self.pixelScale = pixelScale
        self.screen = screen
        self.owner = owner
        super.init(frame: frame)
        cachedWindows = Self.captureWindowList()
        let full = NSRect(origin: .zero, size: frame.size)
        addTrackingArea(NSTrackingArea(
            rect: full,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: - Window snapping

    private static func captureWindowList() -> [(rect: CGRect, area: CGFloat)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [(CGRect, CGFloat)] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) != Int(getpid()),
                  let dict = info[kCGWindowBounds as String] as? [String: Any]
            else { continue }
            var bounds = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &bounds)
            guard bounds.width >= 80, bounds.height >= 60 else { continue }
            result.append((bounds, bounds.width * bounds.height))
        }
        return result
    }

    /// 视图坐标 → CG 全局（左上原点）坐标
    private func globalPoint(from point: CGPoint) -> CGPoint {
        guard let main = NSScreen.screens.first else { return point }
        let bottomLeftY = screen.frame.maxY - point.y
        return CGPoint(x: screen.frame.minX + point.x, y: main.frame.height - bottomLeftY)
    }

    /// CG 窗口 bounds（左上原点全局）→ 本视图坐标
    private func viewRect(fromWindowBounds bounds: CGRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return bounds }
        let bottomLeftRect = CGRect(
            x: bounds.minX,
            y: main.frame.height - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
        return CGRect(
            x: bottomLeftRect.minX - screen.frame.minX,
            y: screen.frame.maxY - bottomLeftRect.maxY,
            width: bottomLeftRect.width,
            height: bottomLeftRect.height
        )
    }

    private func refreshCandidate(at point: CGPoint) {
        let global = globalPoint(from: point)
        var best: CGRect?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (rect, area) in cachedWindows where rect.contains(global) && area < bestArea {
            best = rect
            bestArea = area
        }
        candidate = best.map { viewRect(fromWindowBounds: $0) }
    }

    // MARK: - Mouse

    private func point(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.point(for: event)
        window?.makeFirstResponder(self)

        if let sel = selection {
            let edge = handleEdge(at: point, in: sel)
            if edge != .none {
                dragMode = .resizing
                resizeEdge = edge
                rectAtDragStart = sel
                dragOrigin = point
                return
            }
            if sel.contains(point) {
                // 点击选区内部：直接平移
                dragMode = .moving
                rectAtDragStart = sel
                dragOrigin = point
                return
            }
            // 选区外重新框选
        }

        if let cand = candidate {
            windowPickOrigin = point
            windowPickRect = cand
            return
        }

        dragMode = .drawing
        dragOrigin = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = self.point(for: event)
        magnifierPoint = point
        if let origin = windowPickOrigin {
            let travel = hypot(point.x - origin.x, point.y - origin.y)
            if travel <= 4 {
                return
            }
            // 拖出去了：从按下的位置重新开始框选
            dragMode = .drawing
            dragOrigin = origin
            selection = CGRect(origin: origin, size: .zero)
            windowPickOrigin = nil
            windowPickRect = nil
        }
        switch dragMode {
        case .drawing:
            var rect = Self.normalizedRect(from: dragOrigin, to: point)
            if event.modifierFlags.contains(.shift) {
                // Shift：正方形约束
                let side = max(rect.width, rect.height)
                rect = CGRect(
                    x: dragOrigin.x < point.x ? dragOrigin.x : dragOrigin.x - side,
                    y: dragOrigin.y < point.y ? dragOrigin.y : dragOrigin.y - side,
                    width: side, height: side
                )
            }
            selection = rect.clamped(to: bounds.size)
        case .moving:
            let delta = CGPoint(x: point.x - dragOrigin.x, y: point.y - dragOrigin.y)
            selection = rectAtDragStart.offsetBy(dx: delta.x, dy: delta.y).clamped(to: bounds.size)
        case .resizing:
            selection = Self.resized(rect: rectAtDragStart, edge: resizeEdge, to: point).clamped(to: bounds.size)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let _ = windowPickOrigin {
            // 原地点击 = 整窗选中
            windowPickOrigin = nil
            selection = windowPickRect
            windowPickRect = nil
            needsDisplay = true
            return
        }
        if dragMode == .drawing, let sel = selection,
           sel.width < 6 || sel.height < 6 {
            selection = nil
        }
        dragMode = .none
        resizeEdge = .none
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = self.point(for: event)
        magnifierPoint = point
        if selection == nil {
            refreshCandidate(at: point)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        magnifierPoint = nil
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Esc 逐层退出：先清选区，再关面板
            if selection != nil {
                selection = nil
                needsDisplay = true
            } else {
                owner?.cancel()
            }
        case 36, 76: // Return / keypad Enter 确认
            if selection != nil { confirm() }
        case 123, 124, 125, 126: // 方向键微调 1pt，Shift 10pt
            guard let sel = selection else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = Int(event.keyCode) == 124 ? step : (Int(event.keyCode) == 123 ? -step : 0)
            let dy: CGFloat = Int(event.keyCode) == 125 ? step : (Int(event.keyCode) == 126 ? -step : 0)
            selection = sel.offsetBy(dx: dx, dy: dy).clamped(to: bounds.size)
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    private func confirm() {
        guard let sel = selection else { return }
        let pixelRect = CGRect(
            x: (sel.minX * pixelScale).rounded(.down),
            y: (sel.minY * pixelScale).rounded(.down),
            width: (sel.width * pixelScale).rounded(.awayFromZero),
            height: (sel.height * pixelScale).rounded(.awayFromZero)
        ).integral
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.cropping(to: pixelRect) else { return }
        let out = NSImage(
            cgImage: cg,
            size: NSSize(width: pixelRect.width / pixelScale, height: pixelRect.height / pixelScale)
        )
        owner?.confirmSelection(image: out)
    }

    // MARK: - Hit testing

    private func handleEdge(at point: CGPoint, in rect: CGRect) -> ResizeEdge {
        let hit = handleSize + 4
        let corners: [(ResizeEdge, CGPoint)] = [
            (.topLeft, rect.origin),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        for (edge, corner) in corners where abs(point.x - corner.x) <= hit && abs(point.y - corner.y) <= hit {
            return edge
        }
        let midTop = CGPoint(x: rect.midX, y: rect.minY)
        let midBottom = CGPoint(x: rect.midX, y: rect.maxY)
        let midLeft = CGPoint(x: rect.minX, y: rect.midY)
        let midRight = CGPoint(x: rect.maxX, y: rect.midY)
        if abs(point.y - midTop.y) <= hit && point.x >= rect.minX && point.x <= rect.maxX { return .top }
        if abs(point.y - midBottom.y) <= hit && point.x >= rect.minX && point.x <= rect.maxX { return .bottom }
        if abs(point.x - midLeft.x) <= hit && point.y >= rect.minY && point.y <= rect.maxY { return .left }
        if abs(point.x - midRight.x) <= hit && point.y >= rect.minY && point.y <= rect.maxY { return .right }
        return .none
    }

    private static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
    }

    private static func resized(rect: CGRect, edge: ResizeEdge, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY
        var maxX = rect.maxX, maxY = rect.maxY
        switch edge {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .left: minX = point.x
        case .right: maxX = point.x
        case .bottomLeft: minX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomRight: maxX = point.x; maxY = point.y
        case .none: break
        }
        return normalizedRect(
            from: CGPoint(x: min(minX, maxX), y: min(minY, maxY)),
            to: CGPoint(x: max(minX, maxX), y: max(minY, maxY))
        )
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let sel = selection {
            let edges: [(ResizeEdge, NSRect, NSCursor)] = [
                (.topLeft, handleRect(at: sel.origin), .crosshair),
                (.topRight, handleRect(at: CGPoint(x: sel.maxX, y: sel.minY)), .crosshair),
                (.bottomLeft, handleRect(at: CGPoint(x: sel.minX, y: sel.maxY)), .crosshair),
                (.bottomRight, handleRect(at: CGPoint(x: sel.maxX, y: sel.maxY)), .crosshair),
                (.top, NSRect(x: sel.midX - handleSize, y: sel.minY - 4, width: handleSize * 2, height: 8), .resizeUpDown),
                (.bottom, NSRect(x: sel.midX - handleSize, y: sel.maxY - 4, width: handleSize * 2, height: 8), .resizeUpDown),
                (.left, NSRect(x: sel.minX - 4, y: sel.midY - handleSize, width: 8, height: handleSize * 2), .resizeLeftRight),
                (.right, NSRect(x: sel.maxX - 4, y: sel.midY - handleSize, width: 8, height: handleSize * 2), .resizeLeftRight),
            ]
            for (_, rect, cursor) in edges {
                addCursorRect(rect, cursor: cursor)
            }
        }
    }

    private func handleRect(at point: CGPoint) -> NSRect {
        NSRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2, width: handleSize, height: handleSize)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 冻结帧铺底
        image.draw(in: bounds)

        let sel = selection
        let dimTarget: CGRect?
        if sel != nil {
            dimTarget = sel
        } else if let cand = candidate {
            dimTarget = cand
        } else {
            dimTarget = nil
        }

        // 选区外压暗（浮引式：四条带挖洞）
        ctx.setFillColor(NSColor.black.withAlphaComponent(sel != nil ? 0.38 : 0.32).cgColor)
        if let region = dimTarget {
            let r = region
            let bands = [
                CGRect(x: 0, y: 0, width: bounds.width, height: r.minY),
                CGRect(x: 0, y: r.minY, width: r.minX, height: r.height),
                CGRect(x: r.maxX, y: r.minY, width: bounds.width - r.maxX, height: r.height),
                CGRect(x: 0, y: r.maxY, width: bounds.width, height: bounds.height - r.maxY),
            ]
            bands.forEach { ctx.fill($0) }
        } else {
            ctx.fill(bounds)
        }

        if let cand = candidate, sel == nil {
            // 窗口识别高亮
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(cand.insetBy(dx: 0.75, dy: 0.75))
            drawSizeBadge(for: cand, at: badgeAnchor(for: cand), ctx: ctx)
        }

        if let sel {
            // 选区描边 + 8 手柄 + 尺寸徽章
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(sel.insetBy(dx: 0.75, dy: 0.75))

            let handles = [
                sel.origin,
                CGPoint(x: sel.midX, y: sel.minY),
                CGPoint(x: sel.maxX, y: sel.minY),
                CGPoint(x: sel.minX, y: sel.midY),
                CGPoint(x: sel.maxX, y: sel.midY),
                CGPoint(x: sel.minX, y: sel.maxY),
                CGPoint(x: sel.midX, y: sel.maxY),
                CGPoint(x: sel.maxX, y: sel.maxY),
            ]
            for point in handles {
                let rect = NSRect(origin: CGPoint(x: point.x - handleSize / 2, y: point.y - handleSize / 2), size: CGSize(width: handleSize, height: handleSize))
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(rect)
                ctx.setStrokeColor(NSColor(white: 0.4, alpha: 1).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(rect)
            }
            drawSizeBadge(for: sel, at: badgeAnchor(for: sel), ctx: ctx)
        }

        if let point = magnifierPoint {
            drawMagnifier(at: point)
        }
    }

    private func badgeAnchor(for rect: CGRect) -> CGPoint {
        let below = rect.maxY + 8
        return CGPoint(x: rect.midX, y: below + 20 > bounds.height ? rect.minY - 28 : below)
    }

    private func drawSizeBadge(for rect: CGRect, at anchor: CGPoint, ctx: CGContext) {
        let text = "\(Int(rect.width * pixelScale)) × \(Int(rect.height * pixelScale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let badge = NSRect(x: anchor.x - size.width / 2 - 8, y: anchor.y, width: size.width + 16, height: 20)
            .clamped(to: bounds.size)
        let path = NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        (text as NSString).draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawMagnifier(at point: CGPoint) {
        guard let ctx = NSGraphicsContext.current else { return }
        // 光标右下偏移，贴边自动翻到左上
        var center = CGPoint(x: point.x + magnifierDiameter / 2 + 20, y: point.y + magnifierDiameter / 2 + 20)
        if center.x + magnifierDiameter / 2 > bounds.width || center.y + magnifierDiameter / 2 > bounds.height {
            center = CGPoint(x: point.x - magnifierDiameter / 2 - 20, y: point.y - magnifierDiameter / 2 - 20)
        }
        let circle = NSRect(
            x: center.x - magnifierDiameter / 2, y: center.y - magnifierDiameter / 2,
            width: magnifierDiameter, height: magnifierDiameter
        ).clamped(to: bounds.size)

        let clip = NSBezierPath(ovalIn: circle)
        clip.addClip()
        // 从冻结帧取光标邻域像素，nearest 放大出马赛克感
        let samplePt = magnifierDiameter / magnifierZoom
        let samplePixel = CGRect(
            x: (point.x - samplePt / 2) * pixelScale,
            y: (point.y - samplePt / 2) * pixelScale,
            width: samplePt * pixelScale,
            height: samplePt * pixelScale
        ).integral
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           samplePixel.width >= 2, samplePixel.height >= 2,
           let cropped = cg.cropping(to: samplePixel.intersection(CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))) {
            let sample = NSImage(cgImage: cropped, size: CGSize(width: samplePt, height: samplePt))
            ctx.imageInterpolation = .none
            sample.draw(in: circle)
            ctx.imageInterpolation = .default
        }
        clip.setClip()

        // 十字准星
        let cross = magnifierDiameter * 0.22
        NSColor.white.setStroke()
        let crossPath = NSBezierPath()
        crossPath.lineWidth = 1
        crossPath.move(to: CGPoint(x: center.x - cross, y: center.y))
        crossPath.line(to: CGPoint(x: center.x + cross, y: center.y))
        crossPath.move(to: CGPoint(x: center.x, y: center.y - cross))
        crossPath.line(to: CGPoint(x: center.x, y: center.y + cross))
        crossPath.stroke()

        // 白色外圈 + 深色内衬
        NSColor.white.setStroke()
        let border = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
        NSColor(white: 0.2, alpha: 0.9).setStroke()
        let inner = NSBezierPath(ovalIn: circle.insetBy(dx: 3, dy: 3))
        inner.lineWidth = 1
        inner.stroke()
    }
}

private extension CGRect {
    func clamped(to size: CGSize) -> CGRect {
        let w = min(width, size.width)
        let h = min(height, size.height)
        let x = max(0, min(minX, size.width - w))
        let y = max(0, min(minY, size.height - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: minX + dx, y: minY + dy, width: width, height: height)
    }
}
