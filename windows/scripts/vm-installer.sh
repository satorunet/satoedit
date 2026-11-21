#!/bin/bash
# インストーラーを Parallels の Windows で確かめる: ./scripts/vm-installer.sh [VM の名前]
# 画面を出さずに入れる (/S) → ファイル・ショートカット・「アプリ」一覧の登録を見る → 入れたものを起動して自己点検 → 消す (/S) → 残っていないかを見る
cd "$(dirname "$0")/.." || exit 1
VM="${1:-Windows 10}"
WINUSER="${WINUSER:-satorunet}"
HERE="C:\\Mac\\Home\\Hinoki\\windows"
SETUP=$(ls build/satoruEditor-*-win-x64-setup.exe | tail -1)
[ -n "$SETUP" ] || { echo "インストーラーがありません (node scripts/package-installer.js)"; exit 1; }
NAME=$(basename "$SETUP")
DIR="C:\\Users\\$WINUSER\\AppData\\Local\\Programs\\satoruEditor"
KEY='HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\satoruEditor'
x() { prlctl exec "$VM" --current-user cmd /c "$1" 2>/dev/null | LC_ALL=C tr -d '\r' | LC_ALL=C sed 's/ *$//'; }
ok() { if [ "$1" = "$2" ]; then echo "  OK  $3"; else echo "  NG  $3 ($1)"; FAIL=1; fi; }
FAIL=0

prlctl resume "$VM" >/dev/null 2>&1
x "taskkill /F /IM satoruEditor.exe" >/dev/null
x "copy /Y $HERE\\build\\$NAME C:\\Users\\$WINUSER\\$NAME" >/dev/null
echo "入れる (/S)"
x "C:\\Users\\$WINUSER\\$NAME /S"
ok "$(x "if exist $DIR\\satoruEditor.exe (echo yes) else (echo no)")" yes "本体 satoruEditor.exe"
ok "$(x "if exist $DIR\\uninstall.exe (echo yes) else (echo no)")" yes "uninstall.exe"
ok "$(x "if exist $DIR\\app\\renderer\\index.html (echo yes) else (echo no)")" yes "画面のファイル"
ok "$(x "if exist \"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\さとるエディタ.lnk\" (echo yes) else (echo no)" | tail -1)" yes "スタートメニューのショートカット"
ok "$(x "reg query $KEY /v DisplayName >nul 2>&1 && echo yes || echo no")" yes "「アプリ」一覧への登録"
WV='Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
ok "$(x "(reg query \"HKCU\Software\\$WV\" /v pv || reg query \"HKLM\SOFTWARE\WOW6432Node\\$WV\" /v pv) >nul 2>&1 && echo yes || echo no")" yes "WebView2 ランタイム (入っているか、いっしょに入れた)"
echo "入れたものを起動 (自己点検)"
OUT="C:\\Users\\$WINUSER\\satoruEditor-installed-selftest"
x "rmdir /S /Q $OUT" >/dev/null
# WebView2 ランタイムが入っていない VM では、vm-host.sh が置いた決まった版を使う
RUNTIME=$(x "dir /s /b C:\\Users\\$WINUSER\\wv2fixed\\msedgewebview2.exe" | head -1)
RUNVAR=""
[ -n "$RUNTIME" ] && RUNVAR="set SATOEDIT_WEBVIEW2=${RUNTIME%\\msedgewebview2.exe}&& "
perl -e 'alarm shift; exec @ARGV' 300 prlctl exec "$VM" --current-user cmd /c "${RUNVAR}$DIR\\satoruEditor.exe --selftest=$OUT --fixtures=$HERE\\test\\fixtures" >/dev/null 2>&1
for i in $(seq 1 36); do x "dir /b $OUT\\report.json" | grep -q report && break; sleep 5; done
rm -rf build/selftest-installed; mkdir -p build/selftest-installed
prlctl exec "$VM" --current-user robocopy "$OUT" "$HERE\\build\\selftest-installed" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 >/dev/null 2>&1
python3 -c 'import json
try:
  r=json.load(open("build/selftest-installed/report.json")); print("  自己点検: 項目", len(r["steps"]), " エラー", len(r["errors"]))
except Exception as e: print("  自己点検: 結果がありません", e)'
echo "消す (/S)"
x "$DIR\\uninstall.exe /uninstall /S"
sleep 6
ok "$(x "if exist $DIR (echo yes) else (echo no)")" no "入れた先のフォルダが消えた"
ok "$(x "reg query $KEY >nul 2>&1 && echo yes || echo no")" no "「アプリ」一覧から消えた"
ok "$(x "if exist \"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\さとるエディタ.lnk\" (echo yes) else (echo no)" | tail -1)" no "ショートカットが消えた"
x "del C:\\Users\\$WINUSER\\$NAME" >/dev/null
[ $FAIL = 0 ] && echo "すべて OK" || echo "うまくいかなかった項目があります"
