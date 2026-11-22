#!/bin/zsh
# 本地类型检查（本机无 Xcode、CLT 6.1.2 过旧，用开源 6.4.2 工具链替代 CI 编译验证）
# 用法: tools/local-typecheck.sh
# 过滤掉 Bundle.pasteMemoResources —— SPM 在构建时生成的访问器，本地没有，属已知误报。
set -o pipefail
TOOLCHAIN=/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swiftc
cd "$(dirname "$0")/.."
FILES=(
  Sources/Engine/ScreenshotSelectionController.swift
  Sources/Views/ScreenshotEditor/ScreenshotAnnotation.swift
  Sources/Views/ScreenshotEditor/ScreenshotEditorViewModel.swift
  Sources/Engine/ScreenshotPinWindow.swift
  Sources/Engine/ToastCenter.swift
  Sources/Views/Components/UnifiedToastView.swift
  Sources/Engine/ImageOCRService.swift
  Sources/Engine/LongScreenshotStitcher.swift
  Sources/Engine/ScreenshotCapture.swift
  Sources/App/Localization.swift
)
out=$($TOOLCHAIN -typecheck -target arm64-apple-macos14.0 $FILES 2>&1)
errors=$(echo "$out" | grep "error:" | grep -v "pasteMemoResources")
if [ -n "$errors" ]; then
  echo "$errors"
  echo "TYPECHECK FAILED"
  exit 1
fi
echo "TYPECHECK OK"
