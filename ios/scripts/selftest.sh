#!/bin/bash
# シミュレータで動作確認を 1 つ走らせ、画像を build/screens/ に取り出す。
# 使い方: scripts/selftest.sh <library|editor|genko|genkoH|ai|share|links|cloud|nocloud> ["iPhone 11"]
#   cloud   … build/cloudtest/Documents を iCloud コンテナの Documents の代わりにし、Mac 側からファイルを置いて確かめる
#             (はじめて使うときの写し・原稿用紙の拡張属性・a4 と変更履歴 id が消えない・まだ落としていない「.名前.txt.icloud」・
#              開いている間の書き換え・両方で書き換えたとき)
#   nocloud … iCloud が使えない (シミュレータ) とき、この iPhone の中を使い、設定に書いてあるか
#   追加の環境変数は、そのまま渡す: SATORU_AI_BASE_URL, SATORU_SHARE_PUBLISH, SATORU_LANG, SATORU_SEED (既定 1)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="$1"
DEVICE="${2:-iPhone 11}"
BUNDLE=net.satoru.satoruEditor.ios
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/SatoruEditor.app
UDID=$(xcrun simctl list devices available | grep -F "    $DEVICE (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "no simulator named $DEVICE"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
LOG="$DATA/Documents/.selftest/log.txt"
rm -f "$LOG"
CLOUD=""
ATTR=net.satoru.satoruEditor
if [ "$MODE" = cloud ]; then
  # Mac 版が iCloud コンテナに置くのと同じ形: フォルダ 1 段、拡張属性 mode#S / history#S
  CLOUD="$(pwd)/build/cloudtest/Documents"
  rm -rf build/cloudtest
  mkdir -p "$CLOUD/学校"
  printf '春の作文\n山田 太郎\n\n　春になって、校庭の桜が咲きました。\n' > "$CLOUD/学校/春の作文.txt"
  xattr -w "$ATTR.mode#S" genko "$CLOUD/学校/春の作文.txt"
  xattr -w "$ATTR.history#S" hist-genko-1 "$CLOUD/学校/春の作文.txt"
  printf 'Macのメモ\nMac で書いた。\n' > "$CLOUD/Macのメモ.txt"
  printf 'A4の書類\nA4 用紙で書いた。\n' > "$CLOUD/A4の書類.txt"
  xattr -w "$ATTR.mode#S" a4 "$CLOUD/A4の書類.txt"
  xattr -w "$ATTR.history#S" hist-a4-1 "$CLOUD/A4の書類.txt"
  # 同じ名前で中身が違う (写すとき「日記 (iPhone).txt」になる)
  printf 'Mac の日記\n' > "$CLOUD/日記.txt"
  # まだ落としていない iCloud のファイル (中身は iCloud の小さな plist)
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>NSURLNameKey</key><string>クラウドだけ.txt</string></dict></plist>' > "$CLOUD/.クラウドだけ.txt.icloud"
  touch -t 202601010900 "$CLOUD/Macのメモ.txt"
fi
SIMCTL_CHILD_SATORU_SELFTEST="$MODE" SIMCTL_CHILD_SATORU_SEED="${SATORU_SEED:-1}" \
SIMCTL_CHILD_SATORU_AI_BASE_URL="${SATORU_AI_BASE_URL:-}" SIMCTL_CHILD_SATORU_SHARE_PUBLISH="${SATORU_SHARE_PUBLISH:-}" \
SIMCTL_CHILD_SATORU_LANG="${SATORU_LANG:-ja}" SIMCTL_CHILD_SATORU_CLOUD_DIR="$CLOUD" \
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
DID_DL=0; DID_EDIT=0
for i in $(seq 1 120); do
  sleep 1
  if [ -n "$CLOUD" ] && [ -f "$LOG" ]; then
    # Mac 側 (iCloud) の動き: 落とし終わる・開いている間に書き換える
    if [ $DID_DL = 0 ] && grep -q "^await download" "$LOG"; then
      printf 'クラウドだけ\niCloud から届いた横書きの原稿。\n' > "$CLOUD/クラウドだけ.txt"
      xattr -w "$ATTR.mode#S" genkoH "$CLOUD/クラウドだけ.txt"
      rm -f "$CLOUD/.クラウドだけ.txt.icloud"; DID_DL=1
    fi
    if [ $DID_EDIT = 0 ] && grep -q "^await external-edit" "$LOG"; then
      printf 'Macのメモ\nMac で書いた。\nMac で書き足した行\n' > "$CLOUD/Macのメモ.txt.tmp"
      mv "$CLOUD/Macのメモ.txt.tmp" "$CLOUD/Macのメモ.txt"; DID_EDIT=1
    fi
  fi
  if [ -f "$LOG" ] && grep -q -E "^done|FAIL|unknown" "$LOG"; then break; fi
done
OUT=build/screens/$(echo "$DEVICE" | tr ' ' '_')
mkdir -p "$OUT"
for f in "$DATA"/Documents/.selftest/*.png; do [ -f "$f" ] && cp "$f" "$OUT/"; done
xcrun simctl io "$UDID" screenshot "$OUT/$MODE-simctl.png" >/dev/null 2>&1 || true
cat "$LOG"
if [ -n "$CLOUD" ]; then
  echo "--- $CLOUD"
  cd "$CLOUD"
  for f in * */*; do
    if [ -f "$f" ]; then echo "$f  mode=$(xattr -p "$ATTR.mode#S" "$f" 2>/dev/null || echo -)  history=$(xattr -p "$ATTR.history#S" "$f" 2>/dev/null || echo -)"; fi
  done
fi
