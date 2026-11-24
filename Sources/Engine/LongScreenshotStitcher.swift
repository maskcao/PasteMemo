import CoreGraphics
import Foundation

/// 长截图拼接引擎：对连续抓取的选区帧做重叠检测，只把新内容追加到画布底部。
/// 匹配用「行 × 色块」灰度签名（CoreGraphics 缩放到 24 列逐行取均值），
/// 对内容单一（整片空白/纯色）的行自动跳过，避免在空白区匹配出错误偏移。
/// 画布位图随追加重建（新内容总在底部 = y-up 坐标里把旧内容上移），峰值内存 ≈ 成品长图。
final class LongScreenshotStitcher {
    struct AppendResult: Equatable {
        /// 本次实际新增的行数（像素）
        let addedRows: Int
        /// 追加后画布总行数
        let totalRows: Int
        /// 帧顶部与画布重叠的行数；0 = 无可信匹配（整帧追加）
        let matchedOverlap: Int?
        /// 整帧与画布完全重叠 = 没有滚动（连续多次即判定到底）
        var atBottom: Bool { matchedOverlap != nil && addedRows == 0 }
    }

    /// 匹配接受的平均色差阈值（0-255 灰度刻度）
    private let matchThreshold: Float
    /// 用于校验重叠的顶部条带行数
    private let stripRows: Int
    /// 向前搜索的最大重叠行数
    private let maxOverlapRows: Int
    /// 行签名色块数
    private static let blockCount = 24
    /// 行被视作「有信息量」所需的最小对比度（块均值的 max-min，0-255 刻度）
    private static let informativeContrast: Float = 8
    /// 可信匹配需要的最少有信息量行数
    private static let minInformativeRows = 8

    private(set) var totalRows = 0
    private var canvasContext: CGContext?
    private var rowSignatures: [[Float]] = []

    private let canvasWidth: Int

    init(
        pixelWidth: Int,
        matchThreshold: Float = 10,
        stripRows: Int = 40,
        maxOverlapRows: Int = 1600
    ) {
        self.canvasWidth = max(1, pixelWidth)
        self.matchThreshold = matchThreshold
        self.stripRows = stripRows
        self.maxOverlapRows = maxOverlapRows
    }

    func reset() {
        canvasContext = nil
        rowSignatures = []
        totalRows = 0
    }

    /// 追加一帧（宽度必须与初始化 pixelWidth 一致）。首帧无条件全量接收。
    /// 滚动时新内容出现在帧底部：帧顶部条带与画布底部对齐后，帧中超出画布底部的部分才是新内容。
    @discardableResult
    func append(_ frame: CGImage) -> AppendResult? {
        guard frame.width == pixelWidth, frame.height >= 1 else { return nil }
        let frameSig = Self.rowSignatures(of: frame)
        guard frameSig.count == frame.height else { return nil }

        // overlap = 帧顶部与画布重叠的行数；0 表示无可信匹配（整帧追加）。
        // overlap == frame.height 表示整帧已在画布里（没有滚动，可能已到底）。
        let overlap = totalRows > 0 ? (findOverlap(frameSignature: frameSig, frameHeight: frame.height) ?? 0) : 0
        let startRow = overlap
        let added = frame.height - startRow
        guard added > 0 else {
            return AppendResult(addedRows: 0, totalRows: totalRows, matchedOverlap: overlap)
        }
        // 新内容是画布最底部：image 行 [totalRows, totalRows+added) ↔ y-up [0, added)，顶部对齐 y=added
        guard let segment = frame.cropping(to: CGRect(x: 0, y: startRow, width: frame.width, height: added)),
              let ctx = rebuildCanvas(height: totalRows + added) else { return nil }
        ctx.draw(segment, in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(added)))
        canvasContext = ctx
        rowSignatures.append(contentsOf: frameSig[startRow...])
        totalRows += added
        return AppendResult(addedRows: added, totalRows: totalRows, matchedOverlap: overlap)
    }

    var pixelWidth: Int { canvasWidth }

    /// 合成当前完整长图（顶行 = 最先捕获的内容）。
    func makeImage() -> CGImage? {
        canvasContext?.makeImage()
    }

    // MARK: - Matching

    /// 搜索帧顶部条带在画布底部区域的重叠行数 o（帧行 [0, o) 已存在于画布底部）。
    /// o == frameHeight 表示整帧都在画布里 = 没有滚动（可能已到底）。
    private func findOverlap(frameSignature: [[Float]], frameHeight: Int) -> Int? {
        // o 至少 stripRows（条带要完整落在画布内才能校验），至多 min(frameHeight, maxOverlapRows, totalRows)
        let maxO = min(frameHeight, maxOverlapRows, totalRows)
        guard maxO >= stripRows else { return nil }

        var bestO: Int?
        var bestError = Float.greatestFiniteMagnitude
        // 升序搜索、严格更优才替换：误差并列时保留更小的 o（追加更多内容）。
        // 重复比丢失好：误判「大重叠」会静默丢内容，误判「小重叠」只是多追加。
        for o in stripRows...maxO {
            let canvasBase = totalRows - o
            var total: Float = 0
            var counted = 0
            for i in 0..<stripRows {
                let frameRow = frameSignature[i]
                // 只比较有信息量的行，空白/纯色行不参与
                guard let contrast = Self.contrast(of: frameRow), contrast > Self.informativeContrast else { continue }
                let canvasRow = rowSignatures[canvasBase + i]
                for b in 0..<frameRow.count {
                    total += abs(frameRow[b] - canvasRow[b])
                }
                counted += 1
            }
            guard counted >= Self.minInformativeRows else { continue }
            let error = total / Float(counted)
            if error < bestError {
                bestError = error
                bestO = o
            }
        }
        guard let o = bestO, bestError <= matchThreshold else { return nil }
        return o
    }

    private static func contrast(of row: [Float]) -> Float? {
        guard let minV = row.min(), let maxV = row.max() else { return nil }
        return maxV - minV
    }

    // MARK: - Canvas

    /// 重建画布：旧内容上移 `newHeight - totalRows` 行（y-up），给底部新内容腾位。
    private func rebuildCanvas(height: Int) -> CGContext? {
        guard let ctx = Self.makeContext(width: pixelWidth, height: height) else { return nil }
        if let old = canvasContext, totalRows > 0, let oldImage = old.makeImage() {
            let shift = CGFloat(height - totalRows)
            ctx.draw(oldImage, in: CGRect(x: 0, y: shift, width: CGFloat(pixelWidth), height: CGFloat(totalRows)))
        }
        return ctx
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    // MARK: - Signature

    /// 行签名：把帧缩放为 24 列逐行灰度图，每行 = 24 个 0-255 色块均值。
    private static func rowSignatures(of image: CGImage) -> [[Float]] {
        let height = image.height
        guard let ctx = CGContext(
            data: nil,
            width: blockCount,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: blockCount,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: blockCount, height: height))
        guard let data = ctx.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: height * blockCount)
        return (0..<height).map { row in
            let base = row * blockCount
            return (0..<blockCount).map { Float(bytes[base + $0]) }
        }
    }
}
