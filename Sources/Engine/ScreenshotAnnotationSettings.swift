import Foundation

/// 截图标注的「上次选择」：线条粗细、颜色、形状、字号……下次截图直接沿用，
/// 省得每张图都把样式重新调一遍。
///
/// 整份设置序列化成一个 JSON 存进 UserDefaults：以后加字段不用改存储格式，
/// 读不出来（首次启动 / 存档损坏）就回落到默认值，绝不让存档把界面带崩。
struct ScreenshotAnnotationSettings: Codable, Equatable {

    /// 自定义色（浮层色板最后一格）
    struct RGB: Codable, Equatable {
        var r: Double
        var g: Double
        var b: Double
    }

    // MARK: - 浮层标注（截图选区后浮出的工具条）

    /// 色板下标：0-6 命名色，7 自定义色
    var colorIndex = 0
    /// 序号大小档位：0 小 / 1 中 / 2 大
    var weightIndex = 1
    /// 形状：0 矩形 / 1 椭圆
    var shapeKind = 0
    /// 线宽档位：0 小 / 1 中 / 2 大
    var widthPreset = 1
    var strokeScale = 1.8
    var highlighterOpacity = 0.5
    var mosaicOpacity = 1.0
    /// 箭头样式：0-2
    var arrowStyle = 1
    /// 马赛克形状：0 矩形 / 1 椭圆 / 2 圆角
    var mosaicStyle = 0
    var fontSize = 16.0
    var textBold = false
    /// 文字对齐：0 左 / 1 中 / 2 右
    var textAlign = 0
    var customColor = RGB(r: 0.75, g: 0.35, b: 0.95)

    // MARK: - 独立标注编辑器（历史条目上「标注」打开的窗口）

    // 编辑器的色板与浮层不是同一套，下标含义不同，所以分开记。
    var editorColorIndex = 0
    var editorWeightIndex = 1

    /// UserDefaults 键
    static let defaultsKey = "screenshotAnnotationSettings"

    /// 读取上次的选择：没有记录 / 记录损坏 → 默认值；越界的值一律夹回合法区间
    static func load(from defaults: UserDefaults = .standard) -> ScreenshotAnnotationSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(ScreenshotAnnotationSettings.self, from: data)
        else { return ScreenshotAnnotationSettings() }
        settings.clamp()
        return settings
    }

    /// 记住当前选择
    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// 夹回合法区间：色板/档位下标越界会在绘制时直接越界崩溃，
    /// 存档被手改过（或旧版本留下的值）都不能信。
    mutating func clamp() {
        colorIndex = min(max(colorIndex, 0), 7)
        weightIndex = min(max(weightIndex, 0), 2)
        shapeKind = min(max(shapeKind, 0), 1)
        widthPreset = min(max(widthPreset, 0), 2)
        strokeScale = min(max(strokeScale, 0.8), 3.0)
        highlighterOpacity = min(max(highlighterOpacity, 0), 1)
        mosaicOpacity = min(max(mosaicOpacity, 0), 1)
        arrowStyle = min(max(arrowStyle, 0), 2)
        mosaicStyle = min(max(mosaicStyle, 0), 2)
        fontSize = Self.nearestFontSize(fontSize)
        textAlign = min(max(textAlign, 0), 2)
        editorColorIndex = min(max(editorColorIndex, 0), 7)
        editorWeightIndex = min(max(editorWeightIndex, 0), 2)
        customColor.r = min(max(customColor.r, 0), 1)
        customColor.g = min(max(customColor.g, 0), 1)
        customColor.b = min(max(customColor.b, 0), 1)
    }

    /// 字号只能取工具条给出的几档，落到最近的一档
    private static func nearestFontSize(_ value: Double) -> Double {
        let options = ScreenshotSelectionSurfaceView.textSizeOptions
        let target = CGFloat(value)
        guard let first = options.first else { return 16 }
        return Double(options.min(by: { abs($0 - target) < abs($1 - target) }) ?? first)
    }
}
