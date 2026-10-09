#!/usr/bin/env bash
# Builds the Rust core + SwiftUI app and assembles build/Equilibrium.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Equilibrium.app"

(cd "$ROOT/core" && cargo build --release)
(cd "$ROOT/app" && swift build -c release --product Equilibrium)
BIN="$(cd "$ROOT/app" && swift build -c release --show-bin-path)/Equilibrium"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Equilibrium"

if [ ! -f "$ROOT/build/AppIcon.icns" ] || [ "$ROOT/assets/AppIcon.svg" -nt "$ROOT/build/AppIcon.icns" ]; then
  "$ROOT/scripts/make-icon.sh"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Equilibrium</string>
  <key>CFBundleDisplayName</key><string>Equilibrium</string>
  <key>CFBundleIdentifier</key><string>app.equilibrium.poker</string>
  <key>CFBundleExecutable</key><string>Equilibrium</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
