#!/bin/bash
# 编译并打包成 build/QuickCap.app
#
# 签名：优先用钥匙串里的 "Apple Development" 证书，也可以用环境变量
# QUICKCAP_SIGN_IDENTITY 指定。找不到证书时退回临时签名（adhoc）。
# 临时签名每次编译都会变，系统会把新版本当成另一个 app，屏幕录制权限需要重新授权。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/QuickCap"

APP="build/QuickCap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuickCap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${QUICKCAP_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null
    echo "signed with: $IDENTITY" >&2
else
    codesign --force --sign - "$APP" >/dev/null
    echo "warning: 没找到开发者证书，使用临时签名，每次编译后都要重新授权屏幕录制" >&2
fi
echo "$APP"
