#!/bin/bash
# アイコンを作り直す: Resources/AppIcon.icns (既定 = 藍) と、設定で選べる色ちがい Resources/Icons/*.png
# 色を足すときは Sources/Hinoki/AppIcon.swift の一覧にも足すこと
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p Resources/Icons

# 名前 上の色 下の色
VARIANTS="ai:3F6FB5:1B3566 shu:F4623F:BF2A1A hinoki:4FA57A:1F6A4B sumi:4A4E57:1D2026 yamabuki:F7C948:E39A1B murasaki:8A63C9:4B2C86 asagi:3DB6C4:14788C kinari:F4EBDA:D9C7A6"
for v in $VARIANTS; do
    IFS=: read -r name top bottom <<< "$v"
    swift scripts/make_icon.swift "$TMP/$name.png" "$top" "$bottom" >/dev/null
    sips -z 512 512 "$TMP/$name.png" --out "Resources/Icons/$name.png" >/dev/null
done

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -z $s $s "$TMP/ai.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $d $d "$TMP/ai.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
ls -la Resources/AppIcon.icns Resources/Icons
