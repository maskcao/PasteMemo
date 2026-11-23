import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import Vision

/// 采集模式，对齐 FloGravity 的选区类型切换（Tab）：普通截图 / 滚动长截图。
enum CaptureMode {
    case screenshot
    case longCapture
}

/// 长截图滚动捕获的会话状态。进入捕获后选区面板整体隐藏（点击穿透 + 透明），
/// 只留 HUD 浮窗，帧采集与拼接都围绕这个会话进行。
final class LongCaptureSessionState {
    let stitcher: LongScreenshotStitcher
    /// 本屏显示像素空间（CGImage 空间，左上原点）的捕获区域
    let pixelRect: CGRect
    var timer: Timer?
    var hud: LongCaptureHUD?
    /// 连续无新增内容的帧数，达到阈值提示「已滚动到底」
    var noAddStreak = 0

    init(stitcher: LongScreenshotStitcher, pixelRect: CGRect) {
        self.stitcher = stitcher
        self.pixelRect = pixelRect
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func closeHUD() {
        hud?.close()
        hud = nil
    }
}

/// 浮引式自绘框选：触发热键后逐屏开全屏透明面板，先用 CGDisplayCreateImage 冻结当前画面，
/// 之后的框选/标注都在冻结帧上做——不存在「截到自己的遮罩」的问题。
/// 标注工具条挂在选区下方（浮引同款玻璃条），确认后扁平化直接进剪贴板，不再弹独立编辑器窗口。
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
        // 在激活 App 之前抓窗口列表：顺序要和刚冻结的那一帧一致，
        // 否则本应用被提到最前后，悬停高亮会选到冻结画面里并不在最上层的窗口。
        let windows = ScreenshotSelectionSurfaceView.captureWindowList()

        isActive = true
        let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
        if !hideDock {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)
        for (screen, image, scale) in frozen {
            let panel = SelectionPanel(
                screen: screen, image: image, pixelScale: scale, owner: self, windows: windows
            )
            panels.append(panel)
            panel.showPanel()
        }
        return true
    }

    func confirmSelection(pngData: Data) {
        closeAll()
        // 不带 markAsPasteMemoWrite 写剪贴板 → ClipboardManager 照常捕获成新条目
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
    }

    func cancel() {
        closeAll()
    }

    /// 保存面板是普通层级的窗口，会被 screenSaver 级浮层盖住——模态期间临时降级。
    func runSavePanel(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        panels.forEach { $0.level = .normal }
        NSApp.activate(ignoringOtherApps: true)
        let result = panel.runModal()
        panels.forEach { panel in
            panel.level = .screenSaver
            panel.makeKey()
        }
        return result
    }

    /// 长截图滚动期间隐藏全部选区面板（透明 + 点击穿透），完成后恢复。
    func setPanelsHidden(_ hidden: Bool) {
        panels.forEach { panel in
            panel.alphaValue = hidden ? 0 : 1
            panel.ignoresMouseEvents = hidden
        }
    }

    /// 长截图完成：直接收起整套框选 UI（预览窗自行展示）。
    func finishLongSession() {
        closeAll()
    }

    private func closeAll() {
        ToolbarButton.dismissHoverTip()
        panels.forEach {
            ($0.contentView as? ScreenshotSelectionSurfaceView)?.abortLongCaptureIfNeeded()
            $0.alphaValue = 1
            $0.ignoresMouseEvents = false
            $0.orderOut(nil)
        }
        panels.removeAll()
        isActive = false
        if !UserDefaults.standard.bool(forKey: "hideDockIcon") {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Panel

    private final class SelectionPanel: NSPanel {
        override var canBecomeKey: Bool { true }

        init(
            screen: NSScreen,
            image: NSImage,
            pixelScale: CGFloat,
            owner: ScreenshotSelectionController,
            windows: [(rect: CGRect, area: CGFloat)]
        ) {
            let surface = ScreenshotSelectionSurfaceView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                image: image,
                pixelScale: pixelScale,
                screen: screen,
                owner: owner,
                windows: windows
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
            makeFirstResponder(contentView)
            contentView?.needsDisplay = true
            invalidateCursorRects(for: contentView!)
            (contentView as? ScreenshotSelectionSurfaceView)?.applySelectionCursor()
        }
    }
}

/// 冻结帧选区面。坐标系 = 视图自身（flipped，左上原点 = 屏幕左上），尺寸标注用像素。
/// 选区确认后工具条浮出，标注直接画在冻结帧上（浮引式），不再打开独立标注编辑器。
final class ScreenshotSelectionSurfaceView: NSView {
    private let image: NSImage
    private let pixelScale: CGFloat
    private let screen: NSScreen
    private weak var owner: ScreenshotSelectionController?

    // 供复现 harness 注入状态
    var selection: CGRect?
    var candidate: CGRect?
    var magnifierPoint: CGPoint?
    var annotations: [ScreenshotAnnotation] = []

    /// 采集模式（对齐 FloGravity：Tab 在模式间切换；长截图与截图共用选区交互）
    var captureMode: CaptureMode = .screenshot

    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []
    private var activeTool: ScreenshotAnnotation.Kind?

    // MARK: - 长截图会话

    /// 长截图进行中的会话状态；非 nil 表示正在滚动捕获
    var longSession: LongCaptureSessionState?
    private var autoScrollEnabled = false
    /// 形状按钮记住上一次选的形状（矩形/椭圆），面板里的下拉也能改。
    private var shapeKind: ScreenshotAnnotation.Kind = .rectangle
    private var colorIndex = 0
    /// 文字标注加粗与对齐（0 左 / 1 中 / 2 右），浮引样式面板
    var textBold = false
    var textAlign = 0
    /// 识别结果小窗（浮引「识别结果」面板）
    var ocrPanel: OCRResultPanel?
    private var weightIndex = 1
    /// 二级面板的可调参数：线宽倍率 / 荧光笔透明度 / 马赛克透明度 / 箭头样式 / 马赛克形状 / 字号
    private var strokeScale: CGFloat = 1.8
    /// 线宽预设：0 小 / 1 中 / 2 大 / 3 跟随主题（对应 0.9 / 1.8 / 2.8 / 1.8）
    private var widthPreset = 1
    private var highlighterOpacity: CGFloat = 0.5
    private var mosaicOpacity: CGFloat = 1.0
    private var arrowStyle = 1
    private var mosaicStyle = 0
    private var fontSize: CGFloat = 16
    /// 高亮工具的水印文字（参考图面板里的「最多输入 16 个字符」）；非空时点按落一段半透明文字。
    private var highlighterText = ""
    private var draft: ScreenshotAnnotation?
    private var lastMosaicPreviewTime: TimeInterval = 0
    private var textField: NSTextField?
    private var textCancelling = false
    private var chipView: NSView?
    private var chipWorkItem: DispatchWorkItem?

    private enum DragMode { case none, drawing, moving, resizing }
    private var dragMode: DragMode = .none
    private var dragOrigin: CGPoint = .zero
    private var rectAtDragStart: CGRect = .zero
    private var resizeEdge: ResizeEdge = .none
    // 候选窗口上的按下：未拖动 = 整窗选中，拖出去 = 从该点重新框选
    private var windowPickOrigin: CGPoint?
    private var windowPickRect: CGRect?
    private var cachedWindows: [(rect: CGRect, area: CGFloat)] = []

    private var toolbar: SelectionToolbar!
    private var optionsBar: SelectionOptionsBar!

    private enum ResizeEdge { case none, topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight }

    /// 放大镜为正方形预览窗：边长更大、倍数更低，方便看清周边
    private let magnifierSide: CGFloat = 132
    private let magnifierZoom: CGFloat = 3
    private let magnifierCornerRadius: CGFloat = 8
    /// 十字准星用亮黄色（应用图标的黄色调）
    private static let magnifierCrosshairColor = NSColor(
        red: 1.0, green: 0.84, blue: 0.04, alpha: 1
    )
    private let handleSize: CGFloat = 9

    /// FloGravity 色板：红 / 绿 / 蓝 / 紫 / 白 / 黑 / 跟随主题 / 自定义
    /// 浮引 7 色命名色板（墨色/红/橙/黄/绿/蓝/紫）
    private static let nsPalette: [NSColor] = [
        NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),  // 墨色
        NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1),  // 红
        NSColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1),  // 橙
        NSColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1),  // 黄
        NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1),  // 绿
        NSColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1),  // 蓝
        NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1),  // 紫
    ]
    static var customPaletteColor = NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1)

    /// 选区比例约束（"free" / "1:1" / "4:3" / "16:9"），More 菜单设置并持久化
    static var constraintKey: String {
        get { UserDefaults.standard.string(forKey: "selectionConstraintRatio") ?? "free" }
        set { UserDefaults.standard.set(newValue, forKey: "selectionConstraintRatio") }
    }

    init(
        frame: NSRect,
        image: NSImage,
        pixelScale: CGFloat,
        screen: NSScreen,
        owner: ScreenshotSelectionController,
        windows: [(rect: CGRect, area: CGFloat)]
    ) {
        self.image = image
        self.pixelScale = pixelScale
        self.screen = screen
        self.owner = owner
        self.cachedWindows = windows
        super.init(frame: frame)
        let full = NSRect(origin: .zero, size: frame.size)
        addTrackingArea(NSTrackingArea(
            rect: full,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        toolbar = SelectionToolbar(target: self, action: #selector(toolbarAction(_:)))
        toolbar.isHidden = true
        addSubview(toolbar)
        optionsBar = SelectionOptionsBar(target: self, action: #selector(toolbarAction(_:)))
        optionsBar.isHidden = true
        addSubview(optionsBar)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        positionToolbar()
    }

    private func positionToolbar() {
        guard let sel = selection, dragMode == .none else {
            toolbar.isHidden = true
            optionsBar.isHidden = true
            return
        }
        toolbar.isHidden = false
        optionsBar.isHidden = activeTool == nil
        let mainSize = toolbar.fittingSize
        let optionSize = optionsBar.isHidden ? .zero : optionsBar.fittingSize
        let gap: CGFloat = 6
        let totalHeight = mainSize.height + (optionSize.height > 0 ? gap + optionSize.height : 0)

        func clampX(_ width: CGFloat, center: CGFloat) -> CGFloat {
            max(8, min(center - width / 2, bounds.width - width - 8))
        }

        var y = sel.maxY + 10
        if y + totalHeight > bounds.height - 8 {
            y = max(8, sel.minY - 10 - totalHeight)
        }
        toolbar.frame = NSRect(
            x: clampX(mainSize.width, center: sel.midX), y: y,
            width: mainSize.width, height: mainSize.height
        )
        if !optionsBar.isHidden {
            optionsBar.frame = NSRect(
                x: clampX(optionSize.width, center: sel.midX), y: y + mainSize.height + gap,
                width: optionSize.width, height: optionSize.height
            )
        }
    }

    private func syncToolbar() {
        // 识别结果面板开着时不显示工具条
        if ocrPanel != nil {
            toolbar.isHidden = true
            optionsBar.isHidden = true
            return
        }
        toolbar.update(
            mode: captureMode,
            tool: activeTool,
            canUndo: !undoStack.isEmpty,
            canRedo: !redoStack.isEmpty,
            hasSelection: selection != nil
        )
        optionsBar.configure(
            tool: activeTool,
            shapeKind: shapeKind,
            colorIndex: colorIndex,
            strokeScale: strokeScale,
            widthPreset: widthPreset,
            opacity: highlighterOpacity,
            mosaicOpacity: mosaicOpacity,
            arrowStyle: arrowStyle,
            mosaicStyle: mosaicStyle,
            fontSize: fontSize
        )
        needsLayout = true
    }

    // MARK: - Window snapping

    static func captureWindowList() -> [(rect: CGRect, area: CGFloat)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [(CGRect, CGFloat)] = []
        for info in list {
            // 只取普通层级的窗口。截图浮层自己是 screenSaver 级（layer 1000）、
            // 钉图/HUD 是浮动级，都会被 layer == 0 过滤掉；
            // 不再排除本进程的窗口——这样也能框住 PasteMemo 自己的主界面做截图提示。
            guard (info[kCGWindowLayer as String] as? Int) == 0,
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
        // 窗口列表本身是从前到后排序的：取第一个命中的就是视觉上最上层的那个，
        // 用「面积最小」会把被盖住的小窗口也挑出来，高亮就错位了。
        candidate = cachedWindows.first { $0.rect.contains(global) }
            .map { viewRect(fromWindowBounds: $0.rect) }
    }

    // MARK: - Mouse

    private func point(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.point(for: event)
        window?.makeFirstResponder(self)
        finishTextEntry(commit: true)

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
                if let tool = activeTool {
                    beginAnnotation(tool: tool, at: point)
                    return
                }
                if event.clickCount >= 2 {
                    // 截图模式双击确认；长截图模式双击开始滚动捕获（对齐 FloGravity「双击开始长截图」）
                    if captureMode == .longCapture {
                        startLongCapture()
                    } else {
                        confirm()
                    }
                    return
                }
                // 指针模式：拖动选区平移
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

        beginSelectionDrawing(at: point)
    }

    private func beginSelectionDrawing(at point: CGPoint) {
        // 新选区 = 新画布，旧标注作废
        annotations = []
        undoStack = []
        redoStack = []
        dragMode = .drawing
        dragOrigin = point
        selection = CGRect(origin: point, size: .zero)
        syncToolbar()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = self.point(for: event)
        if draft != nil {
            updateDraft(with: point)
            needsDisplay = true
            return
        }
        if let origin = windowPickOrigin {
            let travel = hypot(point.x - origin.x, point.y - origin.y)
            if travel <= 4 {
                return
            }
            // 拖出去了：从按下的位置重新开始框选
            beginSelectionDrawing(at: origin)
            windowPickOrigin = nil
            windowPickRect = nil
        }
        if dragMode != .none {
            magnifierPoint = point
        }
        switch dragMode {
        case .drawing:
            var rect = Self.normalizedRect(from: dragOrigin, to: point)
            let ratio = Self.constraintRatio
            if let ratio, !event.modifierFlags.contains(.option) {
                // 显式比例约束（Option 临时强制自由）；以拖拽起点为锚角按拖拽方向外扩
                rect = Self.rect(rect, applyingRatio: ratio, origin: dragOrigin, toward: point)
            } else if event.modifierFlags.contains(.shift) {
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
        if draft != nil {
            commitDraft()
            return
        }
        if let _ = windowPickOrigin {
            // 原地单击 = 选中整窗并浮出编辑条（再双击才确认截图）
            windowPickOrigin = nil
            selection = windowPickRect
            windowPickRect = nil
            annotations = []
            undoStack = []
            redoStack = []
            dragMode = .none
            syncToolbar()
            needsDisplay = true
            return
        }
        if dragMode == .drawing, let sel = selection,
           sel.width < 6 || sel.height < 6 {
            // 手抖导致拖拽中途开始、松手时框还很小：如果按下点落在窗口高亮里，
            // 仍按整窗选中处理，避免「点一下没反应、要点第二下」。
            if let cand = candidate, cand.contains(dragOrigin) {
                selection = cand
                syncToolbar()
            } else {
                selection = nil
            }
        }
        dragMode = .none
        resizeEdge = .none
        syncToolbar()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = self.point(for: event)
        // 选区完成后隐藏放大镜，别挡工具条和标注
        if selection == nil || dragMode != .none {
            magnifierPoint = point
        } else {
            magnifierPoint = nil
        }
        if selection == nil, activeTool == nil {
            refreshCandidate(at: point)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        magnifierPoint = nil
        needsDisplay = true
    }

    // MARK: - Annotation

    private func beginAnnotation(tool: ScreenshotAnnotation.Kind, at point: CGPoint) {
        switch tool {
        case .text:
            beginTextEntry(at: point)
        case .stepBadge:
            pushUndo()
            var badge = ScreenshotAnnotation(kind: .stepBadge, colorIndex: colorIndex, weightIndex: weightIndex, start: point, end: point)
            badge.text = "\(annotations.filter { $0.kind == .stepBadge }.count + 1)"
            annotations.append(badge)
            needsDisplay = true
            syncToolbar()
        case .highlighter where !highlighterText.isEmpty:
            pushUndo()
            var stamp = ScreenshotAnnotation(kind: .text, colorIndex: colorIndex, weightIndex: weightIndex, start: point, end: point)
            stamp.text = highlighterText
            stamp.fontSize = 20
            stamp.opacity = highlighterOpacity
            annotations.append(stamp)
            needsDisplay = true
            syncToolbar()
        default:
            var annotation = ScreenshotAnnotation(kind: tool, colorIndex: colorIndex, weightIndex: weightIndex, start: point, end: point)
            annotation.strokeScale = strokeScale
            annotation.arrowStyle = arrowStyle
            annotation.mosaicStyle = mosaicStyle
            annotation.opacity = tool == .highlighter ? highlighterOpacity : (tool == .mosaic ? mosaicOpacity : 0)
            annotation.fontSize = tool == .text ? fontSize : 0
            if tool == .pen || tool == .highlighter {
                annotation.points = [point]
            }
            draft = annotation
            needsDisplay = true
        }
    }

    private func updateDraft(with point: CGPoint) {
        guard var d = draft else { return }
        // 标注不越出选区
        let clamped = CGPoint(
            x: min(max(point.x, (selection?.minX ?? 0)), selection?.maxX ?? bounds.width),
            y: min(max(point.y, (selection?.minY ?? 0)), selection?.maxY ?? bounds.height)
        )
        switch d.kind {
        case .pen, .highlighter:
            d.points.append(clamped)
        case .mosaic:
            d.end = clamped
            let r = d.rect
            let now = ProcessInfo.processInfo.systemUptime
            if r.width >= 6, r.height >= 6, now - lastMosaicPreviewTime >= 0.06 {
                lastMosaicPreviewTime = now
                d.mosaicImage = makeMosaicImage(for: r)
            }
        default:
            d.end = clamped
        }
        draft = d
    }

    private func commitDraft() {
        guard let d = draft else { return }
        draft = nil
        var annotation = d
        var keep = false
        switch d.kind {
        case .pen, .highlighter:
            if d.points.count < 2 {
                annotation.points = [d.start, CGPoint(x: d.start.x + 0.5, y: d.start.y)]
            }
            keep = true
        case .mosaic:
            let r = d.rect
            if r.width >= 6, r.height >= 6, let mosaic = makeMosaicImage(for: r) {
                annotation.mosaicImage = mosaic
                keep = true
            }
        case .arrow:
            keep = hypot(d.end.x - d.start.x, d.end.y - d.start.y) >= 6
        default:
            let r = d.rect
            keep = r.width >= 4 && r.height >= 4
        }
        if keep {
            pushUndo()
            annotations.append(annotation)
        }
        needsDisplay = true
        syncToolbar()
    }

    private func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undoAnnotation() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        needsDisplay = true
        syncToolbar()
    }

    private func redoAnnotation() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        needsDisplay = true
        syncToolbar()
    }

    // MARK: - Text entry

    private var textFontSize: CGFloat { fontSize }

    private func beginTextEntry(at point: CGPoint) {
        finishTextEntry(commit: true)
        let field = NSTextField(frame: NSRect(
            x: point.x, y: point.y,
            width: min(280, max(80, bounds.width - point.x - 8)),
            height: textFontSize * 1.6
        ))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: textFontSize, weight: textBold ? .bold : .semibold)
        field.textColor = Self.paletteColor(colorIndex)
        field.alignment = [.left, .center, .right][min(max(textAlign, 0), 2)]
        field.placeholderString = L10n.tr("editor.tool.text")
        field.delegate = self
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    private func finishTextEntry(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = field.frame.origin
        field.delegate = nil
        field.removeFromSuperview()
        if (window?.firstResponder as? NSTextField) === field {
            window?.makeFirstResponder(self)
        }
        if commit, !text.isEmpty {
            pushUndo()
            var annotation = ScreenshotAnnotation(kind: .text, colorIndex: colorIndex, weightIndex: weightIndex, start: origin, end: origin)
            annotation.text = text
            annotation.fontSize = fontSize
            annotation.isBold = textBold
            annotation.alignIndex = textAlign
            annotations.append(annotation)
        }
        needsDisplay = true
        syncToolbar()
    }

    // MARK: - Toolbar

    @objc private func toolbarAction(_ sender: Any) {
        finishTextEntry(commit: true)

        if let item = sender as? NSMenuItem, item.tag == 503 {
            if let number = item.representedObject as? NSNumber {
                fontSize = CGFloat(number.doubleValue)
                needsDisplay = true
            }
            window?.makeFirstResponder(self)
            return
        }

        if let field = sender as? NSTextField, field.tag == 505 {
            let limited = String(field.stringValue.prefix(16))
            if limited != field.stringValue { field.stringValue = limited }
            highlighterText = limited
            return
        }

        if let item = sender as? NSMenuItem {
            // More 菜单与形状下拉
            switch item.tag {
            case 5: toggleTool(.mosaic)
            case 8: toggleTool(.highlighter)
            case 601: shapeKind = .rectangle; activeTool = .rectangle
            case 602: shapeKind = .ellipse; activeTool = .ellipse
            default: return
            }
            needsDisplay = true
            syncToolbar()
            window?.makeFirstResponder(self)
            return
        }

        guard let control = sender as? NSControl else { return }

        if let slider = control as? NSSlider {
            switch control.tag {
            case 501:
                strokeScale = 0.8 + CGFloat(slider.doubleValue) * 2.2
            case 502:
                if activeTool == .mosaic { mosaicOpacity = CGFloat(slider.doubleValue) } else {
                    highlighterOpacity = CGFloat(slider.doubleValue)
                }
                optionsBar.updateOpacityDisplay(CGFloat(slider.doubleValue))
            default:
                break
            }
            needsDisplay = true
            return
        }

        switch control.tag {
        case 20:
            switchCaptureMode(.screenshot)
        case 21:
            switchCaptureMode(.longCapture)
        case 12:
            startLongCapture()
        case 0:
            if captureMode == .screenshot { activeTool = nil }
        case 1:
            guard captureMode == .screenshot else { break }
            if activeTool == .rectangle || activeTool == .ellipse {
                activeTool = nil
            } else {
                activeTool = shapeKind
            }
        case 11:
            if captureMode == .screenshot { showMoreMenu(from: control) }
        case 2: if captureMode == .screenshot { toggleTool(.ellipse) }
        case 603: if captureMode == .screenshot { toggleTool(.roundedRect) }
        case 604: if captureMode == .screenshot { toggleTool(.triangle) }
        case 605: if captureMode == .screenshot { toggleTool(.pentagon) }
        case 606: if captureMode == .screenshot { toggleTool(.hexagon) }
        case 607: if captureMode == .screenshot { toggleTool(.star) }
        case 608: if captureMode == .screenshot { toggleTool(.speechBubble) }
        case 609: if captureMode == .screenshot { toggleTool(.callout) }
        case 620...623:
            Self.constraintKey = ["free", "1:1", "4:3", "16:9"][control.tag - 620]
        case 630...633:
            ScreenshotCapture.setDelayPreset(control.tag - 630)
        case 430:
            textBold.toggle()
            needsDisplay = true
            syncToolbar()
        case 431...433:
            textAlign = control.tag - 431
            needsDisplay = true
            syncToolbar()
        case 3: if captureMode == .screenshot { toggleTool(.arrow) }
        case 4: if captureMode == .screenshot { toggleTool(.pen) }
        case 5: if captureMode == .screenshot { toggleTool(.mosaic) }
        case 6: if captureMode == .screenshot { toggleTool(.text) }
        case 7: if captureMode == .screenshot { toggleTool(.stepBadge) }
        case 8: if captureMode == .screenshot { toggleTool(.highlighter) }
        case 9: if captureMode == .screenshot { extractText() }
        case 14: if captureMode == .screenshot { translateSelection() }
        case 13: if captureMode == .screenshot { recognizeQRCode() }
        case 10: if captureMode == .screenshot { pinSelection() }
        case 511...513:
            widthPreset = control.tag - 511
            strokeScale = [0.9, 1.8, 2.8][widthPreset]
        case 101...107:
            colorIndex = control.tag - 101
            needsDisplay = true
            syncToolbar()
        case 108:
            colorIndex = 7
            NSColorPanel.shared.setTarget(self)
            NSColorPanel.shared.setAction(#selector(customColorPicked(_:)))
            NSColorPanel.shared.color = Self.customPaletteColor
            NSColorPanel.shared.orderFront(nil)
            needsDisplay = true
            syncToolbar()
        case 401...403:
            arrowStyle = control.tag - 401
            needsDisplay = true
            syncToolbar()
        case 411...413:
            mosaicStyle = control.tag - 411
            needsDisplay = true
            syncToolbar()
        case 301: undoAnnotation()
        case 306: redoAnnotation()
        case 302: copySelection()
        case 303: saveToFile()
        case 304: owner?.cancel()
        case 305: confirm()
        default: break
        }
        needsDisplay = true
        syncToolbar()
        window?.makeFirstResponder(self)
    }

    private func toggleTool(_ kind: ScreenshotAnnotation.Kind) {
        activeTool = activeTool == kind ? nil : kind
        needsDisplay = true
        syncToolbar()
    }

    /// FloGravity 的 More：折叠次要标注工具。
    private func showMoreMenu(from control: NSControl) {
        let menu = NSMenu()
        let entries: [(Int, String, ScreenshotAnnotation.Kind)] = [
            (5, "editor.tool.mosaic", .mosaic),
            (8, "editor.tool.highlighter", .highlighter),
        ]
        for (tag, key, kind) in entries {
            let item = NSMenuItem(title: L10n.tr(key), action: #selector(toolbarAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = activeTool == kind ? .on : .off
            menu.addItem(item)
        }

        // 选区比例约束（对齐 FloGravity CaptureSelectionConstraintPicker）
        let constraintMenu = NSMenu()
        for (index, key) in ["editor.constraint.free", "editor.constraint.1_1", "editor.constraint.4_3", "editor.constraint.16_9"].enumerated() {
            let item = NSMenuItem(title: L10n.tr(key), action: #selector(toolbarAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 620 + index
            item.state = Self.constraintKey == ["free", "1:1", "4:3", "16:9"][index] ? .on : .off
            constraintMenu.addItem(item)
        }
        let constraintItem = NSMenuItem(title: L10n.tr("editor.constraint"), action: nil, keyEquivalent: "")
        constraintItem.submenu = constraintMenu
        menu.addItem(constraintItem)

        // 延时截图（对齐 FloGravity CaptureDelayDurationPicker）
        let delayMenu = NSMenu()
        let delaySeconds = ScreenshotCapture.delaySeconds
        for (index, key) in ["screenshot.delay.off", "screenshot.delay.3", "screenshot.delay.5", "screenshot.delay.10"].enumerated() {
            let item = NSMenuItem(title: L10n.tr(key), action: #selector(toolbarAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 630 + index
            item.state = delaySeconds == [0, 3, 5, 10][index] ? .on : .off
            delayMenu.addItem(item)
        }
        let delayItem = NSMenuItem(title: L10n.tr("screenshot.delay"), action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: control.bounds.maxY + 4), in: control)
    }

    @objc private func customColorPicked(_ sender: NSColorPanel) {
        Self.customPaletteColor = sender.color
        colorIndex = 7
        needsDisplay = true
        syncToolbar()
    }

    // MARK: - Long capture（对齐 FloGravity 长截图：框选 → 滚动自动拼接 → 预览复制/保存）

    private func switchCaptureMode(_ mode: CaptureMode) {
        guard longSession == nil, captureMode != mode else { return }
        captureMode = mode
        activeTool = nil
        draft = nil
        needsDisplay = true
        syncToolbar()
    }

    /// 隐藏选区面板，露出真实屏幕内容供滚动（HUD 在捕获区域外，不会入镜）。
    private func captureDisplayImage(for rect: CGRect) -> CGImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let cg = CGDisplayCreateImage(displayID) else { return nil }
        let displayBounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let crop = rect.intersection(displayBounds)
        guard abs(crop.width - rect.width) < 1, abs(crop.height - rect.height) < 1 else { return nil }
        return cg.cropping(to: crop)
    }

    private func startLongCapture() {
        guard selection != nil, longSession == nil else { return }
        finishTextEntry(commit: true)
        activeTool = nil
        draft = nil

        let sel = selection!.integral
        let pixelRect = CGRect(
            x: sel.minX * pixelScale, y: sel.minY * pixelScale,
            width: sel.width * pixelScale, height: sel.height * pixelScale
        ).integral
        // 先把面板藏掉再抓首帧，避免遮罩入镜
        owner?.setPanelsHidden(true)
        guard let first = captureDisplayImage(for: pixelRect) else {
            owner?.setPanelsHidden(false)
            showChip(L10n.tr("capture.long.failed"))
            return
        }
        let stitcher = LongScreenshotStitcher(pixelWidth: first.width)
        stitcher.append(first)
        let session = LongCaptureSessionState(stitcher: stitcher, pixelRect: pixelRect)
        longSession = session

        let hud = LongCaptureHUD(
            regionRect: sel, screen: screen,
            onFinish: { [weak self] in self?.finishLongCapture() },
            onCancel: { [weak self] in self?.cancelLongCapture() },
            onAutoscroll: { [weak self] enabled in self?.autoScrollEnabled = enabled }
        )
        hud.showPanel()
        session.hud = hud

        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.longTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        session.timer = timer
        needsDisplay = true
    }

    private func longTick() {
        guard let session = longSession else { return }
        guard let frame = captureDisplayImage(for: session.pixelRect) else { return }
        guard let result = session.stitcher.append(frame) else { return }
        if result.atBottom {
            session.noAddStreak += 1
        } else {
            session.noAddStreak = 0
        }
        let atBottom = session.noAddStreak >= 4
        session.hud?.update(height: result.totalRows, atBottom: atBottom)
        if autoScrollEnabled, !atBottom {
            postScrollTick()
        }
    }

    /// 自动滚动：向前台窗口发送滚轮事件（需要辅助功能权限，缺权限时静默失败）。
    private func postScrollTick() {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: -3, wheel2: 0, wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func finishLongCapture() {
        guard let session = longSession else { return }
        teardownLongSession()
        owner?.setPanelsHidden(false)
        guard let image = session.stitcher.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            showChip(L10n.tr("capture.long.failed"))
            return
        }
        owner?.finishLongSession()
        LongCapturePreview.present(pngData: png)
    }

    private func cancelLongCapture() {
        guard longSession != nil else { return }
        teardownLongSession()
        owner?.setPanelsHidden(false)
        needsDisplay = true
    }

    private func teardownLongSession() {
        guard let session = longSession else { return }
        session.stopTimer()
        session.closeHUD()
        autoScrollEnabled = false
        longSession = nil
    }

    /// 面板被外部关闭（Esc / 取消）时中断滚动捕获。
    func abortLongCaptureIfNeeded() {
        teardownLongSession()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "z", "Z":
                if event.modifierFlags.contains(.shift) { redoAnnotation() } else { undoAnnotation() }
                return
            case "s":
                saveToFile()
                return
            case "c":
                copySelection()
                return
            default:
                break
            }
        }
        switch Int(event.keyCode) {
        case 48: // Tab 切换选区类型（截图 ↔ 长截图）
            if longSession == nil {
                switchCaptureMode(captureMode == .screenshot ? .longCapture : .screenshot)
            }
        case 53: // Esc 逐层退出：草稿 → 工具 → 选区 → 面板
            if draft != nil {
                draft = nil
                needsDisplay = true
            } else if activeTool != nil {
                activeTool = nil
                syncToolbar()
                needsDisplay = true
            } else if selection != nil {
                selection = nil
                annotations = []
                undoStack = []
                redoStack = []
                syncToolbar()
                needsDisplay = true
            } else {
                owner?.cancel()
            }
        case 36, 76: // Return / keypad Enter：截图确认；长截图开始/完成
            if longSession != nil {
                finishLongCapture()
            } else if selection != nil {
                if captureMode == .longCapture {
                    startLongCapture()
                } else {
                    confirm()
                }
            }
        case 123, 124, 125, 126: // 方向键微调 1pt，Shift 10pt
            guard let sel = selection else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = Int(event.keyCode) == 124 ? step : (Int(event.keyCode) == 123 ? -step : 0)
            let dy: CGFloat = Int(event.keyCode) == 125 ? step : (Int(event.keyCode) == 126 ? -step : 0)
            selection = sel.offsetBy(dx: dx, dy: dy).clamped(to: bounds.size)
            syncToolbar()
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Output

    private func confirm() {
        guard selection != nil, let png = flattenPNG() else { return }
        owner?.confirmSelection(pngData: png)
    }

    private func saveToFile() {
        guard selection != nil, let png = flattenPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot.png"
        panel.canCreateDirectories = true
        let result = owner?.runSavePanel(panel) ?? panel.runModal()
        if result == .OK, let url = panel.url {
            try? png.write(to: url)
            ToastCenter.shared.show(ToastDescriptor(message: String(format: L10n.tr("editor.saved.named"), url.lastPathComponent), icon: .success))
        }
        window?.makeFirstResponder(self)
    }

    private func copySelection() {
        guard let png = flattenPNG() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        showChip(L10n.tr("action.copied"))
    }

    /// 选区原始像素（不含标注）——OCR 用干净底图。
    private func croppedBasePNG() -> Data? {
        guard let sel = selection?.integral,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        let pixelRect = CGRect(
            x: sel.minX * pixelScale, y: sel.minY * pixelScale,
            width: sel.width * pixelScale, height: sel.height * pixelScale
        ).integral.intersection(imageBounds)
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let cropped = cg.cropping(to: pixelRect) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }

    /// 选区比例约束值（宽/高）；free 返回 nil
    static var constraintRatio: CGFloat? {
        switch constraintKey {
        case "1:1": return 1
        case "4:3": return 4.0 / 3.0
        case "16:9": return 16.0 / 9.0
        default: return nil
        }
    }

    /// 以 origin 为锚角、按拖拽方向外扩出指定宽高比的矩形
    static func rect(_ rect: CGRect, applyingRatio ratio: CGFloat, origin: CGPoint, toward point: CGPoint) -> CGRect {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let width = max(abs(dx), abs(dy) * ratio)
        let height = width / ratio
        return CGRect(
            x: dx < 0 ? origin.x - width : origin.x,
            y: dy < 0 ? origin.y - height : origin.y,
            width: width,
            height: height
        )
    }

    /// 识别二维码：选区干净底图跑 Vision 条码识别，内容进剪贴板（对齐 FloGravity「识别二维码」）
    private func recognizeQRCode() {
        guard selection != nil, let png = croppedBasePNG() else { return }
        guard let cg = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showChip(L10n.tr("capture.qr.none"))
            return
        }
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            let payloads = request.results?.compactMap(\.payloadStringValue) ?? []
            if let payload = payloads.first {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(payload, forType: .string)
                showChip(L10n.tr("capture.qr.copied"))
            } else {
                showChip(L10n.tr("capture.qr.none"))
            }
        } catch {
            showChip(L10n.tr("capture.qr.none"))
        }
    }

    private func extractText() {
        guard let png = croppedBasePNG() else { return }
        showChip(L10n.tr("editor.ocr.working"), duration: 4)
        Task { [weak self] in
            guard let self else { return }
            do {
                // 与剪贴板 OCR 走同一条链路：读同一个 markdown 开关（默认开）。
                // macOS 26+ 走版面感知引擎（识别更完整），低版本自动回退纯文本。
                let useMarkdown = UserDefaults.standard.object(forKey: "ocrToMarkdown") as? Bool ?? true
                let result = try await ImageOCRService.shared.recognizeText(from: png, markdown: useMarkdown)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.showChip(L10n.tr("editor.ocr.empty"))
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // 识别结果小窗显示在选区右侧（对齐浮引「识别结果」面板）
                if let sel = self.selection {
                    self.presentOCRResult(text: text, selection: sel)
                }
                self.showChip(L10n.tr("editor.ocr.copied"))
            } catch {
                self.showChip(L10n.tr("editor.ocr.failed"))
            }
        }
    }

    /// 翻译选区文字（对齐浮引：截图取词翻译使用系统翻译）。
    /// 先走与「提取文字」相同的 OCR，再把整段文字交给系统 Translation 框架。
    private func translateSelection() {
        guard let png = croppedBasePNG() else { return }
        if #available(macOS 15.0, *) {
            showChip(L10n.tr("editor.translate.working"), duration: 60)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let useMarkdown = UserDefaults.standard.object(forKey: "ocrToMarkdown") as? Bool ?? true
                    let result = try await ImageOCRService.shared.recognizeText(from: png, markdown: useMarkdown)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        self.hideChip()
                        self.showChip(L10n.tr("editor.ocr.empty"))
                        return
                    }
                    let translated = try await ScreenshotTranslationService.shared.translate(
                        text: text,
                        in: self.window
                    )
                    self.hideChip()
                    if let sel = self.selection {
                        self.presentResultPanel(
                            title: L10n.tr("editor.translate.result.title"),
                            text: translated,
                            selection: sel
                        )
                    }
                } catch {
                    NSLog("Screenshot translation failed: %@", String(describing: error))
                    self.hideChip()
                    // 把系统给的原因一并显示出来，便于定位是语言包未下载还是语言对不支持
                    let generic = L10n.tr("editor.translate.failed")
                    let reason = error.localizedDescription
                    let message = (reason.isEmpty || reason == generic)
                        ? generic
                        : "\(generic)：\(String(reason.prefix(80)))"
                    self.showChip(message, duration: 6)
                }
            }
        } else {
            showChip(L10n.tr("editor.translate.failed"))
        }
    }

    private func presentOCRResult(text: String, selection: CGRect) {
        presentResultPanel(title: L10n.tr("editor.ocr.result.title"), text: text, selection: selection)
    }

    /// 提取文字 / 翻译共用结果面板：标题可换，正文与复制按钮一致。
    private func presentResultPanel(title: String, text: String, selection: CGRect) {
        ocrPanel?.removeFromSuperview()
        // 结果面板出现时收起工具条与二级面板（浮引：进入结果态后不再显示工具条）
        toolbar.isHidden = true
        optionsBar.isHidden = true
        let panel = OCRResultPanel(title: title, text: text) { [weak self] in
            guard let self else { return }
            self.ocrPanel?.removeFromSuperview()
            self.ocrPanel = nil
            // 关闭结果面板后恢复工具条
            self.syncToolbar()
            self.needsDisplay = true
        }
        // 位置（对齐浮引）：优先选区右侧；右侧不够放左侧；两侧都不够则贴屏幕右缘，绝不放正中遮挡
        let size = panel.idealSize
        let bounds = self.bounds
        let margin: CGFloat = 12
        var x = selection.maxX + margin
        if x + size.width > bounds.maxX - margin {
            let left = selection.minX - margin - size.width
            // 左侧放得下就放左侧，否则贴屏幕右缘（不居中遮挡选区）
            x = left >= margin ? left : bounds.maxX - size.width - margin
        }
        x = max(margin, min(x, bounds.width - size.width - margin))
        var y = selection.midY - size.height / 2
        y = min(max(y, margin), bounds.height - size.height - margin)
        panel.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        addSubview(panel)
        ocrPanel = panel
    }

    private func pinSelection() {
        guard let sel = selection, let png = flattenPNG() else { return }
        let center = CGPoint(
            x: screen.frame.minX + sel.midX,
            y: screen.frame.maxY - sel.midY
        )
        ScreenshotPinBoard.shared.pin(pngData: png, near: center, scale: pixelScale)
        owner?.cancel()
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("editor.pin.done"), icon: .success))
    }

    /// 选区内淡入淡出的结果提示（复制/OCR）。ToastCenter 在 screenSaver 级浮层下面，面板开着时看不到。
    private func showChip(_ text: String, duration: TimeInterval = 1.4) {
        chipWorkItem?.cancel()
        chipView?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        let textSize = label.fittingSize
        let width = textSize.width + 24
        let height: CGFloat = 26
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.82).cgColor
        container.layer?.cornerRadius = height / 2
        label.frame = NSRect(x: 12, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height)
        container.addSubview(label)
        let centerX = selection?.midX ?? bounds.midX
        var y = (selection?.minY ?? bounds.midY) - 12 - height
        if y < 8 {
            y = (selection?.maxY ?? bounds.midY) + 12
        }
        container.frame = NSRect(x: centerX - width / 2, y: y, width: width, height: height)
        addSubview(container)
        chipView = container
        let item = DispatchWorkItem { [weak self] in
            self?.chipView?.removeFromSuperview()
            self?.chipView = nil
        }
        chipWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    /// 立刻收起当前提示（翻译耗时较长，结果面板出来前要先把「翻译中」去掉）
    private func hideChip() {
        chipWorkItem?.cancel()
        chipView?.removeFromSuperview()
        chipView = nil
    }

    /// 选区 × 冻结帧 + 全部标注 → 扁平化 PNG（像素级裁剪，标注按点坐标缩放）。
    func flattenPNG() -> Data? {
        guard let sel = selection?.integral,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        let pixelRect = CGRect(
            x: sel.minX * pixelScale,
            y: sel.minY * pixelScale,
            width: sel.width * pixelScale,
            height: sel.height * pixelScale
        ).integral.intersection(imageBounds)
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let croppedBase = cg.cropping(to: pixelRect),
              let ctx = CGContext(
                data: nil,
                width: Int(pixelRect.width),
                height: Int(pixelRect.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(pixelRect.height))
        ctx.scaleBy(x: 1, y: -1) // 翻成左上原点，对齐视图坐标
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        NSImage(cgImage: croppedBase, size: sel.size).draw(in: sel)
        drawAnnotationLayer(imageWidth: bounds.width)
        NSGraphicsContext.restoreGraphicsState()

        guard let flat = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])
    }

    private func makeMosaicImage(for rect: CGRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        let pixelRect = CGRect(
            x: rect.minX * pixelScale, y: rect.minY * pixelScale,
            width: rect.width * pixelScale, height: rect.height * pixelScale
        ).integral.intersection(imageBounds)
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let cropped = cg.cropping(to: pixelRect) else { return nil }

        let width = Int(pixelRect.width)
        let height = Int(pixelRect.height)
        // 块 = 短边 1/10（至少 10pt，按屏幕像素密度换算）：块太小字还认得出，太大又看不出内容；
        // 网格按整块取整，放大后每块严格等大，不会出现宽窄不一的条纹
        let block = max(Int((10 * pixelScale).rounded()), min(width, height) / 10)
        let smallW = max(1, (width + block - 1) / block)
        let smallH = max(1, (height + block - 1) / block)
        let canvasW = smallW * block
        let canvasH = smallH * block

        guard let small = CGContext(
            data: nil, width: smallW, height: smallH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // 高质量缩小 = 区域滤波，每块颜色接近真实平均值，不留噪点
        small.interpolationQuality = .high
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let smallImage = small.makeImage(),
              let big = CGContext(
                data: nil, width: canvasW, height: canvasH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        big.interpolationQuality = .none
        big.draw(smallImage, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        guard let padded = big.makeImage(),
              let mosaicCG = padded.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        return NSImage(cgImage: mosaicCG, size: rect.size)
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

    /// 热键唤起面板后立刻把光标切成十字准星，不必等鼠标移动
    func applySelectionCursor() {
        window?.invalidateCursorRects(for: self)
        NSCursor.crosshair.set()
    }

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
            // 窗口识别高亮：深底 + 白线，浅色/深色画面上都看得见
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(2.5)
            ctx.stroke(cand.insetBy(dx: 0.75, dy: 0.75))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(cand.insetBy(dx: 0.75, dy: 0.75))
            drawSizeBadge(for: cand, at: badgeAnchor(for: cand), ctx: ctx)
        }

        // 标注只出现在选区内
        if let sel, !annotations.isEmpty || draft != nil {
            ctx.saveGState()
            ctx.clip(to: sel)
            drawAnnotationLayer(imageWidth: bounds.width)
            ctx.restoreGState()
        }

        if let sel {
            // 选区描边 + 8 手柄；拖拽中显示像素徽章，松手后换成工具条。
            // 先画深色描边再叠白线：浅色截图（浅色模式下很常见）也能看清边界。
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(2.5)
            ctx.stroke(sel.insetBy(dx: 0.75, dy: 0.75))
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
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(rect)
            }
            if dragMode != .none {
                drawSizeBadge(for: sel, at: badgeAnchor(for: sel), ctx: ctx)
            }
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

    // MARK: - Annotation rendering（AppKit 版，预览与扁平化共用）

    private func drawAnnotationLayer(imageWidth: CGFloat) {
        for annotation in annotations {
            drawAnnotation(annotation, imageWidth: imageWidth)
        }
        if let draft {
            drawAnnotation(draft, imageWidth: imageWidth)
        }
    }

    private func drawAnnotation(_ a: ScreenshotAnnotation, imageWidth: CGFloat) {
        let weight = a.strokeScale > 0 ? a.strokeScale : AnnotationStyle.weights[a.weightIndex]
        let stroke = AnnotationStyle.baseStroke(imageWidth: imageWidth) * weight
        let color = Self.paletteColor(a.colorIndex)

        switch a.kind {
        case .arrow:
            let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
            let headLength = max(stroke * 3.5, 10)
            let shaft = NSBezierPath()
            shaft.lineWidth = stroke
            shaft.lineCapStyle = .round
            shaft.move(to: a.start)
            if a.arrowStyle == 0 {
                shaft.line(to: CGPoint(
                    x: a.end.x - headLength * 0.7 * cos(angle),
                    y: a.end.y - headLength * 0.7 * sin(angle)
                ))
            } else {
                shaft.line(to: a.end)
            }
            color.setStroke()
            shaft.stroke()

            if a.arrowStyle == 0 {
                let left = CGPoint(
                    x: a.end.x - headLength * cos(angle - 0.42),
                    y: a.end.y - headLength * sin(angle - 0.42)
                )
                let right = CGPoint(
                    x: a.end.x - headLength * cos(angle + 0.42),
                    y: a.end.y - headLength * sin(angle + 0.42)
                )
                let head = NSBezierPath()
                head.move(to: a.end)
                head.line(to: left)
                head.line(to: right)
                head.close()
                color.setFill()
                head.fill()
            } else if a.arrowStyle == 1 {
                let head = NSBezierPath()
                head.lineWidth = stroke
                head.lineCapStyle = .round
                head.lineJoinStyle = .round
                head.move(to: a.end)
                head.line(to: CGPoint(
                    x: a.end.x - headLength * cos(angle - 0.45),
                    y: a.end.y - headLength * sin(angle - 0.45)
                ))
                head.move(to: a.end)
                head.line(to: CGPoint(
                    x: a.end.x - headLength * cos(angle + 0.45),
                    y: a.end.y - headLength * sin(angle + 0.45)
                ))
                color.setStroke()
                head.stroke()
            }

        case .rectangle:
            let path = NSBezierPath(rect: a.rect.insetBy(dx: stroke / 2, dy: stroke / 2))
            path.lineWidth = stroke
            color.setStroke()
            path.stroke()

        case .roundedRect:
            let rect = a.rect.insetBy(dx: stroke / 2, dy: stroke / 2)
            // 圆角随短边缩放，上限 24pt（与 SwiftUI 绘制路径保持一致）
            let radius = min(min(rect.width, rect.height) * 0.2, 24)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = stroke
            color.setStroke()
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: a.rect.insetBy(dx: stroke / 2, dy: stroke / 2))
            path.lineWidth = stroke
            color.setStroke()
            path.stroke()

        case .triangle, .pentagon, .hexagon, .star, .speechBubble, .callout:
            // 与 SwiftUI 渲染共用同一几何（顶点换算成 NSBezierPath）
            let insetRect = a.rect.insetBy(dx: stroke / 2, dy: stroke / 2)
            let path = NSBezierPath()
            path.lineWidth = stroke
            color.setStroke()
            switch a.kind {
            case .triangle, .pentagon, .hexagon:
                let sides: CGFloat = a.kind == .triangle ? 3 : (a.kind == .pentagon ? 5 : 6)
                let radius = min(insetRect.width, insetRect.height) / 2
                let scaleX = insetRect.width / (radius * 2)
                let scaleY = insetRect.height / (radius * 2)
                for i in 0..<Int(sides) {
                    let angle = -Double.pi / 2 + Double(i) * (2 * .pi / Double(sides))
                    let point = CGPoint(
                        x: insetRect.midX + cos(angle) * radius * scaleX,
                        y: insetRect.midY + sin(angle) * radius * scaleY
                    )
                    if i == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                path.close()
            case .star:
                let outer = min(insetRect.width, insetRect.height) / 2
                let inner = outer * 0.42
                let scaleX = insetRect.width / (outer * 2)
                let scaleY = insetRect.height / (outer * 2)
                for i in 0..<10 {
                    let radius = i % 2 == 0 ? outer : inner
                    let angle = -Double.pi / 2 + Double(i) * (.pi / 5)
                    let point = CGPoint(
                        x: insetRect.midX + cos(angle) * radius * scaleX,
                        y: insetRect.midY + sin(angle) * radius * scaleY
                    )
                    if i == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                path.close()
            default:
                let tail: CGFloat = min(insetRect.width, insetRect.height) * 0.25
                if a.kind == .speechBubble {
                    let bubble = CGRect(x: insetRect.minX, y: insetRect.minY, width: insetRect.width, height: max(insetRect.height - tail, insetRect.height * 0.5))
                    let radius = min(min(bubble.width, bubble.height) * 0.2, 18)
                    path.append(NSBezierPath(roundedRect: bubble, xRadius: radius, yRadius: radius))
                    path.move(to: CGPoint(x: bubble.minX + bubble.width * 0.22, y: bubble.maxY - stroke))
                    path.line(to: CGPoint(x: insetRect.minX + tail * 0.35, y: insetRect.maxY))
                    path.line(to: CGPoint(x: bubble.minX + bubble.width * 0.42, y: bubble.maxY - stroke))
                } else {
                    let bubble = CGRect(x: insetRect.minX, y: insetRect.minY, width: insetRect.width, height: max(insetRect.height - tail, insetRect.height * 0.5))
                    path.append(NSBezierPath(ovalIn: bubble))
                    path.move(to: CGPoint(x: bubble.maxX - bubble.width * 0.40, y: bubble.maxY - stroke))
                    path.line(to: CGPoint(x: insetRect.maxX - tail * 0.35, y: insetRect.maxY))
                    path.line(to: CGPoint(x: bubble.maxX - bubble.width * 0.20, y: bubble.maxY - stroke))
                }
            }
            path.stroke()

        case .pen, .highlighter:
            let line = a.points.isEmpty ? [a.start, a.end] : a.points
            guard line.count >= 2 else { break }
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: line[0])
            for point in line.dropFirst() {
                path.line(to: point)
            }
            if a.kind == .highlighter {
                // 荧光笔：整条路径一次 stroke，半透明不会因线段交叠而叠深
                path.lineWidth = stroke * 4
                color.withAlphaComponent(a.opacity > 0 ? a.opacity : 0.35).setStroke()
            } else {
                path.lineWidth = stroke
                color.setStroke()
            }
            path.stroke()

        case .mosaic:
            NSGraphicsContext.saveGraphicsState()
            let clipPath: NSBezierPath
            switch a.mosaicStyle {
            case 1:
                clipPath = NSBezierPath(ovalIn: a.rect)
            case 2:
                let radius = min(a.rect.width, a.rect.height) * 0.2
                clipPath = NSBezierPath(roundedRect: a.rect, xRadius: radius, yRadius: radius)
            default:
                clipPath = NSBezierPath(rect: a.rect)
            }
            clipPath.addClip()
            if let mosaic = a.mosaicImage {
                mosaic.draw(in: a.rect, from: .zero, operation: .sourceOver, fraction: a.opacity > 0 ? a.opacity : 1)
            } else {
                NSColor.gray.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: a.rect).fill()
            }
            NSGraphicsContext.restoreGraphicsState()

        case .stepBadge:
            let radius = AnnotationStyle.badgeRadius(imageWidth: imageWidth) * AnnotationStyle.badgeScales[a.weightIndex]
            let circle = NSRect(x: a.start.x - radius, y: a.start.y - radius, width: radius * 2, height: radius * 2)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: circle)
            ring.lineWidth = max(2, stroke * 0.7)
            ring.stroke()
            let number = a.text.isEmpty ? "1" : a.text
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.05, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = (number as NSString).size(withAttributes: attrs)
            (number as NSString).draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attrs)

        case .text:
            let fontSize = a.fontSize > 0
                ? a.fontSize
                : AnnotationStyle.fontSize(imageWidth: imageWidth) * AnnotationStyle.textScales[a.weightIndex]
            let font = NSFont.systemFont(ofSize: fontSize, weight: a.isBold ? .bold : .semibold)
            let alpha = a.opacity > 0 ? a.opacity : 1
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = [.left, .center, .right][min(max(a.alignIndex, 0), 2)]
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color.withAlphaComponent(alpha),
                .paragraphStyle: paragraph,
            ]
            (a.text as NSString).draw(with: CGRect(origin: a.start, size: CGSize(width: bounds.width - a.start.x, height: 200)), options: [.usesLineFragmentOrigin], attributes: attrs)
        }
    }

    // MARK: - Magnifier

    private func drawMagnifier(at point: CGPoint) {
        guard let ctx = NSGraphicsContext.current else { return }
        // 光标右下偏移，贴边自动翻到左上
        var center = CGPoint(x: point.x + magnifierSide / 2 + 20, y: point.y + magnifierSide / 2 + 20)
        if center.x + magnifierSide / 2 > bounds.width || center.y + magnifierSide / 2 > bounds.height {
            center = CGPoint(x: point.x - magnifierSide / 2 - 20, y: point.y - magnifierSide / 2 - 20)
        }
        let lens = NSRect(
            x: center.x - magnifierSide / 2, y: center.y - magnifierSide / 2,
            width: magnifierSide, height: magnifierSide
        ).clamped(to: bounds.size)

        let clip = NSBezierPath(roundedRect: lens, xRadius: magnifierCornerRadius, yRadius: magnifierCornerRadius)
        clip.addClip()
        // 从冻结帧取光标邻域像素，nearest 放大出马赛克感
        let samplePt = magnifierSide / magnifierZoom
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
            sample.draw(in: lens)
            ctx.imageInterpolation = .default
        }
        clip.setClip()

        // 十字准星（亮黄色 + 深色衬底，浅色画面上也看得清）
        let cross = magnifierSide * 0.14
        let crossPath = NSBezierPath()
        crossPath.move(to: CGPoint(x: center.x - cross, y: center.y))
        crossPath.line(to: CGPoint(x: center.x + cross, y: center.y))
        crossPath.move(to: CGPoint(x: center.x, y: center.y - cross))
        crossPath.line(to: CGPoint(x: center.x, y: center.y + cross))
        NSColor.black.withAlphaComponent(0.35).setStroke()
        crossPath.lineWidth = 3.5
        crossPath.stroke()
        Self.magnifierCrosshairColor.setStroke()
        crossPath.lineWidth = 1.5
        crossPath.stroke()

        // 白色外圈 + 深色内衬
        NSColor.white.setStroke()
        let border = NSBezierPath(
            roundedRect: lens.insetBy(dx: 1, dy: 1),
            xRadius: magnifierCornerRadius - 1, yRadius: magnifierCornerRadius - 1
        )
        border.lineWidth = 2
        border.stroke()
        NSColor(white: 0.2, alpha: 0.9).setStroke()
        let inner = NSBezierPath(
            roundedRect: lens.insetBy(dx: 3, dy: 3),
            xRadius: magnifierCornerRadius - 2, yRadius: magnifierCornerRadius - 2
        )
        inner.lineWidth = 1
        inner.stroke()
    }
}

// MARK: - Text delegate

extension ScreenshotSelectionSurfaceView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        finishTextEntry(commit: !textCancelling)
        textCancelling = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textCancelling = true
            window?.makeFirstResponder(self)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            textCancelling = false
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }
}

// MARK: - Toolbar（参考截图：白色玻璃主条 + 工具二级面板）

final class SelectionToolbar: NSVisualEffectView {
    private var toolButtons: [Int: ToolbarButton] = [:]
    private var undoButton: ToolbarButton!
    private var redoButton: ToolbarButton!
    private var copyButton: ToolbarButton!
    private var saveButton: ToolbarButton!
    private var ocrButton: ToolbarButton!
    private var translateButton: ToolbarButton!
    private var qrButton: ToolbarButton!
    private var pinButton: ToolbarButton!
    private var shapeButton: ToolbarButton!
    private var currentShapeAsset = "Shape"
    private var modeScreenshotButton: ToolbarButton!
    private var modeLongButton: ToolbarButton!
    private var startLongButton: ToolbarButton!
    private let chromeTintView = NSView()

    /// 磨砂条叠加色：随系统深浅色自适应。
    /// 浅色用接近实白的底，保证叠在压暗的截图上时仍是一条干净的浅色工具条，
    /// 而不是被背景染成灰黑色。
    static let chromeTint: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.18, alpha: 0.92)
            : NSColor(white: 0.97, alpha: 0.96)
    }

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        // 磨砂条跟随系统外观：浅色叠白、深色叠深灰，避免深色模式下过亮
        let tint = chromeTintView
        tint.wantsLayer = true
        tint.layer?.backgroundColor = Self.chromeTint.cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        func add(_ tag: Int, _ look: ToolbarButton.Look, _ tooltip: String) -> ToolbarButton {
            let button = ToolbarButton(look: look, tooltip: tooltip, target: target, action: action)
            button.tag = tag
            button.size = NSSize(width: 31, height: 31)
            toolButtons[tag] = button
            stack.addArrangedSubview(button)
            return button
        }

        func add(_ tag: Int, _ symbol: String, _ tooltip: String) -> ToolbarButton {
            add(tag, .symbol(symbol), tooltip)
        }

        // 左侧模式切换（对齐 FloGravity「左侧切换模式」）：截图 / 长截图，Tab 也能切换
        modeScreenshotButton = add(20, .asset("Annotation"), L10n.tr("capture.mode.screenshot"))
        modeLongButton = add(21, .asset("LongCapture"), L10n.tr("capture.mode.long"))
        stack.addArrangedSubview(Self.divider())

        // 顺序对齐 FloGravity 6.3.10：批注 / 序号 / 形状 / 箭头 / 文字 / 画笔 / 更多
        // | 文字识别 | 撤销 / 重做 / 保存 / 钉图 / 复制 / 关闭 / 完成
        _ = add(0, .asset("Remark"), L10n.tr("editor.tool.pointer"))
        stack.addArrangedSubview(Self.divider())
        _ = add(7, .asset("Callout"), L10n.tr("editor.tool.stepBadge"))
        shapeButton = add(1, .asset("Shape"), L10n.tr("editor.tool.rectangle"))
        _ = add(3, .asset("Arrow"), L10n.tr("editor.tool.arrow"))
        _ = add(6, .asset("Text"), L10n.tr("editor.tool.text"))
        _ = add(4, .asset("Brush"), L10n.tr("editor.tool.pen"))
        _ = add(11, .assetWithChevron("More"), L10n.tr("editor.more"))
        stack.addArrangedSubview(Self.divider())
        ocrButton = add(9, .asset("OCR"), L10n.tr("editor.tool.ocr"))
        translateButton = add(14, .asset("Translate"), L10n.tr("editor.tool.translate"))
        qrButton = add(13, .asset("QRCode"), L10n.tr("editor.tool.qr"))
        stack.addArrangedSubview(Self.divider())

        undoButton = add(301, .asset("Undo"), L10n.tr("editor.undo"))
        redoButton = add(306, .asset("Redo"), L10n.tr("editor.redo"))
        saveButton = add(303, .asset("Download"), L10n.tr("editor.saveToFile"))
        pinButton = add(10, .asset("Pin"), L10n.tr("editor.tool.pin"))
        copyButton = add(302, "square.and.arrow.up", L10n.tr("editor.copy"))
        _ = add(304, .asset("Close"), L10n.tr("action.cancel"))
        _ = add(305, .asset("Complete"), L10n.tr("action.confirm"))
        startLongButton = add(12, .asset("Complete"), L10n.tr("capture.long.start"))
        startLongButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 系统切换深浅色时，layer 里的 CGColor 不会自动更新，这里重新解析
        effectiveAppearance.performAsCurrentDrawingAppearance {
            chromeTintView.layer?.backgroundColor = Self.chromeTint.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private static func divider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    func update(mode: CaptureMode, tool: ScreenshotAnnotation.Kind?, canUndo: Bool, canRedo: Bool, hasSelection: Bool) {
        let activeTag = Self.tag(for: tool) ?? 0
        for (tag, button) in toolButtons {
            let isAction = (301...306).contains(tag) || tag == 12 || tag == 20 || tag == 21
            button.selectedState = tag == activeTag && !isAction
        }
        modeScreenshotButton.selectedState = mode == .screenshot
        modeLongButton.selectedState = mode == .longCapture

        // 长截图模式隐藏标注区与撤销/保存/钉图/复制组，换成「开始长截图」
        let annotationTags = [0, 7, 1, 3, 6, 4, 11, 9, 14]
        for tag in annotationTags {
            toolButtons[tag]?.isHidden = mode == .longCapture
        }
        for tag in [301, 306, 303, 10, 302] {
            toolButtons[tag]?.isHidden = mode == .longCapture
        }
        toolButtons[305]?.isHidden = mode == .longCapture
        startLongButton.isHidden = mode != .longCapture
        startLongButton.isEnabled = hasSelection

        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        copyButton.isEnabled = hasSelection
        saveButton.isEnabled = hasSelection
        ocrButton.isEnabled = hasSelection
        translateButton.isEnabled = hasSelection
        qrButton.isEnabled = hasSelection
        pinButton.isEnabled = hasSelection
        switch tool {
        case .rectangle: setShapeAsset("ShapeRectangle")
        case .roundedRect: setShapeAsset("ShapeRoundedRectangle")
        case .ellipse: setShapeAsset("ShapeEllipse")
        case .triangle: setShapeAsset("ShapeTriangle")
        case .pentagon: setShapeAsset("ShapePentagon")
        case .hexagon: setShapeAsset("ShapeHexagon")
        case .star: setShapeAsset("ShapeStar")
        case .speechBubble: setShapeAsset("ShapeSpeechBubble")
        case .callout: setShapeAsset("Callout")
        default: break
        }
    }

    private func setShapeAsset(_ name: String) {
        guard currentShapeAsset != name else { return }
        currentShapeAsset = name
        shapeButton.setLook(.asset(name))
    }

    private static func tag(for tool: ScreenshotAnnotation.Kind?) -> Int? {
        switch tool {
        case .rectangle, .roundedRect, .ellipse, .triangle, .pentagon, .hexagon, .star, .speechBubble, .callout: return 1
        case .arrow: return 3
        case .pen: return 4
        case .mosaic: return 5
        case .text: return 6
        case .stepBadge: return 7
        case .highlighter: return 8
        case nil: return 0
        }
    }
}

final class SelectionOptionsBar: NSVisualEffectView {
    private let stack = NSStackView()
    private weak var target: AnyObject?
    private let action: Selector
    private var configuredTool: ScreenshotAnnotation.Kind?
    private var colorButtons: [Int: ToolbarButton] = [:]
    private var arrowButtons: [Int: ToolbarButton] = [:]
    private var mosaicButtons: [Int: ToolbarButton] = [:]
    private var opacitySlider: NSSlider?
    private var opacityValueLabel: NSTextField?
    private var sizeButton: PopupSizeButton?
    private var shapeButton: PopupShapeButton?
    private var widthButtons: [Int: ToolbarButton] = [:]
    private var boldButtons: [Int: ToolbarButton] = [:]
    private var alignButtons: [Int: ToolbarButton] = [:]
    private var previewDot: NSView?
    private let chromeTintView = NSView()

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let tint = chromeTintView
        tint.wantsLayer = true
        tint.layer?.backgroundColor = SelectionToolbar.chromeTint.cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            chromeTintView.layer?.backgroundColor = SelectionToolbar.chromeTint.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func configure(
        tool: ScreenshotAnnotation.Kind?,
        shapeKind: ScreenshotAnnotation.Kind,
        colorIndex: Int,
        strokeScale: CGFloat,
        widthPreset: Int,
        opacity: CGFloat,
        mosaicOpacity: CGFloat,
        arrowStyle: Int,
        mosaicStyle: Int,
        fontSize: CGFloat
    ) {
        guard let tool else {
            configuredTool = nil
            return
        }
        let activeOpacity = tool == .mosaic ? mosaicOpacity : opacity
        if configuredTool != tool {
            rebuild(for: tool, shapeKind: shapeKind, widthPreset: widthPreset, strokeScale: strokeScale, opacity: activeOpacity, arrowStyle: arrowStyle, mosaicStyle: mosaicStyle, fontSize: fontSize)
            configuredTool = tool
        }
        shapeButton?.titleText = PopupShapeButton.shapeTitle(shapeKind)
        shapeButton?.currentKind = shapeKind
        for (index, button) in widthButtons { button.selectedState = index == widthPreset }
        opacitySlider?.doubleValue = Double(activeOpacity)
        opacityValueLabel?.stringValue = "\(Int(round(activeOpacity * 100))) %"
        for (index, button) in colorButtons { button.selectedState = index == colorIndex }
        for (index, button) in arrowButtons { button.selectedState = index == arrowStyle }
        for (index, button) in mosaicButtons { button.selectedState = index == mosaicStyle }
        if let surface = target as? ScreenshotSelectionSurfaceView {
            for (_, button) in boldButtons { button.selectedState = surface.textBold }
            for (index, button) in alignButtons { button.selectedState = index == surface.textAlign }
        }
        previewDot?.layer?.backgroundColor = ScreenshotSelectionSurfaceView.paletteColor(colorIndex).cgColor
        sizeButton?.titleText = "\(Int(fontSize))"
    }

    /// 滑杆拖动时同步百分比文字（避免整条重建）。
    func updateOpacityDisplay(_ value: CGFloat) {
        opacityValueLabel?.stringValue = "\(Int(round(value * 100))) %"
    }

    private func rebuild(
        for tool: ScreenshotAnnotation.Kind,
        shapeKind: ScreenshotAnnotation.Kind,
        widthPreset: Int,
        strokeScale: CGFloat,
        opacity: CGFloat,
        arrowStyle: Int,
        mosaicStyle: Int,
        fontSize: CGFloat
    ) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        colorButtons.removeAll()
        arrowButtons.removeAll()
        mosaicButtons.removeAll()
        widthButtons.removeAll()
        boldButtons.removeAll()
        alignButtons.removeAll()
        opacitySlider = nil
        opacityValueLabel = nil
        sizeButton = nil
        shapeButton = nil
        previewDot = nil

        switch tool {
        case .rectangle, .roundedRect, .ellipse, .triangle, .pentagon, .hexagon, .star, .speechBubble, .callout:
            addShapeControl(kind: shapeKind)
            addDivider()
            addWidthControl(preset: widthPreset)
            addDivider()
            addColors()
        case .pen:
            addWidthControl(preset: widthPreset)
            addDivider()
            addColors()
        case .arrow:
            for index in 0..<3 {
                let button = ToolbarButton(look: .arrowStyle(index), tooltip: Self.arrowTooltip(index), target: target, action: action)
                button.tag = 401 + index
                button.size = NSSize(width: 28, height: 28)
                arrowButtons[index] = button
                stack.addArrangedSubview(button)
            }
            addDivider()
            addWidthControl(preset: widthPreset)
            addDivider()
            addColors()
        case .highlighter:
            addHighlightTextField()
            addDivider()
            addOpacityControl(value: opacity)
            addDivider()
            addColors()
        case .mosaic:
            for index in 0..<3 {
                let button = ToolbarButton(look: .mosaicShape(index), tooltip: Self.mosaicTooltip(index), target: target, action: action)
                button.tag = 411 + index
                button.size = NSSize(width: 28, height: 28)
                mosaicButtons[index] = button
                stack.addArrangedSubview(button)
            }
            addDivider()
            addOpacityControl(value: opacity)
        case .text:
            // 对齐浮引文字面板：加粗 + 对齐 | 字号 | 色板
            let surface = target as? ScreenshotSelectionSurfaceView
            let boldButton = ToolbarButton(look: .symbol("bold"), tooltip: L10n.tr("editor.text.bold"), target: target, action: action)
            boldButton.tag = 430
            boldButton.size = NSSize(width: 28, height: 28)
            boldButton.selectedState = surface?.textBold == true
            boldButtons[0] = boldButton
            stack.addArrangedSubview(boldButton)
            let alignSymbols = ["text.alignleft", "text.aligncenter", "text.alignright"]
            let alignTooltips = ["editor.align.left", "editor.align.center", "editor.align.right"]
            for index in 0..<3 {
                let button = ToolbarButton(look: .symbol(alignSymbols[index]), tooltip: L10n.tr(alignTooltips[index]), target: target, action: action)
                button.tag = 431 + index
                button.size = NSSize(width: 28, height: 28)
                button.selectedState = surface?.textAlign == index
                alignButtons[index] = button
                stack.addArrangedSubview(button)
            }
            addDivider()
            addTextSizeControl(fontSize: fontSize)
            addDivider()
            addColors()
        case .stepBadge:
            addColors()
        }
    }

    private static func arrowTooltip(_ index: Int) -> String {
        switch index {
        case 0: return L10n.tr("editor.arrow.solid")
        case 1: return L10n.tr("editor.arrow.outline")
        default: return L10n.tr("editor.arrow.line")
        }
    }

    private static func mosaicTooltip(_ index: Int) -> String {
        switch index {
        case 0: return L10n.tr("editor.mosaic.square")
        case 1: return L10n.tr("editor.mosaic.circle")
        default: return L10n.tr("editor.mosaic.rounded")
        }
    }

    private func addColors() {
        // 浮引 7 色命名色板（墨色/红/橙/黄/绿/蓝/紫）+ 自定义色
        for index in 0..<ScreenshotSelectionSurfaceView.paletteCount {
            let look: ToolbarButton.Look
            switch index {
            case 7: look = .customSwatch
            default: look = .color(ScreenshotSelectionSurfaceView.paletteColor(index))
            }
            let button = ToolbarButton(look: look, tooltip: "", target: target, action: action)
            button.tag = 101 + index
            button.size = NSSize(width: 26, height: 28)
            colorButtons[index] = button
            stack.addArrangedSubview(button)
        }
    }

    private func addShapeControl(kind: ScreenshotAnnotation.Kind) {
        let button = PopupShapeButton(current: kind, target: target, action: action)
        shapeButton = button
        stack.addArrangedSubview(button)
    }

    private func addWidthControl(preset: Int) {
        // 对齐浮引：粗细只有 小/中/大 三档（"跟随主题"是钉图属性，不进截图面板）
        let titles = [
            L10n.tr("editor.size.small"),
            L10n.tr("editor.size.medium"),
            L10n.tr("editor.size.large"),
        ]
        for (index, title) in titles.enumerated() {
            let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]).width
            let button = ToolbarButton(look: .chip(title), tooltip: "", target: target, action: action)
            button.tag = 511 + index
            button.size = NSSize(width: ceil(textWidth) + 16, height: 26)
            button.selectedState = index == preset
            widthButtons[index] = button
            stack.addArrangedSubview(button)
        }
        let preview = Self.dot(size: 16, color: ScreenshotSelectionSurfaceView.paletteColor(0))
        previewDot = preview
        stack.addArrangedSubview(preview)
    }

    private func addHighlightTextField() {
        let field = NSTextField(frame: .zero)
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11.5)
        field.placeholderString = L10n.tr("editor.highlight.placeholder")
        field.bezelStyle = .roundedBezel
        field.target = target
        field.action = action
        field.tag = 505
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 158).isActive = true
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(field)
    }

    private func addTextSizeControl(fontSize: CGFloat) {
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        chip.layer?.cornerRadius = 7
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: 26).isActive = true
        chip.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let glyph = NSTextField(labelWithString: "T")
        glyph.font = .systemFont(ofSize: 15, weight: .medium)
        glyph.textColor = .labelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
        stack.addArrangedSubview(chip)
        let button = PopupSizeButton(
            sizes: ScreenshotSelectionSurfaceView.textSizeOptions,
            current: fontSize,
            target: target,
            action: action
        )
        sizeButton = button
        stack.addArrangedSubview(button)
    }

    private func addOpacityControl(value: CGFloat) {
        let label = NSTextField(labelWithString: L10n.tr("editor.opacity"))
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        let slider = NSSlider(value: Double(value), minValue: 0.2, maxValue: 1, target: target, action: action)
        slider.tag = 502
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        opacitySlider = slider
        stack.addArrangedSubview(slider)
        let valueLabel = NSTextField(labelWithString: "\(Int(round(value * 100))) %")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .labelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        opacityValueLabel = valueLabel
        stack.addArrangedSubview(valueLabel)
    }

    private func addDivider() {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(line)
    }

    private static func dot(size: CGFloat, color: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = size / 2
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }
}

extension SelectionOptionsBar: NSTextFieldDelegate {
    /// 水印文字边输入边生效，不必等回车。
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field.tag == 505 else { return }
        _ = (target as? NSObject)?.perform(action, with: field)
    }
}

/// 参考图里的字号下拉：白色圆角小按钮 + 数值 + 折叠箭头。
final class PopupSizeButton: NSButton {    var titleText = "16" {
        didSet { needsDisplay = true }
    }
    private let sizeMenu: NSMenu

    init(sizes: [CGFloat], current: CGFloat, target: AnyObject?, action: Selector) {
        let menu = NSMenu()
        for size in sizes {
            let item = NSMenuItem(title: "\(Int(size))", action: action, keyEquivalent: "")
            item.target = target
            item.tag = 503
            item.representedObject = NSNumber(value: Double(size))
            menu.addItem(item)
        }
        sizeMenu = menu
        super.init(frame: .zero)
        isBordered = false
        title = ""
        refusesFirstResponder = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 58),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        titleText = "\(Int(current))"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 58, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (titleText as NSString).size(withAttributes: attrs)
        (titleText as NSString).draw(at: NSPoint(x: 10, y: bounds.midY - size.height / 2), withAttributes: attrs)

        let chevron = NSBezierPath()
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        let cx = bounds.maxX - 13
        let cy = bounds.midY
        chevron.move(to: NSPoint(x: cx - 4, y: cy - 2))
        chevron.line(to: NSPoint(x: cx, y: cy + 2))
        chevron.line(to: NSPoint(x: cx + 4, y: cy - 2))
        NSColor.secondaryLabelColor.setStroke()
        chevron.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        sizeMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }
}

/// 形状下拉（矩形/椭圆），对齐 FloGravity 样式面板的「形状」菜单。
final class PopupShapeButton: NSButton {
    var titleText: String {
        didSet { needsDisplay = true }
    }
    private let shapeMenu: NSMenu
    var currentKind: ScreenshotAnnotation.Kind
    private let shapeWidth: CGFloat

    init(current: ScreenshotAnnotation.Kind, target: AnyObject?, action: Selector) {
        currentKind = current
        let menu = NSMenu()
        for (tag, key) in [
            (601, "editor.tool.rectangle"),
            (603, "editor.tool.roundedRect"),
            (602, "editor.tool.ellipse"),
            (604, "editor.tool.triangle"),
            (605, "editor.tool.pentagon"),
            (606, "editor.tool.hexagon"),
            (607, "editor.tool.star"),
            (608, "editor.tool.speechBubble"),
            (609, "editor.tool.callout"),
        ] {
            let item = NSMenuItem(title: L10n.tr(key), action: action, keyEquivalent: "")
            item.target = target
            item.tag = tag
            menu.addItem(item)
        }
        shapeMenu = menu
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let longest = (L10n.tr("editor.tool.speechBubble") as NSString).size(withAttributes: [.font: font]).width
        let widest = max(
            (L10n.tr("editor.tool.rectangle") as NSString).size(withAttributes: [.font: font]).width,
            (L10n.tr("editor.tool.ellipse") as NSString).size(withAttributes: [.font: font]).width,
            longest
        )
        shapeWidth = ceil(widest) + 34
        titleText = ""
        super.init(frame: .zero)
        isBordered = false
        title = ""
        refusesFirstResponder = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: shapeWidth),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        titleText = Self.shapeTitle(current)
    }

    /// 形状下拉按钮显示的名称（对齐浮引形状菜单）
    static func shapeTitle(_ kind: ScreenshotAnnotation.Kind) -> String {
        switch kind {
        case .rectangle: return L10n.tr("editor.tool.rectangle")
        case .roundedRect: return L10n.tr("editor.tool.roundedRect")
        case .ellipse: return L10n.tr("editor.tool.ellipse")
        case .triangle: return L10n.tr("editor.tool.triangle")
        case .pentagon: return L10n.tr("editor.tool.pentagon")
        case .hexagon: return L10n.tr("editor.tool.hexagon")
        case .star: return L10n.tr("editor.tool.star")
        case .speechBubble: return L10n.tr("editor.tool.speechBubble")
        case .callout: return L10n.tr("editor.tool.callout")
        default: return L10n.tr("editor.tool.rectangle")
        }
    }

    /// 弹出菜单前同步当前形状勾选态
    func syncMenuSelection(_ kind: ScreenshotAnnotation.Kind) {
        let tagMap: [ScreenshotAnnotation.Kind: Int] = [
            .rectangle: 601, .roundedRect: 603, .ellipse: 602, .triangle: 604,
            .pentagon: 605, .hexagon: 606, .star: 607, .speechBubble: 608, .callout: 609,
        ]
        for item in shapeMenu.items {
            item.state = item.tag == tagMap[kind] ? .on : .off
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: shapeWidth, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (titleText as NSString).size(withAttributes: attrs)
        (titleText as NSString).draw(at: NSPoint(x: 10, y: bounds.midY - size.height / 2), withAttributes: attrs)

        let chevron = NSBezierPath()
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        let cx = bounds.maxX - 12
        let cy = bounds.midY
        chevron.move(to: NSPoint(x: cx - 4, y: cy - 2))
        chevron.line(to: NSPoint(x: cx, y: cy + 2))
        chevron.line(to: NSPoint(x: cx + 4, y: cy - 2))
        NSColor.secondaryLabelColor.setStroke()
        chevron.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        syncMenuSelection(currentKind)
        shapeMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }
}

/// 提取文字结果小窗（对齐浮引「识别结果」面板）：白卡片 + 标题/关闭 + 可选正文 + 复制按钮
final class OCRResultPanel: NSView {
    static let cardSize = NSSize(width: 420, height: 340)

    var idealSize: NSSize { Self.cardSize }

    private let text: String
    private let onClose: () -> Void

    init(title titleText: String, text: String, onClose: @escaping () -> Void) {
        self.text = text
        self.onClose = onClose
        super.init(frame: .zero)
        // 跟随系统深浅色：不再强制浅色，背景与文字都用语义色，深浅色下都清晰
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        updateChromeColors()

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // 正文放进滚动区：文本较长时不能溢出卡片，也不能只显示一半。
        // documentView 用 frame 布局（不用 Auto Layout），这是 NSScrollView 最稳的用法。
        let contentWidth: CGFloat = 372
        let body = NSTextField(wrappingLabelWithString: text)
        body.isSelectable = true
        body.isEditable = false
        body.drawsBackground = false
        body.isBordered = false
        body.font = .systemFont(ofSize: 14)
        body.textColor = .labelColor
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.preferredMaxLayoutWidth = contentWidth
        let needed = body.sizeThatFits(NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)).height
        body.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(ceil(needed) + 4, 24))
        body.autoresizingMask = [.width]

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let copyButton = NSButton(title: L10n.tr("action.copy"), target: self, action: #selector(copyClicked))
        copyButton.isBordered = false
        copyButton.wantsLayer = true
        copyButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        copyButton.layer?.cornerRadius = 17
        copyButton.contentTintColor = .white
        copyButton.font = .systemFont(ofSize: 14, weight: .medium)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -14),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            copyButton.widthAnchor.constraint(equalToConstant: 84),
            copyButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChromeColors()
    }

    /// layer 背景是 CGColor，不会随外观自动更新，需在初始化与外观变化时重新解析
    private func updateChromeColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    @objc private func closeClicked() {
        onClose()
    }

    @objc private func copyClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onClose()
    }
}

final class ToolbarButton: NSButton {
    enum Look {
        case symbol(String)
        case color(NSColor)
        case arrowStyle(Int)
        case mosaicShape(Int)
        case textGlyph
        case badgeGlyph
        case highlightGlyph
        case pointerGlyph
        case rectangleGlyph
        case arrowGlyph
        case pencilGlyph
        case mosaicGlyph
        case ocrGlyph
        case pinGlyph
        case asset(String)
        case assetWithChevron(String)
        case chip(String)
        case themeSwatch
        case customSwatch
    }

    private var look: Look {
        didSet { needsDisplay = true }
    }
    var size: NSSize = NSSize(width: 30, height: 30) {
        didSet {
            invalidateIntrinsicContentSize()
            // init 时建的固定约束必须同步更新，否则 chip 按钮仍是 30pt 宽、长文字画出边界
            widthConstraint?.constant = size.width
            heightConstraint?.constant = size.height
        }
    }
    var selectedState = false {
        didSet { needsDisplay = true }
    }
    private var hovering = false
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverTipWork: DispatchWorkItem?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    init(look: Look, tooltip: String, target: AnyObject?, action: Selector) {
        self.look = look
        super.init(frame: .zero)
        self.toolTip = tooltip.isEmpty ? nil : tooltip
        self.target = target
        self.action = action
        self.isBordered = false
        self.title = ""
        self.setButtonType(.momentaryChange)
        self.refusesFirstResponder = true
        // 面板空间不足时 NSStackView 会挤压按钮导致文字溢出（如"跟随主题"），禁止压缩
        self.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.setContentHuggingPriority(.required, for: .horizontal)
        self.translatesAutoresizingMaskIntoConstraints = false
        let wc = widthAnchor.constraint(equalToConstant: size.width)
        let hc = heightAnchor.constraint(equalToConstant: size.height)
        widthConstraint = wc
        heightConstraint = hc
        NSLayoutConstraint.activate([wc, hc])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setLook(_ newLook: Look) { look = newLook }

    override var intrinsicContentSize: NSSize { size }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // 只替换自己的 hover 区域；清空全部会连 AppKit 的 toolTip 追踪区一起删掉，提示就不弹了
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        hoverTipWork?.cancel()
        guard let text = toolTip, !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering, let window = self.window else { return }
            let rect = window.convertToScreen(self.convert(self.bounds, to: nil))
            HoverTipPanel.shared.show(text: text, near: rect)
        }
        hoverTipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        hoverTipWork?.cancel()
        hoverTipWork = nil
        HoverTipPanel.shared.hide()
    }

    override func mouseDown(with event: NSEvent) {
        hoverTipWork?.cancel()
        HoverTipPanel.shared.hide()
        super.mouseDown(with: event)
    }

    static func dismissHoverTip() {
        HoverTipPanel.shared.hide()
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = bounds.insetBy(dx: 1, dy: 1)
        if selectedState {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 7, yRadius: 7).fill()
        } else if hovering, isEnabled {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 7, yRadius: 7).fill()
        }

        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.3)
        let tint: NSColor = selectedState ? .controlAccentColor : .labelColor

        switch look {
        case .symbol(let name):
            if let symbol = Self.symbolImage(name, color: tint) {
                let rect = NSRect(
                    x: bounds.midX - symbol.size.width / 2,
                    y: bounds.midY - symbol.size.height / 2,
                    width: symbol.size.width, height: symbol.size.height
                )
                symbol.draw(in: rect)
            }
        case .color(let color):
            let swatch = NSRect(x: bounds.midX - 8.5, y: bounds.midY - 8.5, width: 17, height: 17)
            let path = NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4)
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(color == .white ? 0.2 : 0.08).setStroke()
            path.lineWidth = 1
            path.stroke()
            if selectedState {
                // 浅色块（白/黄/灰）用深勾，否则勾看不见
                var luminance: CGFloat = 0
                if let rgb = color.usingColorSpace(.sRGB) {
                    luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                }
                (luminance > 0.7 ? NSColor.black.withAlphaComponent(0.75) : NSColor.white).setStroke()
                let check = NSBezierPath()
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                // 绘制上下文是 flipped（y 向下），左起点在上、拐点在下方、右上收尾才是正 ✓
                check.move(to: CGPoint(x: swatch.minX + 4, y: swatch.midY - 1))
                check.line(to: CGPoint(x: swatch.minX + 7.5, y: swatch.midY + 3.5))
                check.line(to: CGPoint(x: swatch.maxX - 4, y: swatch.midY - 4))
                check.stroke()
            }
        case .arrowStyle(let index):
            drawArrowSample(index, tint: tint)
        case .mosaicShape(let index):
            drawMosaicSample(index, tint: tint)
        case .textGlyph:
            drawTextGlyph(tint: tint)
        case .badgeGlyph:
            drawBadgeGlyph(tint: tint)
        case .highlightGlyph:
            drawHighlightGlyph(tint: tint)
        case .pointerGlyph:
            drawPointerGlyph(tint: tint)
        case .rectangleGlyph:
            drawRectangleGlyph(tint: tint)
        case .arrowGlyph:
            drawArrowGlyph(tint: tint)
        case .pencilGlyph:
            drawPencilGlyph(tint: tint)
        case .mosaicGlyph:
            drawMosaicGlyph(tint: tint)
        case .ocrGlyph:
            drawOCRGlyph(tint: tint)
        case .pinGlyph:
            drawPinGlyph(tint: tint)
        case .asset(let name):
            drawArt(name, tint: tint)
        case .assetWithChevron(let name):
            drawArt(name, tint: tint, chevron: true)
        case .chip(let title):
            drawChip(title, tint: tint)
        case .themeSwatch:
            drawSpecialSwatch(theme: true)
        case .customSwatch:
            drawSpecialSwatch(theme: false)
        }
        NSGraphicsContext.current?.cgContext.setAlpha(1)
    }

    /// 跟随主题：黑白对半；自定义：四色环。
    private func drawSpecialSwatch(theme: Bool) {
        let swatch = NSRect(x: bounds.midX - 8.5, y: bounds.midY - 8.5, width: 17, height: 17)
        let clip = NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if theme {
            NSColor(white: 0.08, alpha: 1).setFill()
            NSRect(x: swatch.minX, y: swatch.minY, width: swatch.width / 2, height: swatch.height).fill()
            NSColor.white.setFill()
            NSRect(x: swatch.midX, y: swatch.minY, width: swatch.width / 2, height: swatch.height).fill()
        } else {
            let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue]
            for (i, color) in colors.enumerated() {
                color.setFill()
                let x = i % 2 == 0 ? swatch.minX : swatch.midX
                let y = i / 2 == 0 ? swatch.midY : swatch.minY
                NSRect(x: x, y: y, width: swatch.width / 2, height: swatch.height / 2).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        clip.lineWidth = 1
        clip.stroke()
        if selectedState {
            NSColor.white.setStroke()
            let check = NSBezierPath()
            check.lineWidth = 2
            check.lineCapStyle = .round
            check.move(to: CGPoint(x: swatch.minX + 4, y: swatch.midY - 1))
            check.line(to: CGPoint(x: swatch.minX + 7.5, y: swatch.midY + 3.5))
            check.line(to: CGPoint(x: swatch.maxX - 4, y: swatch.midY - 4))
            check.stroke()
        }
    }

    /// FloGravity 样式面板里的「小/中/大」胶囊按钮。
    private func drawChip(_ title: String, tint: NSColor) {
        let rect = bounds.insetBy(dx: 1, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (selectedState ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selectedState ? 1.5 : 1
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: selectedState ? NSColor.controlAccentColor : tint,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    /// FloGravity 原始工具条图标（38pt 线稿 PNG，模板着色）。
    private static var artCache: [String: NSImage] = [:]

    static func art(_ name: String) -> NSImage? {
        if let cached = artCache[name] { return cached }
        guard let url = Bundle.pasteMemoResources.url(
            forResource: "ScreenshotToolbar" + name,
            withExtension: "png",
            subdirectory: "Resources/ScreenshotToolbar"
        ), let image = NSImage(contentsOf: url) else { return nil }
        artCache[name] = image
        return image
    }

    private func drawArt(_ name: String, tint: NSColor, chevron: Bool = false) {
        guard let image = Self.art(name) else { return }
        // 线稿 PNG 缩得越小线条越灰，放大一点让描边更实
        let side: CGFloat = chevron ? 19 : 21
        let originX = chevron ? bounds.midX - side / 2 - 2.5 : bounds.midX - side / 2
        let rect = NSRect(x: originX, y: bounds.midY - side / 2, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        // 视图是 flipped（y 向下），respectFlipped: true 让 NSImage 自动翻正，否则图标上下颠倒
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        tint.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        if chevron {
            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let x = bounds.maxX - 5.5
            let y = bounds.midY
            path.move(to: NSPoint(x: x - 2.2, y: y + 1.4))
            path.line(to: NSPoint(x: x, y: y - 0.8))
            path.line(to: NSPoint(x: x + 2.2, y: y + 1.4))
            tint.setStroke()
            path.stroke()
        }
    }

    private func drawTextGlyph(tint: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: tint,
        ]
        let size = ("T" as NSString).size(withAttributes: attrs)
        ("T" as NSString).draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private func drawBadgeGlyph(tint: NSColor) {
        let outer = NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        let outerPath = NSBezierPath(roundedRect: outer, xRadius: 4, yRadius: 4)
        outerPath.lineWidth = 1.7
        tint.setStroke()
        outerPath.stroke()
        let inner = NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)
        tint.setFill()
        NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).fill()
    }

    private func drawHighlightGlyph(tint: NSColor) {
        tint.setStroke()
        for offset in [-4.5, 0, 4.5] as [CGFloat] {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: bounds.midX - 7 + offset, y: bounds.midY + 6))
            path.line(to: CGPoint(x: bounds.midX + 1 + offset, y: bounds.midY - 6))
            path.stroke()
        }
    }

    // 以下图标按参考图矢量绘制（原生 SF Symbol 形态和参考不一致）

    private func drawPointerGlyph(tint: NSColor) {
        let cx = bounds.midX, cy = bounds.midY
        let ring = NSBezierPath(ovalIn: NSRect(x: cx - 8, y: cy - 8, width: 16, height: 16))
        ring.lineWidth = 2
        tint.setStroke()
        ring.stroke()
        // 内侧左侧月牙形填充：外圆挖掉一块形成凹口
        let blob = NSBezierPath(ovalIn: NSRect(x: cx - 8.2, y: cy - 4.4, width: 9.6, height: 9.6))
        blob.append(NSBezierPath(ovalIn: NSRect(x: cx - 5.6, y: cy - 6.6, width: 5.4, height: 5.4)))
        blob.windingRule = .evenOdd
        tint.setFill()
        blob.fill()
    }

    private func drawRectangleGlyph(tint: NSColor) {
        let rect = NSRect(x: bounds.midX - 7.5, y: bounds.midY - 7.5, width: 15, height: 15)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4.2, yRadius: 4.2)
        path.lineWidth = 2
        tint.setStroke()
        path.stroke()
    }

    private func drawArrowGlyph(tint: NSColor) {
        // 参考图是开放 V 形箭头，不是实心三角
        let start = CGPoint(x: bounds.midX - 7, y: bounds.midY + 7)
        let end = CGPoint(x: bounds.midX + 7, y: bounds.midY - 7)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 7.5
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: start)
        path.line(to: end)
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - headLength * cos(angle - 0.55), y: end.y - headLength * sin(angle - 0.55)))
        path.move(to: end)
        path.line(to: CGPoint(x: end.x - headLength * cos(angle + 0.55), y: end.y - headLength * sin(angle + 0.55)))
        tint.setStroke()
        path.stroke()
    }

    private func drawPencilGlyph(tint: NSColor) {
        let cx = bounds.midX, cy = bounds.midY
        let dir = CGPoint(x: 0.7071, y: -0.7071)
        let perp = CGPoint(x: 0.7071, y: 0.7071)
        let halfWidth: CGFloat = 2.8
        let tip = CGPoint(x: cx - 8.5, y: cy + 8.5)
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(
                x: tip.x + dir.x * along + perp.x * across,
                y: tip.y + dir.y * along + perp.y * across
            )
        }
        let outline = NSBezierPath()
        outline.move(to: tip)
        outline.line(to: point(4.5, halfWidth))
        outline.line(to: point(20, halfWidth))
        outline.line(to: point(20, -halfWidth))
        outline.line(to: point(4.5, -halfWidth))
        outline.close()
        outline.lineWidth = 1.8
        outline.lineJoinStyle = .round
        tint.setStroke()
        outline.stroke()
        let ferrule = NSBezierPath()
        ferrule.lineWidth = 1.8
        ferrule.lineCapStyle = .round
        ferrule.move(to: point(4.5, -(halfWidth - 0.6)))
        ferrule.line(to: point(4.5, halfWidth - 0.6))
        tint.setStroke()
        ferrule.stroke()
    }

    private func drawMosaicGlyph(tint: NSColor) {
        let cx = bounds.midX, cy = bounds.midY
        let frame = NSRect(x: cx - 8, y: cy - 8, width: 16, height: 16)
        let framePath = NSBezierPath(roundedRect: frame, xRadius: 4.5, yRadius: 4.5)
        framePath.lineWidth = 2
        tint.setStroke()
        framePath.stroke()
        tint.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: frame.minX + 2.9, y: frame.minY + 2.9, width: 6.8, height: 6.8),
            xRadius: 1.4, yRadius: 1.4
        ).fill()
        NSBezierPath(
            roundedRect: NSRect(x: frame.maxX - 2.6 - 5.8, y: frame.maxY - 2.6 - 5.8, width: 5.8, height: 5.8),
            xRadius: 1.2, yRadius: 1.2
        ).fill()
    }

    private func drawOCRGlyph(tint: NSColor) {
        let cx = bounds.midX, cy = bounds.midY
        let halfW: CGFloat = 9, halfH: CGFloat = 8.5
        let cornerLen: CGFloat = 5.5
        let radius: CGFloat = 3
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        func corner(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
            path.move(to: CGPoint(x: x, y: y + dy * cornerLen))
            path.line(to: CGPoint(x: x, y: y + dy * radius))
            path.curve(
                to: CGPoint(x: x + dx * radius, y: y),
                controlPoint1: CGPoint(x: x, y: y),
                controlPoint2: CGPoint(x: x, y: y)
            )
            path.line(to: CGPoint(x: x + dx * cornerLen, y: y))
        }
        corner(cx - halfW, cy - halfH, 1, 1)
        corner(cx + halfW, cy - halfH, -1, 1)
        corner(cx - halfW, cy + halfH, 1, -1)
        corner(cx + halfW, cy + halfH, -1, -1)
        tint.setStroke()
        path.stroke()

        // 衬线 T
        let t = NSBezierPath()
        t.lineWidth = 2.2
        t.lineCapStyle = .butt
        t.lineJoinStyle = .round
        t.move(to: CGPoint(x: cx - 4.4, y: cy - 4.6))
        t.line(to: CGPoint(x: cx + 4.4, y: cy - 4.6))
        t.move(to: CGPoint(x: cx - 4.4, y: cy - 4.6))
        t.line(to: CGPoint(x: cx - 4.4, y: cy - 3.2))
        t.move(to: CGPoint(x: cx + 4.4, y: cy - 4.6))
        t.line(to: CGPoint(x: cx + 4.4, y: cy - 3.2))
        t.move(to: CGPoint(x: cx, y: cy - 4.6))
        t.line(to: CGPoint(x: cx, y: cy + 5))
        t.move(to: CGPoint(x: cx - 2.8, y: cy + 5))
        t.line(to: CGPoint(x: cx + 2.8, y: cy + 5))
        t.stroke()
    }

    private func drawPinGlyph(tint: NSColor) {
        let cx = bounds.midX, cy = bounds.midY
        let topY = cy - 8, bottomY = cy + 3
        let path = NSBezierPath()
        path.lineWidth = 1.9
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // 顶杆
        path.move(to: CGPoint(x: cx - 6.5, y: topY))
        path.line(to: CGPoint(x: cx + 6.5, y: topY))
        // 左侧：内收到腰再外撇
        path.move(to: CGPoint(x: cx - 6.5, y: topY))
        path.curve(
            to: CGPoint(x: cx - 3.3, y: cy - 0.5),
            controlPoint1: CGPoint(x: cx - 5.4, y: topY + 2.2),
            controlPoint2: CGPoint(x: cx - 4.2, y: cy - 3)
        )
        path.curve(
            to: CGPoint(x: cx - 6, y: bottomY),
            controlPoint1: CGPoint(x: cx - 2.5, y: cy + 1.2),
            controlPoint2: CGPoint(x: cx - 3.8, y: bottomY - 1.4)
        )
        // 右侧镜像
        path.move(to: CGPoint(x: cx + 6.5, y: topY))
        path.curve(
            to: CGPoint(x: cx + 3.3, y: cy - 0.5),
            controlPoint1: CGPoint(x: cx + 5.4, y: topY + 2.2),
            controlPoint2: CGPoint(x: cx + 4.2, y: cy - 3)
        )
        path.curve(
            to: CGPoint(x: cx + 6, y: bottomY),
            controlPoint1: CGPoint(x: cx + 2.5, y: cy + 1.2),
            controlPoint2: CGPoint(x: cx + 3.8, y: bottomY - 1.4)
        )
        // 底杆 + 针
        path.move(to: CGPoint(x: cx - 6, y: bottomY))
        path.line(to: CGPoint(x: cx + 6, y: bottomY))
        path.move(to: CGPoint(x: cx, y: bottomY))
        path.line(to: CGPoint(x: cx, y: cy + 6.5))
        tint.setStroke()
        path.stroke()
    }

    private func drawArrowSample(_ index: Int, tint: NSColor) {
        let start = CGPoint(x: bounds.midX - 6, y: bounds.midY + 6)
        let end = CGPoint(x: bounds.midX + 6, y: bounds.midY - 6)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 6
        let shaft = NSBezierPath()
        shaft.lineWidth = index == 2 ? 1.4 : 2.2
        shaft.lineCapStyle = .round
        shaft.move(to: start)
        if index == 0 {
            shaft.line(to: CGPoint(x: end.x - headLength * 0.7 * cos(angle), y: end.y - headLength * 0.7 * sin(angle)))
        } else {
            shaft.line(to: end)
        }
        tint.setStroke()
        shaft.stroke()
        if index == 0 {
            let head = NSBezierPath()
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - headLength * cos(angle - 0.5), y: end.y - headLength * sin(angle - 0.5)))
            head.line(to: CGPoint(x: end.x - headLength * cos(angle + 0.5), y: end.y - headLength * sin(angle + 0.5)))
            head.close()
            tint.setFill()
            head.fill()
        } else if index == 1 {
            let head = NSBezierPath()
            head.lineWidth = 1.7
            head.lineCapStyle = .round
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - headLength * cos(angle - 0.5), y: end.y - headLength * sin(angle - 0.5)))
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - headLength * cos(angle + 0.5), y: end.y - headLength * sin(angle + 0.5)))
            tint.setStroke()
            head.stroke()
        }
    }

    private func drawMosaicSample(_ index: Int, tint: NSColor) {
        let rect = NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14)
        let path: NSBezierPath
        switch index {
        case 1:
            path = NSBezierPath(ovalIn: rect)
        case 2:
            path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        default:
            path = NSBezierPath(rect: rect)
        }
        path.lineWidth = 1.7
        tint.setStroke()
        path.stroke()
    }

    private static func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [color]))
        return base.withSymbolConfiguration(config) ?? base
    }
}

/// 悬停提示：原生 tooltip 窗口层级很低，会被 screenSaver 级截图浮层盖住，所以自绘一层置顶小窗。
@MainActor
final class HoverTipPanel: NSPanel {
    static let shared = HoverTipPanel()

    private let label = NSTextField(labelWithString: "")

    private init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .white
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.09, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 5
        container.addSubview(label)
        contentView = container
    }

    func show(text: String, near buttonRect: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        let padX: CGFloat = 9, padY: CGFloat = 5
        let size = NSSize(width: ceil(label.frame.width) + padX * 2, height: ceil(label.frame.height) + padY * 2)
        label.setFrameOrigin(NSPoint(x: padX, y: padY))

        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: buttonRect.midX, y: buttonRect.midY)) } ?? NSScreen.main
        var origin = NSPoint(x: buttonRect.midX - size.width / 2, y: buttonRect.minY - size.height - 7)
        if let frame = screen?.frame {
            if origin.y < frame.minY + 4 { origin.y = buttonRect.maxY + 7 }
            origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

extension ScreenshotSelectionSurfaceView {
    static let paletteCount = 8
    static let textSizeOptions: [CGFloat] = [12, 16, 20, 24, 28, 32, 40]

    static func paletteColor(_ index: Int) -> NSColor {
        if index >= nsPalette.count { return customPaletteColor }
        return nsPalette[max(index, 0)]
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

// MARK: - 长截图 HUD（滚动捕获期间的悬浮控制条，与 FloGravity 一致放在捕获区域外）

final class LongCaptureHUD: NSPanel {
    private let statusLabel: NSTextField
    private let autoscrollButton: NSButton

    init(
        regionRect: CGRect, screen: NSScreen,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onAutoscroll: @escaping (Bool) -> Void
    ) {
        statusLabel = NSTextField(labelWithString: L10n.tr("capture.long.capturing"))
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor(white: 0.12, alpha: 1)

        autoscrollButton = NSButton(checkboxWithTitle: L10n.tr("capture.long.autoscroll"), target: nil, action: nil)
        autoscrollButton.font = .systemFont(ofSize: 12)

        let finishButton = NSButton(title: L10n.tr("capture.long.finish"), target: nil, action: nil)
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        finishButton.controlSize = .small
        finishButton.font = .systemFont(ofSize: 12, weight: .medium)

        let cancelButton = NSButton(title: L10n.tr("action.cancel"), target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 12)

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .aqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 1, alpha: 0.72).cgColor

        let stack = NSStackView(views: [statusLabel, autoscrollButton, finishButton, cancelButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        tint.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        effect.addSubview(stack)
        container.addSubview(effect)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        contentView = container

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: container.topAnchor, constant: 0),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 0),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 0),

            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
        ])

        // 目标回调（NSButton target 需要 target-action；用辅助闭包持有）
        finishButton.target = ClosureTarget.shared
        finishButton.action = #selector(ClosureTarget.finishAction)
        ClosureTarget.shared.finishHandler = onFinish
        cancelButton.target = ClosureTarget.shared
        cancelButton.action = #selector(ClosureTarget.cancelAction)
        ClosureTarget.shared.cancelHandler = onCancel
        autoscrollButton.target = ClosureTarget.shared
        autoscrollButton.action = #selector(ClosureTarget.autoscrollAction)
        ClosureTarget.shared.autoscrollHandler = onAutoscroll

        // 位置：优先捕获区域正上方；放不下则放区域下方（始终在捕获区域外，不会入镜）
        let width: CGFloat = 380
        let height: CGFloat = 52
        let gap: CGFloat = 12
        let visibleTop = screen.frame.maxY
        let visibleBottom = screen.frame.minY
        var hudOriginY = screen.frame.maxY - regionRect.minY + gap
        if hudOriginY + height > visibleTop {
            hudOriginY = screen.frame.maxY - regionRect.maxY - gap - height
        }
        hudOriginY = max(visibleBottom + 4, min(hudOriginY, visibleTop - height - 4))
        var x = screen.frame.minX + regionRect.midX - width / 2
        x = max(screen.frame.minX + 8, min(x, screen.frame.maxX - width - 8))
        setFrameOrigin(NSPoint(x: x, y: hudOriginY))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeKey: Bool { true }

    func showPanel() {
        makeKeyAndOrderFront(nil)
    }

    func update(height: Int, atBottom: Bool) {
        statusLabel.stringValue = atBottom
            ? L10n.tr("capture.long.bottom")
            : String(format: L10n.tr("capture.long.height"), height)
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 53 { // Esc 取消
            ClosureTarget.shared.cancelHandler?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// NSButton 需要 target-action 桥接闭包的最小容器。
@MainActor
final class ClosureTarget: NSObject {
    static let shared = ClosureTarget()
    var finishHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    var autoscrollHandler: ((Bool) -> Void)?
    /// 预览窗的输出数据（复制/保存用）
    var pngData: Data?
    weak var previewWindow: NSWindow?

    @objc func finishAction(_ sender: Any?) { finishHandler?() }
    @objc func cancelAction(_ sender: Any?) { cancelHandler?() }
    @objc func autoscrollAction(_ sender: NSButton) {
        autoscrollHandler?(sender.state == .on)
    }

    @objc func copyPNGAction(_ sender: Any?) {
        guard let pngData else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        previewWindow?.close()
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("capture.long.copied"), icon: .success))
    }

    @objc func savePNGAction(_ sender: Any?) {
        guard let pngData, let window = previewWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "LongScreenshot.png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                try? pngData.write(to: url)
            }
        }
    }
}

// MARK: - 长截图预览（完成后预览长图，复制或保存——对齐 FloGravity 流程）

@MainActor
final class LongCapturePreview {
    @discardableResult
    static func present(pngData: Data) -> NSWindow? {
        guard let image = NSImage(data: pngData) else { return nil }

        let size = image.size
        let maxWidth = min(760, (NSScreen.main?.frame.width ?? 1200) - 80)
        let maxHeight = (NSScreen.main?.frame.height ?? 900) - 160
        let windowWidth = maxWidth
        let windowHeight = min(maxHeight, max(360, size.height * min(1, maxWidth / size.width) + 92))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = L10n.tr("capture.long.preview")
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = NSImageView(image: image)
        (scrollView.documentView as? NSImageView)?.imageScaling = .scaleNone

        let copyButton = NSButton(title: L10n.tr("editor.copy"), target: nil, action: nil)
        copyButton.bezelStyle = .rounded
        let saveButton = NSButton(title: L10n.tr("editor.saveToFile"), target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        let infoLabel = NSTextField(labelWithString: "\(Int(size.width)) × \(Int(size.height)) px")
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor

        let buttonStack = NSStackView(views: [infoLabel, NSView(), saveButton, copyButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -4),
            buttonStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 40),
        ])
        window.contentView = container

        copyButton.target = ClosureTarget.shared
        copyButton.action = #selector(ClosureTarget.copyPNGAction)
        saveButton.target = ClosureTarget.shared
        saveButton.action = #selector(ClosureTarget.savePNGAction)
        ClosureTarget.shared.pngData = pngData
        ClosureTarget.shared.previewWindow = window

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
