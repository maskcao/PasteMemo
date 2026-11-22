#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PasteMemo"
EXECUTABLE_NAME="PasteMemo"
DEFAULT_BUNDLE_ID="com.lifedever.pastememo"
MIN_SYSTEM_VERSION="14.0"

ARCH="${ARCH:-$(uname -m)}"
CONFIGURATION="${CONFIGURATION:-release}"
BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
ICON_FILE="$ROOT_DIR/Sources/Resources/AppIcon.icns"

resolve_version() {
  if [[ -n "${VERSION:-}" ]]; then
    printf '%s\n' "$VERSION"
    return 0
  fi

  if git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    local tag
    tag="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
    tag="${tag#v}"
    if [[ -n "$tag" ]]; then
      printf '%s\n' "$tag"
      return 0
    fi
  fi

  echo "VERSION is not set, and no git tag was found." >&2
  echo "Use: make package VERSION=1.2.3" >&2
  exit 1
}

VERSION="$(resolve_version)"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-${ARCH}.dmg"
STAGING_DIR="$DIST_DIR/.dmg-staging"

# Shortcuts / Spotlight actions: compiler flags + metadata step (see the script).
source "$ROOT_DIR/scripts/appintents-metadata.sh"

# --build-system native, same as ci-build-dmg.sh: Xcode 27 / Swift 6.4's default
# swiftbuild backend writes the deployment target into LC_BUILD_VERSION's sdk field
# (the app then renders with macOS 14-era window chrome) and puts its products under
# .build/out/Products/ instead. The bin path is asked from SwiftPM, never hard-coded:
# with a stale hard-coded path the old binary left there gets packaged without a
# single error.
SWIFT_BUILD=(swift build -c "$CONFIGURATION" --arch "$ARCH" --build-system native)
BUILD_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
PRODUCT_BINARY="$BUILD_DIR/$EXECUTABLE_NAME"

printf '[package] building %s %s (%s)\n' "$APP_NAME" "$VERSION" "$ARCH"
# Removed first so a build that produced nothing fails here instead of shipping the
# previous binary.
rm -f "$PRODUCT_BINARY"
"${SWIFT_BUILD[@]}" "${APPINTENTS_SWIFTC_FLAGS[@]}"

if [[ ! -x "$PRODUCT_BINARY" ]]; then
  echo "Built binary not found: $PRODUCT_BINARY" >&2
  exit 1
fi
if ! lipo -archs "$PRODUCT_BINARY" | tr ' ' '\n' | grep -qx "$ARCH"; then
  echo "Built binary is $(lipo -archs "$PRODUCT_BINARY"), expected $ARCH: $PRODUCT_BINARY" >&2
  exit 1
fi
EXPECTED_SDK="$(xcrun --show-sdk-version)"
LINKED_SDK="$(otool -l "$PRODUCT_BINARY" | awk '/LC_BUILD_VERSION/{f=1} f && /sdk/{print $2; exit}')"
if [[ "$LINKED_SDK" != "$EXPECTED_SDK" ]]; then
  echo "LC_BUILD_VERSION sdk=$LINKED_SDK, expected $EXPECTED_SDK (legacy window chrome otherwise)" >&2
  exit 1
fi

# MCP CLI proxy (AI Agents integration, see MCPInstallerAgents): built alongside
# the main app and expected at Contents/MacOS/pastememo-mcp.
"${SWIFT_BUILD[@]}" "${APPINTENTS_SWIFTC_FLAGS[@]}" --product pastememo-mcp
MCP_BINARY="$BUILD_DIR/pastememo-mcp"
if [[ ! -x "$MCP_BINARY" ]]; then
  echo "Built MCP binary not found: $MCP_BINARY" >&2
  exit 1
fi

# Glob every *.bundle produced by SwiftPM resource targets. Hard-coding names
# silently misses new SPM dependencies and crashes Bundle.module at runtime.
RESOURCE_BUNDLES=("$BUILD_DIR"/*.bundle)
if [[ ! -d "${RESOURCE_BUNDLES[0]}" ]]; then
  echo "No SwiftPM resource bundles found in $BUILD_DIR" >&2
  exit 1
fi

if [[ ! -f "$ICON_FILE" ]]; then
  echo "App icon not found: $ICON_FILE" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$STAGING_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DIST_DIR"

cp "$PRODUCT_BINARY" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$MCP_BINARY" "$APP_DIR/Contents/MacOS/pastememo-mcp"
chmod +x "$APP_DIR/Contents/MacOS/pastememo-mcp"
cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
for bundle in "${RESOURCE_BUNDLES[@]}"; do
  # Must live under Contents/Resources: codesign rejects unsealed items in the
  # bundle root, and Bundle.module resolves this location first.
  cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done
# lproj per language (also carries the Shortcuts action titles), then the Shortcuts
# metadata. Before codesign.
appintents_install_strings "$APP_DIR"
appintents_install_metadata "$BUILD_DIR" "$ARCH" "$APP_DIR"

CURRENT_YEAR="$(date +%Y)"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © ${CURRENT_YEAR} lifedever. All rights reserved.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>PasteMemo needs to communicate with Finder to save images to folders.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  printf '[package] codesigning app bundle\n'
  # Inner → outer: the secondary executable first, then the bundle.
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR/Contents/MacOS/pastememo-mcp"
  codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi

mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

# 带背景图、图标位置和安装提示的 DMG。Finder 的视图设置（.DS_Store）只能
# 通过 AppleScript 写入，所以在 CI 的 GUI 会话里先挂一个读写镜像设置好再压缩。
# 任何一步失败都退回普通 DMG，保证打包不中断。
make_styled_dmg() {
  local tmp_dmg="$DIST_DIR/.${APP_NAME}-rw.dmg"
  local mount_dir="/Volumes/$APP_NAME"
  local bg_dir="$STAGING_DIR/.background"
  local script_file="$DIST_DIR/.dmg-layout.applescript"

  rm -rf "$bg_dir"
  mkdir -p "$bg_dir"
  if ! swift "$ROOT_DIR/scripts/make-dmg-background.swift" "$bg_dir/background.tiff"; then
    return 1
  fi

  rm -f "$tmp_dmg"
  if ! hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov \
    -format UDRW -fs HFS+ "$tmp_dmg" >/dev/null; then
    return 1
  fi
  if ! hdiutil attach "$tmp_dmg" -readwrite -noverify -noautoopen >/dev/null; then
    rm -f "$tmp_dmg"
    return 1
  fi

  # 卷图标（可选）
  if [[ -f "$ICON_FILE" ]] && command -v SetFile >/dev/null 2>&1; then
    cp "$ICON_FILE" "$mount_dir/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$mount_dir" >/dev/null 2>&1 || true
  fi

  sleep 1
  cat > "$script_file" <<APPLESCRIPT
set diskName to "$APP_NAME"
tell application "Finder"
  tell disk diskName
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

  local layout_ok=1
  # 90s 兜底：Finder 在无 GUI 权限时可能弹授权框，不能让它把构建挂死
  perl -e 'alarm 90; exec @ARGV' osascript "$script_file" >/dev/null 2>&1 || layout_ok=0
  rm -f "$script_file"
  sync

  hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
  if [[ "$layout_ok" -ne 1 ]]; then
    rm -f "$tmp_dmg"
    return 1
  fi

  if ! hdiutil convert "$tmp_dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null; then
    rm -f "$tmp_dmg"
    return 1
  fi
  rm -f "$tmp_dmg"
  return 0
}

printf '[package] creating dmg %s\n' "$(basename "$DMG_PATH")"
if ! make_styled_dmg; then
  printf '[package] styled dmg failed, falling back to plain dmg\n'
  rm -f "$DMG_PATH"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
fi

rm -rf "$STAGING_DIR"

printf '[package] app: %s\n' "$APP_DIR"
printf '[package] dmg: %s\n' "$DMG_PATH"
