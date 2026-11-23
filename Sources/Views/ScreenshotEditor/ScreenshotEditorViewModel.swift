import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class ScreenshotEditorViewModel {
    enum Tool: CaseIterable {
        case rectangle, ellipse, arrow, pen, highlighter, text, stepBadge, mosaic, crop

        var icon: String {
            switch self {
            case .rectangle: "rectangle"
            case .ellipse: "ellipse"
            case .arrow: "arrow.up.right"
            case .pen: "scribble.variable"
            case .highlighter: "highlighter"
            case .text: "textformat"
            case .stepBadge: "number.circle"
            case .mosaic: "checkerboard.rectangle"
            case .crop: "crop"
            }
        }

        var helpKey: String {
            switch self {
            case .rectangle: "editor.tool.rectangle"
            case .ellipse: "editor.tool.ellipse"
            case .arrow: "editor.tool.arrow"
            case .pen: "editor.tool.pen"
            case .highlighter: "editor.tool.highlighter"
            case .text: "editor.tool.text"
            case .stepBadge: "editor.tool.stepBadge"
            case .mosaic: "editor.tool.mosaic"
            case .crop: "editor.tool.crop"
            }
        }
    }

    struct TextDraft {
        var point: CGPoint
        var string: String
    }

    /// 撤销快照：图像 + 标注一起存（裁剪会同时改两者）
    struct Snapshot {
        let image: NSImage
        let annotations: [ScreenshotAnnotation]
    }

    private(set) var image: NSImage
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []
    var tool: Tool = .arrow
    /// 颜色 / 粗细沿用上次的选择（编辑器色板与浮层不是同一套，下标分开记）
    var colorIndex = 0 {
        didSet { rememberStyle() }
    }
    var weightIndex = 1 {
        didSet { rememberStyle() }
    }
    var textDraft: TextDraft?
    private(set) var isCropping = false
    private(set) var cropRect: CGRect?

    private var dragStart: CGPoint?
    private(set) var inProgress: ScreenshotAnnotation?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(image: NSImage) {
        self.image = image
        let settings = ScreenshotAnnotationSettings.load()
        self.colorIndex = settings.editorColorIndex
        self.weightIndex = settings.editorWeightIndex
    }

    /// 记住编辑器里选的颜色与粗细，下次打开沿用
    private func rememberStyle() {
        var settings = ScreenshotAnnotationSettings.load()
        settings.editorColorIndex = colorIndex
        settings.editorWeightIndex = weightIndex
        settings.save()
    }

    // MARK: - Gestures (points already converted to image coordinates)

    func dragMoved(at point: CGPoint) {
        if dragStart == nil { dragStart = point }
        guard let start = dragStart else { return }
        if isCropping {
            cropRect = Self.normalizedRect(from: start, to: point)
            return
        }
        switch tool {
        case .rectangle:
            inProgress = ScreenshotAnnotation(kind: .rectangle, colorIndex: colorIndex, weightIndex: weightIndex, start: start, end: point)
        case .ellipse:
            inProgress = ScreenshotAnnotation(kind: .ellipse, colorIndex: colorIndex, weightIndex: weightIndex, start: start, end: point)
        case .arrow:
            inProgress = ScreenshotAnnotation(kind: .arrow, colorIndex: colorIndex, weightIndex: weightIndex, start: start, end: point)
        case .pen, .highlighter:
            let kind: ScreenshotAnnotation.Kind = tool == .pen ? .pen : .highlighter
            var points = inProgress?.points ?? [start]
            points.append(point)
            inProgress = ScreenshotAnnotation(kind: kind, colorIndex: colorIndex, weightIndex: weightIndex, start: start, end: point, points: points)
        case .mosaic:
            inProgress = ScreenshotAnnotation(kind: .mosaic, colorIndex: colorIndex, weightIndex: weightIndex, start: start, end: point)
        case .text, .stepBadge, .crop:
            inProgress = nil
        }
    }

    func dragEnded(at point: CGPoint, tapThreshold: CGFloat = 8) {
        defer {
            dragStart = nil
            inProgress = nil
        }
        guard let start = dragStart else { return }
        if isCropping { return } // cropRect 在 dragMoved 里已实时更新
        let travel = abs(point.x - start.x) + abs(point.y - start.y)

        switch tool {
        case .rectangle, .ellipse, .arrow:
            guard travel > tapThreshold else { return }
            let kind: ScreenshotAnnotation.Kind = tool == .rectangle ? .rectangle : (tool == .ellipse ? .ellipse : .arrow)
            commit(ScreenshotAnnotation(
                kind: kind,
                colorIndex: colorIndex, weightIndex: weightIndex,
                start: start, end: point
            ))
        case .pen, .highlighter:
            let kind: ScreenshotAnnotation.Kind = tool == .pen ? .pen : .highlighter
            var points = inProgress?.points ?? [start]
            if points.count == 1 { points.append(point) } // 单击也出个圆点
            commit(ScreenshotAnnotation(
                kind: kind,
                colorIndex: colorIndex, weightIndex: weightIndex,
                start: start, end: point, points: points
            ))
        case .mosaic:
            let region = ScreenshotAnnotation(
                kind: .mosaic, colorIndex: colorIndex, weightIndex: weightIndex,
                start: start, end: point
            ).rect
            guard region.width >= tapThreshold, region.height >= tapThreshold,
                  let mosaic = Self.makeMosaicImage(of: image, rect: region) else { return }
            commit(ScreenshotAnnotation(
                kind: .mosaic, colorIndex: colorIndex, weightIndex: weightIndex,
                start: start, end: point, mosaicImage: mosaic
            ))
        case .stepBadge:
            let number = annotations.filter { $0.kind == .stepBadge }.count + 1
            commit(ScreenshotAnnotation(
                kind: .stepBadge, colorIndex: colorIndex, weightIndex: weightIndex,
                start: point, end: point, text: "\(number)"
            ))
        case .text:
            textDraft = TextDraft(point: point, string: "")
        case .crop:
            break
        }
    }

    // MARK: - Crop

    func toggleCrop() {
        if isCropping {
            exitCrop()
        } else {
            isCropping = true
            tool = .crop
            cropRect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        }
    }

    func exitCrop() {
        isCropping = false
        cropRect = nil
        tool = .arrow
    }

    func applyCrop() {
        guard isCropping, let rect = cropRect,
              rect.width >= 4, rect.height >= 4 else {
            exitCrop()
            return
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage,
              image.size.width > 0 else {
            exitCrop()
            return
        }
        let pxPerPt = CGFloat(rep.pixelsWide) / image.size.width
        let pixelRect = CGRect(
            x: rect.minX * pxPerPt, y: rect.minY * pxPerPt,
            width: rect.width * pxPerPt, height: rect.height * pxPerPt
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let cropped = cgImage.cropping(to: pixelRect) else {
            exitCrop()
            return
        }
        let newImage = NSImage(
            cgImage: cropped,
            size: NSSize(width: pixelRect.width / pxPerPt, height: pixelRect.height / pxPerPt)
        )
        pushUndo()
        image = newImage
        // 标注随裁剪整体平移；越界部分由画布自然裁掉
        let dx = -CGFloat(pixelRect.minX) / pxPerPt
        let dy = -CGFloat(pixelRect.minY) / pxPerPt
        annotations = annotations.map { $0.translated(dx: dx, dy: dy) }
        exitCrop()
    }

    private static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
    }

    func commitText() {
        guard let draft = textDraft,
              !draft.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            textDraft = nil
            return
        }
        commit(ScreenshotAnnotation(
            kind: .text, colorIndex: colorIndex, weightIndex: weightIndex,
            start: draft.point, end: draft.point, text: draft.string
        ))
        textDraft = nil
    }

    func cancelText() {
        textDraft = nil
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(image: image, annotations: annotations))
        image = previous.image
        annotations = previous.annotations
        textDraft = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(image: image, annotations: annotations))
        image = next.image
        annotations = next.annotations
        textDraft = nil
    }

    private func commit(_ annotation: ScreenshotAnnotation) {
        pushUndo()
        annotations.append(annotation)
    }

    private func pushUndo() {
        undoStack.append(Snapshot(image: image, annotations: annotations))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    // MARK: - Flatten (save)

    func flattenedPNGData() -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = ImageRenderer(content: ScreenshotFlatView(image: image, annotations: annotations))
        // retina 源图按原生像素密度出图，别把 2x 截图压回逻辑分辨率
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           rep.pixelsWide > 0 {
            renderer.scale = CGFloat(rep.pixelsWide) / size.width
        } else {
            renderer.scale = 1
        }
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    // MARK: - Mosaic

    static func makeMosaicImage(of source: NSImage, rect: CGRect) -> NSImage? {
        guard let tiff = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage,
              source.size.width > 0 else { return nil }
        let pxPerPt = CGFloat(rep.pixelsWide) / source.size.width
        let pixelRect = CGRect(
            x: rect.minX * pxPerPt, y: rect.minY * pxPerPt,
            width: rect.width * pxPerPt, height: rect.height * pxPerPt
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        guard pixelRect.width >= 4, pixelRect.height >= 4,
              let cropped = cgImage.cropping(to: pixelRect) else { return nil }

        let block = max(10, min(pixelRect.width, pixelRect.height) / 12)
        let smallW = max(1, Int(pixelRect.width / block))
        let smallH = max(1, Int(pixelRect.height / block))

        guard let smallContext = makeBitmapContext(width: smallW, height: smallH),
              let outputContext = makeBitmapContext(width: Int(pixelRect.width), height: Int(pixelRect.height)) else { return nil }
        // 缩小用平均插值（真正的像素化，不残留单点采样），放大用无插值出硬边块；
        // CGContext.draw 自带的翻转在两步里正好抵消
        smallContext.interpolationQuality = .high
        smallContext.draw(cropped, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        guard let smallImage = smallContext.makeImage() else { return nil }
        outputContext.interpolationQuality = .none
        outputContext.draw(smallImage, in: CGRect(x: 0, y: 0, width: pixelRect.width, height: pixelRect.height))
        guard let outputImage = outputContext.makeImage() else { return nil }
        return NSImage(cgImage: outputImage, size: NSSize(width: pixelRect.width, height: pixelRect.height))
    }

    private static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
