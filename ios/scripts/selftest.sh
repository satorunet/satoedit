#!/bin/bash
# シミュレータで動作確認を 1 つ走らせ、画像を build/screens/ に取り出す。
# 使い方: scripts/selftest.sh <library|editor|genko|genkoH|ai|share|links> ["iPhone 11"]
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
SIMCTL_CHILD_SATORU_SELFTEST="$MODE" SIMCTL_CHILD_SATORU_SEED="${SATORU_SEED:-1}" \
SIMCTL_CHILD_SATORU_AI_BASE_URL="${SATORU_AI_BASE_URL:-}" SIMCTL_CHILD_SATORU_SHARE_PUBLISH="${SATORU_SHARE_PUBLISH:-}" \
SIMCTL_CHILD_SATORU_LANG="${SATORU_LANG:-ja}" \
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
for i in $(seq 1 90); do
  sleep 1
  if [ -f "$LOG" ] && grep -q -E "^done|FAIL|unknown" "$LOG"; then break; fi
done
OUT=build/screens/$(echo "$DEVICE" | tr ' ' '_')
mkdir -p "$OUT"
for f in "$DATA"/Documents/.selftest/*.png; do [ -f "$f" ] && cp "$f" "$OUT/"; done
xcrun simctl io "$UDID" screenshot "$OUT/$MODE-simctl.png" >/dev/null 2>&1 || true
cat "$LOG"
