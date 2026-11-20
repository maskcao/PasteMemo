import AppKit
import SwiftUI

/// 保存时给 ImageRenderer 渲染的最终画面：原图 + 标注，尺寸 = 图片点尺寸。
struct ScreenshotFlatView: View {
    let image: NSImage
    let annotations: [ScreenshotAnnotation]

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
            AnnotationCanvasView(annotations: annotations, inProgress: nil, imageWidth: image.size.width)
        }
        .frame(width: image.size.width, height: image.size.height)
    }
}

/// 只画标注层的 Canvas（预览与扁平化共用）。displayScale = 预览显示比例，
/// 扁平化渲染传 1（画布尺寸即图片尺寸）。
struct AnnotationCanvasView: View {
    let annotations: [ScreenshotAnnotation]
    let inProgress: ScreenshotAnnotation?
    let imageWidth: CGFloat
    var displayScale: CGFloat = 1

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: displayScale, y: displayScale)
            AnnotationRenderer.draw(&context, annotations: annotations, inProgress: inProgress, imageWidth: imageWidth)
        }
    }
}

struct ScreenshotEditorView: View {
    let image: NSImage
    var onSave: (Data) -> Void
    var onClose: () -> Void

    @State private var viewModel: ScreenshotEditorViewModel
    @FocusState private var textFocused: Bool

    init(image: NSImage, onSave: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.image = image
        self.onSave = onSave
        self.onClose = onClose
        _viewModel = State(initialValue: ScreenshotEditorViewModel(image: image))
    }

    private var imgW: CGFloat { image.size.width }
    private var imgH: CGFloat { image.size.height }
    private var isImageValid: Bool { imgW >= 1 && imgH >= 1 }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            Divider()
            toolbar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            if isImageValid {
                // 封顶 1：小图不放大，保持原始清晰度
                let scale = min(1, proxy.size.width / imgW, proxy.size.height / imgH)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                    AnnotationCanvasView(
                        annotations: viewModel.annotations,
                        inProgress: viewModel.inProgress,
                        imageWidth: imgW,
                        displayScale: scale
                    )
                    .allowsHitTesting(false)
                    if let draft = viewModel.textDraft {
                        textDraftField(draft, scale: scale)
                    }
                }
                .frame(width: imgW * scale, height: imgH * scale)
                .contentShape(Rectangle())
                .gesture(editorGesture(scale: scale))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
    }

    private func imagePoint(from location: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(location.x / scale, 0), imgW),
            y: min(max(location.y / scale, 0), imgH)
        )
    }

    private func editorGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                viewModel.dragMoved(at: imagePoint(from: value.location, scale: scale))
            }
            .onEnded { value in
                // 阈值用视图像素（8px），换算回图片坐标
                viewModel.dragEnded(at: imagePoint(from: value.location, scale: scale), tapThreshold: 8 / scale)
            }
    }

    private func textDraftField(_ draft: ScreenshotEditorViewModel.TextDraft, scale: CGFloat) -> some View {
        TextField("", text: Binding(
            get: { viewModel.textDraft?.string ?? "" },
            set: { viewModel.textDraft?.string = $0 }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 220)
        .position(x: draft.point.x * scale + 120, y: draft.point.y * scale + 16)
        .focused($textFocused)
        .onSubmit { viewModel.commitText() }
        .onExitCommand { viewModel.cancelText() }
        .task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            textFocused = true
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 6) {
            toolRow
            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var toolRow: some View {
        HStack(spacing: 8) {
            ForEach(ScreenshotEditorViewModel.Tool.allCases, id: \.self) { tool in
                toolButton(tool)
            }
            Divider().frame(height: 18)
            ForEach(AnnotationStyle.palette.indices, id: \.self) { index in
                colorDot(index)
            }
            Divider().frame(height: 18)
            ForEach(AnnotationStyle.weights.indices, id: \.self) { index in
                weightDot(index)
            }
            Divider().frame(height: 18)
            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 14))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward.circle")
                    .font(.system(size: 14))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Text("\(Int(imgW)) × \(Int(imgH))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Button(L10n.tr("action.cancel")) {
                // Esc（.cancelAction）在文字输入中先只取消文字，再按一次才关窗口
                if viewModel.textDraft != nil {
                    viewModel.cancelText()
                } else {
                    onClose()
                }
            }
            .keyboardShortcut(.cancelAction)
            Button(L10n.tr("editor.screenshot.saveCopy")) {
                save()
            }
            // ⌘↩ 而不是裸 Return：避免文字输入按回车时误触保存
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func toolButton(_ tool: ScreenshotEditorViewModel.Tool) -> some View {
        Button {
            viewModel.tool = tool
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .foregroundStyle(viewModel.tool == tool ? .white : .primary)
                .background(
                    viewModel.tool == tool ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }

    private func colorDot(_ index: Int) -> some View {
        Button {
            viewModel.colorIndex = index
        } label: {
            Circle()
                .fill(AnnotationStyle.palette[index])
                .frame(width: 15, height: 15)
                .overlay {
                    Circle()
                        .strokeBorder(
                            viewModel.colorIndex == index ? Color.primary : Color.primary.opacity(0.25),
                            lineWidth: viewModel.colorIndex == index ? 2 : 1
                        )
                }
        }
        .buttonStyle(.plain)
    }

    private func weightDot(_ index: Int) -> some View {
        Button {
            viewModel.weightIndex = index
        } label: {
            Circle()
                .strokeBorder(Color.primary, lineWidth: 2)
                .frame(width: 6 + CGFloat(index) * 3.5, height: 6 + CGFloat(index) * 3.5)
                .frame(width: 18, height: 18)
                .background(
                    viewModel.weightIndex == index
                        ? Color.primary.opacity(0.12)
                        : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func save() {
        viewModel.commitText()
        guard let data = viewModel.flattenedPNGData() else { return }
        onSave(data)
    }
}
