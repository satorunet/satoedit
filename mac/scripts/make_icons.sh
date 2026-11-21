#!/bin/bash
# アイコンを作り直す: Resources/AppIcon.icns (既定 = 藍の罫線の原稿用紙) と、設定で選べる色ちがい Resources/Icons/*.png
# 色を足すときは Sources/Hinoki/AppIcon.swift の一覧にも足すこと
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p Resources/Icons

# 名前:未使用:罫線の色[:invert]  (字はいつも墨。sumi は濃い紙に生成りの罫線と字)
VARIANTS="ai:0:2B4C9B shu:0:C8553D hinoki:0:1F7A55 sumi:0:1B1F2E:invert yamabuki:0:D98A10 murasaki:0:5B3A96 asagi:0:1A8A9E kinari:0:9A7A45"
for v in $VARIANTS; do
    IFS=: read -r name top bottom extra <<< "$v"
    swift scripts/make_icon.swift "$TMP/$name.png" "$top" "$bottom" ${extra:-} >/dev/null
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
