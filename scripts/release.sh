#!/usr/bin/env bash
# Produce release artifacts for GitHub:
#   dist/QuickCap-<ver>.app.zip   — plain zipped .app
#   dist/QuickCap-<ver>.dmg       — drag-to-Applications installer
#
# bundle.sh runs first, then the .app is re-signed ad-hoc so the personal
# Apple Development identity (which embeds the developer's email) never
# ships in a public download.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/QuickCap.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "→ Version: $VERSION"

bash scripts/bundle.sh release >/dev/null

# Debug symbols embed the build machine's absolute paths (home folder, account email in a
# cloud-synced path). Strip them so the public binary carries no personal info.
echo "→ Stripping debug symbols (paths, no personal info)"
/usr/bin/strip -S -x "$APP/Contents/MacOS/QuickCap" 2>/dev/null
if /usr/bin/grep -q -a -F -e "/Users/" "$APP/Contents/MacOS/QuickCap"; then
    echo "✗ Release binary still contains a user path — not shipping it." >&2
    exit 1
fi

echo "→ Re-signing with ad-hoc identity (no personal info)"
find "$APP" -name '._*' -delete 2>/dev/null || true
/usr/bin/codesign --remove-signature "$APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP"
if ! /usr/bin/codesign --verify --deep --strict "$APP"; then
    echo "✗ Ad-hoc signature failed verification — refusing to package." >&2
    exit 1
fi
if /usr/bin/codesign -dvv "$APP" 2>&1 | /usr/bin/grep -q '^Authority='; then
    echo "✗ Release binary still carries a certificate chain — not shipping it." >&2
    exit 1
fi

DIST="dist"
mkdir -p "$DIST"

ZIP="$DIST/QuickCap-${VERSION}.app.zip"
rm -f "$ZIP"
echo "→ Zipping → $ZIP"
# ditto keeps the code signature intact; plain zip makes macOS call the app "damaged"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

DMG="$DIST/QuickCap-${VERSION}.dmg"
rm -f "$DMG"
STAGE=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/quickcap-dmg.XXXXXX")
trap 'rm -rf "$STAGE" "$STAGE.dmg"' EXIT
/usr/bin/ditto "$APP" "$STAGE/QuickCap.app"
/bin/ln -s /Applications "$STAGE/Applications"
echo "→ Creating $DMG"
/usr/bin/hdiutil create -volname "QuickCap $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$STAGE.dmg" >/dev/null
/usr/bin/ditto "$STAGE.dmg" "$DMG"

echo
echo "✓ Release artifacts:"
ls -lh "$DIST" | /usr/bin/awk 'NR>1 {print "    " $9 "  (" $5 ")"}'
