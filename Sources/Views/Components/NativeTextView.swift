import SwiftUI
import AppKit

struct NativeTextView: NSViewRepresentable {
    let text: String
    var richTextData: Data?
    var richTextType: String?
    /// When false, the view shows `text` (plain string) only and skips all rich-text decoding.
    /// Callers use this to avoid paying the RTFD/HTML cost during rapid selection changes
    /// (e.g. arrow-key scrubbing in QuickPanel). Pass true once the selection settles.
    var allowRichRender: Bool = true
    /// Stable identifier for caching decoded rich-text results across view recreations.
    /// When provided, decoded NSAttributedString is keyed on `(itemID, dataHash, width)`.
    var itemID: String? = nil
    var isEditable: Bool = false
    var autoFocus: Bool = false
    /// Optional search query for highlighting in the plain-text render path.
    /// Empty string disables highlighting. Tokenization matches the search bar's
    /// behavior (whitespace → AND tokens). Rich-text branch ignores this.
    var searchText: String = ""
    /// Plain-text style. Defaults match the standard text-clip preview; the
    /// quick panel's OCR card passes a smaller secondary style instead.
    var fontSize: CGFloat = 13
    var textColor: NSColor = .labelColor
    /// 快捷面板预览区去掉滚动条槽轨，只留滑块。
    var hidesScrollerTrack: Bool = false
    var onTextChange: ((String) -> Void)?
    var onEscape: (() -> Void)?

    /// Skip the highlight scan for very large content to keep typing responsive.
    /// 200K chars ≈ a 200 KB plain-text clip; above this the per-keystroke scan
    /// starts being perceptible.
    static let highlightSizeLimit = 200_000

    /// 可渲染性检查扫描的可见字符上限。足够判定整段是不是坏数据，又不会在
    /// 几十万字的长文档上白跑一遍。
    nonisolated static let renderabilityScanLimit = 4_000

    /// Measured plain-text render heights keyed by (text, width, fontSize).
    /// Tiny bounded cache — OCR cards re-evaluate body often but only ever show
    /// a handful of texts at a time.
    @MainActor private static var measureCache: [Int: CGFloat] = [:]

    /// 按给定宽度测量纯文本的渲染高度（已计入 NSTextContainer 默认的左右各
    /// 5pt lineFragmentPadding）。供"高度贴内容、封顶滚动"的调用方使用，
    /// 结果缓存，重复调用不重新跑 TextKit。
    @MainActor static func measuredHeight(text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(Int(width))
        hasher.combine(fontSize)
        let key = hasher.finalize()
        if let cached = measureCache[key] { return cached }

        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        let bounds = attributed.boundingRect(
            with: CGSize(width: max(width - 10, 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        let height = ceil(bounds.height) + 4
        if measureCache.count > 64 { measureCache.removeAll(keepingCapacity: true) }
        measureCache[key] = height
        return height
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = isEditable
        textView.isSelectable = true
        if isEditable {
            // 改的是剪贴板原文：只收纯文本（粘进来的格式存不下来），关掉智能引号 / 破折号 /
            // 文本替换 / 自动纠错——否则代码、JSON、链接一边改一边被系统悄悄换字符。
            textView.isRichText = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
        }
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.delegate = context.coordinator
        // Horizontal scroll must stay off so that text/images wrap to the container width.
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        if hidesScrollerTrack {
            TracklessScroller.install(on: scrollView)
        }
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        if autoFocus {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = isEditable
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = textColor
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onEscape = onEscape

        let isFirstResponder = textView.window?.firstResponder == textView
        guard !isFirstResponder else { return }

        // Fast path: rich render disabled OR no rich data — render plain string only, skip all decoding.
        guard allowRichRender, let rtfData = richTextData else {
            let wasRich = context.coordinator.lastRichTextData != nil
            let fontChanged = abs(context.coordinator.lastFontSize - fontSize) > 0.1
            context.coordinator.lastRichTextData = nil
            context.coordinator.lastLayoutWidth = 0
            context.coordinator.lastFontSize = fontSize
            var textWasReplaced = false
            if wasRich || fontChanged {
                // Switching from rich → plain on the same view: setting
                // `.string` only replaces the characters and keeps the prior
                // attributed run's typing attributes (bold/colors/font), so
                // the visual still looks formatted. Force a fully attributed
                // overwrite with the default plain attrs to clear all
                // inherited formatting.
                // fontChanged 同理：已有 run 的 .font 不会跟着 textView.font 变。
                let plain = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: textColor,
                ])
                textView.textStorage?.setAttributedString(plain)
                textWasReplaced = true
            } else if textView.string != text {
                textView.string = text
                textView.font = .systemFont(ofSize: fontSize)
                textView.textColor = textColor
                textWasReplaced = true
            }
            let searchChanged = context.coordinator.lastSearchText != searchText
            context.coordinator.lastSearchText = searchText
            // 切换条目(textWasReplaced)→ 立即高亮，方向键扫不滞后
            // 仅搜索词变化(searchChanged)→ 80ms 微防抖,连打字时不重复扫
            if textWasReplaced {
                context.coordinator.cancelPendingHighlight()
                Self.applyHighlights(textView: textView, searchText: searchText)
            } else if searchChanged {
                context.coordinator.scheduleDebouncedHighlight(textView: textView, searchText: searchText)
            }
            return
        }

        let currentWidth = textView.textContainer?.size.width ?? 0
        let widthChanged = abs(currentWidth - context.coordinator.lastLayoutWidth) > 1
        let dataChanged = rtfData != context.coordinator.lastRichTextData
        guard dataChanged || widthChanged else { return }

        // Serve from cache instantly if we've decoded the same (itemID, data, width) combo recently.
        if let id = itemID,
           let cached = RichTextCache.shared.get(itemID: id, data: rtfData, width: currentWidth) {
            context.coordinator.lastRichTextData = rtfData
            context.coordinator.lastLayoutWidth = currentWidth
            textView.textStorage?.setAttributedString(cached)
            return
        }

        // Show the plain string immediately so the viewport isn't blank while we decode.
        // 用完整的 attributed 覆盖而不是只写 `.string`：后者保留上一条富文本留下的
        // 字体/颜色（同 plain 分支的注释），而这里也是解码被否决时的最终画面。
        if textView.string.isEmpty || dataChanged {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: textColor,
            ]))
        }
        context.coordinator.lastRichTextData = rtfData
        context.coordinator.lastLayoutWidth = currentWidth

        // Decode off the main thread — RTFD with large inline images can take 100ms+.
        // Only Sendable values (Data, String?, CGFloat) cross into Task.detached; the
        // NSTextView/Coordinator references stay on the MainActor side.
        let typeLocal = richTextType
        let itemIDLocal = itemID
        let dataLocal = rtfData
        let widthLocal = currentWidth
        let coordinator = context.coordinator
        let token = coordinator.beginDecodeToken()
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Task { @MainActor in
            // NSAttributedString isn't Sendable in Swift 6, but we're only ever moving the
            // reference from one detached decode task to this single MainActor consumer — wrap
            // in an unchecked box so the compiler is satisfied.
            let box = await Task.detached(priority: .userInitiated) {
                UnsafeSendableBox(Self.decode(data: dataLocal, type: typeLocal, plainText: text, maxImageWidth: widthLocal, isDark: isDark))
            }.value
            guard let attr = box.value else {
                // The plain fallback must never be keyed as if it were the decoded rich
                // text: on the next width change the cache would resurrect the corrupt
                // rendering.
                RichTextCache.shared.markRejected(data: dataLocal)
                return
            }
            guard coordinator.isCurrentDecodeToken(token) else { return }
            // Selection changed meanwhile — discard.
            guard coordinator.lastRichTextData == dataLocal else { return }
            if let id = itemIDLocal {
                RichTextCache.shared.set(itemID: id, data: dataLocal, width: widthLocal, value: attr)
            }
            textView.textStorage?.setAttributedString(attr)
        }
    }

    // MARK: - Decoding (nonisolated: safe on background)

    nonisolated private static func decode(data: Data, type: String?, plainText: String, maxImageWidth: CGFloat, isDark: Bool) -> NSAttributedString? {
        let raw: NSAttributedString?
        switch type {
        case "rtfd":
            raw = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            )
        case "html":
            raw = NSAttributedString(html: data, documentAttributes: nil)
        default:
            raw = NSAttributedString(rtf: data, documentAttributes: nil)
        }
        // 解不出来、或者解出来是一整段没有任何字体能显示的码点时返回 nil，
        // 调用方保留已经铺好的纯文本渲染。
        guard let raw, isRenderable(raw, plainText: plainText) else { return nil }
        // The plain fallback must never be keyed as if it were the decoded rich text:
        // on the next width change the cache would resurrect the corrupt rendering.
        let adapted = adaptColorsForAppearance(raw, isDark: isDark)
        return scaleAttachmentsToFit(adapted, maxWidth: maxImageWidth)
    }

    /// 解码丢字符的判定阈值。源应用写进剪贴板的 HTML/RTF 编码对不上时（TRAE
    /// 复制的条目在"文本"模式下整段变彩色问号，切 Auto 走纯文本才恢复），
    /// AppKit 会把解不开的字符统一替换成 "?" 或 U+FFFD。问号本身完全可渲染，
    /// 码点检查拦不住，只能对照纯文本原文判 losses。
    nonisolated private static let lossyCountFloor = 8      // 短句里的零星问号不触发
    nonisolated private static let lossyRateFloor = 0.15    // 解码结果里 "?" 至少占这个比例
    nonisolated private static let lossyRateGap = 0.10      // 且要显著高于原文里的 "?" 占比
    nonisolated private static let plainScanLimit = 20_000  // 原文只扫前缀估占比
    /// 连续坏字符的独立判据。有些 payload 混入大量正常字符后，总占比可能低于
    /// 上面的比例线，但预览里仍会看到成片 "?????"。富文本解码不应无中生有地
    /// 造出长问号串；原文没有对应的连续问号时，这样的结果直接否决。
    nonisolated private static let lossyRunFloor = 8
    nonisolated private static let lossyRunTolerance = 2
    nonisolated private static let lossyScanLimit = 200_000

    /// 解码结果是否值得拿来替换纯文本渲染。
    ///
    /// 两道判据：
    ///
    /// 1. 码点检查——某些来源给出的富文本会把整段正文解成私用区 / 未分配码点，
    ///    系统里没有任何字体覆盖，渲染出来是一排 LastResort 的 "?" 方框——比纯
    ///    文本还不可读（#88：VS Code 复制的代码在"文本"模式下整段变方框，而同
    ///    一条在列表里显示正常）。判据是"过半可见字符不可渲染"而不是"存在即否
    ///    决"：从终端复制的 Powerline / Nerd Font 图标本身就是私用区字符，那些
    ///    条目只是夹带少量，富文本照常渲染。
    ///
    /// 2. 丢字符检查（传入 `plainText` 时）——解码结果里 "?" / U+FFFD 的占比
    ///    远高于纯文本原文，说明字符是在富文本解码这一步丢的，宁可放弃格式退回
    ///    纯文本，保住内容可读。
    nonisolated static func isRenderable(_ attributed: NSAttributedString, plainText: String? = nil) -> Bool {
        var visible = 0
        var unrenderable = 0
        var lossy = 0
        for scalar in attributed.string.unicodeScalars {
            // 空白、控制字符、图片占位符不参与判断
            if scalar.value < 0x20 || scalar.value == 0xFFFC || scalar.properties.isWhitespace { continue }
            visible += 1
            switch scalar.properties.generalCategory {
            case .privateUse, .unassigned:
                unrenderable += 1
            default:
                break
            }
            // U+FFFD 是"转换时丢字符"的通用标记；字面 "?" 则要等和原文对比后才能定罪
            if scalar.value == 0xFFFD {
                unrenderable += 1
                lossy += 1
            } else if scalar.value == 0x3F {
                lossy += 1
            }
            if visible >= renderabilityScanLimit { break }
        }
        guard visible > 0 else { return true }
        if unrenderable * 2 >= visible { return false }
        if let plainText,
           // Hard gate: a long unexplained "?" run is always corruption, even when
            // normal text dilutes it below the aggregate ratio.
           maxLossyRun(in: attributed.string) >= lossyRunFloor
                && maxLossyRun(in: attributed.string) > maxLossyRun(in: plainText) + lossyRunTolerance {
            return false
        }
        if let plainText,
           decodedTextLostCharacters(decodedVisible: visible, decodedLossy: lossy, plainText: plainText) {
            return false
        }
        return true
    }

    /// Longest run of "?" / U+FFFD. A rich-text decoder should never invent such a
    /// run from ordinary copied text; if the original has no comparable run, the
    /// decoded payload lost characters.
    nonisolated private static func maxLossyRun(in text: String) -> Int {
        var maxRun = 0
        var currentRun = 0
        var seen = 0
        for scalar in text.unicodeScalars {
            seen += 1
            if scalar.value == 0x3F || scalar.value == 0xFFFD {
                currentRun += 1
                maxRun = max(maxRun, currentRun)
            } else {
                currentRun = 0
            }
            if seen >= lossyScanLimit { break }
        }
        return maxRun
    }

    /// 丢字符判定的对比端：解码结果的 "?" 占比要有绝对数量兜底（防 "What?" 这类
    /// 短句误伤）、够高的占比，且显著高于原文里的 "?" 占比——原文本来就满是
    /// 问号的条目不受影响。
    nonisolated private static func decodedTextLostCharacters(decodedVisible: Int, decodedLossy: Int, plainText: String) -> Bool {
        guard decodedLossy >= lossyCountFloor else { return false }
        let decodedRate = Double(decodedLossy) / Double(max(decodedVisible, 1))
        guard decodedRate >= lossyRateFloor else { return false }

        var plainVisible = 0
        var plainLossy = 0
        for scalar in plainText.unicodeScalars {
            if scalar.value < 0x20 || scalar.properties.isWhitespace { continue }
            plainVisible += 1
            if scalar.value == 0x3F { plainLossy += 1 }
            if plainVisible >= plainScanLimit { break }
        }
        let plainRate = plainVisible > 0 ? Double(plainLossy) / Double(plainVisible) : 0
        return decodedRate >= plainRate + lossyRateGap
    }

    /// Responsive images: shrink attachments whose intrinsic width exceeds the text container.
    /// Preserves aspect ratio. Leaves narrower images at natural size.
    nonisolated private static func scaleAttachmentsToFit(_ source: NSAttributedString, maxWidth: CGFloat) -> NSAttributedString {
        guard maxWidth > 1 else { return source }
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        // Leave a little breathing room so the scroll indicator / insets don't clip.
        let targetWidth = max(40, maxWidth - 8)

        result.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let intrinsic = intrinsicSize(of: attachment)
            guard intrinsic.width > 0, intrinsic.height > 0 else { return }
            guard intrinsic.width > targetWidth else {
                // Natural size fits — honor the source dimensions.
                attachment.bounds = CGRect(origin: .zero, size: intrinsic)
                return
            }
            let scale = targetWidth / intrinsic.width
            attachment.bounds = CGRect(
                x: 0, y: 0,
                width: targetWidth,
                height: (intrinsic.height * scale).rounded()
            )
            _ = range
        }
        return result
    }

    nonisolated private static func intrinsicSize(of attachment: NSTextAttachment) -> CGSize {
        if let image = attachment.image {
            return image.size
        }
        if let wrapper = attachment.fileWrapper,
           let data = wrapper.regularFileContents,
           let image = NSImage(data: data) {
            // Cache so subsequent layout passes don't re-decode.
            attachment.image = image
            return image.size
        }
        return attachment.bounds.size
    }

    nonisolated private static func adaptColorsForAppearance(_ source: NSAttributedString, isDark: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)

        // Strip source backgroundColor across the whole string — the preview
        // uses the panel's own material background; dragging in black/gray
        // backgrounds from the source makes text unreadable on dark mode.
        result.removeAttribute(.backgroundColor, range: fullRange)

        result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor else {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                return
            }
            if shouldAdaptForegroundColor(color, isDark: isDark) {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        return result
    }

    // MARK: - Search highlight (plain-text branch only)

    /// Applies search-term highlights to the text view's backing storage.
    /// Clears any previous `.backgroundColor` runs first so removed tokens disappear.
    /// Bails on empty input or oversized content so the per-keystroke cost stays cheap.
    @MainActor
    private static func applyHighlights(textView: NSTextView, searchText: String) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.removeAttribute(.backgroundColor, range: fullRange)

        let tokens = ClipItemStore.tokenizeSearchInput(searchText)
        guard !tokens.isEmpty else { return }
        guard storage.length <= highlightSizeLimit else { return }

        let color = NSColor.systemYellow.withAlphaComponent(0.35)
        for range in highlightRanges(in: storage.string, tokens: tokens) {
            storage.addAttribute(.backgroundColor, value: color, range: range)
        }
    }

    /// Pure function: every case-insensitive match for each token in `content`,
    /// returned as NSRanges suitable for NSTextStorage attribute application.
    /// Empty / overlapping tokens are tolerated; overlaps may produce overlapping
    /// ranges, but NSTextStorage merges them on the same `.backgroundColor` value.
    static func highlightRanges(in content: String, tokens: [String]) -> [NSRange] {
        var ranges: [NSRange] = []
        for token in tokens where !token.isEmpty {
            var cursor = content.startIndex
            while cursor < content.endIndex,
                  let match = content.range(of: token, options: .caseInsensitive, range: cursor..<content.endIndex) {
                ranges.append(NSRange(match, in: content))
                cursor = match.upperBound
            }
        }
        return ranges
    }

    nonisolated private static func shouldAdaptForegroundColor(_ color: NSColor, isDark: Bool) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let brightness = rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
        // Near-black or near-white: always adapt.
        if brightness < 0.15 || brightness > 0.85 { return true }
        // Mid-grey on dark / light panel — low contrast, swap to label color.
        if isDark, brightness < 0.40 { return true }
        if !isDark, brightness > 0.70 { return true }
        return false
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: ((String) -> Void)?
        var onEscape: (() -> Void)?
        var lastRichTextData: Data?
        var lastLayoutWidth: CGFloat = 0
        var lastSearchText: String = ""
        var lastFontSize: CGFloat = 0
        private var decodeToken: Int = 0
        private var highlightTask: Task<Void, Never>?

        @MainActor
        func cancelPendingHighlight() {
            highlightTask?.cancel()
            highlightTask = nil
        }

        @MainActor
        func scheduleDebouncedHighlight(textView: NSTextView, searchText: String) {
            cancelPendingHighlight()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                NativeTextView.applyHighlights(textView: textView, searchText: searchText)
                self.highlightTask = nil
            }
        }

        init(onTextChange: ((String) -> Void)?, onEscape: (() -> Void)? = nil) {
            self.onTextChange = onTextChange
            self.onEscape = onEscape
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let onEscape {
                onEscape()
                return true
            }
            return false
        }

        /// Increment-and-return used to invalidate in-flight decodes when selection changes.
        func beginDecodeToken() -> Int {
            decodeToken &+= 1
            return decodeToken
        }

        func isCurrentDecodeToken(_ token: Int) -> Bool {
            decodeToken == token
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange?(textView.string)
        }
    }
}

/// Single-use box to pass non-Sendable values between tasks when we know by construction that
/// the value is only accessed by one isolation domain at a time.
private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Rich-text render cache

/// LRU cache of decoded NSAttributedString keyed on (itemID, data hash, container width).
/// Saves 100ms+ per arrow-key navigation through RTFD-heavy items.
@MainActor
final class RichTextCache {
    static let shared = RichTextCache()

    private struct Key: Hashable {
        let itemID: String
        let dataHash: Int
        let width: Int  // rounded to reduce cache key churn from sub-pixel width drift
    }

    private var cache: [Key: NSAttributedString] = [:]
    private var order: [Key] = []
    private let capacity = 20
    private var rejectedDataHashes: Set<Int> = []
    private let rejectedCapacity = 100

    func get(itemID: String, data: Data, width: CGFloat) -> NSAttributedString? {
        guard !rejectedDataHashes.contains(data.hashValue) else { return nil }
        let key = Key(itemID: itemID, dataHash: data.hashValue, width: Int(width))
        guard let value = cache[key] else { return nil }
        // Mark as most recently used.
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    /// Remember data whose rich-text decode failed, so the plain-text fallback is not
    /// accidentally cached later under the same `(itemID, data, width)` key.
    func markRejected(data: Data) {
        rejectedDataHashes.insert(data.hashValue)
        if rejectedDataHashes.count > rejectedCapacity {
            rejectedDataHashes.removeFirst()
        }
    }

    func set(itemID: String, data: Data, width: CGFloat, value: NSAttributedString) {
        let key = Key(itemID: itemID, dataHash: data.hashValue, width: Int(width))
        if cache[key] == nil {
            order.append(key)
        } else if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        cache[key] = value
        while order.count > capacity {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    func invalidate(itemID: String) {
        let keysToRemove = cache.keys.filter { $0.itemID == itemID }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
            }
        }
    }
}
