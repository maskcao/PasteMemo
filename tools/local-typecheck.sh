#!/bin/zsh
# 本地类型检查（本机无 Xcode、CLT 6.1.2 过旧，用开源 6.4.2 工具链替代 CI 编译验证）
# 用法: tools/local-typecheck.sh
# 过滤掉 Bundle.pasteMemoResources —— SPM 在构建时生成的访问器，本地没有，属已知误报。
# -Xfrontend -strict-init：6.4.2 工具链默认放行"let/var 在 super.init 后才初始化"，
# 而 CI 的 Xcode 编译器会报错；该内部开关可让本地对齐 CI 的严格初始化检查。
set -o pipefail
TOOLCHAIN=/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swiftc
# 开源工具链不会自动找 SDK：未显式指定时回落到 CLT 的 macOS SDK，否则连 AppKit 都找不到
# （必须 export：脚本内普通赋值不会传给 swiftc 子进程）
if [[ -z "${SDKROOT}" ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
fi
cd "$(dirname "$0")/.."
FILES=(
  Sources/Engine/ScreenshotSelectionController.swift
  Sources/Views/ScreenshotEditor/ScreenshotAnnotation.swift
  Sources/Views/ScreenshotEditor/ScreenshotEditorViewModel.swift
  Sources/Engine/ScreenshotPinWindow.swift
  Sources/Engine/ToastCenter.swift
  Sources/Views/Components/UnifiedToastView.swift
  Sources/Engine/ImageOCRService.swift
  Sources/Engine/ScreenshotTranslationService.swift
  Sources/Engine/LongScreenshotStitcher.swift
  Sources/Engine/ScreenshotCapture.swift
  Sources/App/Localization.swift
  Sources/Engine/AI/AIClient.swift
  Sources/Engine/AI/AICLIBackend.swift
  Sources/Engine/AI/AIProviderSettings.swift
)
out=$($TOOLCHAIN -typecheck -target arm64-apple-macos14.0 $FILES 2>&1)
errors=$(echo "$out" | grep "error:" | grep -v "pasteMemoResources")
if [ -n "$errors" ]; then
  echo "$errors"
  echo "TYPECHECK FAILED"
  exit 1
fi
echo "TYPECHECK OK"
# CI 跑 Xcode 26（Swift 6.2+），比本机工具链严格：补一条针对性 lint
python3 "$(dirname "$0")/lint-stored-props.py" $FILES || exit 1
