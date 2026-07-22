#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP=AIBenchmarks.app
BIN=AIBenchmarks

echo "==> Компиляция Swift..."
swiftc -O -o "$BIN" *.swift \
  -framework Cocoa -framework SwiftUI \
  -target arm64-apple-macosx13.0

echo "==> Упаковка .app бандла..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIBenchmarks</string>
    <key>CFBundleIdentifier</key>
    <string>com.aibenchmarks.menubar</string>
    <key>CFBundleName</key>
    <string>AI Benchmarks</string>
    <key>CFBundleDisplayName</key>
    <string>AI Benchmarks</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Готово: $APP"
ls -la "$APP/Contents/MacOS/$BIN"
