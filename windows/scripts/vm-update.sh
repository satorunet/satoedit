#!/bin/bash
# インストーラーのアップデート (/update) を Parallels の Windows で確かめる: ./scripts/vm-update.sh
# /S で入れる → アプリを起動 → /update /wait-pid=PID /S がアプリの終了を待って入れ替える → /update (小窓) が入れ替えて起動し直す → 消す
cd "$(dirname "$0")/.." || exit 1
VM="Windows 10"; U=satorunet
HERE="C:\\Mac\\Home\\Hinoki\\windows"
NAME=$(basename "$(ls build/satoruEditor-*-win-x64-setup.exe | tail -1)")
SETUP="C:\\Users\\$U\\$NAME"
DIR="C:\\Users\\$U\\AppData\\Local\\Programs\\satoruEditor"
KEY='HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\satoruEditor'
x() { prlctl exec "$VM" --current-user cmd /c "$1" 2>/dev/null | iconv -f cp932 -t utf-8 | LC_ALL=C tr -d '\r' | LC_ALL=C sed 's/ *$//'; }
ok() { if [ "$1" = "$2" ]; then echo "  OK  $3"; else echo "  NG  $3 ($1)"; FAIL=1; fi; }
FAIL=0
prlctl resume "$VM" >/dev/null 2>&1
( while true; do prlctl list -i "$VM" 2>/dev/null | grep -q "^State: paused" && prlctl resume "$VM" >/dev/null 2>&1; sleep 4; done ) &
KEEP=$!; trap 'kill $KEEP 2>/dev/null' EXIT
bg() { perl -e 'alarm shift; exec @ARGV' 10 prlctl exec "$VM" --current-user cmd /c "$1" >/dev/null 2>&1; }
procs() { x "tasklist /NH" | grep -ci "^${1:0:20}"; }
x "taskkill /F /IM satoruEditor.exe" >/dev/null
x "copy /Y $HERE\\build\\$NAME $SETUP" >/dev/null
echo "1. 入れる (/S)"
x "$SETUP /S"
VER=$(node -p "require('./package.json').version")
ok "$(x "reg query $KEY /v DisplayVersion" | grep -o "$VER" | head -1)" "$VER" "DisplayVersion $VER"
x "del \"%USERPROFILE%\\Desktop\\さとるエディタ.lnk\"" >/dev/null
ok "$(x "if exist \"%USERPROFILE%\\Desktop\\さとるエディタ.lnk\" (echo yes) else (echo no)" | tail -1)" no "デスクトップのショートカットを消した"
echo "2. アプリを起動して、/update /wait-pid=PID /S がアプリの終了を待つか"
bg "start \"\" \"$DIR\\satoruEditor.exe\""
sleep 6
PID=$(x "tasklist /FI \"IMAGENAME eq satoruEditor.exe\" /FO CSV /NH" | head -1 | cut -d, -f2 | tr -d '"')
echo "  app pid=$PID"
x "del $DIR\\README.txt" >/dev/null
bg "start \"\" $SETUP /update /wait-pid=$PID /S"
sleep 6
ok "$(procs $NAME)" 1 "インストーラーはアプリが閉じるまで待っている"
ok "$(x "if exist $DIR\\README.txt (echo yes) else (echo no)")" no "待っている間は入れ替えない"
x "taskkill /F /PID $PID" >/dev/null
for i in $(seq 1 20); do [ "$(procs $NAME)" = 0 ] && break; sleep 2; done
ok "$(procs $NAME)" 0 "アプリが閉じたらインストーラーが終わる"
ok "$(x "if exist $DIR\\README.txt (echo yes) else (echo no)")" yes "入れ替えた (消したファイルが戻った)"
ok "$(x "if exist $DIR\\satoruEditor.exe (echo yes) else (echo no)")" yes "本体がある"
ok "$(x "if exist \"%USERPROFILE%\\Desktop\\さとるエディタ.lnk\" (echo yes) else (echo no)" | tail -1)" no "デスクトップのショートカットは作らない (前の選び方を引き継ぐ)"
ok "$(procs satoruEditor.exe)" 0 "/S では起動しない"
echo "3. /update (小窓を出して入れ替え、起動し直す)"
bg "start \"\" $SETUP /update"
for i in $(seq 1 30); do [ "$(procs satoruEditor.exe)" -ge 1 ] && [ "$(procs $NAME)" = 0 ] && break; sleep 2; done
ok "$(procs $NAME)" 0 "インストーラーが終わった"
ok "$(procs satoruEditor.exe)" 1 "さとるエディタが起動し直した"
WHERE=$(x "wmic process where name='satoruEditor.exe' get ExecutablePath" | grep -i satoruEditor.exe | head -1)
echo "  動いている exe: $WHERE"
sleep 3
x "taskkill /F /IM satoruEditor.exe" >/dev/null
echo "4. 片付け"
x "$DIR\\uninstall.exe /uninstall /S"
sleep 6
ok "$(x "if exist $DIR (echo yes) else (echo no)")" no "消えた"
x "del $SETUP" >/dev/null
[ $FAIL = 0 ] && echo "すべて OK" || echo "うまくいかなかった項目があります"
