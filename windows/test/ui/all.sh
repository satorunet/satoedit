#!/bin/bash
# 画面の確認の手順をすべて流して、うまくいかなかったものを並べる: ./test/ui/all.sh <出力フォルダ>
cd "$(dirname "$0")/../.." || exit 1
OUT="${1:-/tmp/satoedit-ui}"
mkdir -p "$OUT"
python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1
NAMES=$(node -e "global.window={};require('./test/ui/scenarios.js');console.log(Object.keys(window.__scenarios).join(' '))")
FAILED=0
for n in $NAMES; do
  r=$(./test/ui/shot.sh "$n" "$OUT" ja 2>/dev/null)
  case "$r" in
    '{"ok":true'*) echo "  ok  $n" ;;
    *) echo "  NG  $n  ${r:0:400}"; FAILED=$((FAILED+1)) ;;
  esac
done
echo "失敗: $FAILED"
