import AppKit
import SwiftUI

/// 单条标注。几何用图片坐标（左上原点），跨预览/扁平化渲染一致。
struct ScreenshotAnnotation: Identifiable {
    enum Kind {
        case arrow, rectangle, text, stepBadge, mosaic
    }

    let id = UUID()
    var kind: Kind
    var colorIndex: Int
    var weightIndex: Int
    var start: CGPoint
    var end: CGPoint
    var text: String = ""
    var mosaicImage: NSImage?

    var rect: CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }
}

enum AnnotationStyle {
    static let palette: [Color] = [
        Color(red: 1.00, green: 0.27, blue: 0.23),
        Color(red: 1.00, green: 0.80, blue: 0.00),
        Color(red: 0.20, green: 0.78, blue: 0.35),
        Color(red: 0.00, green: 0.48, blue: 1.00),
        Color(red: 0.10, green: 0.10, blue: 0.12),
    ]

    static let weights: [CGFloat] = [1.0, 1.8, 3.0]
    static let textScales: [CGFloat] = [0.75, 1.0, 1.5]
    static let badgeScales: [CGFloat] = [0.8, 1.0, 1.3]

    // 笔画/字号按图宽等比， retina 2x 截图上不至于细成一发丝
    static func baseStroke(imageWidth: CGFloat) -> CGFloat { max(3, imageWidth / 300) }
    static func fontSize(imageWidth: CGFloat) -> CGFloat { max(14, imageWidth / 30) }
    static func badgeRadius(imageWidth: CGFloat) -> CGFloat { max(12, imageWidth / 50) }
}

/// 预览 Canvas 与 ImageRenderer 扁平化共用同一绘制入口，保证所见即所得。
enum AnnotationRenderer {
    static func draw(
        _ context: inout GraphicsContext,
        annotations: [ScreenshotAnnotation],
        inProgress: ScreenshotAnnotation?,
        imageWidth: CGFloat
    ) {
        for annotation in annotations {
            drawOne(&context, annotation, imageWidth)
        }
        if let inProgress {
            drawOne(&context, inProgress, imageWidth)
        }
    }

    private static func drawOne(_ context: inout GraphicsContext, _ a: ScreenshotAnnotation, _ imageWidth: CGFloat) {
        let stroke = AnnotationStyle.baseStroke(imageWidth: imageWidth) * AnnotationStyle.weights[a.weightIndex]
        let color = AnnotationStyle.palette[a.colorIndex]

        switch a.kind {
        case .arrow:
            var shaft = Path()
            shaft.move(to: a.start)
            shaft.addLine(to: a.end)
            context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .round))

            let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
            let headLength = max(stroke * 3.5, 10)
            var head = Path()
            head.move(to: a.end)
            head.addLine(to: CGPoint(
                x: a.end.x - headLength * cos(angle - 0.45),
                y: a.end.y - headLength * sin(angle - 0.45)
            ))
            head.move(to: a.end)
            head.addLine(to: CGPoint(
                x: a.end.x - headLength * cos(angle + 0.45),
                y: a.end.y - headLength * sin(angle + 0.45)
            ))
            context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))

        case .rectangle:
            let inset = stroke / 2
            let path = Path(a.rect.insetBy(dx: inset, dy: inset))
            context.stroke(path, with: .color(color), lineWidth: stroke)

        case .mosaic:
            if let mosaic = a.mosaicImage {
                context.draw(Image(nsImage: mosaic), in: a.rect)
            } else {
                context.fill(Path(a.rect), with: .color(.gray.opacity(0.35)))
            }

        case .stepBadge:
            let radius = AnnotationStyle.badgeRadius(imageWidth: imageWidth) * AnnotationStyle.badgeScales[a.weightIndex]
            let circle = CGRect(x: a.start.x - radius, y: a.start.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: circle), with: .color(color))
            context.stroke(Path(ellipseIn: circle), with: .color(.white), lineWidth: max(2, stroke * 0.7))
            let number = context.resolve(
                Text(a.text)
                    .font(.system(size: radius * 1.05, weight: .bold))
                    .foregroundColor(.white)
            )
            context.draw(number, at: a.start, anchor: .center)

        case .text:
            let fontSize = AnnotationStyle.fontSize(imageWidth: imageWidth) * AnnotationStyle.textScales[a.weightIndex]
            let font = Font.system(size: fontSize, weight: .semibold)
            // GraphicsContext.resolve 只接受裸 Text，阴影用底下一层偏移的深色拷贝来模拟
            let shadow = context.resolve(
                Text(a.text).font(font).foregroundColor(.black.opacity(0.35))
            )
            context.draw(shadow, at: CGPoint(x: a.start.x + stroke * 0.5, y: a.start.y + stroke * 0.5), anchor: .topLeading)
            let line = context.resolve(
                Text(a.text).font(font).foregroundColor(color)
            )
            context.draw(line, at: a.start, anchor: .topLeading)
        }
    }
}
