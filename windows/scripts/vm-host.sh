#!/bin/bash
# 軽量版 (C# + WebView2) を Parallels の Windows で自己点検する: ./scripts/vm-host.sh [VM の名前]
# 配布物を作り、VM にコピーして satoruEditor.exe --selftest を実行し、結果を build/selftest-lite に持ってくる。
# VM は、Parallels のウインドウが Mac の画面に出ていないと描画されない (画面を撮れない) ので、先に前に出す。
cd "$(dirname "$0")/.." || exit 1
VM="${1:-Windows 10}"
WINUSER="${WINUSER:-satorunet}"
APP="C:\\Users\\$WINUSER\\satoruEditor-lite"
OUT="C:\\Users\\$WINUSER\\satoruEditor-lite-selftest"
HERE="C:\\Mac\\Home\\Hinoki\\windows"

prlctl resume "$VM" >/dev/null 2>&1
( while true; do
    prlctl list -i "$VM" 2>/dev/null | grep -q "^State: paused" && prlctl resume "$VM" >/dev/null 2>&1
    prlctl exec "$VM" cmd /c "echo." >/dev/null 2>&1
    sleep 8
  done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT
prlctl exec "$VM" --current-user cmd /c 'taskkill /F /IM satoruEditor.exe & taskkill /F /IM satoedit.exe' >/dev/null 2>&1
if [ -z "$NOBUILD" ]; then node scripts/package-host.js | tail -1 || exit 1; fi
prlctl exec "$VM" --current-user robocopy "$HERE\\build\\satoruEditor-lite\\satoruEditor" "$APP" /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 >/dev/null 2>&1
prlctl exec "$VM" --current-user cmd /c "rmdir /S /Q $OUT" >/dev/null 2>&1
# WebView2 ランタイムが入っていない Windows (更新していない古い 10 など) では、決まった版のランタイム (Fixed Version) を
# VM のユーザーフォルダに展開して使う (Windows には入れない)。.tools/wv2-x64.cab は Microsoft の配布元から取ってきたもの
WV2="C:\\Users\\$WINUSER\\wv2fixed"
RUNVAR=""
if ! prlctl exec "$VM" --current-user cmd /c 'reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" /v pv' >/dev/null 2>&1 \
   && ! prlctl exec "$VM" --current-user cmd /c 'reg query "HKCU\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" /v pv' >/dev/null 2>&1; then
  if ! prlctl exec "$VM" --current-user cmd /c "dir /s /b $WV2\\msedgewebview2.exe" 2>/dev/null | grep -q msedgewebview2; then
    [ -f .tools/wv2-x64.cab ] || { echo ".tools/wv2-x64.cab がありません"; exit 1; }
    prlctl exec "$VM" --current-user cmd /c "mkdir $WV2 & expand $HERE\\.tools\\wv2-x64.cab -F:* $WV2" >/dev/null 2>&1
    prlctl exec "$VM" --current-user cmd /c "icacls $WV2 /grant *S-1-15-2-2:(OI)(CI)(RX) /grant *S-1-15-2-1:(OI)(CI)(RX) /T /Q" >/dev/null 2>&1
  fi
  RUNTIME=$(prlctl exec "$VM" --current-user cmd /c "dir /s /b $WV2\\msedgewebview2.exe" 2>/dev/null | head -1 | tr -d '\r')
  RUNVAR="set SATOEDIT_WEBVIEW2=${RUNTIME%\\msedgewebview2.exe}&& "
  echo "WebView2 (決まった版): ${RUNTIME%\\msedgewebview2.exe}"
fi
# 試験用のサーバ (SATOEDIT_TEST_SFTP=10.211.55.2:ポート など) を渡すと、サーバとの読み書きも確かめる
for v in SATOEDIT_TEST_SFTP SATOEDIT_TEST_FTP SATOEDIT_TEST_AI; do
  [ -n "${!v}" ] && RUNVAR="${RUNVAR}set $v=${!v}&& "
done
open -a "Parallels Desktop"
perl -e 'alarm shift; exec @ARGV' 300 prlctl exec "$VM" --current-user cmd /c "${RUNVAR}$APP\\satoruEditor.exe --selftest=$OUT --fixtures=$HERE\\test\\fixtures" >/dev/null 2>&1
for i in $(seq 1 36); do
  prlctl exec "$VM" --current-user cmd /c "dir /b $OUT\\report.json" 2>/dev/null | grep -q report && break
  sleep 5
done
rm -rf build/selftest-lite
mkdir -p build/selftest-lite
prlctl exec "$VM" --current-user robocopy "$OUT" "$HERE\\build\\selftest-lite" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 >/dev/null 2>&1
prlctl exec "$VM" --current-user cmd /c "type %LOCALAPPDATA%\\satoruEditor\\host.log" 2>/dev/null | iconv -f cp932 -t utf-8 > build/selftest-lite/host.log
if [ ! -f build/selftest-lite/report.json ]; then
  echo "結果 (report.json) がありません。VM の中でアプリが止まっているかもしれません。"
  exit 1
fi
python3 - <<'PY'
import json
r = json.load(open('build/selftest-lite/report.json'))
print('点検した項目:', len(r['steps']), ' エラー:', len(r['errors']))
for e in r['errors']:
    print('  ', e[:400])
PY
