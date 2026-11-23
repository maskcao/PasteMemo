import AppKit

/// 冻结帧取色器：把选区面的视图坐标换算成冻结帧里的像素坐标，并取出该像素的 sRGB 分量。
///
/// 抽成独立类型是为了能脱离界面单测「坐标换算 + 取色」这两件最容易出错的事：
/// 视图是 flipped（左上原点），CGImage 也是左上原点，但缩放比（Retina 为 2）不等，
/// 换算错一个像素，读数面板就会和放大镜里看到的那一格对不上。
struct ScreenshotPixelSampler {

    /// 取色结果：图像像素坐标（左上原点）+ sRGB 分量（0-255）
    struct Sample: Equatable {
        let px: Int
        let py: Int
        let r: Int
        let g: Int
        let b: Int

        /// 统一按 sRGB 描述颜色，方便输出 HEX / RGB 两种格式
        var color: ParsedColor {
            ParsedColor(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1, originalFormat: .hex)
        }
    }

    let image: NSImage
    /// 冻结帧像素 / 视图点的比例（Retina 屏为 2）
    let pixelScale: CGFloat

    /// 1×1 取色用的 sRGB 上下文（复用，免去每次移动鼠标都新建）
    private let context: CGContext? = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )

    init(image: NSImage, pixelScale: CGFloat) {
        self.image = image
        self.pixelScale = pixelScale
    }

    /// 视图坐标（flipped，左上原点）→ 冻结帧像素坐标（左上原点）
    func pixel(atViewPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x * pixelScale).rounded(.down),
            y: (point.y * pixelScale).rounded(.down)
        )
    }

    /// 取某个图像像素的 sRGB 分量；越界返回 nil
    func sample(pixelX: Int, pixelY: Int) -> Sample? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              pixelX >= 0, pixelY >= 0, pixelX < cg.width, pixelY < cg.height,
              let cropped = cg.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)),
              let context
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let alpha = Int(base[3])
        guard alpha > 0 else { return Sample(px: pixelX, py: pixelY, r: 0, g: 0, b: 0) }
        // 上下文是预乘 alpha 的，还原成直通分量
        let scale = 255.0 / Double(alpha)
        return Sample(
            px: pixelX,
            py: pixelY,
            r: min(255, Int((Double(base[0]) * scale).rounded())),
            g: min(255, Int((Double(base[1]) * scale).rounded())),
            b: min(255, Int((Double(base[2]) * scale).rounded()))
        )
    }

    /// 取视图坐标处的取色结果
    func sample(atViewPoint point: CGPoint) -> Sample? {
        let pixel = pixel(atViewPoint: point)
        return sample(pixelX: Int(pixel.x), pixelY: Int(pixel.y))
    }
}
