#!/bin/bash
# Собирает build/Torrent Disk.app и build/TorrentDisk.dmg. Запускается на macOS.
set -euo pipefail

VERSION="${VERSION:-1.0.0}"
DISTRIBYTED_VERSION="v0.15.0"
DISTRIBYTED_URL="https://github.com/distribyted/distribyted/releases/download/$DISTRIBYTED_VERSION/distribyted-$DISTRIBYTED_VERSION-darwin-arm64"
DISTRIBYTED_LICENSE_URL="https://raw.githubusercontent.com/distribyted/distribyted/$DISTRIBYTED_VERSION/LICENSE"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Torrent Disk.app"
RES="$APP/Contents/Resources"
PLIST="$APP/Contents/Info.plist"

rm -rf "$BUILD"
mkdir -p "$BUILD"

osacompile -o "$APP" "$ROOT/app/TorrentDisk.applescript"

# Проверяем, что русский текст не испортился при компиляции.
osadecompile "$APP/Contents/Resources/Scripts/main.scpt" | grep "Открыть диск" >/dev/null

cp "$ROOT/app/tdisk.sh" "$RES/tdisk.sh"
chmod +x "$RES/tdisk.sh"

curl -fsSL -o "$RES/distribyted" "$DISTRIBYTED_URL"
chmod +x "$RES/distribyted"
curl -fsSL -o "$RES/distribyted-LICENSE.txt" "$DISTRIBYTED_LICENSE_URL"
cat > "$RES/distribyted-SOURCE.txt" <<EOF
Torrent Disk включает distribyted $DISTRIBYTED_VERSION (GPL-3.0).
Исходный код: https://github.com/distribyted/distribyted/tree/$DISTRIBYTED_VERSION
EOF

plutil -replace CFBundleIdentifier -string com.arthuralend.torrentdisk "$PLIST"
plutil -replace CFBundleName -string "Torrent Disk" "$PLIST"
plutil -replace CFBundleDisplayName -string "Torrent Disk" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"

# Тип файла .torrent, чтобы работали «Открыть в программе» и перетаскивание.
plutil -replace CFBundleDocumentTypes -json '[{
  "CFBundleTypeName": "BitTorrent",
  "CFBundleTypeRole": "Viewer",
  "LSHandlerRank": "Alternate",
  "CFBundleTypeExtensions": ["torrent"],
  "LSItemContentTypes": ["org.bittorrent.torrent"]
}]' "$PLIST"
plutil -replace UTImportedTypeDeclarations -json '[{
  "UTTypeIdentifier": "org.bittorrent.torrent",
  "UTTypeDescription": "BitTorrent",
  "UTTypeConformsTo": ["public.data"],
  "UTTypeTagSpecification": {"public.filename-extension": ["torrent"]}
}]' "$PLIST"
plutil -lint "$PLIST"

# Ad-hoc подпись: без Apple Developer ID, но Apple Silicon требует хотя бы её.
codesign --force --deep --sign - "$APP"
codesign --verify --deep "$APP"

STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Torrent Disk" -srcfolder "$STAGE" -ov -format UDZO "$BUILD/TorrentDisk.dmg"
rm -rf "$STAGE"

echo "Готово: $BUILD/TorrentDisk.dmg"
