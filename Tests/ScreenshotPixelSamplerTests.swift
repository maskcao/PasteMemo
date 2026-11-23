import AppKit
import CoreGraphics
import Testing
@testable import PasteMemo

/// 冻结帧取色：视图坐标 → 像素坐标的换算，以及取到的颜色是否就是画面上那一格。
/// 视图是 flipped（左上原点）、CGImage 也是左上原点，两者只差一个缩放比；
/// 换算错一个像素，放大镜里的十字与读数面板就会指向不同的像素。
@Suite("Screenshot pixel sampler")
struct ScreenshotPixelSamplerTests {

    /// 4×4 冻结帧：
    /// - 左上角 2×2 是 #8A8A8A（图像坐标 0-2 行、0-2 列）
    /// - 右下角 2×2 是 #FF0000（图像坐标 2-4 行、2-4 列）
    private func makeImage() -> NSImage {
        let ctx = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // CGContext 是左下原点，所以「左上角」在 CG 坐标里是 y = 2 那一段
        ctx.setFillColor(NSColor(srgbRed: 138.0 / 255.0, green: 138.0 / 255.0, blue: 138.0 / 255.0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 2, width: 2, height: 2))
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: 4, height: 4))
    }

    @Test("视图坐标按缩放比换算成像素坐标（向左下取整）")
    func pixelMappingFollowsScale() {
        let image = makeImage()
        let plain = ScreenshotPixelSampler(image: image, pixelScale: 1)
        #expect(plain.pixel(atViewPoint: CGPoint(x: 1.7, y: 2.9)) == CGPoint(x: 1, y: 2))

        // Retina：1 个视图点 = 2 个像素
        let retina = ScreenshotPixelSampler(image: image, pixelScale: 2)
        #expect(retina.pixel(atViewPoint: CGPoint(x: 1.7, y: 2.9)) == CGPoint(x: 3, y: 5))
    }

    @Test("取到的颜色就是画面上那一格的颜色")
    func sampleMatchesPixelColor() {
        let sampler = ScreenshotPixelSampler(image: makeImage(), pixelScale: 1)
        let gray = sampler.sample(pixelX: 0, pixelY: 0)
        #expect(gray == ScreenshotPixelSampler.Sample(px: 0, py: 0, r: 138, g: 138, b: 138))
        let red = sampler.sample(pixelX: 3, pixelY: 3)
        #expect(red == ScreenshotPixelSampler.Sample(px: 3, py: 3, r: 255, g: 0, b: 0))
    }

    @Test("越界取色返回 nil，不给假颜色")
    func outOfBoundsIsNil() {
        let sampler = ScreenshotPixelSampler(image: makeImage(), pixelScale: 1)
        #expect(sampler.sample(pixelX: -1, pixelY: 0) == nil)
        #expect(sampler.sample(pixelX: 0, pixelY: 4) == nil)
        #expect(sampler.sample(pixelX: 4, pixelY: 0) == nil)
        #expect(sampler.sample(atViewPoint: CGPoint(x: 99, y: 99)) == nil)
    }

    @Test("按视图坐标取色，缩放比决定落到哪个像素")
    func sampleByViewPoint() {
        let image = makeImage()
        let plain = ScreenshotPixelSampler(image: image, pixelScale: 1)
        #expect(plain.sample(atViewPoint: CGPoint(x: 0.5, y: 0.5))?.r == 138)

        // Retina 上同一视图点落在第 2 个像素上，已经越过灰色块
        let retina = ScreenshotPixelSampler(image: image, pixelScale: 2)
        #expect(retina.sample(atViewPoint: CGPoint(x: 0.5, y: 0.5))?.px == 1)
        #expect(retina.sample(atViewPoint: CGPoint(x: 0.5, y: 0.5))?.r == 138)
    }

    @Test("色值可按 HEX / RGB 两种格式输出")
    func colorFormatting() {
        let sampler = ScreenshotPixelSampler(image: makeImage(), pixelScale: 1)
        let color = sampler.sample(pixelX: 0, pixelY: 0)?.color
        #expect(color?.formatted(.hex) == "#8A8A8A")
        #expect(color?.formatted(.rgb) == "rgb(138, 138, 138)")
    }
}
