#!/bin/bash
# Собирает Clean SSD.app в папку build/
set -euo pipefail
cd "$(dirname "$0")/.."

# --universal — один бинарник для Apple Silicon и Intel (для раздачи другим людям).
ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/CleanSSD"

APP="build/Clean SSD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CleanSSD"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Иконка
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  swift scripts/make_icon.swift $s "$ICONSET/icon_${s}x${s}.png"
  swift scripts/make_icon.swift $((s*2)) "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --deep --sign - "$APP"
echo "Готово: $APP"
