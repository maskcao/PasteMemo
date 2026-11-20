import SwiftUI

/// E1 骨架：画布（等比缩放）+ 底部工具条。标注工具在 E2 加进工具条。
struct ScreenshotEditorView: View {
    let image: NSImage
    var onSave: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            canvas
            Divider()
            toolbar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var canvas: some View {
        GeometryReader { proxy in
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Button(L10n.tr("action.cancel")) {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            Button(L10n.tr("editor.screenshot.saveCopy")) {
                onSave()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
