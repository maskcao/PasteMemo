import Foundation
import Testing
@testable import PasteMemo

/// 截图标注样式的记忆：存了要能原样读回来，读不出来要回落默认值，
/// 越界的值要夹回合法区间（存档被手改过也不能把界面带崩）。
@Suite("Screenshot annotation settings")
struct ScreenshotAnnotationSettingsTests {

    /// 每个用例一个独立的 UserDefaults suite，互不污染
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "pm.test.annotation.\(UUID().uuidString)")!
    }

    @Test("没有记录时返回默认值")
    func defaultsWhenEmpty() {
        let defaults = makeDefaults()
        #expect(ScreenshotAnnotationSettings.load(from: defaults) == ScreenshotAnnotationSettings())
    }

    @Test("存过再读能原样回来")
    func roundTrip() {
        let defaults = makeDefaults()
        var settings = ScreenshotAnnotationSettings()
        settings.colorIndex = 3
        settings.weightIndex = 2
        settings.shapeKind = 1
        settings.widthPreset = 2
        settings.strokeScale = 2.8
        settings.highlighterOpacity = 0.25
        settings.mosaicOpacity = 0.6
        settings.arrowStyle = 2
        settings.mosaicStyle = 1
        settings.fontSize = 28
        settings.textBold = true
        settings.textAlign = 2
        settings.customColor = .init(r: 0.2, g: 0.4, b: 0.6)
        settings.editorColorIndex = 5
        settings.editorWeightIndex = 2
        settings.save(to: defaults)

        #expect(ScreenshotAnnotationSettings.load(from: defaults) == settings)
    }

    @Test("存档损坏时回落默认值，不崩")
    func corruptDataFallsBack() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: ScreenshotAnnotationSettings.defaultsKey)
        #expect(ScreenshotAnnotationSettings.load(from: defaults) == ScreenshotAnnotationSettings())
    }

    @Test("越界的下标与数值夹回合法区间")
    func clampsOutOfRange() {
        let defaults = makeDefaults()
        var settings = ScreenshotAnnotationSettings()
        settings.colorIndex = 99
        settings.weightIndex = -3
        settings.shapeKind = 7
        settings.widthPreset = 9
        settings.strokeScale = 99
        settings.highlighterOpacity = 4
        settings.mosaicOpacity = -1
        settings.arrowStyle = -2
        settings.mosaicStyle = 8
        settings.fontSize = 999
        settings.textAlign = 5
        settings.editorColorIndex = 12
        settings.editorWeightIndex = -1
        settings.save(to: defaults)

        let loaded = ScreenshotAnnotationSettings.load(from: defaults)
        #expect(loaded.colorIndex == 7)
        #expect(loaded.weightIndex == 0)
        #expect(loaded.shapeKind == 1)
        #expect(loaded.widthPreset == 2)
        #expect(loaded.strokeScale == 3.0)
        #expect(loaded.highlighterOpacity == 1)
        #expect(loaded.mosaicOpacity == 0)
        #expect(loaded.arrowStyle == 0)
        #expect(loaded.mosaicStyle == 2)
        #expect(loaded.fontSize == 40)   // 落到最近的字号档
        #expect(loaded.textAlign == 2)
        #expect(loaded.editorColorIndex == 7)
        #expect(loaded.editorWeightIndex == 0)
    }

    @Test("自定义色越界也夹回 0-1")
    func clampsCustomColor() {
        let defaults = makeDefaults()
        var settings = ScreenshotAnnotationSettings()
        settings.customColor = .init(r: 2, g: -1, b: 0.5)
        settings.save(to: defaults)

        let loaded = ScreenshotAnnotationSettings.load(from: defaults)
        #expect(loaded.customColor.r == 1)
        #expect(loaded.customColor.g == 0)
        #expect(loaded.customColor.b == 0.5)
    }
}
