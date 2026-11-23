import AppKit
import SwiftUI

/// 单条标注。几何用图片坐标（左上原点），跨预览/扁平化渲染一致。
struct ScreenshotAnnotation: Identifiable {
    enum Kind {
        case arrow, rectangle, roundedRect, ellipse, triangle, pentagon, hexagon, star, speechBubble, callout, pen, highlighter, text, stepBadge, mosaic
    }

    let id = UUID()
    var kind: Kind
    var colorIndex: Int
    var weightIndex: Int
    var start: CGPoint
    var end: CGPoint
    var text: String = ""
    var mosaicImage: NSImage?
    // pen / highlighter 的自由路径（图片坐标），其余 kind 不用
    var points: [CGPoint] = []
    /// 0 = 用 weightIndex 查表（老数据）；>0 = 连续线宽倍率（工具条滑杆）
    var strokeScale: CGFloat = 0
    /// 0 = 老默认（荧光笔 0.35、马赛克 1）；>0 = 用户选的不透明度
    var opacity: CGFloat = 0
    /// 0 实心箭头、1 线框箭头（老默认）、2 直线
    var arrowStyle: Int = 1
    /// 0 方形、1 圆形、2 圆角
    var mosaicStyle: Int = 0
    /// 0 = 按图宽自适应（老数据）；>0 = 用户选的绝对字号
    var fontSize: CGFloat = 0
    /// 文字是否加粗（对齐浮引「加粗」⌘B）
    var isBold = false
    /// 文字对齐：0 左、1 中、2 右
    var alignIndex = 0

    var rect: CGRect {
        if kind == .pen || kind == .highlighter, !points.isEmpty {
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(
                x: xs.min()!, y: ys.min()!,
                width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!
            )
        }
        return CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    /// 裁剪后整体平移（mosaicImage 是像素块，跟着 rect 走即可）
    func translated(dx: CGFloat, dy: CGFloat) -> ScreenshotAnnotation {
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }
}

enum AnnotationStyle {
    static let palette: [Color] = [
        Color(red: 1.00, green: 0.27, blue: 0.23),
        Color(red: 0.20, green: 0.78, blue: 0.35),
        Color(red: 0.00, green: 0.48, blue: 1.00),
        Color(red: 0.68, green: 0.32, blue: 0.88),
        Color.white,
        Color(red: 0.10, green: 0.10, blue: 0.12),
        Color(red: 0.10, green: 0.10, blue: 0.12),
        Color(red: 0.68, green: 0.32, blue: 0.88),
    ]

    static let weights: [CGFloat] = [1.0, 1.8, 3.0]
    static let textScales: [CGFloat] = [0.75, 1.0, 1.5]
    /// 序号大小三档（小/中/大）：档位差拉大，肉眼一眼可辨
    static let badgeScales: [CGFloat] = [0.7, 1.0, 1.4]

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
        let weight = a.strokeScale > 0 ? a.strokeScale : AnnotationStyle.weights[a.weightIndex]
        let stroke = AnnotationStyle.baseStroke(imageWidth: imageWidth) * weight
        let color = AnnotationStyle.palette[min(max(a.colorIndex, 0), AnnotationStyle.palette.count - 1)]

        switch a.kind {
        case .arrow:
            let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
            let headLength = max(stroke * 3.5, 10)
            var shaft = Path()
            shaft.move(to: a.start)
            if a.arrowStyle == 0 {
                shaft.addLine(to: CGPoint(
                    x: a.end.x - headLength * 0.7 * cos(angle),
                    y: a.end.y - headLength * 0.7 * sin(angle)
                ))
            } else {
                shaft.addLine(to: a.end)
            }
            context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .round))

            if a.arrowStyle == 0 {
                var head = Path()
                head.move(to: a.end)
                head.addLine(to: CGPoint(
                    x: a.end.x - headLength * cos(angle - 0.42),
                    y: a.end.y - headLength * sin(angle - 0.42)
                ))
                head.addLine(to: CGPoint(
                    x: a.end.x - headLength * cos(angle + 0.42),
                    y: a.end.y - headLength * sin(angle + 0.42)
                ))
                head.closeSubpath()
                context.fill(head, with: .color(color))
            } else if a.arrowStyle == 1 {
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
            }

        case .rectangle:
            let inset = stroke / 2
            let path = Path(a.rect.insetBy(dx: inset, dy: inset))
            context.stroke(path, with: .color(color), lineWidth: stroke)

        case .roundedRect:
            let inset = stroke / 2
            let rect = a.rect.insetBy(dx: inset, dy: inset)
            // 圆角随短边缩放（对齐 FloGravity 圆角矩形观感），上限 24pt
            let radius = min(min(rect.width, rect.height) * 0.2, 24)
            let path = Path(roundedRect: rect, cornerRadius: radius)
            context.stroke(path, with: .color(color), lineWidth: stroke)

        case .ellipse:
            let inset = stroke / 2
            let path = Path(ellipseIn: a.rect.insetBy(dx: inset, dy: inset))
            context.stroke(path, with: .color(color), lineWidth: stroke)

        case .triangle, .pentagon, .hexagon:
            let inset = stroke / 2
            let path = Self.regularPolygonPath(kind: a.kind, in: a.rect.insetBy(dx: inset, dy: inset))
            context.stroke(path, with: .color(color), lineWidth: stroke)

        case .star:
            let inset = stroke / 2
            let path = Self.starPath(in: a.rect.insetBy(dx: inset, dy: inset))
            context.stroke(path, with: .color(color), lineWidth: stroke)

        case .speechBubble, .callout:
            let inset = stroke / 2
            let path = Self.bubblePath(kind: a.kind, in: a.rect.insetBy(dx: inset, dy: inset), stroke: stroke)
            context.stroke(path, with: .color(color), lineWidth: stroke)

        case .pen, .highlighter:
            var path = Path()
            let line = a.points.isEmpty ? [a.start, a.end] : a.points
            path.addLines(line)
            if a.kind == .highlighter {
                // 荧光笔：整条路径一次 stroke，半透明在单次合成里不会因线段交叠而叠深
                context.stroke(
                    path, with: .color(color.opacity(a.opacity > 0 ? a.opacity : 0.35)),
                    style: StrokeStyle(lineWidth: stroke * 4, lineCap: .round, lineJoin: .round)
                )
            } else {
                context.stroke(
                    path, with: .color(color),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                )
            }

        case .mosaic:
            context.drawLayer { layer in
                switch a.mosaicStyle {
                case 1:
                    layer.clip(to: Path(ellipseIn: a.rect))
                case 2:
                    let radius = min(a.rect.width, a.rect.height) * 0.2
                    layer.clip(to: Path(roundedRect: a.rect, cornerRadius: radius))
                default:
                    break
                }
                if let mosaic = a.mosaicImage {
                    layer.opacity = a.opacity > 0 ? a.opacity : 1
                    layer.draw(Image(nsImage: mosaic), in: a.rect)
                } else {
                    layer.fill(Path(a.rect), with: .color(.gray.opacity(0.35)))
                }
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
            let fontSize = a.fontSize > 0
                ? a.fontSize
                : AnnotationStyle.fontSize(imageWidth: imageWidth) * AnnotationStyle.textScales[a.weightIndex]
            let font = Font.system(size: fontSize, weight: a.isBold ? .bold : .semibold)
            // GraphicsContext.resolve 只接受裸 Text；行内对齐由扁平化导出的 paragraphStyle 兜底
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

    /// 正多边形路径（三角形/五边形/六边形），顶边起、顺时针（对齐浮引形状观感）
    static func regularPolygonPath(kind: ScreenshotAnnotation.Kind, in rect: CGRect) -> Path {
        let sides: CGFloat
        switch kind {
        case .triangle: sides = 3
        case .pentagon: sides = 5
        default: sides = 6
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let scaleX = rect.width / (radius * 2)
        let scaleY = rect.height / (radius * 2)
        // 顶点朝上：从 -90° 开始
        let start = -Double.pi / 2
        var path = Path()
        for i in 0..<Int(sides) {
            let angle = start + Double(i) * (2 * .pi / Double(sides))
            let point = CGPoint(
                x: center.x + cos(angle) * radius * scaleX,
                y: center.y + sin(angle) * radius * scaleY
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// 五角星路径（顶点朝上）
    static func starPath(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.42
        let scaleX = rect.width / (outer * 2)
        let scaleY = rect.height / (outer * 2)
        var path = Path()
        for i in 0..<10 {
            let radius = i % 2 == 0 ? outer : inner
            let angle = -Double.pi / 2 + Double(i) * (.pi / 5)
            let point = CGPoint(
                x: center.x + cos(angle) * radius * scaleX,
                y: center.y + sin(angle) * radius * scaleY
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// 对话气泡（圆角矩形 + 左下尾巴）与标注气泡（椭圆 + 右下尾巴）
    static func bubblePath(kind: ScreenshotAnnotation.Kind, in rect: CGRect, stroke: CGFloat) -> Path {
        let tail: CGFloat = min(rect.width, rect.height) * 0.25
        let bubble: CGRect
        var path = Path()
        if kind == .speechBubble {
            bubble = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height - tail, rect.height * 0.5))
            let radius = min(min(bubble.width, bubble.height) * 0.2, 18)
            path.addPath(Path(roundedRect: bubble, cornerRadius: radius))
            // 左下尾巴（朝左下角）
            let tip = CGPoint(x: rect.minX + tail * 0.35, y: rect.maxY)
            path.move(to: CGPoint(x: bubble.minX + bubble.width * 0.22, y: bubble.maxY - stroke))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: bubble.minX + bubble.width * 0.42, y: bubble.maxY - stroke))
        } else {
            bubble = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height - tail, rect.height * 0.5))
            path.addPath(Path(ellipseIn: bubble))
            // 右下尾巴
            let tip = CGPoint(x: rect.maxX - tail * 0.35, y: rect.maxY)
            path.move(to: CGPoint(x: bubble.maxX - bubble.width * 0.40, y: bubble.maxY - stroke))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: bubble.maxX - bubble.width * 0.20, y: bubble.maxY - stroke))
        }
        return path
    }
}
