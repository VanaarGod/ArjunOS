#!/usr/bin/env bash
# Builds the ArjunOS macOS app bundle and a DMG.
#   scripts/package.sh              -> dist/ArjunOS.app  and  dist/ArjunOS-<version>.dmg
#   scripts/package.sh --open       -> also launches the app
#   scripts/package.sh --install    -> also copies the app to ~/Applications (no sudo)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
APP_NAME="ArjunOS"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/ArjunOS-$VERSION.dmg"
OPEN=0; INSTALL=0
for a in "$@"; do case "$a" in --open) OPEN=1;; --install) INSTALL=1;; *) echo "unknown option $a" >&2; exit 2;; esac; done

[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: packaging needs macOS." >&2; exit 1; }
command -v swift >/dev/null || { echo "ERROR: swift not found. Install Xcode 15+." >&2; exit 1; }

echo "==> 1/6 Python bridge environment"
APP_SUPPORT="${JARVIS_HOME:-$HOME/Library/Application Support/JarvisOS}"
"$ROOT/scripts/setup.sh"        # idempotent; also picks up any new Python dependencies

echo "==> 2/6 Compiling (release)"
mkdir -p "$DIST"; LOG="$DIST/build.log"
if ! ( cd "$ROOT/apps/macos" && swift build -c release ) >"$LOG" 2>&1; then
  echo; echo "COMPILE FAILED. Errors (paste these lines):"; echo
  CLEAN="$LOG.txt"; perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' "$LOG" > "$CLEAN" 2>/dev/null || cp "$LOG" "$CLEAN"     # the compiler colours its output; strip that first
  ERRS="$(grep -E "\.swift:[0-9]+:[0-9]+: error:" "$CLEAN" | sed 's#.*/Sources/#Sources/#' | sort -u | head -40 || true)"
  if [ -n "$ERRS" ]; then echo "$ERRS"
  else
    echo "(no file-and-line errors found; here is what the build said)"; echo
    OTHER="$(grep -iE "error|fatal|cannot|undefined|not found|failed" "$CLEAN" | sed 's#.*/Sources/#Sources/#' | sort -u | head -30 || true)"
    if [ -n "$OTHER" ]; then echo "$OTHER"; else tail -40 "$CLEAN"; fi
  fi
  echo; echo "(full log: $LOG)   to see more:  grep -n error: \"$CLEAN\" | head -60"; exit 1
fi
BIN="$(cd "$ROOT/apps/macos" && swift build -c release --show-bin-path)/JarvisOS"
[ -x "$BIN" ] || { echo "ERROR: built binary not found at $BIN" >&2; exit 1; }

echo "==> 3/6 Assembling $APP_NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bridge"
cp "$BIN" "$APP/Contents/MacOS/JarvisOS"
rsync -a --exclude '__pycache__' --exclude '*.pyc' "$ROOT/services/python/src/jarvis_bridge" "$APP/Contents/Resources/bridge/"
# markdown + math renderer (offline; test tooling is not shipped)
mkdir -p "$APP/Contents/Resources/web"
rsync -a --exclude node_modules --exclude test --exclude 'package*.json' "$ROOT/apps/macos/Web/" "$APP/Contents/Resources/web/"
[ -f "$APP/Contents/Resources/web/chat.html" ] || { echo "ERROR: renderer assets missing from the bundle" >&2; exit 1; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.arjunos.app</string>
  <key>CFBundleExecutable</key><string>JarvisOS</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Only if a website you open in the built-in browser asks to use your microphone, and only after you allow it. ArjunOS itself never records audio.</string>
  <key>NSCameraUsageDescription</key><string>Only if a website you open in the built-in browser asks to use your camera, and only after you allow it. ArjunOS itself never uses the camera.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict></plist>
PLIST

echo "==> 4/6 Icon (non-fatal if it fails)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if python3 "$ROOT/scripts/make_icon.py" "$TMP/icon.png" 2>/dev/null; then
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" && echo "    icon ok" || echo "    (icon skipped)"
else echo "    (icon skipped)"; fi

echo "==> 5/6 Ad-hoc signing (local use; not notarized)"
codesign --force --deep --sign - "$APP" && codesign --verify --deep --strict "$APP" && echo "    signature ok"

echo "==> 6/6 Disk image"
STAGE="$TMP/stage"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"; hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo
echo "Built:"; echo "  $APP"; echo "  $DMG"
echo "Run it:      open \"$APP\""
echo "Install it:  drag it onto Applications in the DMG, or re-run with --install"
echo "Note: signed ad-hoc, so macOS may ask you to right-click > Open the first time if you move it between Macs."
[ "$INSTALL" = 1 ] && { mkdir -p "$HOME/Applications"; rm -rf "$HOME/Applications/$APP_NAME.app"; cp -R "$APP" "$HOME/Applications/"; echo "Installed to ~/Applications/$APP_NAME.app"; }
[ "$OPEN" = 1 ] && open "$APP"
exit 0
