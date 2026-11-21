#!/bin/bash
# 画面の確認: ./test/ui/shot.sh <シナリオ名> <出力フォルダ> [言語] [幅] [高さ]
# 先に別の端末で「python3 -m http.server 8765 --bind 127.0.0.1」を windows フォルダで動かしておく
NAME="$1"; OUT="$2"; LANG_ID="${3:-ja}"; W="${4:-1200}"; H="${5:-800}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
URL="http://127.0.0.1:8765/renderer/index.html?lang=$LANG_ID&scenario=$NAME"
PROFILE="$OUT/profile-$NAME"
perl -e 'alarm shift; exec @ARGV' 12 "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$PROFILE" \
  --window-size="$W,$H" --virtual-time-budget=6000 --screenshot="$OUT/$NAME-$LANG_ID.png" "$URL" >/dev/null 2>&1
perl -e 'alarm shift; exec @ARGV' 12 "$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir="$PROFILE" \
  --window-size="$W,$H" --virtual-time-budget=6000 --dump-dom "$URL" 2>/dev/null \
  | python3 -c 'import sys,re,html; d=sys.stdin.read(); m=re.search(r"<pre id=\"scenario-result\"[^>]*>(.*?)</pre>", d, re.S); e=re.search(r"<pre style=\"padding: 16px[^>]*>(.*?)</pre>", d, re.S); print(html.unescape(m.group(1)) if m else ("START ERROR: "+html.unescape(e.group(1)) if e else "NO RESULT (len %d)" % len(d)))'
pkill -f "user-data-dir=$PROFILE" 2>/dev/null
rm -rf "$PROFILE"
