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

/// 裁剪遮罩：裁剪框外压暗，框上白色描边。eoFill 挖洞。
struct CropOverlayView: View {
    let cropRect: CGRect
    var displayScale: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(
                x: cropRect.minX * displayScale, y: cropRect.minY * displayScale,
                width: cropRect.width * displayScale, height: cropRect.height * displayScale
            )
            var hole = Path()
            hole.addRect(CGRect(origin: .zero, size: size))
            hole.addRect(rect)
            context.fill(hole, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
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

    private var imgW: CGFloat { viewModel.image.size.width }
    private var imgH: CGFloat { viewModel.image.size.height }
    private var isImageValid: Bool { imgW >= 1 && imgH >= 1 }

    var body: some View {
        // 钉钉式：工具条悬浮在图片区域底部，而不是占用独立的窗口行
        ZStack(alignment: .bottom) {
            canvas
            toolbar
                .padding(.bottom, 12)
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
                    Image(nsImage: viewModel.image)
                        .resizable()
                        .scaledToFit()
                    AnnotationCanvasView(
                        annotations: viewModel.annotations,
                        inProgress: viewModel.inProgress,
                        imageWidth: imgW,
                        displayScale: scale
                    )
                    .allowsHitTesting(false)
                    if viewModel.isCropping, let cropRect = viewModel.cropRect {
                        CropOverlayView(cropRect: cropRect, displayScale: scale)
                    }
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

    // MARK: - Toolbar（钉钉式：单行图标悬浮条）

    private var toolbar: some View {
        HStack(spacing: 6) {
            Group {
                // 裁剪中实时显示选区尺寸
                if viewModel.isCropping, let cropRect = viewModel.cropRect {
                    Text("\(Int(cropRect.width)) × \(Int(cropRect.height))")
                } else {
                    Text("\(Int(imgW)) × \(Int(imgH))")
                }
            }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(minWidth: 64, alignment: .leading)
            Divider().frame(height: 18)
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
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(viewModel.canUndo ? Color.primary : Color.primary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help(L10n.tr("editor.undo"))

            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(viewModel.canRedo ? Color.primary : Color.primary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help(L10n.tr("editor.redo"))

            Spacer(minLength: 6)
            Divider().frame(height: 18)

            Button {
                saveToFile()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .help(L10n.tr("editor.saveToFile"))

            Button {
                // Esc（.cancelAction）分层退出：先文字 → 再裁剪 → 最后关窗口
                if viewModel.textDraft != nil {
                    viewModel.cancelText()
                } else if viewModel.isCropping {
                    viewModel.exitCrop()
                } else {
                    onClose()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L10n.tr("action.cancel"))

            Button {
                if viewModel.isCropping {
                    viewModel.applyCrop()
                } else {
                    save()
                }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            // ⌘↩ 而不是裸 Return：避免文字输入按回车时误触保存
            .keyboardShortcut(.return, modifiers: .command)
            .help(L10n.tr("editor.screenshot.saveCopy"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.22), radius: 9, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func toolButton(_ tool: ScreenshotEditorViewModel.Tool) -> some View {
        Button {
            if tool == .crop {
                viewModel.toggleCrop()
            } else {
                viewModel.exitCrop()
                viewModel.tool = tool
            }
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
        .help(L10n.tr(tool.helpKey))
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

    private func saveToFile() {
        viewModel.commitText()
        guard let data = viewModel.flattenedPNGData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "PasteMemo-\(formatter.string(from: Date())).png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}
