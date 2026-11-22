import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import _Translation_SwiftUI

/// 截图取词翻译（对齐浮引：截图取词翻译使用系统翻译）。
///
/// `TranslationSession` 不能手动创建，只能由 SwiftUI 的 `translationTask` 提供。
/// 这里在选区面板上挂一个 1×1 的隐藏 SwiftUI 宿主视图，用它换一次会话，
/// 会话准备好后翻完整段文字，再把结果回传给截图控制器展示。
@available(macOS 15.0, *)
@MainActor
final class ScreenshotTranslationService {
    static let shared = ScreenshotTranslationService()

    private var pending: CheckedContinuation<String, Error>?
    /// 每次翻译的轮次：迟到的回调/超时不会误伤下一轮
    private var pendingToken = 0
    private var hostView: NSView?
    private var fallbackWindow: NSWindow?

    private init() {}

    /// 把一段文字翻成目标语言。目标语言默认取系统首选语言，
    /// 若原文本来就是该语言（常见是中→中），则翻成英文。
    func translate(text: String, in window: NSWindow?) async throws -> String {
        cancelPending()
        pendingToken &+= 1
        let token = pendingToken
        let configuration = TranslationSession.Configuration(
            source: nil,
            target: Self.targetLanguage(for: text)
        )

        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation

            let runner = TranslationRunnerView(configuration: configuration, text: text) { [weak self] outcome in
                self?.finish(outcome, token: token)
            }
            let host = NSHostingView(rootView: runner)
            host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

            if let content = window?.contentView {
                content.addSubview(host)
                hostView = host
            } else {
                // 没有可用窗口时退到屏幕外的隐藏窗口，保证视图确实「出现」，
                // 否则 translationTask 不会启动。
                let hidden = NSWindow(
                    contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                hidden.contentView = host
                hidden.alphaValue = 0
                hidden.orderFrontRegardless()
                fallbackWindow = hidden
                hostView = host
            }

            // 首次使用需要下载语言包，可能很久；超时兜底避免 UI 永远停在「翻译中」
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.finish(.failure(Self.localizedFailure()), token: token)
            }
        }
    }

    private func finish(_ outcome: TranslationOutcome, token: Int) {
        guard token == pendingToken, let continuation = pending else { return }
        pending = nil
        teardown()
        switch outcome {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let message):
            continuation.resume(throwing: NSError(
                domain: "ScreenshotTranslation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }

    private func cancelPending() {
        guard let continuation = pending else { return }
        pending = nil
        pendingToken &+= 1
        teardown()
        continuation.resume(throwing: NSError(
            domain: "ScreenshotTranslation",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: Self.localizedFailure()]
        ))
    }

    private func teardown() {
        hostView?.removeFromSuperview()
        hostView = nil
        fallbackWindow?.orderOut(nil)
        fallbackWindow = nil
    }

    private static func localizedFailure() -> String {
        L10n.tr("editor.translate.failed")
    }

    /// 源语言与系统首选语言相同 → 翻英文；否则翻成系统首选语言。
    private static func targetLanguage(for text: String) -> Locale.Language {
        let systemCode = String((Locale.preferredLanguages.first ?? "en").prefix(2)).lowercased()
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue.lowercased()
        if detected == systemCode {
            return Locale.Language(identifier: systemCode == "en" ? "zh-Hans" : "en")
        }
        return Locale.Language(identifier: systemCode)
    }
}

/// 只给跨隔离边界回传用：String 是 Sendable，避免把 Error 送过 actor。
private enum TranslationOutcome: Sendable {
    case success(String)
    case failure(String)
}

@available(macOS 15.0, *)
private struct TranslationRunnerView: View {
    let configuration: TranslationSession.Configuration
    let text: String
    let completion: @MainActor @Sendable (TranslationOutcome) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    let response = try await session.translate(text)
                    completion(.success(response.targetText))
                } catch {
                    completion(.failure(error.localizedDescription))
                }
            }
    }
}
