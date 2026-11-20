import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class ScreenshotEditorViewModel {
    enum Tool: CaseIterable {
        case arrow, rectangle, text, stepBadge, mosaic

        var icon: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .text: "textformat"
            case .stepBadge: "number.circle"
            case .mosaic: "checkerboard.rectangle"
            }
        }

        var helpKey: String {
            switch self {
            case .arrow: "editor.tool.arrow"
            case .rectangle: "editor.tool.rectangle"
            case .text: "editor.tool.text"
            case .stepBadge: "editor.tool.stepBadge"
            case .mosaic: "editor.tool.mosaic"
            }
        }
    }

    struct TextDraft {
        var point: CGPoint
        var string: String
    }

    let image: NSImage
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var undoStack: [[ScreenshotAnnotation]] = []
    private(set) var redoStack: [[ScreenshotAnnotation]] = []
    var tool: Tool = .arrow
    var colorIndex = 0
    var weightIndex = 1
    var textDraft: TextDraft?

    private var dragStart: CGPoint?
    private(set) var inProgress: ScreenshotAnnotation?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(image: NSImage) {
        self.image = image
    }

    // MARK: - Gestures (points already converted to image coordinates)

    func dragMoved(at point: CGPoint) {
        if dragStart == nil { dragStart = point }
        guard let start = dragStart else { return }
        switch tool {
        case .arrow:
            inProgress = ScreenshotAnnotation(kind: .arrow, colorIndex: colorIndex, weightIndex: weightIndex, start: start, end: point)
        case .rectangle:
            inProgress = ScreenshotAnnotation(kind: .rectangle, colorIndex: colorIndex, weightIndex: weightIndex, start: start, end: point)
        case .mosaic:
            inProgress = ScreenshotAnnotation(kind: .mosaic, colorIndex: colorIndex, weightIndex: weightIndex, start: start, end: point)
        case .text, .stepBadge:
            inProgress = nil
        }
    }

    func dragEnded(at point: CGPoint, tapThreshold: CGFloat = 8) {
        defer {
            dragStart = nil
            inProgress = nil
        }
        guard let start = dragStart else { return }
        let travel = abs(point.x - start.x) + abs(point.y - start.y)

        switch tool {
        case .arrow, .rectangle:
            guard travel > tapThreshold else { return }
            commit(ScreenshotAnnotation(
                kind: tool == .arrow ? .arrow : .rectangle,
                colorIndex: colorIndex, weightIndex: weightIndex,
                start: start, end: point
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
        }
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
        redoStack.append(annotations)
        annotations = previous
        textDraft = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        textDraft = nil
    }

    private func commit(_ annotation: ScreenshotAnnotation) {
        pushUndo()
        annotations.append(annotation)
    }

    private func pushUndo() {
        undoStack.append(annotations)
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
