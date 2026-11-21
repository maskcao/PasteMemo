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
    private var draft: ScreenshotAnnotation?
    private var textField: NSTextField?
    private var textCancelling = false

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

    private enum ResizeEdge { case none, topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight }

    private let magnifierDiameter: CGFloat = 88
    private let magnifierZoom: CGFloat = 8
    private let handleSize: CGFloat = 9

    private static let nsPalette: [NSColor] = [
        NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1),
        NSColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
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
            return
        }
        toolbar.isHidden = false
        let size = toolbar.fittingSize
        var x = sel.midX - size.width / 2
        var y = sel.maxY + 10
        if y + size.height > bounds.height {
            y = sel.minY - 10 - size.height
        }
        x = max(8, min(x, bounds.width - size.width - 8))
        y = max(8, min(y, bounds.height - size.height - 8))
        toolbar.frame = NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func syncToolbar() {
        toolbar.update(
            tool: activeTool,
            color: colorIndex,
            weight: weightIndex,
            canUndo: !undoStack.isEmpty,
            canRedo: !redoStack.isEmpty
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
        default:
            draft = ScreenshotAnnotation(kind: tool, colorIndex: colorIndex, weightIndex: weightIndex, start: point, end: point)
            if tool == .pen || tool == .highlighter {
                draft?.points = [point]
            }
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

    private var textFontSize: CGFloat {
        AnnotationStyle.fontSize(imageWidth: bounds.width) * AnnotationStyle.textScales[weightIndex]
    }

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
            annotations.append(annotation)
        }
        needsDisplay = true
        syncToolbar()
    }

    // MARK: - Toolbar

    @objc private func toolbarAction(_ sender: NSButton) {
        finishTextEntry(commit: true)
        switch sender.tag {
        case 1: toggleTool(.rectangle)
        case 2: toggleTool(.ellipse)
        case 3: toggleTool(.arrow)
        case 4: toggleTool(.pen)
        case 5: toggleTool(.highlighter)
        case 6: toggleTool(.text)
        case 7: toggleTool(.stepBadge)
        case 8: toggleTool(.mosaic)
        case 101...105:
            colorIndex = sender.tag - 101
            needsDisplay = true
            syncToolbar()
        case 201...203:
            weightIndex = sender.tag - 201
            needsDisplay = true
            syncToolbar()
        case 301: undoAnnotation()
        case 302: redoAnnotation()
        case 303: saveToFile()
        case 304: owner?.cancel()
        case 305: confirm()
        default: break
        }
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
        let block = max(8, min(pixelRect.width, pixelRect.height) / 12)
        let smallW = max(1, Int(pixelRect.width / block))
        let smallH = max(1, Int(pixelRect.height / block))
        guard let small = CGContext(
            data: nil, width: smallW, height: smallH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        small.interpolationQuality = .high
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let smallImage = small.makeImage(),
              let big = CGContext(
                data: nil, width: Int(pixelRect.width), height: Int(pixelRect.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        big.interpolationQuality = .none
        big.draw(smallImage, in: CGRect(x: 0, y: 0, width: pixelRect.width, height: pixelRect.height))
        guard let mosaicCG = big.makeImage() else { return nil }
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
        let stroke = AnnotationStyle.baseStroke(imageWidth: imageWidth) * AnnotationStyle.weights[a.weightIndex]
        let color = Self.nsPalette[a.colorIndex]

        switch a.kind {
        case .arrow:
            let path = NSBezierPath()
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: a.start)
            path.line(to: a.end)
            let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
            let headLength = max(stroke * 3.5, 10)
            path.move(to: a.end)
            path.line(to: CGPoint(
                x: a.end.x - headLength * cos(angle - 0.45),
                y: a.end.y - headLength * sin(angle - 0.45)
            ))
            path.move(to: a.end)
            path.line(to: CGPoint(
                x: a.end.x - headLength * cos(angle + 0.45),
                y: a.end.y - headLength * sin(angle + 0.45)
            ))
            color.setStroke()
            path.stroke()

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
                color.withAlphaComponent(0.35).setStroke()
            } else {
                path.lineWidth = stroke
                color.setStroke()
            }
            path.stroke()

        case .mosaic:
            if let mosaic = a.mosaicImage {
                mosaic.draw(in: a.rect)
            } else {
                NSColor.gray.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: a.rect).fill()
            }

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
            let fontSize = AnnotationStyle.fontSize(imageWidth: imageWidth) * AnnotationStyle.textScales[a.weightIndex]
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            // 阴影 = 底下一层偏移的深色拷贝
            let shadowAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black.withAlphaComponent(0.35),
            ]
            (a.text as NSString).draw(at: CGPoint(x: a.start.x + stroke * 0.5, y: a.start.y + stroke * 0.5), withAttributes: shadowAttrs)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
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

// MARK: - Toolbar（浮引式玻璃条）

final class SelectionToolbar: NSVisualEffectView {
    private var toolButtons: [Int: ToolbarButton] = [:]
    private var colorButtons: [ToolbarButton] = []
    private var weightButtons: [ToolbarButton] = []
    private var undoButton: ToolbarButton!
    private var redoButton: ToolbarButton!

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let tools: [(Int, String, String)] = [
            (1, "rectangle", "editor.tool.rectangle"),
            (2, "circle", "editor.tool.ellipse"),
            (3, "arrow.up.right", "editor.tool.arrow"),
            (4, "pencil.tip", "editor.tool.pen"),
            (5, "highlighter", "editor.tool.highlighter"),
            (6, "textformat", "editor.tool.text"),
            (7, "1.circle", "editor.tool.stepBadge"),
            (8, "square.grid.3x3", "editor.tool.mosaic"),
        ]
        for (tag, symbol, key) in tools {
            let button = ToolbarButton(look: .symbol(symbol), tooltip: L10n.tr(key), target: target, action: action)
            button.tag = tag
            button.size = NSSize(width: 28, height: 28)
            toolButtons[tag] = button
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(Self.divider())

        for index in 0..<ScreenshotSelectionSurfaceView.paletteCount {
            let button = ToolbarButton(look: .color(Self.paletteColor(index)), tooltip: "", target: target, action: action)
            button.tag = 101 + index
            button.size = NSSize(width: 22, height: 28)
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(Self.divider())

        for (index, weight) in AnnotationStyle.weights.enumerated() {
            let button = ToolbarButton(look: .width(weight), tooltip: "", target: target, action: action)
            button.tag = 201 + index
            button.size = NSSize(width: 22, height: 28)
            weightButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(Self.divider())

        undoButton = ToolbarButton(look: .symbol("arrow.uturn.backward"), tooltip: L10n.tr("editor.undo"), target: target, action: action)
        undoButton.tag = 301
        undoButton.size = NSSize(width: 28, height: 28)
        stack.addArrangedSubview(undoButton)

        redoButton = ToolbarButton(look: .symbol("arrow.uturn.forward"), tooltip: L10n.tr("editor.redo"), target: target, action: action)
        redoButton.tag = 302
        redoButton.size = NSSize(width: 28, height: 28)
        stack.addArrangedSubview(redoButton)

        stack.addArrangedSubview(Self.divider())

        let saveButton = ToolbarButton(look: .symbol("square.and.arrow.down"), tooltip: L10n.tr("editor.saveToFile"), target: target, action: action)
        saveButton.tag = 303
        saveButton.size = NSSize(width: 28, height: 28)
        stack.addArrangedSubview(saveButton)

        stack.addArrangedSubview(Self.divider())

        let cancelButton = ToolbarButton(look: .symbol("xmark"), tooltip: L10n.tr("action.cancel"), target: target, action: action)
        cancelButton.tag = 304
        cancelButton.size = NSSize(width: 28, height: 28)
        stack.addArrangedSubview(cancelButton)

        let confirmButton = ToolbarButton(look: .symbol("checkmark"), tooltip: L10n.tr("action.confirm"), target: target, action: action)
        confirmButton.tag = 305
        confirmButton.size = NSSize(width: 28, height: 28)
        confirmButton.emphasized = true
        stack.addArrangedSubview(confirmButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func divider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    private static func paletteColor(_ index: Int) -> NSColor {
        ScreenshotSelectionSurfaceView.paletteColor(index)
    }

    func update(tool: ScreenshotAnnotation.Kind?, color: Int, weight: Int, canUndo: Bool, canRedo: Bool) {
        for (tag, button) in toolButtons {
            button.selectedState = Self.tag(for: tool) == tag
        }
        for (index, button) in colorButtons.enumerated() {
            button.selectedState = index == color
        }
        for (index, button) in weightButtons.enumerated() {
            button.selectedState = index == weight
        }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    private static func tag(for tool: ScreenshotAnnotation.Kind?) -> Int? {
        switch tool {
        case .rectangle: return 1
        case .ellipse: return 2
        case .arrow: return 3
        case .pen: return 4
        case .highlighter: return 5
        case .text: return 6
        case .stepBadge: return 7
        case .mosaic: return 8
        case nil: return nil
        }
    }
}

final class ToolbarButton: NSButton {
    enum Look {
        case symbol(String)
        case color(NSColor)
        case width(CGFloat)
    }

    private let look: Look
    var size: NSSize = NSSize(width: 28, height: 28) {
        didSet { invalidateIntrinsicContentSize() }
    }
    var selectedState = false {
        didSet { needsDisplay = true }
    }
    var emphasized = false
    private var hovering = false

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
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = bounds.insetBy(dx: 1, dy: 2)
        if selectedState {
            NSColor.white.withAlphaComponent(0.24).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
        } else if hovering, isEnabled {
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
        }

        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.35)
        switch look {
        case .symbol(let name):
            if emphasized {
                NSColor(red: 0.086, green: 0.467, blue: 1, alpha: 1).setFill()
                let circle = NSRect(
                    x: bounds.midX - 12, y: bounds.midY - 12,
                    width: 24, height: 24
                )
                NSBezierPath(ovalIn: circle).fill()
            }
            if let symbol = Self.symbolImage(name) {
                let rect = NSRect(
                    x: bounds.midX - symbol.size.width / 2,
                    y: bounds.midY - symbol.size.height / 2,
                    width: symbol.size.width, height: symbol.size.height
                )
                symbol.draw(in: rect)
            }
        case .color(let color):
            let circle = NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            if selectedState {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        case .width(let width):
            NSColor.white.setStroke()
            let line = NSBezierPath()
            line.lineWidth = width
            line.lineCapStyle = .round
            line.move(to: CGPoint(x: bounds.midX - 6, y: bounds.midY))
            line.line(to: CGPoint(x: bounds.midX + 6, y: bounds.midY))
            line.stroke()
        }
        NSGraphicsContext.current?.cgContext.setAlpha(1)
    }

    private static func symbolImage(_ name: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        return base.withSymbolConfiguration(config) ?? base
    }
}

extension ScreenshotSelectionSurfaceView {
    static let paletteCount = 5

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
