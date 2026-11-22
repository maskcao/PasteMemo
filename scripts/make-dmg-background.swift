#!/usr/bin/env swift
//
// 生成 DMG 安装窗口的背景图（1x + 2x 两档，输出 TIFF）。
// 用法: swift scripts/make-dmg-background.swift <输出路径.tiff>
//
// 版式：左侧 PasteMemo、右侧 Applications，中间一条虚线箭头，
// 上方软件名、下方安装提示。Finder 窗口尺寸按 660×400 设计。

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.tiff"
let canvas = NSSize(width: 660, height: 400)

func makeContext(_ scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width * scale),
        pixelsHigh: Int(canvas.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = canvas
    return rep
}

func draw() {
    let c = NSGraphicsContext.current!.cgContext
    // NSGraphicsContext(bitmapImageRep:) 会按 rep.size（点）映射到像素，
    // 2x 档已经是自动缩放，这里不要再手动 scale，否则会放大成 4 倍。

    // 背景：上浅下深的冷灰渐变，和浅色系统界面协调
    let top = NSColor(srgbRed: 0.976, green: 0.980, blue: 0.988, alpha: 1).cgColor
    let bottom = NSColor(srgbRed: 0.929, green: 0.941, blue: 0.957, alpha: 1).cgColor
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bottom] as CFArray,
        locations: [0, 1]
    )!
    c.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvas.height),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // 两个柔光圆，衬托图标位置
    for x in [165.0, 495.0] {
        let center = CGPoint(x: x, y: 190)
        let clear = NSColor.white.withAlphaComponent(0).cgColor
        let glow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.white.withAlphaComponent(0.9).cgColor, clear] as CFArray,
            locations: [0, 1]
        )!
        c.drawRadialGradient(
            glow,
            startCenter: center,
            startRadius: 24,
            endCenter: center,
            endRadius: 74,
            options: []
        )
    }

    // 标题
    let title = "PasteMemo" as NSString
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.13, green: 0.16, blue: 0.21, alpha: 1),
    ]
    let titleSize = title.size(withAttributes: titleAttrs)
    title.draw(at: NSPoint(x: (canvas.width - titleSize.width) / 2, y: 334), withAttributes: titleAttrs)

    // 中间虚线箭头
    let accent = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
    let arrow = NSBezierPath()
    arrow.lineWidth = 2.5
    arrow.setLineDash([7, 6], count: 2, phase: 0)
    arrow.move(to: NSPoint(x: 254, y: 190))
    arrow.curve(
        to: NSPoint(x: 386, y: 190),
        controlPoint1: NSPoint(x: 300, y: 202),
        controlPoint2: NSPoint(x: 344, y: 202)
    )
    accent.setStroke()
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 398, y: 190))
    head.line(to: NSPoint(x: 382, y: 198))
    head.line(to: NSPoint(x: 382, y: 182))
    head.close()
    accent.setFill()
    head.fill()

    // 底部安装提示
    let hint = "拖动图标到 Applications 文件夹即可安装" as NSString
    let hintAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1),
    ]
    let hintSize = hint.size(withAttributes: hintAttrs)
    hint.draw(at: NSPoint(x: (canvas.width - hintSize.width) / 2, y: 56), withAttributes: hintAttrs)
}

let image = NSImage(size: canvas)
for scale in [CGFloat(1), CGFloat(2)] {
    let rep = makeContext(scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(rep)
}

guard let tiff = image.tiffRepresentation else {
    FileHandle.standardError.write(Data("failed to render dmg background\n".utf8))
    exit(1)
}
do {
    try tiff.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("failed to write \(outputPath): \(error)\n".utf8))
    exit(1)
}
