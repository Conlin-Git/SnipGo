#!/bin/bash
# 构建 SnipGo.app（自用，不公证）
# 用法: ./scripts/build.sh [--install]   --install 额外复制到 /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="SnipGo"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build (release)"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ICONSET="$BUILD_DIR/AppIcon.iconset"
ICNS="$BUILD_DIR/AppIcon.icns"
if [[ ! -f "$ICNS" || "$ROOT/scripts/make_icon.swift" -nt "$ICNS" || "$ROOT/Resources/AppIconSource.png" -nt "$ICNS" ]]; then
  echo "==> 生成图标"
  rm -rf "$ICONSET"
  swift "$ROOT/scripts/make_icon.swift" "$ROOT/Resources/AppIconSource.png" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

echo "==> 签名"
# 优先使用本机开发证书：签名身份固定，重新编译后「屏幕录制」等权限不会失效
IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [[ -n "${IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "    已使用开发证书签名"
else
  codesign --force --deep --sign - "$APP"
  echo "    未找到开发证书，使用 ad-hoc 签名（每次重新编译后可能需要重新授权屏幕录制）"
fi

if [[ "${1:-}" == "--install" ]]; then
  echo "==> 安装到 /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  # 删除 build 里的副本并从 LaunchServices 注销，避免启动台 / Spotlight 出现两个 SnipGo
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  rm -rf "$APP"
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
  echo "完成: /Applications/$APP_NAME.app（已移除 build 中的副本）"
  exit 0
fi

echo "完成: $APP"
