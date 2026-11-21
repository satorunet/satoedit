#!/bin/bash
# Parallels の Windows で自己点検をする: ./scripts/vm-selftest.sh [VM の名前]
# 配布物を作り、VM にコピーして satoruEditor.exe --selftest を実行し、結果を build/selftest に持ってくる。
# VM は、Parallels のウインドウが Mac の画面に出ていないと描画されない (画面を撮れない) ので、先に前に出す。
cd "$(dirname "$0")/.." || exit 1
VM="${1:-Windows 10}"
WINUSER="${WINUSER:-satorunet}"
APP="C:\\Users\\$WINUSER\\satoruEditor-test"
OUT="C:\\Users\\$WINUSER\\satoruEditor-selftest"
HERE="C:\\Mac\\Home\\Hinoki\\windows\\build"

# VM が「使っていないときは一時停止」になっていると点検の途中で止まるので、点検のあいだは数秒ごとに起こしておく
# (VM の設定そのものは変えない)
prlctl resume "$VM" >/dev/null 2>&1
( while true; do
    prlctl list -i "$VM" 2>/dev/null | grep -q "^State: paused" && prlctl resume "$VM" >/dev/null 2>&1
    prlctl exec "$VM" cmd /c "echo." >/dev/null 2>&1
    sleep 8
  done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT
prlctl exec "$VM" cmd /c 'taskkill /F /IM satoruEditor.exe & taskkill /F /IM satoEdit.exe' >/dev/null 2>&1
node scripts/package-win.js | tail -1 || exit 1
prlctl exec "$VM" --current-user robocopy "$HERE\\satoruEditor-win32-x64" "$APP" /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 >/dev/null 2>&1
prlctl exec "$VM" --current-user cmd /c "rmdir /S /Q $OUT" >/dev/null 2>&1
open -a "Parallels Desktop"
perl -e 'alarm shift; exec @ARGV' 240 prlctl exec "$VM" --current-user "$APP\\satoruEditor.exe" "--selftest=$OUT" >/dev/null 2>&1
for i in $(seq 1 36); do
  prlctl exec "$VM" --current-user cmd /c "dir /b $OUT\\report.json" 2>/dev/null | grep -q report && break
  sleep 5
done
rm -rf build/selftest
mkdir -p build/selftest
prlctl exec "$VM" --current-user robocopy "$OUT" "$HERE\\selftest" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 >/dev/null 2>&1
if [ ! -f build/selftest/report.json ]; then
  echo "結果 (report.json) がありません。VM の中でアプリが止まっているかもしれません。"
  exit 1
fi
python3 - "$@" <<'EOF'
import json
r = json.load(open('build/selftest/report.json'))
print('点検した項目:', len(r['steps']), ' エラー:', len(r['errors']))
for e in r['errors']:
    print('  ', e[:300])
EOF
