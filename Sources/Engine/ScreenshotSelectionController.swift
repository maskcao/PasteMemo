import AppKit
import CoreGraphics
import UniformTypeIdentifiers

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

    private func closeAll() {
        ToolbarButton.dismissHoverTip()
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
            makeFirstResponder(contentView)
            contentView?.needsDisplay = true
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

    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []
    private var activeTool: ScreenshotAnnotation.Kind?
    private var colorIndex = 0
    private var weightIndex = 1
    /// 二级面板的可调参数：线宽倍率 / 荧光笔透明度 / 马赛克透明度 / 箭头样式 / 马赛克形状 / 字号
    private var strokeScale: CGFloat = 1.8
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

    private let magnifierDiameter: CGFloat = 88
    private let magnifierZoom: CGFloat = 8
    private let handleSize: CGFloat = 9

    private static let nsPalette: [NSColor] = [
        NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1),
        NSColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        NSColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
        NSColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1),
        NSColor.white,
    ]

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
        toolbar.update(
            tool: activeTool,
            canUndo: !undoStack.isEmpty,
            canRedo: !redoStack.isEmpty,
            hasSelection: selection != nil
        )
        optionsBar.configure(
            tool: activeTool,
            colorIndex: colorIndex,
            strokeScale: strokeScale,
            opacity: highlighterOpacity,
            mosaicOpacity: mosaicOpacity,
            arrowStyle: arrowStyle,
            mosaicStyle: mosaicStyle,
            fontSize: fontSize
        )
        needsLayout = true
    }

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
                    confirm()
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
        if draft != nil {
            commitDraft()
            return
        }
        if let _ = windowPickOrigin {
            // 原地点击 = 整窗选中（换选区 = 新画布，旧标注作废）
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
            selection = nil
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
        field.font = .systemFont(ofSize: textFontSize, weight: .semibold)
        field.textColor = Self.nsPalette[colorIndex]
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
        case 0:
            activeTool = nil
        case 1: toggleTool(.rectangle)
        case 2: toggleTool(.ellipse)
        case 3: toggleTool(.arrow)
        case 4: toggleTool(.pen)
        case 5: toggleTool(.mosaic)
        case 6: toggleTool(.text)
        case 7: toggleTool(.stepBadge)
        case 8: toggleTool(.highlighter)
        case 9: extractText()
        case 10: pinSelection()
        case 101...107:
            colorIndex = control.tag - 101
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
        case 36, 76: // Return / keypad Enter 确认
            if selection != nil { confirm() }
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

    private func extractText() {
        guard let png = croppedBasePNG() else { return }
        showChip(L10n.tr("editor.ocr.working"), duration: 4)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ImageOCRService.shared.recognizeText(from: png, markdown: false)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.showChip(L10n.tr("editor.ocr.empty"))
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self.showChip(L10n.tr("editor.ocr.copied"))
            } catch {
                self.showChip(L10n.tr("editor.ocr.failed"))
            }
        }
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

        // 标注只出现在选区内
        if let sel, !annotations.isEmpty || draft != nil {
            ctx.saveGState()
            ctx.clip(to: sel)
            drawAnnotationLayer(imageWidth: bounds.width)
            ctx.restoreGState()
        }

        if let sel {
            // 选区描边 + 8 手柄；拖拽中显示像素徽章，松手后换成工具条
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
        let color = Self.nsPalette[a.colorIndex]

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

        case .ellipse:
            let path = NSBezierPath(ovalIn: a.rect.insetBy(dx: stroke / 2, dy: stroke / 2))
            path.lineWidth = stroke
            color.setStroke()
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
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let alpha = a.opacity > 0 ? a.opacity : 1
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color.withAlphaComponent(alpha),
            ]
            (a.text as NSString).draw(at: a.start, withAttributes: attrs)
        }
    }

    // MARK: - Magnifier

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
    private var copyButton: ToolbarButton!
    private var saveButton: ToolbarButton!
    private var ocrButton: ToolbarButton!
    private var pinButton: ToolbarButton!

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        // 参考图是接近实白的磨砂条，纯 .popover 在深色底上会发灰，叠一层白。
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 1, alpha: 0.72).cgColor
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

        _ = add(0, .pointerGlyph, L10n.tr("editor.tool.pointer"))
        stack.addArrangedSubview(Self.divider())
        _ = add(1, .rectangleGlyph, L10n.tr("editor.tool.rectangle"))
        _ = add(2, "circle", L10n.tr("editor.tool.ellipse"))
        _ = add(3, .arrowGlyph, L10n.tr("editor.tool.arrow"))
        _ = add(4, .pencilGlyph, L10n.tr("editor.tool.pen"))
        _ = add(5, .mosaicGlyph, L10n.tr("editor.tool.mosaic"))
        _ = add(6, .textGlyph, L10n.tr("editor.tool.text"))
        stack.addArrangedSubview(Self.divider())
        _ = add(7, .badgeGlyph, L10n.tr("editor.tool.stepBadge"))
        _ = add(8, .highlightGlyph, L10n.tr("editor.tool.highlighter"))
        ocrButton = add(9, .ocrGlyph, L10n.tr("editor.tool.ocr"))
        pinButton = add(10, .pinGlyph, L10n.tr("editor.tool.pin"))
        stack.addArrangedSubview(Self.divider())

        undoButton = add(301, "arrow.uturn.backward", L10n.tr("editor.undo"))
        copyButton = add(302, "arrow.up.right.square", L10n.tr("editor.copy"))
        saveButton = add(303, "tray.and.arrow.down", L10n.tr("editor.saveToFile"))
        _ = add(304, "xmark", L10n.tr("action.cancel"))
        _ = add(305, "checkmark", L10n.tr("action.confirm"))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func divider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    func update(tool: ScreenshotAnnotation.Kind?, canUndo: Bool, canRedo: Bool, hasSelection: Bool) {
        let activeTag = Self.tag(for: tool) ?? 0
        for (tag, button) in toolButtons {
            button.selectedState = tag == activeTag && tag != 304 && tag != 305 && tag != 301 && tag != 302 && tag != 303
        }
        undoButton.isEnabled = canUndo
        copyButton.isEnabled = hasSelection
        saveButton.isEnabled = hasSelection
        ocrButton.isEnabled = hasSelection
        pinButton.isEnabled = hasSelection
    }

    private static func tag(for tool: ScreenshotAnnotation.Kind?) -> Int? {
        switch tool {
        case .rectangle: return 1
        case .ellipse: return 2
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
    private var widthSlider: NSSlider?
    private var opacitySlider: NSSlider?
    private var opacityValueLabel: NSTextField?
    private var sizeButton: PopupSizeButton?
    private var previewDot: NSView?

    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 1, alpha: 0.72).cgColor
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

    func configure(
        tool: ScreenshotAnnotation.Kind?,
        colorIndex: Int,
        strokeScale: CGFloat,
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
            rebuild(for: tool, strokeScale: strokeScale, opacity: activeOpacity, arrowStyle: arrowStyle, mosaicStyle: mosaicStyle, fontSize: fontSize)
            configuredTool = tool
        }
        widthSlider?.doubleValue = Double((strokeScale - 0.8) / 2.2)
        opacitySlider?.doubleValue = Double(activeOpacity)
        opacityValueLabel?.stringValue = "\(Int(round(activeOpacity * 100))) %"
        for (index, button) in colorButtons { button.selectedState = index == colorIndex }
        for (index, button) in arrowButtons { button.selectedState = index == arrowStyle }
        for (index, button) in mosaicButtons { button.selectedState = index == mosaicStyle }
        previewDot?.layer?.backgroundColor = ScreenshotSelectionSurfaceView.paletteColor(colorIndex).cgColor
        sizeButton?.titleText = "\(Int(fontSize))"
    }

    /// 滑杆拖动时同步百分比文字（避免整条重建）。
    func updateOpacityDisplay(_ value: CGFloat) {
        opacityValueLabel?.stringValue = "\(Int(round(value * 100))) %"
    }

    private func rebuild(
        for tool: ScreenshotAnnotation.Kind,
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
        widthSlider = nil
        opacitySlider = nil
        opacityValueLabel = nil
        sizeButton = nil
        previewDot = nil

        switch tool {
        case .rectangle, .ellipse, .pen:
            addWidthControl(scale: strokeScale)
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
            addWidthControl(scale: strokeScale)
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
        for index in 0..<ScreenshotSelectionSurfaceView.paletteCount {
            let button = ToolbarButton(look: .color(ScreenshotSelectionSurfaceView.paletteColor(index)), tooltip: "", target: target, action: action)
            button.tag = 101 + index
            button.size = NSSize(width: 26, height: 28)
            colorButtons[index] = button
            stack.addArrangedSubview(button)
        }
    }

    private func addWidthControl(scale: CGFloat) {
        let dot = Self.dot(size: 4, color: NSColor(white: 0.45, alpha: 1))
        stack.addArrangedSubview(dot)
        let slider = NSSlider(value: Double((scale - 0.8) / 2.2), minValue: 0, maxValue: 1, target: target, action: action)
        slider.tag = 501
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        widthSlider = slider
        stack.addArrangedSubview(slider)
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
        chip.layer?.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
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
        line.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
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
        NSColor(white: 1, alpha: 0.9).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.14).setStroke()
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
    }

    private let look: Look
    var size: NSSize = NSSize(width: 30, height: 30) {
        didSet { invalidateIntrinsicContentSize() }
    }
    var selectedState = false {
        didSet { needsDisplay = true }
    }
    private var hovering = false
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverTipWork: DispatchWorkItem?

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
        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
            NSColor.black.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 7, yRadius: 7).fill()
        } else if hovering, isEnabled {
            NSColor.black.withAlphaComponent(0.045).setFill()
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
        }
        NSGraphicsContext.current?.cgContext.setAlpha(1)
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
    static let paletteCount = 7
    static let textSizeOptions: [CGFloat] = [12, 16, 20, 24, 28, 32, 40]

    static func paletteColor(_ index: Int) -> NSColor {
        nsPalette[min(max(index, 0), nsPalette.count - 1)]
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
