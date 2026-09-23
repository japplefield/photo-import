#!/bin/bash
# Builds "Photo Import.app" into ./build (ad-hoc signed, runs on this Mac).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="build/Photo Import.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PhotoImport "$APP/Contents/MacOS/PhotoImport"

# App icon: every size macOS asks for, from the 1024px master (regenerate it with scripts/make-icon.swift).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for px in 16 32 128 256 512; do
    sips -z $px $px Resources/AppIcon-1024.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PhotoImport</string>
    <key>CFBundleIdentifier</key><string>local.photoimport.PhotoImport</string>
    <key>CFBundleName</key><string>Photo Import</string>
    <key>CFBundleDisplayName</key><string>Photo Import</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
