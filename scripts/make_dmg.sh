#!/bin/bash
# Собирает готовый к раздаче образ build/Clean-SSD-<версия>.dmg:
# универсальное приложение (Apple Silicon + Intel), ярлык «Программы» и инструкция.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build_app.sh --universal

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="build/Clean SSD.app"
DMG="build/Clean-SSD-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
cp scripts/dmg_readme.txt "$STAGE/Как установить и открыть.txt"

hdiutil create -volname "Clean SSD" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Готово: $DMG ($(du -h "$DMG" | cut -f1))"
