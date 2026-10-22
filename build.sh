#!/bin/bash
# Собирает build/Torrent Disk.app и build/TorrentDisk.dmg. Запускается на macOS с Xcode.
set -euo pipefail

VERSION="${VERSION:-2.0.0}"
DISTRIBYTED_VERSION="v0.15.0"
DISTRIBYTED_URL="https://github.com/distribyted/distribyted/releases/download/$DISTRIBYTED_VERSION/distribyted-$DISTRIBYTED_VERSION-darwin-arm64"
DISTRIBYTED_LICENSE_URL="https://raw.githubusercontent.com/distribyted/distribyted/$DISTRIBYTED_VERSION/LICENSE"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Torrent Disk.app"
RES="$APP/Contents/Resources"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$RES"

# Программа.
xcrun swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -framework NetFS \
  -o "$APP/Contents/MacOS/TorrentDisk" \
  "$ROOT"/app/Sources/*.swift 2>&1 | tee "$BUILD/swiftc.log"

# Значок (если не получится нарисовать — останется стандартный).
if xcrun swift "$ROOT/app/make_icon.swift" "$BUILD/icon.png"; then
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "warning: значок не создан"
fi

# distribyted и его лицензия (GPL-3.0).
curl -fsSL -o "$RES/distribyted" "$DISTRIBYTED_URL"
chmod +x "$RES/distribyted"
curl -fsSL -o "$RES/distribyted-LICENSE.txt" "$DISTRIBYTED_LICENSE_URL"
cat > "$RES/distribyted-SOURCE.txt" <<EOF
Torrent Disk включает distribyted $DISTRIBYTED_VERSION (GPL-3.0).
Исходный код: https://github.com/distribyted/distribyted/tree/$DISTRIBYTED_VERSION
EOF

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TorrentDisk</string>
  <key>CFBundleIdentifier</key><string>com.arthuralend.torrentdisk</string>
  <key>CFBundleName</key><string>Torrent Disk</string>
  <key>CFBundleDisplayName</key><string>Torrent Disk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Torrent Disk ищет участников раздачи в локальной сети и подключает торренты как диски.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>BitTorrent</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>torrent</string></array>
      <key>LSItemContentTypes</key><array><string>org.bittorrent.torrent</string></array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>org.bittorrent.torrent</string>
      <key>UTTypeDescription</key><string>BitTorrent</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>torrent</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist"

# Ad-hoc подпись: без Apple Developer ID, но Apple Silicon требует хотя бы её.
codesign --force --sign - "$RES/distribyted"
codesign --force --sign - "$APP"
codesign --verify --deep "$APP"

STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Torrent Disk" -srcfolder "$STAGE" -ov -format UDZO "$BUILD/TorrentDisk.dmg"
rm -rf "$STAGE"

echo "Готово: $BUILD/TorrentDisk.dmg"
