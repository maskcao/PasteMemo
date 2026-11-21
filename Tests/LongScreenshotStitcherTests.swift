import CoreGraphics
import Foundation
import Testing
@testable import PasteMemo

/// 长截图拼接引擎：匀速 / 随机变速滚动 + 到底检测。
/// 合成页每行 24 块灰度由 (pageRow, block) 哈希唯一确定，无平移自相似，可与真实 UI 等价看待。
@Suite("Long screenshot stitcher")
struct LongScreenshotStitcherTests {

    /// 灰度单通道合成帧：pixel = hash(pageRow, block)，每行内容唯一
    private func pagePixel(pageRow: Int, block: Int) -> UInt8 {
        let x = pageRow * 24 + block
        return UInt8(truncatingIfNeeded: (UInt64(x) &* 2654435761) &>> 32)
    }

    private func makeFrame(pageTop: Int, width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                let block = (col * 24) / width
                bytes[row * width + col] = pagePixel(pageRow: pageTop + row, block: block)
            }
        }
        let ctx = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return ctx.makeImage()!
    }

    private func runScroll(pageHeight: Int, frameH: Int, step: (Int) -> Int, maxTicks: Int = 300) -> (
        totalRows: Int, atBottom: Bool, frames: Int
    ) {
        let stitcher = LongScreenshotStitcher(pixelWidth: 720)
        var scrollY = 0
        stitcher.append(makeFrame(pageTop: 0, width: 720, height: frameH))
        var frames = 1
        var noAdd = 0
        var reachedBottom = false
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        for tick in 0..<maxTicks {
            let delta = step(tick)
            if delta == 0 {
                rng = rng &* 6_364_136_223_846_793_005 &+ 14_426_950_408_889_634_07
            }
            scrollY = min(scrollY + delta, pageHeight - frameH)
            let result = stitcher.append(makeFrame(pageTop: scrollY, width: 720, height: frameH))!
            frames += 1
            if result.addedRows == 0 {
                noAdd += 1
                if noAdd >= 4 {
                    reachedBottom = true
                    break
                }
            } else {
                noAdd = 0
            }
        }
        return (stitcher.totalRows, reachedBottom, frames)
    }

    @Test("匀速滚动：拼接行数精确等于页面高度，正确检测到底")
    func uniformScroll() {
        let result = runScroll(pageHeight: 3000, frameH: 400) { _ in 120 }
        #expect(result.totalRows == 3000)
        #expect(result.atBottom)
    }

    @Test("随机变速滚动：拼接行数精确，正确检测到底")
    func randomScroll() {
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        let result = runScroll(pageHeight: 5000, frameH: 360) { _ in
            rng = rng &* 6_364_136_223_846_793_005 &+ 14_426_950_408_889_634_07
            return Int((rng &>> 33) % 240)
        }
        #expect(result.totalRows == 5000)
        #expect(result.atBottom)
    }

    @Test("含停顿的滚动：停顿帧判定 atBottom，恢复滚动后继续拼接")
    func scrollWithPauses() {
        let stitcher = LongScreenshotStitcher(pixelWidth: 480)
        let frameH = 400
        stitcher.append(makeFrame(pageTop: 0, width: 480, height: frameH))
        // 停顿帧：内容与画布底部完全一致
        let pause = stitcher.append(makeFrame(pageTop: 0, width: 480, height: frameH))!
        #expect(pause.addedRows == 0)
        #expect(pause.atBottom)
        // 恢复滚动：继续正确拼接
        let next = stitcher.append(makeFrame(pageTop: 120, width: 480, height: frameH))!
        #expect(next.addedRows == 120)
        #expect(stitcher.totalRows == frameH + 120)
    }

    @Test("图像输出：宽度与首帧一致，高度等于累计行数")
    func imageOutput() {
        let stitcher = LongScreenshotStitcher(pixelWidth: 480)
        stitcher.append(makeFrame(pageTop: 0, width: 480, height: 400))
        stitcher.append(makeFrame(pageTop: 120, width: 480, height: 400))
        let image = stitcher.makeImage()
        #expect(image != nil)
        #expect(image?.width == 480)
        #expect(image?.height == 520)
    }
}
