#!/usr/bin/env python3
# docs.satoru.net … さとるエディタの「リンクで公開」の受け取り口。
# アプリから送られたテキストを保存し、https://docs.satoru.net/r/<id> で誰でも読めるページにする。
# 作文 (原稿用紙) は原稿用紙の見た目で、ふつうのテキストは読みやすい本文のページで出す。
# Python の標準の部品だけで動く。データは 1 件 1 ファイル (JSON) で STATE_DIR に置く。
#
#   POST   /api/share            {title, text, mode, days | expiresAt (UNIX 時刻), visibility, password}  → {id, url, token, expires}
#          visibility: "public" (だれでも読める・検索にも出る。一覧には載せない) / "unlisted" (リンクを知っている人だけ) / "password" (パスワードを入れた人だけ)
#   PUT    /api/share/<id>       (X-Delete-Token: <token>) {title, text, mode, layout, theme, image, visibility, password, days}
#                                → {id, url, expires, visibility}
#                                text があれば中身を新しくする (前の中身は変更履歴に。keepHistory=false なら残さない)。
#                                visibility・password・days・keepHistory があれば公開の設定を変える。clearHistory=true で変更履歴を消す
#   DELETE /api/share/<id>       (X-Delete-Token: <token>)  → {ok}
#   GET    /r/<id>               読むページ (HTML)。パスワード制なら入力欄 → POST /r/<id> で読む
#   GET    /r/<id>.txt           もとのテキスト (パスワード制のものは出さない)
#   GET    /r/<id>/shot.png      公開したときの画面の画像 (アプリが作って送る。「画像としてコピー」に使う)
#   GET    /r/<id>/og.png        SNS のカード画像 (1200×630)。原稿用紙は縮小した用紙、テキストは題名と本文のはじめ
import hashlib
import html
import json
import urllib.parse
import urllib.request
import os
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = os.environ.get("STATE_DIRECTORY", os.path.join(os.path.dirname(os.path.abspath(__file__)), "data"))
PORT = int(os.environ.get("PORT", "3720"))
BASE_URL = os.environ.get("BASE_URL", "https://docs.satoru.net")
MAX_BYTES = 9_000_000          # 1 件の大きさの上限 (送られてくる JSON。画面の画像を含む)
MAX_SHOT = 6_000_000           # 画面の画像 (PNG) の上限
MAX_TEXT = 300_000             # 文字数の上限
RATE_PER_HOUR = 60             # 1 つの IP から 1 時間に公開できる数
ID_ALPHABET = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
ID_RE = re.compile(r"^[A-Za-z0-9]{6,16}$")
MODES = {"text", "editor", "genko", "genkoH", "a4"}
VISIBILITIES = {"public", "unlisted", "password"}
PW_TRIES_PER_10MIN = 20        # パスワードを試せる回数 (1 つの IP から 10 分に)

os.makedirs(STATE_DIR, exist_ok=True)
_rate = {}
_pw_rate = {}
_lock = threading.Lock()


def hash_pw(pw, salt):
    return hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), bytes.fromhex(salt), 200_000).hex()


def pw_allowed(ip):
    now = time.time()
    with _lock:
        hits = [t for t in _pw_rate.get(ip, []) if now - t < 600]
        ok = len(hits) < PW_TRIES_PER_10MIN
        hits.append(now)
        _pw_rate[ip] = hits
        return ok


# 公開したものはデータベース (SQLite) に置く。前の版の 1 件ずつの .json は、はじめに読み込む
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from store import Store  # noqa: E402
import admin  # noqa: E402
ADMIN_HASH = os.environ.get("ADMIN_PASSWORD_HASH", "")   # 管理画面のパスワードの印 (なければ管理画面は出さない)
STORE = Store(os.path.join(STATE_DIR, "docs.sqlite3"), STATE_DIR)


def public_list(limit=100):
    """公開のものを新しい順に (題名・日時・はじめの文)"""
    return STORE.public_list(limit)


def new_id():
    while True:
        i = "".join(secrets.choice(ID_ALPHABET) for _ in range(8))
        if not STORE.exists(i):
            return i


def remove_files(i):
    """その公開にくっついたファイル (カード画像・画面の画像) を消す"""
    for extra in (os.path.join(STATE_DIR, i + ".png"), os.path.join(STATE_DIR, i + ".shot.png")):
        try:
            os.remove(extra)
        except OSError:
            pass


def remove_doc(i):
    STORE.delete(i)
    remove_files(i)


def save(i, doc):
    STORE.put(i, doc)


def load(i):
    if not ID_RE.match(i or ""):
        return None
    doc = STORE.get(i)
    if not doc:
        return None
    if doc.get("expires") and doc["expires"] < time.time():
        remove_doc(i)
        return None
    return doc


def allowed(ip):
    now = time.time()
    with _lock:
        hits = [t for t in _rate.get(ip, []) if now - t < 3600]
        if len(hits) >= RATE_PER_HOUR:
            _rate[ip] = hits
            return False
        hits.append(now)
        _rate[ip] = hits
        return True


_tts_rate = {}


def tts_allowed(ip, per_hour=900):
    """読み上げの声を作る回数の上限 (1 時間に 1 人 900 行まで)"""
    now = time.time()
    with _lock:
        hits = [t for t in _tts_rate.get(ip, []) if now - t < 3600]
        ok = len(hits) < per_hour
        if ok:
            hits.append(now)
        _tts_rate[ip] = hits
        return ok


def cleanup():
    """期限切れのものを消す (1 時間ごと)。読み上げの声は 14 日使われなければ消す"""
    while True:
        now = time.time()
        try:
            for name in os.listdir(TTS_DIR):
                f = os.path.join(TTS_DIR, name)
                if now - os.path.getatime(f) > 14 * 86400 and now - os.path.getmtime(f) > 14 * 86400:
                    os.remove(f)
        except OSError:
            pass
        for i in STORE.expired_ids(now):
            remove_doc(i)
        time.sleep(3600)


# ---------- 原稿用紙の並べ方 (アプリの決まりを簡単にしたもの: 1 列 20 マス、改行で列を変える、行頭の句読点は前の列の下へ) ----------

NO_START = set("、。，．・：；？！ー）」』】〕〉》｝’”ゝゞヽヾぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ")


def genko_columns(text, rows=20):
    cols = []
    for para in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        chars = list(para)
        if not chars:
            cols.append([])
            continue
        cur = []
        for ch in chars:
            if len(cur) == rows:
                if ch in NO_START:      # ぶら下げ: 行頭に来る句読点は前の列の最後のマスに入れる
                    cur[-1] = cur[-1] + ch
                    continue
                cols.append(cur)
                cur = []
            cur.append(ch)
        cols.append(cur)
    return cols


# ---------- 原稿用紙の絵 (アプリの GenkoRenderer と同じ寸法・同じ並べ方で SVG に描く) ----------

SHEET_W, SHEET_H = 297.0, 210.0          # 縦書きの用紙 (mm)。横書きは回して 210 × 297
CELL, RUBY, PITCH, CENTER = 9.0, 3.0, 12.0, 12.0
LEFT, TOP = 22.5, 15.0
GRID_W, GRID_H = PITCH * 20 + CENTER, CELL * 20
LINE_V, LINE_H, INK, RUBY_INK = "#cc735a", "#388c5c", "#121212", "#333333"
HALF_MAX = 0x2000


def column_x(k, horizontal):
    x = LEFT + GRID_W - k * PITCH - (CENTER if k >= 10 else 0) - PITCH
    if horizontal:   # 横書きには真ん中の余白がない
        x += (CENTER if k >= 10 else 0) - CENTER / 2
    return x


def genko_cell_map(text, columns):
    """原稿用紙のマスと本文の対応: {(列番号, 行): (本文の何行目, その行の何字目)}。
    読み上げで、読んでいる行・字のマスを光らせるために使う。マスを頭から順にたどり、本文の字と同じ字のマスを探していく
    (自動整形で空けたマスや、行頭禁則で前の列に寄せた句読点があっても、順番は変わらないため)"""
    cells = [(ci, r, ch) for ci, col in enumerate(columns) for r, ch in enumerate(col[:20]) if ch and ch not in (" ", "\t", "\u3000")]
    out, k = {}, 0
    for n, line in enumerate(text.replace("\r", "").split("\n")):
        for c, ch in enumerate(line):
            if ch in (" ", "\t", "\u3000"):
                continue
            # 先の 40 マスまでで同じ字を探す (見つからない字は、とばす)
            for j in range(k, min(k + 40, len(cells))):
                if cells[j][2] == ch:
                    out[(cells[j][0], cells[j][1])] = (n, c)
                    k = j + 1
                    break
    return out


def svg_sheet(columns, ruby, sheet, total, horizontal, cellmap=None):
    """columns: [[文字 or None] * 20], ruby: {列番号: [[row, rows, text], ...]}。
    cellmap があれば、字のマスの下に読み上げ用の光る四角 (class="hl") を置く"""
    esc = html.escape
    line = LINE_H if horizontal else LINE_V
    W, H = (SHEET_H, SHEET_W) if horizontal else (SHEET_W, SHEET_H)

    def P(xv, yv):
        return (yv, SHEET_W - xv) if horizontal else (xv, yv)

    def ln(x1, y1, x2, y2, w):
        a, b = P(x1, y1), P(x2, y2)
        return '<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke-width="%s"/>' % (a[0], a[1], b[0], b[1], w)

    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %g %g" class="sheet">' % (W, H),
           '<rect width="%g" height="%g" fill="#fffdf7"/>' % (W, H), '<g stroke="%s" fill="none">' % line]
    y0, y1 = TOP, TOP + GRID_H
    for k in range(20):
        x = column_x(k, horizontal)
        for vx in (x, x + CELL, x + PITCH):
            out.append(ln(vx, y0, vx, y1, 0.18))
        for r in range(1, 20):
            out.append(ln(x, y0 + r * CELL, x + CELL, y0 + r * CELL, 0.18))
    if not horizontal:   # 真ん中の余白の魚尾
        cx = column_x(9, False) - CENTER / 2
        for fy in (y0 + GRID_H * 0.25, y0 + GRID_H * 0.7):
            out.append(ln(cx - 3.2, fy, cx + 3.2, fy, 0.3))
            out.append(ln(cx - 3.2, fy + 5, cx, fy + 2.6, 0.3))
            out.append(ln(cx, fy + 2.6, cx + 3.2, fy + 5, 0.3))
    gx = LEFT + (CENTER / 2 if horizontal else 0)
    gw = GRID_W - (CENTER if horizontal else 0)
    a, b = P(gx, y0), P(gx + gw, y1)
    frame_a, frame_b = a, b   # 用紙の枠 (下の小さな表示の位置に使う。a, b は後で字のマスに使い回す)
    out.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" stroke-width="0.6"/>' % (min(a[0], b[0]), min(a[1], b[1]), abs(a[0] - b[0]), abs(a[1] - b[1])))
    out.append('</g>')
    font = 'font-family="Hiragino Mincho ProN, Yu Mincho, YuMincho, serif"'
    vmode = '' if horizontal else ' writing-mode="vertical-rl"'
    if cellmap:
        out.append('<g class="hls">')
        for k in range(20):
            ci = sheet * 20 + k
            if ci >= len(columns):
                break
            x = column_x(k, horizontal)
            for r in range(20):
                hit = cellmap.get((ci, r))
                if not hit:
                    continue
                a, b = P(x, y0 + r * CELL), P(x + CELL, y0 + (r + 1) * CELL)
                out.append('<rect class="hl" data-l="%d" data-c="%d" x="%.2f" y="%.2f" width="%.2f" height="%.2f"/>' % (
                    hit[0], hit[1], min(a[0], b[0]), min(a[1], b[1]), abs(a[0] - b[0]), abs(a[1] - b[1])))
        out.append('</g>')
    out.append('<g fill="%s" %s text-anchor="middle" dominant-baseline="central">' % (INK, font))
    first = sheet * 20
    for k in range(20):
        ci = first + k
        if ci >= len(columns):
            break
        x = column_x(k, horizontal)
        for r, ch in enumerate(columns[ci][:20]):
            if not ch or ch in (" ", "\t"):
                continue
            cx, cy = P(x + CELL / 2, y0 + (r + 0.5) * CELL)
            half = len(ch) == 1 and ord(ch) < HALF_MAX
            mode = '' if half else vmode
            out.append('<text x="%.2f" y="%.2f" font-size="%.2f"%s>%s</text>' % (cx, cy, CELL * 0.72, mode, esc(ch)))
        for item in ruby.get(str(ci), []) or []:
            try:
                row, rows, text = int(item[0]), int(item[1]), str(item[2])
            except (TypeError, ValueError, IndexError):
                continue
            if not text:
                continue
            height = rows * CELL
            rsize = min(RUBY * 0.8, (height - 0.4) / len(text))
            top = y0 + row * CELL + (height - rsize * len(text)) / 2
            for i, ch in enumerate(text):
                cx, cy = P(x + CELL + RUBY / 2, top + (i + 0.5) * rsize)
                out.append('<text x="%.2f" y="%.2f" font-size="%.2f" fill="%s"%s>%s</text>' % (cx, cy, rsize, RUBY_INK, vmode, esc(ch)))
    out.append('</g>')
    # 用紙の下の小さな表示
    fx0, fy0 = (min(frame_a[0], frame_b[0]), max(frame_a[1], frame_b[1]))
    fx1 = max(frame_a[0], frame_b[0])
    out.append('<text x="%.2f" y="%.2f" font-size="2.6" fill="%s" font-family="sans-serif">20 × 20</text>' % (fx0, fy0 + 4.5, line))
    out.append('<text x="%.2f" y="%.2f" font-size="2.6" fill="%s" font-family="sans-serif" text-anchor="end">No. %d / %d</text>' % (fx1, fy0 + 4.5, line, sheet + 1, total))
    out.append('</svg>')
    return "".join(out)


THEME_KEYS = ("background", "text", "gutterBackground", "gutterText", "gutterSeparator", "newlineMark", "eof", "chrome", "chromeText",
              "currentLine", "currentLineText", "gutterCurrentText", "selection", "caret")
DEFAULT_THEME = {"background": "#1E1F22", "text": "#E6E6E6", "gutterBackground": "#1E1F22", "gutterText": "#6B6F78",
                 "gutterSeparator": "#34363C", "newlineMark": "#4FC3D9", "eof": "#4FC3D9", "chrome": "#2B2D31", "chromeText": "#9A9CA3",
                 "currentLine": "#2A2D33", "currentLineText": "#F5C451", "gutterCurrentText": "#E6E6E6", "selection": "#264F78", "caret": "#E6E6E6",
                 "currentLineOn": True,
                 "marks": False, "ruler": False}


def clean_theme(o):
    """アプリから来たエディタの色。#RRGGBB だけ受け取る (ほかは既定の色)"""
    t = dict(DEFAULT_THEME)
    if isinstance(o, dict):
        for k in THEME_KEYS:
            v = o.get(k)
            if isinstance(v, str) and re.fullmatch(r"#[0-9A-Fa-f]{6}", v):
                t[k] = v.upper()
        t["marks"] = o.get("marks") is True
        t["ruler"] = o.get("ruler") is True
        t["currentLineOn"] = o.get("currentLineOn") is not False
    return t


def _rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


# ---------- 読み上げ (このサーバの VOICEVOX ENGINE、ずんだもん) ----------

VOICEVOX = os.environ.get("VOICEVOX_URL", "http://127.0.0.1:50021")
ZUNDAMON = 3                     # ずんだもん (ノーマル)
TTS_DIR = os.path.join(STATE_DIR, "tts")
TTS_LOCK = threading.BoundedSemaphore(2)   # 声を作るのは同時に 2 つまで (CPU で作るため)
TTS_MAX_CHARS = 200


def _tts_key(line):
    import hashlib
    return hashlib.sha1(("%d\u0000%s" % (ZUNDAMON, line)).encode("utf-8")).hexdigest()


def _audio_query(line):
    q = urllib.parse.urlencode({"text": line, "speaker": ZUNDAMON})
    req = urllib.request.Request(VOICEVOX + "/audio_query?" + q, method="POST")
    query = json.loads(urllib.request.urlopen(req, timeout=30).read().decode("utf-8"))
    query["speedScale"] = 1.0
    query["prePhonemeLength"] = 0.1
    query["postPhonemeLength"] = 0.15
    return query


PAUSE_PUNCT = "、。，．！？!?…"


def tts_timing(original):
    """読んでいるところを画面で追うための時刻表: [[字のはじめ, 字のおわり, 秒のはじめ, 秒のおわり], …]。
    VOICEVOX の区切り (息つぎ = 句読点) ごとに、その区間の字に時間を割りふる"""
    line = original.strip()[:TTS_MAX_CHARS]
    lead = len(original) - len(original.lstrip())
    path = os.path.join(TTS_DIR, _tts_key(line) + ".json")
    try:
        with open(path, encoding="utf-8") as f:
            query = json.load(f)
    except (OSError, ValueError):
        with TTS_LOCK:
            query = _audio_query(line)
        os.makedirs(TTS_DIR, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(query, f, ensure_ascii=False)
    speed = query.get("speedScale") or 1.0
    t = (query.get("prePhonemeLength") or 0) / speed
    groups, start = [], t
    phrases = query.get("accent_phrases") or []
    for k, ph in enumerate(phrases):
        t += sum((m.get("consonant_length") or 0) + (m.get("vowel_length") or 0) for m in ph.get("moras") or []) / speed
        pm = ph.get("pause_mora")
        if pm:
            groups.append((start, t))
            t += ((pm.get("consonant_length") or 0) + (pm.get("vowel_length") or 0)) / speed
            start = t
    if not groups or start < t:
        groups.append((start, t))
    segs = [(m.start(), m.end()) for m in re.finditer("[^%s]+[%s]*" % (PAUSE_PUNCT, PAUSE_PUNCT), line)]
    if len(segs) != len(groups) or not segs:
        segs, groups = [(0, len(line))], [(groups[0][0], groups[-1][1])] if groups else [(0, 0)]
    return [[lead + a, lead + b, round(ts, 3), round(te, 3)] for (a, b), (ts, te) in zip(segs, groups)]


def tts_wav(line):
    """1 行ぶんの声 (WAV)。同じ言葉は作った声を使い回す"""
    line = line.strip()[:TTS_MAX_CHARS]
    key = _tts_key(line)
    path = os.path.join(TTS_DIR, key + ".wav")
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        pass
    with TTS_LOCK:
        query = _audio_query(line)
        req = urllib.request.Request(VOICEVOX + "/synthesis?speaker=%d" % ZUNDAMON, method="POST",
                                     data=json.dumps(query).encode("utf-8"), headers={"Content-Type": "application/json"})
        wav = urllib.request.urlopen(req, timeout=60).read()
    os.makedirs(TTS_DIR, exist_ok=True)
    tmp = path + ".tmp%d" % threading.get_ident()
    with open(tmp, "wb") as f:
        f.write(wav)
    os.replace(tmp, path)
    with open(os.path.join(TTS_DIR, key + ".json"), "w", encoding="utf-8") as f:   # 時刻表のため、声の作り方も残す
        json.dump(query, f, ensure_ascii=False)
    return wav


def shot_path(i):
    return os.path.join(STATE_DIR, i + ".shot.png")


def save_shot(i, o):
    """アプリが送ってきた画面の画像 (base64 の PNG) を置く。なければ前のものを消す"""
    import base64
    data = None
    if isinstance(o.get("image"), str):
        try:
            data = base64.b64decode(o["image"], validate=True)
        except ValueError:
            data = None
    if data and data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) <= MAX_SHOT:
        tmp = shot_path(i) + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, shot_path(i))
    else:
        try:
            os.remove(shot_path(i))
        except OSError:
            pass


def custom_expiry(o, now):
    """日時を指定した期限 (expiresAt: UNIX 時刻)。なければ None。過去や 10 年より先は受け付けない (ValueError)"""
    v = o.get("expiresAt")
    if v is None:
        return None
    try:
        t = float(v)
    except (TypeError, ValueError):
        raise ValueError("bad expiresAt")
    if t <= now + 60 or t > now + 3650 * 86400:
        raise ValueError("bad expiresAt")
    return t


def clean_layout(o):
    """アプリから届いた並べ方 (列とふりがな) を確かめて整える。おかしければ None"""
    if not isinstance(o, dict) or not isinstance(o.get("columns"), list) or len(o["columns"]) > 4000:
        return None
    cols = []
    for c in o["columns"]:
        if not isinstance(c, list):
            return None
        cols.append([(x[:4] if isinstance(x, str) else None) for x in c[:20]] + [None] * max(0, 20 - len(c)))
    ruby = {}
    if isinstance(o.get("ruby"), dict):
        for k, v in list(o["ruby"].items())[:20000]:
            if isinstance(v, list):
                ruby[str(k)] = [x[:3] for x in v if isinstance(x, list) and len(x) >= 3][:40]
    return {"columns": cols, "ruby": ruby}


# ---------- SNS のカード画像 (OGP) ----------

FONT_BOLD = "/usr/local/share/fonts/zen/ZenKakuGothicNew-Bold.ttf"
# 本文の日本語。英数字は入っていないので、英数字だけ FONT_LATIN で描く (_runs)
FONT_REG = "/usr/share/fonts/google-droid-sans-fonts/DroidSansJapanese.ttf"
FONT_LATIN = "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf"
FONT_MONO = "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf"
OG_W, OG_H = 1200, 630
# 縦書きで向きを変える字 (横に寝かせて描く) と、右上に寄せる字
ROTATE = set("ー〜～…‥「」『』（）【】〔〕〈〉《》｛｝［］()[]{}-－―‐=＝")
UPPER_RIGHT = set("、。，．")


def _font(path, size):
    from PIL import ImageFont
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


class Mixed:
    """日本語の書体と英数字の書体の組 (字ごとに使い分けて描く)"""
    def __init__(self, size):
        self.cjk = _font(FONT_REG, size)
        self.latin = _font(FONT_LATIN, int(size * 0.92))


def _runs(text, font):
    if not isinstance(font, Mixed):
        return [(text, font)]
    out = []
    for ch in text:
        f = font.latin if ord(ch) < 0x2000 else font.cjk
        if out and out[-1][1] is f:
            out[-1] = (out[-1][0] + ch, f)
        else:
            out.append((ch, f))
    return out


def _len(draw, text, font):
    return sum(draw.textlength(t, font=f) for t, f in _runs(text, font))


def _draw(draw, xy, text, font, fill):
    """左上をそろえて描く (英数字と日本語を混ぜても高さがずれないよう、行の下の線でそろえる)"""
    x, y = xy
    size = font.cjk.size if isinstance(font, Mixed) else font.size
    for t, f in _runs(text, font):
        draw.text((x, y + size * 0.88), t, font=f, fill=fill, anchor="ls")
        x += draw.textlength(t, font=f)


def _wrap(draw, text, font, width, max_lines):
    lines, cur = [], ""
    for ch in text:
        if ch == "\n":
            lines.append(cur)
            cur = ""
            continue
        if _len(draw, cur + ch, font) > width:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
        if len(lines) >= max_lines:
            break
    if cur and len(lines) < max_lines:
        lines.append(cur)
    return lines[:max_lines]


def og_png(doc):
    """カード画像 (PNG のバイト列)。Pillow が無ければ None"""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return None
    import io
    bg = (239, 233, 220)
    img = Image.new("RGB", (OG_W, OG_H), bg)
    d = ImageDraw.Draw(img)
    title = doc.get("title") or "さとるエディタ"
    locked = doc.get("visibility") == "password"
    mode = doc.get("mode", "text")
    footer_font = _font(FONT_BOLD, 26)
    # 下の帯: 右にアプリ名。縦書きの原稿用紙は用紙が大きいので、題名もここ (左) に出す
    d.text((OG_W - 60, OG_H - 50), "さとるエディタ  ·  docs.satoru.net", font=footer_font, fill=(150, 140, 125), anchor="rm")
    if mode == "genko" and not locked:
        tf = _font(FONT_BOLD, 36)
        t = title
        while t and d.textlength(t, font=tf) > OG_W - 560:
            t = t[:-1]
        d.text((60, OG_H - 50), t + ("…" if t != title else ""), font=tf, fill=(40, 36, 30), anchor="lm")
    if mode in ("genko", "genkoH") and not locked:
        h = mode == "genkoH"
        layout = doc.get("layout") or {"columns": [c + [None] * (20 - len(c)) for c in genko_columns(doc.get("text", ""))], "ruby": {}}
        cols = layout["columns"]
        W, Hh = (SHEET_H, SHEET_W) if h else (SHEET_W, SHEET_H)
        u = min((OG_W - 120 if not h else 520) / W, (OG_H - 110) / Hh)
        ox, oy = (60, 30) if h else ((OG_W - W * u) / 2, 24)
        line = (56, 140, 92) if h else (204, 115, 90)
        d.rectangle([ox, oy, ox + W * u, oy + Hh * u], fill=(255, 253, 247))

        def P(xv, yv):
            x, y = (yv, SHEET_W - xv) if h else (xv, yv)
            return ox + x * u, oy + y * u
        y0, y1 = TOP, TOP + GRID_H
        for k in range(20):
            x = column_x(k, h)
            for vx in (x, x + CELL, x + PITCH):
                d.line([P(vx, y0), P(vx, y1)], fill=line, width=1)
            for r in range(1, 20):
                d.line([P(x, y0 + r * CELL), P(x + CELL, y0 + r * CELL)], fill=line, width=1)
        gx = LEFT + (CENTER / 2 if h else 0)
        gw = GRID_W - (CENTER if h else 0)
        a, b = P(gx, y0), P(gx + gw, y1)
        d.rectangle([min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1])], outline=line, width=2)
        size = max(8, int(CELL * 0.72 * u))
        f = _font(FONT_REG, size)
        fl = _font(FONT_LATIN, int(size * 0.9))
        for k in range(min(20, len(cols))):
            x = column_x(k, h)
            for r, ch in enumerate(cols[k][:20]):
                if not ch or ch in (" ", "\t"):
                    continue
                cx, cy = P(x + CELL / 2, y0 + (r + 0.5) * CELL)
                if not h and ch in ROTATE:
                    glyph = Image.new("RGBA", (size * 2, size * 2), (0, 0, 0, 0))
                    ImageDraw.Draw(glyph).text((size, size), ch, font=f, fill=(18, 18, 18), anchor="mm")
                    glyph = glyph.rotate(-90)
                    img.paste(glyph, (int(cx - size), int(cy - size)), glyph)
                elif not h and ch in UPPER_RIGHT:
                    d.text((cx + size * 0.3, cy - size * 0.3), ch, font=f, fill=(18, 18, 18), anchor="mm")
                else:
                    d.text((cx, cy), ch, font=fl if ord(ch) < 0x2000 else f, fill=(18, 18, 18), anchor="mm")
        if h:   # 横書きの用紙は縦長なので、右に題名を出す
            tf = _font(FONT_BOLD, 52)
            for i, l in enumerate(_wrap(d, title, tf, 560, 3)):
                d.text((600, 70 + i * 68), l, font=tf, fill=(40, 36, 30))
            d.text((600, 300), "原稿用紙 (横書き)", font=_font(FONT_BOLD, 28), fill=(56, 140, 92))
    elif mode == "editor" and not locked:
        # 標準エディタ: 暗い画面に行番号と本文のはじめ
        th = doc.get("theme") or DEFAULT_THEME
        bgc, fgc, gbg, gfg, gsep, chrome, chrome_fg = (_rgb(th[k]) for k in ("background", "text", "gutterBackground", "gutterText", "gutterSeparator", "chrome", "chromeText"))
        d.rounded_rectangle([40, 30, OG_W - 40, OG_H - 90], radius=14, fill=bgc)
        d.rounded_rectangle([40, 30, OG_W - 40, 84], radius=14, fill=chrome)
        d.rectangle([40, 70, OG_W - 40, 84], fill=chrome)
        for k, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            d.ellipse([64 + k * 26, 49, 80 + k * 26, 65], fill=c)
        tf = _font(FONT_BOLD, 26)
        t = title
        while t and d.textlength(t, font=tf) > OG_W - 400:
            t = t[:-1]
        d.text((OG_W / 2, 57), t + ("…" if t != title else ""), font=tf, fill=chrome_fg, anchor="mm")
        bf = Mixed(30)
        nf = _font(FONT_MONO, 24)
        lines = doc.get("text", "").split("\n")
        if len(lines) > 1 and lines[-1] == "":
            lines.pop()
        y, n = 106, 1
        gx = 130
        d.rectangle([40, 84, gx, OG_H - 98], fill=gbg)
        d.line([(gx, 84), (gx, OG_H - 98)], fill=gsep, width=2)
        for line in lines:
            if y > OG_H - 140:
                break
            d.text((gx - 18, y + 4), str(n), font=nf, fill=gfg, anchor="ra")
            parts = _wrap(d, line, bf, OG_W - 40 - gx - 50, 3) or [""]
            for part in parts:
                if y > OG_H - 140:
                    break
                _draw(d, (gx + 22, y), part, bf, fgc)
                y += 44
            n += 1
    else:
        # テキスト: 紙の上に題名と本文のはじめ
        d.rounded_rectangle([40, 30, OG_W - 40, OG_H - 90], radius=16, fill=(255, 253, 247))
        tf = _font(FONT_BOLD, 56)
        tl = _wrap(d, title, tf, OG_W - 160, 2)
        for i, l in enumerate(tl):
            d.text((80, 64 + i * 72), l, font=tf, fill=(30, 28, 24))
        if locked:
            d.text((80, 64 + len(tl) * 72 + 30), "パスワードで守られた文書", font=_font(FONT_BOLD, 36), fill=(120, 110, 100))
        else:
            bf = Mixed(32)
            body = doc.get("text", "")
            if title and body.strip().startswith(title):   # 1 行目が題名なら、本文は 2 行目から
                body = body.strip()[len(title):].lstrip()
            top = 64 + len(tl) * 72 + 24
            for i, l in enumerate(_wrap(d, body, bf, OG_W - 160, max(1, (OG_H - 120 - top) // 46))):
                _draw(d, (80, top + i * 46), l, bf, (70, 66, 60))
    out = io.BytesIO()
    img.save(out, "PNG", optimize=True)
    return out.getvalue()


# ---------- ページ ----------

PAGE_CSS = """
:root{--paper:#fffdf7;--ink:#1b1f2e;--line:#c8553d;--muted:#7a7468;--bg:#efe9dc}
@media (prefers-color-scheme:dark){:root{--bg:#1d1c1a;--muted:#a9a296}}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--ink);font-family:"Hiragino Mincho ProN","Yu Mincho","YuMincho",serif}
header{max-width:900px;margin:0 auto;padding:24px 16px 8px;color:var(--muted);font:13px/1.6 -apple-system,"Hiragino Sans",sans-serif;display:flex;gap:12px;flex-wrap:wrap;align-items:baseline}
header h1{font:600 20px/1.4 "Hiragino Sans",sans-serif;color:inherit;margin:0;flex:1 1 100%;min-width:0;overflow-wrap:anywhere}
@media (prefers-color-scheme:dark){header h1{color:#eee}}
header a{color:var(--muted)}
.paper{background:var(--paper);box-shadow:0 2px 10px rgba(0,0,0,.18);border-radius:4px}
.text{max-width:860px;margin:8px auto 40px;padding:40px 44px;font-size:17px;line-height:2;white-space:pre-wrap;overflow-wrap:anywhere}
@media (max-width:600px){.text{padding:24px 18px;margin:8px 8px 32px;font-size:16px}}
.genko-wrap{overflow-x:auto;padding:8px 16px 40px;direction:rtl;display:flex;justify-content:safe center}
.genko{display:inline-flex;flex-direction:row-reverse;gap:0;padding:28px 24px;direction:ltr;border:0}
.genko.h{flex-direction:column;direction:ltr}
.genko-wrap.h{direction:ltr;max-width:900px;margin:0 auto}
.col{display:flex;flex-direction:column;border-left:1px solid var(--line);border-top:1.5px solid var(--line);border-bottom:1.5px solid var(--line);padding-left:6px}
.col:first-child{border-right:1.5px solid var(--line)}
.genko.h .col{flex-direction:row;border-left:1.5px solid var(--line);border-right:1.5px solid var(--line);border-top:1px solid var(--line);border-bottom:0;padding:6px 0 0 0}
.genko.h .col:last-child{border-bottom:1.5px solid var(--line)}
.cell{width:30px;height:30px;display:flex;align-items:center;justify-content:center;font-size:22px;border-bottom:1px solid var(--line);border-right:1px solid var(--line);writing-mode:vertical-rl;text-orientation:upright}
.col .cell:last-child{border-bottom:0}
.genko.h .cell{writing-mode:horizontal-tb;border-bottom:0;border-right:1px solid var(--line)}
.genko.h .col .cell:last-child{border-right:0}
.genko.h{--line:#38a05c}
.sheets{display:flex;flex-direction:column;align-items:center;gap:20px;padding:8px 12px 32px}
.sheets svg{width:100%;max-width:1100px;height:auto;box-shadow:0 2px 10px rgba(0,0,0,.18);border-radius:3px;background:#fffdf7}
.sheets.h svg{max-width:760px}
.ed{max-width:960px;margin:8px auto 40px;border-radius:10px;overflow:hidden;background:var(--bg);box-shadow:0 4px 18px rgba(0,0,0,.28)}
.ed-bar{display:flex;align-items:center;gap:7px;padding:9px 12px;background:var(--chrome);color:var(--chrome-fg);font:12px/1.4 -apple-system,"Hiragino Sans",sans-serif;border-bottom:1px solid rgba(128,128,128,.25)}
.ed-bar i{width:11px;height:11px;border-radius:50%;background:#ff5f57}.ed-bar i:nth-child(2){background:#febc2e}.ed-bar i:nth-child(3){background:#28c840}
.ed-bar span{flex:1;text-align:center;margin-right:50px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ed-body{display:grid;grid-template-columns:calc(var(--w) + 18px) 1fr;padding:0;font:15px/1.75 "SF Mono",Menlo,Consolas,"Hiragino Sans","Noto Sans JP",monospace;color:var(--fg)}
.ln{color:var(--gfg);background:var(--gbg);text-align:right;padding-right:12px;border-right:1px solid var(--gsep);user-select:none;font-variant-numeric:tabular-nums}
.ln:first-child,.ln:first-child+.lc{padding-top:10px}.ed-body{padding-bottom:16px;background:linear-gradient(to right,var(--gbg) calc(var(--w) + 18px),transparent 0)}
.ed-body{font-family:"BIZ UDGothic","SF Mono",Menlo,Consolas,monospace;caret-color:var(--caret);outline:none}
.ed-body ::selection{background:var(--sel)}
.ed-body.boxing ::selection{background:transparent}
::highlight(satoru-box){background-color:var(--sel)}
.ln{cursor:pointer}
.ed .ln.sel{color:var(--gct);background:var(--sel);font-weight:700}.ed-body::selection{background:var(--sel)}
.ed.curline .lc.cur{background:var(--cl);color:var(--clt)}
.ed.curline .ln.cur{background:var(--cl);color:var(--gct)}
.ed:not(.curline) .ln.cur{color:var(--gct)}
.rl{position:sticky;top:0;background:var(--gbg);border-bottom:1px solid var(--gsep);padding-top:0!important;z-index:1}
.lc.rl{padding:0 18px 0 14px;overflow:hidden}
.ruler{position:relative;height:22px;max-width:100%;
background-image:repeating-linear-gradient(to right,var(--gfg) 0 1px,transparent 1px 1ch),repeating-linear-gradient(to right,var(--gfg) 0 1px,transparent 1px 5ch),repeating-linear-gradient(to right,var(--gfg) 0 1px,transparent 1px 10ch);
background-size:100% 4px,100% 7px,100% 10px;background-position:left bottom;background-repeat:no-repeat;opacity:.75}
.ruler span{position:absolute;top:0;margin-left:3px;font:11px/1.4 -apple-system,"Hiragino Sans",sans-serif;color:var(--gfg)}
.crumb{margin:14px 16px -4px;font:13px/1.6 -apple-system,"Hiragino Sans",sans-serif;color:var(--muted,#888);overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
.crumb a{color:inherit;text-decoration:none;font-weight:700}.crumb a:hover{text-decoration:underline}
.copy{display:inline-flex;align-items:center;justify-content:center;width:32px;height:32px;padding:0;border-radius:8px;align-self:center;border:1px solid rgba(128,128,128,.45);background:var(--paper);color:var(--ink);cursor:pointer}
.copy:hover{filter:brightness(.97)}
.copywrap{position:relative;display:inline-flex}
.views{display:inline-flex;border:1px solid rgba(128,128,128,.45);border-radius:8px;overflow:hidden;align-self:center}
.views a{padding:4px 10px;font-size:12px;text-decoration:none;color:var(--muted);border-left:1px solid rgba(128,128,128,.3);white-space:nowrap}
.views a:first-child{border-left:0}.views a.on{background:#1d9bf0;color:#fff}
@media (max-width:600px){.views a{padding:4px 7px;font-size:11px}}
.speak.on{background:#1d9bf0;color:#fff;border-color:#1d9bf0}
.ed-body .lc.reading{background:rgba(255,204,0,.16)!important;box-shadow:inset 4px 0 0 #ffcc00}
.ed .ln.reading{color:#ffcc00!important;font-weight:700;background:rgba(255,204,0,.16)!important}
::highlight(satoru-spoken){background-color:rgba(255,204,0,.28)}
.paper .tl{min-height:1em}.paper .tl.reading{background:rgba(255,204,0,.16);box-shadow:-10px 0 0 rgba(255,204,0,.16),-14px 0 0 #ffcc00;border-radius:2px}
.sheets .hl{fill:transparent}.sheets .hl.line{fill:rgba(255,204,0,.22)}.sheets .hl.spoken{fill:rgba(255,204,0,.42)}.sheets .hl.now{fill:#ffcc00}
::highlight(satoru-now){background-color:#ffcc00;color:#111}
.credit{font-size:11px;opacity:.75}
.copymenu{position:absolute;right:0;top:calc(100% + 6px);z-index:40;display:flex;flex-direction:column;min-width:190px;background:#fff;border:1px solid rgba(0,0,0,.14);border-radius:10px;box-shadow:0 10px 30px rgba(0,0,0,.18);padding:5px}
.copymenu[hidden]{display:none}
.copymenu button{all:unset;cursor:pointer;padding:8px 12px;border-radius:7px;font:14px/1.3 -apple-system,"Hiragino Sans",sans-serif;color:#222;white-space:nowrap}
.copymenu button:hover,.copymenu button:focus-visible{background:#1d9bf0;color:#fff}
.toast{position:fixed;left:50%;bottom:28px;transform:translate(-50%,16px);background:rgba(30,30,30,.92);color:#fff;font:14px/1.4 -apple-system,"Hiragino Sans",sans-serif;padding:10px 18px;border-radius:999px;box-shadow:0 6px 20px rgba(0,0,0,.25);opacity:0;pointer-events:none;transition:opacity .18s,transform .18s;z-index:50;white-space:nowrap}
.toast.on{opacity:1;transform:translate(-50%,0)}.copy.done{border-color:#2f8f57;color:#2f8f57}
.nl{color:var(--nl);font-weight:400;user-select:none;margin-left:2px}.eof{color:var(--eof);font-weight:400;user-select:none}
.lc{white-space:pre-wrap;overflow-wrap:anywhere;padding:0 18px 0 14px;min-width:0}
@media (max-width:600px){.ed{margin:8px 8px 32px}.ed-body{font-size:13.5px}}
.oldrev{max-width:900px;margin:0 auto 8px;padding:8px 14px;background:#fff3dc;border:1px solid #f5c26b;border-radius:8px;font:14px/1.6 -apple-system,"Hiragino Sans",sans-serif;color:#7a4b00}
.hist{max-width:900px;margin:0 auto 28px;padding:0 16px;font:14px/1.7 -apple-system,"Hiragino Sans",sans-serif;color:var(--muted)}
.hist h2{font-size:15px;margin:0 0 6px;color:inherit}
.hist ol{list-style:none;margin:0;padding:0;border-top:1px solid rgba(128,128,128,.25)}
.hist li{display:flex;gap:14px;align-items:baseline;padding:6px 2px;border-bottom:1px solid rgba(128,128,128,.25)}
.hist li b,.hist li a{min-width:7.5em}.hist li.cur b{color:var(--ink)}
.hist small{opacity:.8;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
footer{text-align:center;color:var(--muted);font:12px/1.6 -apple-system,sans-serif;padding:0 16px 32px}
"""


HISTORY_MAX = 50

# 公開ページのエディタの動き (読むだけ)。f-string の外に置く (波かっこをそのまま書くため)
EDITOR_JS = '\n// 公開ページのエディタ (読むだけ): カーソルを置く・動かす・選ぶ・列 (矩形) で選ぶ はできるが、書き換えはできない\n(function () {\n  var ed = document.getElementById("edbody");\n  if (!ed) return;\n  var rows = Array.prototype.slice.call(ed.querySelectorAll(".lc:not(.rl)"));\n  var original = ed.innerHTML;          // 書き換えられたら、この形に戻す\n  var lastPos = null;                   // 最後のカーソル (行, 行の中の位置)\n\n  // --- 行の中の位置 <-> DOM の位置 ---\n  function lineOf(node) {\n    var n = node && (node.nodeType === 1 ? node : node.parentNode);\n    while (n && n !== ed && !(n.classList && n.classList.contains("lc"))) n = n.parentNode;\n    return n && n !== ed && !n.classList.contains("rl") ? n : null;\n  }\n  function textNodes(el) {\n    var out = [], w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {\n      acceptNode: function (t) { return t.parentNode.closest && t.parentNode.closest(".nl,.eof") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; }\n    });\n    while (w.nextNode()) out.push(w.currentNode);\n    return out;\n  }\n  function offsetIn(el, node, off) {\n    var n = 0, list = textNodes(el);\n    for (var i = 0; i < list.length; i++) {\n      if (list[i] === node) return n + off;\n      n += list[i].data.length;\n    }\n    return n;\n  }\n  function pointAt(el, off) {\n    var list = textNodes(el);\n    for (var i = 0; i < list.length; i++) {\n      if (off <= list[i].data.length) return [list[i], off];\n      off -= list[i].data.length;\n    }\n    return list.length ? [list[list.length - 1], list[list.length - 1].data.length] : [el, 0];\n  }\n\n  // 読み上げから使う: n 行目の from〜to 字目の範囲\n  window.__satoruLineRange = function (n, from, to) {\n    var line = rows[n];\n    if (!line) return null;\n    var a = pointAt(line, from), b = pointAt(line, to), r = document.createRange();\n    r.setStart(a[0], a[1]); r.setEnd(b[0], b[1]);\n    return r;\n  };\n\n  // --- カーソルのある行に色を付ける (アプリと同じ) ---\n  var cur = null;\n  function markLine() {\n    var s = window.getSelection();\n    if (!s || !s.focusNode) return;\n    var line = lineOf(s.focusNode);\n    if (!line) return;\n    lastPos = [rows.indexOf(line), offsetIn(line, s.focusNode, s.focusOffset)];\n    if (cur === line) return;\n    if (cur) { cur.classList.remove("cur"); if (cur.previousElementSibling) cur.previousElementSibling.classList.remove("cur"); }\n    line.classList.add("cur");\n    if (line.previousElementSibling) line.previousElementSibling.classList.add("cur");\n    cur = line;\n  }\n  document.addEventListener("selectionchange", markLine);\n\n  // --- 選んでいる行の行番号を光らせる (ふつうの選択も、列の選択も) ---\n  var lit = [];\n  function lightNumbers(lines) {\n    lit.forEach(function (n) { n.classList.remove("sel"); });\n    lit = [];\n    lines.forEach(function (line) {\n      var n = line.previousElementSibling;\n      if (n && n.classList.contains("ln")) { n.classList.add("sel"); lit.push(n); }\n    });\n  }\n  document.addEventListener("selectionchange", function () {\n    if (box) return;\n    var s = window.getSelection();\n    if (!s || s.rangeCount === 0 || s.isCollapsed) { lightNumbers([]); return; }\n    var r = s.getRangeAt(0);\n    lightNumbers(rows.filter(function (line) { return r.intersectsNode(line) && r.toString() !== ""; }));\n  });\n\n  // --- 書き換えさせない ---\n  ["beforeinput", "paste", "drop", "cut", "dragstart"].forEach(function (t) {\n    ed.addEventListener(t, function (e) { e.preventDefault(); });\n  });\n  ed.addEventListener("keydown", function (e) {\n    var k = e.key;\n    if ((k.length === 1 && !(e.metaKey || e.ctrlKey)) || k === "Enter" || k === "Backspace" || k === "Delete" || k === "Tab") e.preventDefault();\n  });\n  // 日本語入力 (変換中の文字) は止められないことがあるので、入ってしまったら元に戻して、カーソルも戻す\n  function restore() {\n    if (ed.innerHTML === original) return;\n    var pos = lastPos;\n    ed.innerHTML = original;\n    rows = Array.prototype.slice.call(ed.querySelectorAll(".lc:not(.rl)"));\n    cur = null;\n    if (pos && rows[pos[0]]) {\n      var p = pointAt(rows[pos[0]], pos[1]), r = document.createRange();\n      r.setStart(p[0], Math.min(p[1], p[0].length || 0));\n      r.collapse(true);\n      var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);\n    }\n    markLine();\n  }\n  ed.addEventListener("input", function () { setTimeout(restore, 0); });\n  ed.addEventListener("compositionend", function () { setTimeout(restore, 0); });\n\n  // --- 行番号を押すと、その行を選ぶ (⇧を押しながらなら、そこまで広げる) ---\n  ed.addEventListener("mousedown", function (e) {\n    var ln = e.target.closest && e.target.closest(".ln");\n    if (!ln || ln.classList.contains("rl")) return;\n    var line = ln.nextElementSibling;\n    if (!line) return;\n    e.preventDefault();\n    var s = window.getSelection(), r = document.createRange();\n    if (e.shiftKey && s.anchorNode && lineOf(s.anchorNode)) {\n      var a = lineOf(s.anchorNode), ai = rows.indexOf(a), li = rows.indexOf(line);\n      var first = rows[Math.min(ai, li)], last = rows[Math.max(ai, li)];\n      r.setStart(first, 0); r.setEndAfter(last.lastChild || last);\n    } else {\n      r.selectNodeContents(line);\n    }\n    s.removeAllRanges(); s.addRange(r);\n    ed.focus({ preventScroll: true });\n  });\n\n  // --- 列 (矩形) の選択: ⌥ (Alt) を押しながらドラッグ ---\n  var box = null, boxText = "";\n  var canHighlight = window.CSS && CSS.highlights && window.Highlight;\n  function caretAt(x, y) {\n    if (document.caretRangeFromPoint) { var r = document.caretRangeFromPoint(x, y); return r && [r.startContainer, r.startOffset]; }\n    if (document.caretPositionFromPoint) { var p = document.caretPositionFromPoint(x, y); return p && [p.offsetNode, p.offset]; }\n    return null;\n  }\n  function clearBox() {\n    box = null; boxText = "";\n    lightNumbers([]);\n    if (canHighlight) CSS.highlights.delete("satoru-box");\n    ed.classList.remove("boxing");\n  }\n  function drawBox(x0, y0, x1, y1) {\n    var top = Math.min(y0, y1), bottom = Math.max(y0, y1), left = Math.min(x0, x1), right = Math.max(x0, x1);\n    var ranges = [], lines = [], hit = [];\n    rows.forEach(function (line) {\n      var rc = line.getBoundingClientRect();\n      if (rc.bottom < top || rc.top > bottom) return;\n      var y = Math.max(rc.top + 2, Math.min(rc.bottom - 2, (rc.top + rc.bottom) / 2));\n      var a = caretAt(left, y), b = caretAt(right, y);\n      if (!a || !b || lineOf(a[0]) !== line || lineOf(b[0]) !== line) { lines.push(""); return; }\n      var r = document.createRange();\n      r.setStart(a[0], a[1]); r.setEnd(b[0], b[1]);\n      if (r.collapsed) { lines.push(""); return; }\n      ranges.push(r);\n      hit.push(line);\n      lines.push(r.toString());\n    });\n    boxText = lines.join("\\n");\n    lightNumbers(hit);\n    if (canHighlight) CSS.highlights.set("satoru-box", new Highlight(...ranges));\n  }\n  ed.addEventListener("mousedown", function (e) {\n    if (!e.altKey || e.button !== 0) { if (box) clearBox(); return; }\n    e.preventDefault();\n    box = { x: e.clientX, y: e.clientY };\n    ed.classList.add("boxing");\n    window.getSelection().removeAllRanges();\n    function move(ev) { drawBox(box.x, box.y, ev.clientX, ev.clientY); }\n    function up() { document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up); }\n    document.addEventListener("mousemove", move);\n    document.addEventListener("mouseup", up);\n  });\n  // 列で選んでいるときのコピーは、選んだ列だけを行ごとに\n  document.addEventListener("copy", function (e) {\n    if (!box || !boxText) return;\n    e.clipboardData.setData("text/plain", boxText);\n    e.preventDefault();\n  });\n  document.addEventListener("keydown", function (e) { if (e.key === "Escape" && box) clearBox(); });\n})();\n'



def history_html(full, i, rev, links):
    """変更履歴: 新しい版から順に。版を押すとその版を見られる (パスワード制のものは日時だけ)"""
    hist = full.get("history") or []
    if not hist:
        return ""
    esc = html.escape
    n = len(hist) + 1
    fmt = lambda t: time.strftime("%Y/%m/%d %H:%M", time.localtime(t or 0))
    rows = []
    for k in range(n, 0, -1):
        at = full.get("updated") if k == n else hist[k - 1].get("at")
        label = "第%d版%s" % (k, "（最新）" if k == n else "（最初）" if k == 1 else "")
        title = (full if k == n else hist[k - 1]).get("title") or ""
        cur = (rev or n) == k
        href = "/r/%s" % esc(i) if k == n else "/r/%s?rev=%d" % (esc(i), k)
        name = ('<b>%s</b>' % label) if cur or not links else ('<a href="%s">%s</a>' % (href, label))
        # 日時を押すと、その版で変わったところ (前の版との差分) を見られる
        when = esc(fmt(at))
        if links and k > 1:
            when = '<a class="when" href="/r/%s?diff=%d" title="前の版からの変更を見る">%s 差分</a>' % (esc(i), k, when)
        rows.append('<li%s>%s<span>%s</span><small>%s</small></li>' % (' class="cur"' if cur else '', name, when, esc(title)))
    return '<section class="hist"><h2>変更履歴</h2><ol>%s</ol></section>' % "".join(rows)


def version_of(doc, k):
    """第 k 版 (1 = 最初、いちばん大きい番号 = 最新) の中身"""
    hist = doc.get("history") or []
    if k == len(hist) + 1:
        return doc, doc.get("updated") or doc.get("created")
    v = hist[k - 1]
    return v, v.get("at")


def _diff_rows(a, b):
    """行ごとの差分。書き換えた行は、行の中の変わった字にも印を付ける"""
    import difflib
    esc = html.escape
    out = []
    la, lb = a.split("\n"), b.split("\n")

    def inline(x, y):
        sm = difflib.SequenceMatcher(None, x, y, autojunk=False)
        ox, oy = [], []
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op == "equal":
                ox.append(esc(x[i1:i2])); oy.append(esc(y[j1:j2]))
            else:
                if i2 > i1: ox.append("<del>%s</del>" % esc(x[i1:i2]))
                if j2 > j1: oy.append("<ins>%s</ins>" % esc(y[j1:j2]))
        return "".join(ox), "".join(oy)

    def row(kind, n1, n2, body):
        sign = {"del": "−", "add": "+", "eq": ""}[kind]
        out.append('<tr class="%s"><td class="n">%s</td><td class="n">%s</td><td class="s">%s</td><td class="c">%s</td></tr>'
                   % (kind, n1 or "", n2 or "", sign, body or "&#8203;"))

    sm = difflib.SequenceMatcher(None, la, lb, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal":
            # 変わっていないところは、前後 2 行だけ出して間は省く
            n = i2 - i1
            for t in range(n):
                if n > 5 and 2 <= t < n - 2:
                    if t == 2:
                        out.append('<tr class="skip"><td colspan="4">⋯ %d 行 同じ ⋯</td></tr>' % (n - 4))
                    continue
                row("eq", i1 + t + 1, j1 + t + 1, esc(la[i1 + t]))
        elif op == "replace" and i2 - i1 == j2 - j1:
            for t in range(i2 - i1):
                x, y = inline(la[i1 + t], lb[j1 + t])
                row("del", i1 + t + 1, None, x)
                row("add", None, j1 + t + 1, y)
        else:
            for t in range(i1, i2):
                row("del", t + 1, None, "<del>%s</del>" % esc(la[t]) if la[t] else "")
            for t in range(j1, j2):
                row("add", None, t + 1, "<ins>%s</ins>" % esc(lb[t]) if lb[t] else "")
    return "".join(out)


def diff_page(doc, i, k):
    esc = html.escape
    old, _ = version_of(doc, k - 1)
    new, at = version_of(doc, k)
    fmt = lambda t: time.strftime("%Y/%m/%d %H:%M", time.localtime(t or 0))
    title = doc.get("title") or "さとるエディタ"
    rows = _diff_rows(old.get("text", ""), new.get("text", ""))
    retitle = ""
    if (old.get("title") or "") != (new.get("title") or ""):
        retitle = '<p class="retitle">題名: <del>%s</del> → <ins>%s</ins></p>' % (esc(old.get("title") or ""), esc(new.get("title") or ""))
    return f"""<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>変更 第{k}版 — {esc(title)} — さとるエディタ</title>
<style>{PAGE_CSS}
.diffwrap{{max-width:960px;margin:8px auto 24px;padding:0 12px;font:14px/1.6 -apple-system,"Hiragino Sans",sans-serif}}
.diffwrap h2{{font-size:17px;margin:4px 0 4px;color:var(--ink)}}
.diffwrap p{{margin:4px 0 12px;color:var(--muted)}}
.diff{{width:100%;border-collapse:collapse;background:var(--paper);border-radius:8px;overflow:hidden;box-shadow:0 2px 10px rgba(0,0,0,.12);font:14px/1.7 "SF Mono",Menlo,Consolas,"Hiragino Sans",monospace;color:#222;table-layout:fixed}}
.diff td{{padding:1px 8px;vertical-align:top}}
.diff td.n{{width:3.6em;text-align:right;color:#999;user-select:none;font-variant-numeric:tabular-nums}}
.diff td.s{{width:1.4em;text-align:center;user-select:none;font-weight:700}}
.diff td.c{{white-space:pre-wrap;overflow-wrap:anywhere}}
.diff tr.del{{background:#fdecec}}.diff tr.del td.s{{color:#c0392b}}
.diff tr.add{{background:#e9f7ee}}.diff tr.add td.s{{color:#2f8f57}}
.diff del{{background:#f7b9b4;text-decoration:none;border-radius:2px}}
.diff ins{{background:#a8e2bd;text-decoration:none;border-radius:2px}}
.diff tr.skip td{{text-align:center;color:#999;background:rgba(128,128,128,.08);font-size:12px}}
.retitle del{{background:#f7b9b4;text-decoration:none}}.retitle ins{{background:#a8e2bd;text-decoration:none}}
</style></head>
<body><header><h1>{esc(title)}</h1><a href="/r/{esc(i)}">最新の版を見る</a></header>
<div class="diffwrap"><h2>第{k - 1}版 → 第{k}版 の変更</h2><p>{esc(fmt(at))} に更新 ・ <a href="/r/{esc(i)}?rev={k}">第{k}版を見る</a></p>{retitle}
<table class="diff">{rows or '<tr class="skip"><td colspan="4">本文の変更はありません</td></tr>'}</table></div>
{history_html(doc, i, None, True)}
<footer><a href="https://docs.satoru.net/" style="color:inherit">さとるエディタ</a> で公開</footer>
</body></html>"""


# 用紙切替のアイコン: 文書の紙 (右上を折った形に行の線) と、右上に重ねた丸い 2 本の矢印
PAPER_SWITCH_SVG = ('<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.7" '
                    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
                    '<path d="M11 3H5.5A1.5 1.5 0 0 0 4 4.5v15A1.5 1.5 0 0 0 5.5 21h9a1.5 1.5 0 0 0 1.5-1.5V14"/>'
                    '<path d="M7 10.5h4M7 14h6M7 17.5h6"/>'
                    # 矢印の下の紙を丸く消してから、丸い 2 本の矢印を重ねる
                    '<circle cx="17.6" cy="6.4" r="6" style="fill:var(--paper,#fff);stroke:none"/>'
                    '<g transform="translate(12.4 1.2) scale(0.44)" stroke-width="3.8">'
                    '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>'
                    '<path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/></g></svg>')

VIEWS = [("editor", "エディタ"), ("genko", "原稿用紙 (縦)"), ("genkoH", "原稿用紙 (横)"), ("text", "A4用紙")]


def page(doc, i, rev=None, links=True, view=None):
    """view: 見る人が選んだ表示 (エディタ・原稿用紙・テキスト)。なければ公開したときの表示"""
    full = doc
    hist = doc.get("history") or []
    if rev is not None and not (1 <= rev <= len(hist)):   # 最新の版の番号もここ (ふつうの表示)
        rev = None
    if rev is not None:   # 前の版を見る
        doc = dict(doc)
        doc.update(hist[rev - 1])
        doc["updated"] = hist[rev - 1].get("at")
    title = doc.get("title") or "さとるエディタ"
    public = doc.get("visibility") == "public"
    txt_link = '' if doc.get("visibility") == "password" else '<a href="/r/%s.txt" title="もとのテキストファイル">.txt</a>' % html.escape(i)
    text = doc.get("text", "")
    published_mode = "text" if doc.get("mode") == "a4" else doc.get("mode", "text")
    mode = view if view in dict(VIEWS) else published_mode
    esc = html.escape
    # 表示の切り替え (リンクだけ。前の版を見ているときは、その版のまま)
    def view_link(v):
        q = []
        if rev:
            q.append("rev=%d" % rev)
        if v != published_mode:
            q.append("view=" + v)
        return "/r/%s%s" % (esc(i), ("?" + "&".join(q)) if q else "")
    # 「用紙切替」のアイコン (アプリと同じ: 用紙の右上に丸い矢印)。押すたびに エディタ → 原稿用紙 (縦) → 原稿用紙 (横) → テキスト と切り替わる
    names = dict(VIEWS)
    order = [v for v, _ in VIEWS]
    nxt = order[(order.index(mode) + 1) % len(order)] if mode in order else order[0]
    switcher = ('<a class="copy viewbtn" href="%s" title="用紙切替: いまは「%s」→ 押すと「%s」" aria-label="用紙切替 (いまは%s)">%s</a>'
                % (view_link(nxt), esc(names.get(mode, "")), esc(names[nxt]), esc(names.get(mode, "")), PAPER_SWITCH_SVG)) if links else ""
    desc = re.sub(r"\s+", " ", text)[:120]
    created = time.strftime("%Y/%m/%d %H:%M", time.localtime(doc.get("created", time.time())))
    if doc.get("updated"):
        created = "更新 " + time.strftime("%Y/%m/%d %H:%M", time.localtime(doc["updated"]))
    if mode in ("genko", "genkoH"):
        h = mode == "genkoH"
        # アプリが並べた原稿用紙 (ふりがなつき) があれば使う。縦と横は並べ方が同じなので、どちらにも使える
        layout = doc.get("layout") or {"columns": [c + [None] * (20 - len(c)) for c in genko_columns(text)], "ruby": {}}
        cols = layout["columns"]
        total = max(1, (len(cols) + 19) // 20)
        cmap = genko_cell_map(text, cols)
        sheets = "".join(svg_sheet(cols, layout.get("ruby") or {}, i, total, h, cmap) for i in range(total))
        body = '<div class="sheets%s">%s</div>' % (" h" if h else "", sheets)
    elif mode == "editor":
        # 標準エディタ: 行番号つきのエディタの画面 (折り返した行は番号なし)
        lines = text.split("\n")
        if len(lines) > 1 and lines[-1] == "":
            lines.pop()
        th = doc.get("theme") or DEFAULT_THEME
        mark = '<b class="nl" contenteditable="false">↓</b>' if th.get("marks") else ''
        rows = "".join('<div class="ln" contenteditable="false">%d</div><div class="lc">%s%s</div>' % (n, esc(l), mark if n < len(lines) or text.endswith("\n") else "")
                       for n, l in enumerate(lines, 1))
        if th.get("marks"):
            rows += '<div class="ln" contenteditable="false"></div><div class="lc"><b class="eof" contenteditable="false">[EOF]</b></div>'
        if th.get("ruler"):
            # 横の目盛り (アプリと同じ: 1 桁ごと・5 桁・10 桁で長さを変え、10 桁ごとに数字)。全角は 2 桁
            cols = 300   # 画面の幅いっぱいまで (はみ出すぶんは隠れる)
            labels = "".join('<span style="left:%dch">%d</span>' % (n, n) for n in range(10, cols + 1, 10))
            rows = '<div class="ln rl" contenteditable="false"></div><div class="lc rl" contenteditable="false"><div class="ruler" style="width:%dch">%s</div></div>' % (cols, labels) + rows
        th = dict(DEFAULT_THEME, **th)   # 前に公開したもの (色が足りない) にも既定の色を
        style = ("--w:%dch;--bg:%s;--fg:%s;--gbg:%s;--gfg:%s;--gsep:%s;--nl:%s;--eof:%s;--chrome:%s;--chrome-fg:%s;"
                 "--cl:%s;--clt:%s;--gct:%s;--sel:%s;--caret:%s") % (
            len(str(len(lines))) + 1, th["background"], th["text"], th["gutterBackground"], th["gutterText"], th["gutterSeparator"],
            th["newlineMark"], th["eof"], th["chrome"], th["chromeText"],
            th["currentLine"], th["currentLineText"], th["gutterCurrentText"], th["selection"], th["caret"])
        # 読むだけのエディタ: クリックでカーソルを置ける・矢印で動ける・選べる (書き換えはできない)
        body = ('<div class="ed%s" style="%s"><div class="ed-bar"><i></i><i></i><i></i><span>%s</span></div>'
                '<div class="ed-body" id="edbody" contenteditable="true" spellcheck="false" inputmode="none" '
                'autocorrect="off" autocapitalize="off" role="textbox" aria-readonly="true" aria-multiline="true">%s</div></div>') % (
            " curline" if th.get("currentLineOn") else "", style, esc(title), rows)
    else:
        # A4用紙 (紙のテキスト): 1 行ずつ分けておく (読み上げで、読んでいる行・字を光らせるため)
        body = '<div class="text paper">%s</div>' % "".join(
            '<div class="tl" data-l="%d">%s</div>' % (n, esc(l) or "<br>") for n, l in enumerate(text.replace("\r", "").split("\n")))
    src_json = json.dumps(text, ensure_ascii=False).replace("<", "\\u003c")
    nonce = secrets.token_urlsafe(18)
    # 画面の画像は、最新の版で、パスワード制でないときだけ (公開したときにアプリが作ったもの)
    has_shot = rev is None and full.get("visibility") != "password" and os.path.exists(shot_path(i))
    shot_item = '<button type="button" role="menuitem" data-k="image">画像としてコピー</button>' if has_shot else ''
    shot_url = "/r/%s/shot.png?v=%d" % (i, int(full.get("updated") or full.get("created") or 0))
    # 「みんなのメモ」に載っているものは、一覧へ戻れるパンくずを付ける
    crumb = ('<nav class="crumb" aria-label="パンくず"><a href="/memos">みんなのメモ</a> › %s</nav>' % html.escape(full.get("title") or "無題")) \
        if full.get("listed") and full.get("visibility") == "public" else ""
    # 読み上げ (ずんだもん): 最新の版で、パスワード制でないときだけ。版ごとに URL を変える (古い声を使わないように)
    tts_base = ("/r/%s/tts/%d/" % (i, int(full.get("updated") or full.get("created") or 0))) if rev is None and full.get("visibility") != "password" else ""   # コピーボタン用 (</script> で切れないように)
    return f"""<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(title)} — さとるエディタ</title>
<meta name="description" content="{esc(desc)}">
<meta property="og:title" content="{esc(title)}"><meta property="og:description" content="{esc(desc)}">
<meta property="og:type" content="article"><meta property="og:url" content="{esc(BASE_URL)}/r/{esc(i)}">
<meta property="og:image" content="{esc(BASE_URL)}/r/{esc(i)}/og.png?v={int(doc.get('updated') or doc.get('created') or 0)}"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:image" content="{esc(BASE_URL)}/r/{esc(i)}/og.png?v={int(doc.get('updated') or doc.get('created') or 0)}">
{'' if public else '<meta name="robots" content="noindex">'}
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=BIZ+UDGothic&display=swap" rel="stylesheet">
<style>{PAGE_CSS}</style></head>
<body>{crumb}<header><h1>{esc(title)}</h1><span>{esc(created)}</span>{txt_link}{switcher}<button class="copy speak" type="button" id="speak" title="読み上げ (ずんだもん)" aria-label="読み上げ" hidden><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M11 5 6 9H2v6h4l5 4V5z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M19 5a10 10 0 0 1 0 14"/></svg></button><button class="copy" type="button" id="copylink" title="リンクをコピー" aria-label="リンクをコピー"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg></button><span class="copywrap"><button class="copy" type="button" id="copy" title="コピー" aria-label="コピー" aria-haspopup="menu" aria-expanded="false"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg></button><span class="copymenu" id="copymenu" role="menu" hidden><button type="button" role="menuitem" data-k="text">テキストとしてコピー</button>{shot_item}</span></span></header>
{'<p class="oldrev">これは第%d版 (前の版) です。<a href="/r/%s">最新の版を見る</a></p>' % (rev, esc(i)) if rev else ''}
{body}
{history_html(full, i, rev, links)}
<script type="application/json" id="src">{src_json}</script>
<script nonce="{nonce}">{EDITOR_JS}</script>
<script nonce="{nonce}">
(function(){{
  var b=document.getElementById("copy"),t=JSON.parse(document.getElementById("src").textContent);
  // 画面の下に「コピーしました」のトーストを出す (ボタンでも、選んで ⌘C / 右クリックでコピーしても)
  var toast=document.createElement("div");toast.className="toast";toast.setAttribute("role","status");toast.setAttribute("aria-live","polite");document.body.appendChild(toast);
  var timer;
  function show(msg){{toast.textContent=msg;toast.classList.add("on");clearTimeout(timer);timer=setTimeout(function(){{toast.classList.remove("on")}},1800)}}
  document.addEventListener("copy",function(){{if(!copying)setTimeout(function(){{show("コピーしました")}},0)}});
  function done(){{show("テキストとしてコピーしました");b.classList.add("done");setTimeout(function(){{b.classList.remove("done")}},1600)}}
  var ttsBase={json.dumps(tts_base)};
  // 読み上げ: サーバのずんだもん (VOICEVOX) が 1 行ずつ読む。読んでいる行に色を付ける。もう一度押すと止める
  var sp=document.getElementById("speak");
  if(sp&&ttsBase){{
    sp.hidden=false;
    var speakIcon=sp.innerHTML,stopIcon='<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>';
    var lines=t.replace(/\\r/g,"").split("\\n"),queue=[],pos=0,audio=null,speaking=false,cache={{}};
    var rows=document.querySelectorAll(".ed-body .lc:not(.rl)");
    // 読んでいる行 (と行番号) を目立たせる。行は毎回探し直す (本文が戻されて作り直されることがあるため)
    function mark(n){{
      var rows=document.querySelectorAll(".ed-body .lc:not(.rl)");
      document.querySelectorAll(".ed-body .reading,.paper .tl.reading").forEach(function(r){{r.classList.remove("reading")}});
      var tl=n>=0?document.querySelector('.paper .tl[data-l="'+n+'"]'):null;
      if(tl){{tl.classList.add("reading");tl.scrollIntoView({{block:"nearest",behavior:"smooth"}})}}
      if(n>=0&&rows[n]){{rows[n].classList.add("reading");if(rows[n].previousElementSibling)rows[n].previousElementSibling.classList.add("reading");rows[n].scrollIntoView({{block:"nearest",behavior:"smooth"}})}}
      // 原稿用紙: 読んでいる行のマスを光らせる
      document.querySelectorAll(".sheets .hl.line,.sheets .hl.spoken,.sheets .hl.now").forEach(function(r){{r.classList.remove("line","spoken","now")}});
      var cells=n>=0?document.querySelectorAll('.sheets .hl[data-l="'+n+'"]'):[];
      cells.forEach(function(c){{c.classList.add("line")}});
      if(cells.length){{var svg=cells[0].ownerSVGElement;if(svg){{var rc=svg.getBoundingClientRect();if(rc.top<0||rc.bottom>innerHeight)svg.scrollIntoView({{block:"nearest",behavior:"smooth"}})}}}}
    }}
    function url(n){{return ttsBase+n+".wav"}}
    var timing={{}},raf=0,hl=window.CSS&&CSS.highlights&&window.Highlight;
    function fetchTiming(n){{if(!timing[n])timing[n]=fetch(ttsBase+n+".json").then(function(r){{return r.ok?r.json():[]}}).catch(function(){{return []}});return timing[n]}}
    // いま読んでいる字: 読み終わった所は薄く、いま読んでいる所はくっきり
    function clearNow(){{cancelAnimationFrame(raf);if(hl){{CSS.highlights.delete("satoru-spoken");CSS.highlights.delete("satoru-now")}}}}
    // 原稿用紙: いま読んでいる字のマスをくっきり、読み終わったマスを少し濃く
    function followGenko(n,segs){{
      var cells=Array.prototype.slice.call(document.querySelectorAll('.sheets .hl[data-l="'+n+'"]'));
      if(!cells.length||!segs.length)return;
      (function tick(){{
        if(!audio||!speaking)return;
        var t=audio.currentTime,pos=segs[segs.length-1][1];
        for(var k=0;k<segs.length;k++){{var g=segs[k];if(t<g[2]){{pos=g[0];break}}if(t<=g[3]){{pos=g[0]+Math.floor((g[1]-g[0])*(t-g[2])/Math.max(0.01,g[3]-g[2]));break}}}}
        cells.forEach(function(c){{var x=+c.getAttribute("data-c");c.classList.toggle("spoken",x<pos);c.classList.toggle("now",x>=pos&&x<pos+2)}});
        raf=requestAnimationFrame(tick);
      }})();
    }}
    function follow(n,segs){{
      if(document.querySelector(".sheets .hl")){{followGenko(n,segs);return}}
      var tlEl=document.querySelector('.paper .tl[data-l="'+n+'"]');
      // A4用紙の行: その行の字の範囲を作る (エディタの行は、エディタの側の決まりで作る)
      var rangeOf=tlEl?function(_,a,b){{
        var w=document.createTreeWalker(tlEl,NodeFilter.SHOW_TEXT),node,off=0,r=document.createRange(),started=false;
        while((node=w.nextNode())){{var L=node.data.length;
          if(!started&&a<=off+L){{r.setStart(node,a-off);started=true}}
          if(started&&b<=off+L){{r.setEnd(node,b-off);return r}}
          off+=L}}
        return started?r:null}}:window.__satoruLineRange;
      if(!hl||!rangeOf||!segs.length)return;
      var lineStart=segs[0][0];
      (function tick(){{
        if(!audio||!speaking)return;
        var t=audio.currentTime,pos=segs[segs.length-1][1];
        for(var k=0;k<segs.length;k++){{var g=segs[k];if(t<g[2]){{pos=g[0];break}}if(t<=g[3]){{pos=g[0]+Math.floor((g[1]-g[0])*(t-g[2])/Math.max(0.01,g[3]-g[2]));break}}}}
        var done=rangeOf(n,lineStart,pos),now=rangeOf(n,pos,Math.min(pos+2,segs[segs.length-1][1]));
        if(done)CSS.highlights.set("satoru-spoken",new Highlight(done));
        if(now)CSS.highlights.set("satoru-now",new Highlight(now));
        raf=requestAnimationFrame(tick);
      }})();
    }}
    function fetchLine(n){{if(!cache[n])cache[n]=fetch(url(n)).then(function(r){{if(!r.ok)throw new Error("tts "+r.status);return r.blob()}});return cache[n]}}
    function stopSpeak(msg){{speaking=false;clearNow();if(audio){{audio.pause();audio=null}}mark(-1);sp.innerHTML=speakIcon;sp.title="読み上げ (ずんだもん)";sp.classList.remove("on");if(msg)show(msg)}}
    function next(){{
      if(!speaking)return;
      if(pos>=queue.length){{stopSpeak("読み終わりました");return}}
      var n=queue[pos++];mark(n);clearNow();
      if(pos<queue.length){{fetchLine(queue[pos]);fetchTiming(queue[pos])}}   // 次の行は先に作っておく
      Promise.all([fetchLine(n),fetchTiming(n)]).then(function(v){{
        if(!speaking)return;
        audio=new Audio(URL.createObjectURL(v[0]));
        audio.onended=function(){{clearNow();setTimeout(next,250)}};   // 行のあいだに少し間をあける
        audio.onerror=function(){{next()}};
        audio.onplaying=function(){{follow(n,v[1])}};
        return audio.play();
      }}).catch(function(){{if(speaking)stopSpeak("読み上げの声を作れませんでした。少し待ってからもう一度どうぞ")}});
    }}
    sp.addEventListener("click",function(){{
      if(speaking){{stopSpeak("読み上げを止めました");return}}
      queue=[];lines.forEach(function(l,k){{if(l.trim())queue.push(k)}});
      if(!queue.length)return;
      pos=0;speaking=true;sp.innerHTML=stopIcon;sp.title="読み上げを止める";sp.classList.add("on");
      show("ずんだもんが読み上げます");next();
    }});
    window.addEventListener("pagehide",function(){{stopSpeak()}});
  }}
  // リンクをコピー: このページの URL (前の版・表示の指定は付けない) をクリップボードへ
  var linkUrl={json.dumps(BASE_URL + "/r/" + i)};
  document.getElementById("copylink").addEventListener("click",function(){{
    var ok=false,a=document.createElement("textarea");
    a.value=linkUrl;a.setAttribute("readonly","");a.style.position="fixed";a.style.top="0";a.style.opacity="0";document.body.appendChild(a);a.select();
    try{{ok=document.execCommand("copy")}}catch(e){{}}
    document.body.removeChild(a);
    if(!ok&&navigator.clipboard)navigator.clipboard.writeText(linkUrl).catch(function(){{}});
    show("リンクをコピーしました");
  }});
  // コピーのアイコン: 押すと「テキストとして / 画像として」を選ぶメニュー
  var menu=document.getElementById("copymenu"),shotUrl={json.dumps(shot_url)};
  function closeMenu(){{menu.hidden=true;b.setAttribute("aria-expanded","false")}}
  b.addEventListener("click",function(e){{e.stopPropagation();menu.hidden=!menu.hidden;b.setAttribute("aria-expanded",String(!menu.hidden));if(!menu.hidden)menu.querySelector("button").focus()}});
  document.addEventListener("click",function(e){{if(!menu.contains(e.target))closeMenu()}});
  document.addEventListener("keydown",function(e){{if(e.key==="Escape")closeMenu()}});
  menu.addEventListener("click",function(e){{
    var k=e.target.getAttribute("data-k");if(!k)return;closeMenu();
    if(k==="text")copyText();else copyImage();
  }});
  // 画像としてコピー: 公開したときにアプリが作った画面の画像を読みこんで、クリップボードへ
  function copyImage(){{
    if(!(window.ClipboardItem&&navigator.clipboard&&navigator.clipboard.write)){{window.open(shotUrl,"_blank");show("このブラウザでは画像のコピーができないので、画像を開きました");return}}
    var blob=fetch(shotUrl).then(function(r){{if(!r.ok)throw new Error("no image");return r.blob()}}).then(function(b){{return b.type==="image/png"?b:new Blob([b],{{type:"image/png"}})}});
    navigator.clipboard.write([new ClipboardItem({{"image/png":blob}})]).then(function(){{show("画像としてコピーしました")}},function(){{window.open(shotUrl,"_blank");show("画像をコピーできなかったので、画像を開きました")}});
  }}
  // テキストとしてコピー: 押したらすぐトーストで知らせる (クリップボードへの書き込みは、使える方法で)
  var copying=false;
  function copyText(){{
    copying=true;
    var ok=false,a=document.createElement("textarea");
    a.value=t;a.setAttribute("readonly","");a.style.position="fixed";a.style.top="0";a.style.opacity="0";document.body.appendChild(a);a.select();
    try{{ok=document.execCommand("copy")}}catch(e){{}}
    document.body.removeChild(a);
    if(!ok&&navigator.clipboard)navigator.clipboard.writeText(t).catch(function(){{}});
    copying=false;
    done();
  }}
}})();
</script>
<footer><a href="https://docs.satoru.net/" style="color:inherit">さとるエディタ</a> で公開{'<br><span class="credit">読み上げ VOICEVOX:ずんだもん</span>' if tts_base else ''}</footer>
{live_js(i, full, reload=rev is None and full.get("visibility") != "password") if links else ''}
</body></html>"""


def password_page(i, title, wrong=False):
    esc = html.escape
    msg = '<p class="err">パスワードが違います。</p>' if wrong else ''
    return f"""<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>パスワード — さとるエディタ</title>
<style>body{{font-family:-apple-system,"Hiragino Sans",sans-serif;background:#efe9dc;color:#333;text-align:center;padding:80px 16px}}
form{{display:inline-block;background:#fffdf7;padding:28px 32px;border-radius:8px;box-shadow:0 2px 10px rgba(0,0,0,.15)}}
input{{font-size:16px;padding:8px 10px;border:1px solid #bbb;border-radius:6px;width:220px}}button{{font-size:15px;padding:8px 18px;margin-left:6px;border-radius:6px;border:0;background:#2b4c9b;color:#fff}}
.err{{color:#c0392b}}</style></head>
<body><form method="post" action="/r/{esc(i)}"><h2>🔒 {esc(title or "パスワードで守られた文書")}</h2>
<p>読むにはパスワードを入れてください。</p>{msg}
<input type="password" name="password" autofocus autocomplete="off"><button>読む</button></form></body></html>"""


def memo_items(limit=60):
    """「みんなのメモ」の 1 件ずつ (題名・日時・はじめの文・表示の種類)"""
    out = []
    for at, i, doc in STORE.listed_list(limit):
        snippet = re.sub(r"\s+", " ", doc.get("text", "")).strip()[:120]
        kind = "原稿用紙" if doc.get("mode") in ("genko", "genkoH") else "エディタ" if doc.get("mode") == "editor" else "テキスト"
        # サムネ: 公開したときにアプリが撮った、実際の見た目の画像 (なければ SNS 用のカード画像)
        v = int(doc.get("updated") or doc.get("created") or 0)
        thumb = ("/r/%s/shot.png?v=%d" % (i, v)) if os.path.exists(shot_path(i)) else ("/r/%s/og.png?v=%d" % (i, v))
        out.append({"id": i, "url": "/r/" + i, "title": doc.get("title") or "無題", "snippet": snippet, "kind": kind, "thumb": thumb,
                    "at": int(at), "date": time.strftime("%Y/%m/%d %H:%M", time.localtime(at))})
    return out


def memos_page():
    esc = html.escape
    rows = []
    for m in memo_items(100):
        rows.append(f'<a class="row" href="{esc(m["url"])}"><img src="{esc(m["thumb"])}" alt="" loading="lazy"><div><b>{esc(m["title"])}</b><span>{esc(m["date"])} ・ {esc(m["kind"])}</span><small>{esc(m["snippet"])}</small></div></a>')
    body = "".join(rows) or '<p class="empty">まだありません。さとるエディタで公開するときに「みんなのメモに掲載 OK」をチェックすると、ここに並びます。</p>'
    return f"""<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>みんなのメモ — さとるエディタβ</title><meta name="description" content="さとるエディタで書いて、みんなのメモに載せてくれたテキスト・作文">
<style>body{{margin:0;font-family:-apple-system,"Hiragino Sans",sans-serif;background:#efe9dc;color:#222}}
main{{max-width:760px;margin:0 auto;padding:28px 16px 48px}}h1{{font-size:22px}}
.row{{display:flex;gap:14px;align-items:center;background:#fffdf7;border-radius:8px;padding:10px 12px;margin:10px 0;color:inherit;text-decoration:none;box-shadow:0 1px 4px rgba(0,0,0,.1)}}
.row img{{width:150px;height:100px;object-fit:cover;object-position:top;border-radius:6px;border:1px solid rgba(0,0,0,.08);flex:none;background:#eee}}
.row div{{min-width:0;flex:1}}
@media (max-width:520px){{.row img{{width:96px;height:72px}}}}
.row:hover{{box-shadow:0 2px 10px rgba(0,0,0,.18)}}
.row b{{display:block;font-size:16px}}.row span{{color:#888;font-size:12px}}.row small{{display:block;color:#555;margin-top:4px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}}
.empty{{color:#888}}a.home{{color:#666}}footer{{text-align:center;color:#888;font-size:12px;padding:0 16px 32px}}footer a{{color:inherit}}</style></head>
<body><main><h1>みんなのメモ</h1><p><a class="home" href="https://docs.satoru.net/">さとるエディタ</a> で書いて、「みんなのメモに掲載 OK」にしてくれたものです。</p>{body}</main>
<footer><a href="https://docs.satoru.net/">さとるエディタβ</a></footer></body></html>"""


# 公開をやめた・期限が切れたページ (見ている途中で消えたときも、この中身に差し替える)
GONE_BODY = """<main class="gone"><h1>このページは公開を終了しました</h1><p>作者が公開をやめたか、公開の期限が切れました。</p></main>
<footer class="gone-foot"><a href="https://docs.satoru.net/">さとるエディタ</a> で書いて、リンクで公開共有できます。<br><a class="gone-app" href="https://docs.satoru.net/">さとるエディタβ を見てみる →</a></footer>"""
GONE_CSS = """.gone{text-align:center;padding:80px 16px 24px;color:#555;font-family:-apple-system,"Hiragino Sans",sans-serif}
.gone h1{font-size:22px}.gone-foot{text-align:center;color:#888;font:13px/1.9 -apple-system,"Hiragino Sans",sans-serif;padding:8px 16px 40px}
.gone-foot a{color:#2b6cb0}.gone-app{display:inline-block;margin-top:10px;padding:8px 16px;border-radius:999px;background:#2b6cb0;color:#fff!important;text-decoration:none;font-weight:600}"""
NOT_FOUND = """<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>公開終了 — さとるエディタ</title><style>body{margin:0;background:#f6f3ec}""" + GONE_CSS + """</style></head>
<body>""" + GONE_BODY + """</body></html>"""


def live_stamp(doc):
    """中身・設定が変わると変わる印 (見ている人のページが、変わったことに気づくため)"""
    t = int((doc.get("updated") or doc.get("created") or 0) * 1000)
    h = hashlib.md5(("%s|%s|%s" % (doc.get("title", ""), doc.get("visibility", ""), doc.get("expires"))).encode("utf-8")).hexdigest()[:8]
    return "%d-%s" % (t, h)


# 見ている人のページ: 作者が公開をやめたらすぐ「公開終了」に、書き換えたら自動で新しい中身に (数秒ごとに問い合わせる)
LIVE_JS = """<script data-live>(function(){
  var id=__ID__,stamp=__STAMP__,reload=__RELOAD__,gone=false,busy=false;
  try{var u=new URL(location.href);if(u.searchParams.has("u")){u.searchParams.delete("u");history.replaceState(null,"",u.pathname+u.search+u.hash)}}catch(e){}
  function check(){
    if(gone||busy||document.hidden)return;busy=true;
    fetch("/r/"+id+"/state.json?t="+Date.now(),{cache:"no-store"}).then(function(r){
      if(r.status===404||r.status===410){gone=true;showGone();return null}
      return r.ok?r.json():null;
    }).then(function(o){
      if(o&&o.v&&o.v!==stamp&&reload)return swap(o.v);
    }).catch(function(){}).then(function(){busy=false});
  }
  // 新しい中身を取ってきて、ページを読み直さずに差し替える (読んでいた場所はそのまま)
  function swap(v){
    var u=new URL(location.href);u.searchParams.delete("u");u.searchParams.set("u",v);
    return fetch(u.toString(),{cache:"no-store"}).then(function(r){return r.ok?r.text():null}).then(function(h){
      if(!h)return;
      var d=new DOMParser().parseFromString(h,"text/html"),y=window.scrollY;
      document.title=d.title;
      document.querySelectorAll("head style").forEach(function(s){s.remove()});
      d.querySelectorAll("head style").forEach(function(s){document.head.appendChild(s.cloneNode(true))});
      document.body.innerHTML=d.body.innerHTML;
      // 中の script は、差し替えたあとにもう一度動かす (この見張り役は、今のものをそのまま使う)
      document.body.querySelectorAll("script").forEach(function(old){
        if(old.hasAttribute("data-live")){old.remove();return}
        var s=document.createElement("script");s.textContent=old.textContent;old.replaceWith(s);
      });
      window.scrollTo(0,y);stamp=v;note();
    }).catch(function(){location.reload()});
  }
  function note(){
    var n=document.createElement("div");n.textContent="最新の内容に更新しました";
    n.style.cssText="position:fixed;left:50%;top:14px;transform:translateX(-50%);background:rgba(20,20,20,.82);color:#fff;font:13px/1 -apple-system,sans-serif;padding:9px 16px;border-radius:999px;z-index:9999;transition:opacity .4s";
    document.body.appendChild(n);setTimeout(function(){n.style.opacity="0"},2200);setTimeout(function(){n.remove()},2800);
  }
  function showGone(){
    var st=document.createElement("style");st.textContent=__CSS__;document.head.appendChild(st);
    document.body.innerHTML=__BODY__;document.title="公開終了 — さとるエディタ";window.scrollTo(0,0);
  }
  setInterval(check,5000);
  document.addEventListener("visibilitychange",function(){if(!document.hidden)check()});
})();</script>"""


def live_js(i, doc, reload=True):
    return (LIVE_JS.replace("__ID__", json.dumps(i)).replace("__STAMP__", json.dumps(live_stamp(doc)))
            .replace("__RELOAD__", "true" if reload else "false")
            .replace("__CSS__", json.dumps(GONE_CSS).replace("</", "<\\/")).replace("__BODY__", json.dumps(GONE_BODY).replace("</", "<\\/")))


class Handler(BaseHTTPRequestHandler):
    server_version = "satoru-docs/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_ip(), fmt % args))

    def client_ip(self):
        return self.headers.get("CF-Connecting-IP") or self.headers.get("X-Real-IP") or self.client_address[0]

    def send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if ctype.startswith("text/html"):
            # ページの中のスクリプトは、ページごとの合言葉 (nonce) が付いたものだけ動かす (書いた文章に紛れたものは動かない)
            m = re.search(rb'<script nonce="([A-Za-z0-9_-]{16,})"', data)
            script = "script-src 'nonce-%s'; " % m.group(1).decode() if m else ""
            self.send_header("Content-Security-Policy",
                             "default-src 'none'; " + script +
                             "style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
                             "img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; "
                             "form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def json_out(self, code, obj):
        self.send(code, json.dumps(obj, ensure_ascii=False))

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        p = self.path.split("?", 1)[0]
        if p == "/admin" or p.startswith("/admin/"):
            return self.admin_get(p)
        if p in ("/", ""):   # / は nginx がサイトのトップを出す。公開したものを一覧にして見せることはしない (一律には載せない)
            return self.send(404, "", "text/plain")
        m = re.match(r"^/r/([A-Za-z0-9]{6,16})/tts/[0-9]+/([0-9]{1,6})\.(wav|json)$", p)
        if m:
            doc = load(m.group(1))
            if not doc or doc.get("visibility") == "password":
                return self.send(404, "", "text/plain")
            lines = doc.get("text", "").replace("\r", "").split("\n")
            n = int(m.group(2))
            if n >= len(lines) or not lines[n].strip():
                return self.send(404, "", "text/plain")
            if not tts_allowed(self.client_ip()):
                return self.send(429, "", "text/plain")
            try:
                if m.group(3) == "json":   # 読んでいるところの時刻表
                    return self.send(200, json.dumps(tts_timing(lines[n])), "application/json; charset=utf-8",
                                     {"Cache-Control": "public, max-age=86400"})
                wav = tts_wav(lines[n])
            except Exception:
                return self.send(503, "", "text/plain")
            return self.send(200, wav, "audio/wav", {"Cache-Control": "public, max-age=86400"})
        if p in ("/memos", "/memos/"):   # みんなのメモ (作者が掲載 OK にしたものだけ)
            return self.send(200, memos_page(), "text/html; charset=utf-8", {"Cache-Control": "public, max-age=60"})
        if p == "/api/memos":   # サイトのトップに並べる用
            return self.send(200, json.dumps(memo_items(30), ensure_ascii=False), "application/json; charset=utf-8", {"Cache-Control": "public, max-age=60"})
        m = re.match(r"^/r/([A-Za-z0-9]{6,16})/state\.json$", p)
        if m:   # 見ている人のページが数秒ごとに聞く: まだ公開中か、中身が変わったか
            doc = load(m.group(1))
            if not doc:
                return self.send(404, json.dumps({"gone": True}), "application/json; charset=utf-8", {"Cache-Control": "no-store"})
            return self.send(200, json.dumps({"v": live_stamp(doc)}), "application/json; charset=utf-8", {"Cache-Control": "no-store"})
        m = re.match(r"^/r/([A-Za-z0-9]{6,16})/shot\.png$", p)
        if m:
            doc = load(m.group(1))
            if not doc or doc.get("visibility") == "password":
                return self.send(404, "", "text/plain")
            try:
                with open(shot_path(m.group(1)), "rb") as f:
                    data = f.read()
            except OSError:
                return self.send(404, "", "text/plain")
            return self.send(200, data, "image/png", {"Cache-Control": "public, max-age=60"})
        m = re.match(r"^/r/([A-Za-z0-9]{6,16})/og\.png$", p)
        if m:
            doc = load(m.group(1))
            if not doc:
                return self.send(404, "", "text/plain")
            cache = os.path.join(STATE_DIR, m.group(1) + ".png")
            try:
                with open(cache, "rb") as f:
                    data = f.read()
            except OSError:
                data = og_png(doc)
                if data is None:
                    return self.send(404, "", "text/plain")
                try:
                    with open(cache, "wb") as f:
                        f.write(data)
                except OSError:
                    pass
            return self.send(200, data, "image/png", {"Cache-Control": "public, max-age=86400"})
        m = re.match(r"^/r/([A-Za-z0-9]{6,16})(\.txt)?/?$", p)
        if m:
            doc = load(m.group(1))
            if not doc:
                return self.send(404, NOT_FOUND, "text/html; charset=utf-8")
            if doc.get("visibility") == "password":
                if m.group(2):
                    return self.send(404, NOT_FOUND, "text/html; charset=utf-8")
                return self.send(200, password_page(m.group(1), doc.get("title")), "text/html; charset=utf-8", {"Cache-Control": "no-store"})
            if m.group(2):
                return self.send(200, doc.get("text", ""), "text/plain; charset=utf-8")
            q = urllib.parse.parse_qs(self.path.split("?", 1)[1]) if "?" in self.path else {}
            try:
                rev = int((q.get("rev") or [""])[0])
            except ValueError:
                rev = None
            try:
                dk = int((q.get("diff") or [""])[0])
            except ValueError:
                dk = 0
            if 2 <= dk <= len(doc.get("history") or []) + 1:
                return self.send(200, diff_page(doc, m.group(1), dk), "text/html; charset=utf-8", {"Cache-Control": "public, max-age=60"})
            view = (q.get("view") or [""])[0]
            if self.command != "HEAD":
                STORE.count_view(m.group(1))   # 閲覧数 (Cloudflare が覚えているあいだの閲覧は数えられない)
            return self.send(200, page(doc, m.group(1), rev, view=view), "text/html; charset=utf-8", {"Cache-Control": "public, max-age=60"})
        self.send(404, NOT_FOUND, "text/html; charset=utf-8")

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BYTES:
            return None
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    # ---------- 管理画面 ----------

    def admin_send(self, code, body, extra=None):
        h = {"Cache-Control": "no-store", "X-Frame-Options": "DENY"}
        h.update(extra or {})
        return self.send(code, body, "text/html; charset=utf-8", h)

    def admin_redirect(self, to, extra=None):
        h = {"Location": to, "Cache-Control": "no-store"}
        h.update(extra or {})
        return self.send(303, "", "text/plain", h)

    def admin_files(self, i):
        return {"shot": os.path.exists(shot_path(i)), "og": os.path.exists(os.path.join(STATE_DIR, i + ".png"))}

    def admin_get(self, p):
        if not ADMIN_HASH:
            return self.send(404, NOT_FOUND, "text/html; charset=utf-8")
        csrf = admin.session_of(self.headers.get("Cookie"))
        if not csrf:
            return self.admin_send(200, admin.login_page())
        q = urllib.parse.parse_qs(self.path.split("?", 1)[1]) if "?" in self.path else {}
        if p == "/admin":
            return self.admin_send(200, admin.list_page(STORE, q, csrf, BASE_URL))
        m = re.match(r"^/admin/d/([A-Za-z0-9]{6,16})$", p)
        if m:
            html_ = admin.detail_page(STORE, m.group(1), csrf, BASE_URL, self.admin_files(m.group(1)), (q.get("msg") or [""])[0][:200])
            if html_:
                return self.admin_send(200, html_)
        return self.admin_redirect("/admin")

    def admin_post(self, p):
        if not ADMIN_HASH:
            return self.send(404, NOT_FOUND, "text/html; charset=utf-8")
        n = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(min(n, 16384)).decode("utf-8", "replace")) if n > 0 else {}
        f = lambda k: (form.get(k) or [""])[0]
        if p == "/admin/login":
            if not pw_allowed(self.client_ip()) or not admin.check_password(f("password"), ADMIN_HASH):
                return self.admin_send(403, admin.login_page(True))
            token = admin.new_session()
            return self.admin_redirect("/admin", {"Set-Cookie": "sadm=%s; Path=/admin; HttpOnly;%s SameSite=Strict; Max-Age=%d"
                                                  % (token, " Secure;" if BASE_URL.startswith("https") else "", admin.SESSION_HOURS * 3600)})
        csrf = admin.session_of(self.headers.get("Cookie"))
        if not csrf or not secrets.compare_digest(csrf, f("csrf")):
            return self.admin_redirect("/admin")
        if p == "/admin/logout":
            admin.end_session(self.headers.get("Cookie"))
            return self.admin_redirect("/admin", {"Set-Cookie": "sadm=; Path=/admin; HttpOnly; Secure; SameSite=Strict; Max-Age=0"})
        m = re.match(r"^/admin/d/([A-Za-z0-9]{6,16})/([a-z]+)$", p)
        if not m:
            return self.admin_redirect("/admin")
        i, act = m.group(1), m.group(2)
        doc = load(i)
        if not doc:
            return self.admin_redirect("/admin")
        back = lambda msg: self.admin_redirect("/admin/d/%s?%s" % (i, urllib.parse.urlencode({"msg": msg})))
        if act == "delete":
            if f("sure") != "1":
                return back("「本当に消す」にチェックを入れてください")
            remove_doc(i)
            return self.admin_redirect("/admin")
        if act == "title":
            t = f("title").strip()[:120]
            if not t:
                return back("題名が空です")
            doc["title"] = t
            msg = "題名を変えました"
        elif act == "visibility":
            vis = f("visibility")
            if vis not in VISIBILITIES:
                return back("公開のしかたが正しくありません")
            pw = f("password")
            if vis == "password":
                if pw:
                    if len(pw) < 4:
                        return back("パスワードは 4 文字以上にしてください")
                    salt = secrets.token_hex(16)
                    doc["pw_salt"], doc["pw_hash"] = salt, hash_pw(pw, salt)
                elif doc.get("visibility") != "password":
                    return back("パスワード制にするには、パスワードを入れてください")
                try:
                    os.remove(shot_path(i))
                except OSError:
                    pass
            else:
                doc.pop("pw_salt", None)
                doc.pop("pw_hash", None)
            doc["visibility"] = vis
            msg = "公開のしかたを「%s」にしました" % admin.VIS_NAMES[vis]
        elif act == "expires":
            at, days = f("at"), f("days")
            if at:
                try:
                    t = time.mktime(time.strptime(at, "%Y-%m-%dT%H:%M"))
                except ValueError:
                    return back("日時が正しくありません")
                if t <= time.time():
                    return back("過去の日時は選べません")
                doc["expires"] = t
            elif days != "":
                try:
                    d = max(0, min(int(days), 3650))
                except ValueError:
                    return back("日数が正しくありません")
                doc["expires"] = time.time() + d * 86400 if d else None
            else:
                return back("日数か日時を選んでください")
            msg = "期限を変えました"
        elif act == "history":
            doc["keepHistory"] = f("keep") == "1"
            if not doc["keepHistory"]:
                doc["history"] = []
            msg = "変更履歴を%sにしました" % ("残す" if doc["keepHistory"] else "残さない (今ある履歴も消しました)")
        elif act == "clearhistory":
            doc["history"] = []
            msg = "変更履歴を消しました"
        else:
            return back("わからない操作です")
        save(i, doc)
        try:   # カード画像は作り直す
            os.remove(os.path.join(STATE_DIR, i + ".png"))
        except OSError:
            pass
        return back(msg)

    def do_POST(self):
        if self.path == "/admin/login" or self.path == "/admin/logout" or self.path.startswith("/admin/d/"):
            return self.admin_post(self.path.split("?", 1)[0])
        m = re.match(r"^/r/([A-Za-z0-9]{6,16})/?$", self.path)
        if m:
            return self.password_post(m.group(1))
        if self.path != "/api/share":
            return self.json_out(404, {"error": "not found"})
        if not allowed(self.client_ip()):
            return self.json_out(429, {"error": "too many"})
        o = self.read_json()
        if not isinstance(o, dict) or not isinstance(o.get("text"), str) or not o["text"].strip():
            return self.json_out(400, {"error": "bad request"})
        text = o["text"][:MAX_TEXT]
        title = str(o.get("title") or "").strip()[:120]
        mode = o.get("mode") if o.get("mode") in MODES else "text"
        try:
            days = int(o.get("days") or 0)
        except (TypeError, ValueError):
            days = 0
        days = max(0, min(days, 3650))
        try:   # 日時を指定した期限 (分まで細かく)
            custom = custom_expiry(o, time.time())
        except ValueError:
            return self.json_out(400, {"error": "bad expiresAt"})
        vis = o.get("visibility") if o.get("visibility") in VISIBILITIES else "unlisted"
        pw = str(o.get("password") or "")
        if vis == "password" and len(pw) < 4:
            return self.json_out(400, {"error": "password too short"})
        now = time.time()
        i = new_id()
        token = secrets.token_urlsafe(24)
        layout = clean_layout(o.get("layout")) if mode in ("genko", "genkoH") else None
        doc = {"title": title, "text": text, "mode": mode, "created": now, "visibility": vis, "layout": layout,
               "theme": clean_theme(o.get("theme")) if mode == "editor" else None,
               "expires": custom if custom else (now + days * 86400 if days else None), "token": token,
               "keepHistory": o.get("keepHistory") is not False,
               "listed": bool(o.get("listed")) and vis == "public"}   # 「みんなのメモ」に載せてよい (「公開」のものだけ)
        if vis == "password":
            salt = secrets.token_hex(16)
            doc["pw_salt"] = salt
            doc["pw_hash"] = hash_pw(pw, salt)
        save(i, doc)
        if vis != "password":   # パスワード制のものは、画像を誰でも取れる場所に置かない
            save_shot(i, o)
        self.json_out(200, {"id": i, "url": "%s/r/%s" % (BASE_URL, i), "token": token, "expires": doc["expires"]})

    def password_post(self, i):
        doc = load(i)
        if not doc:
            return self.send(404, NOT_FOUND, "text/html; charset=utf-8")
        if doc.get("visibility") != "password":
            return self.send(303, "", "text/plain", {"Location": "/r/" + i})
        n = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(min(n, 4096)).decode("utf-8", "replace")) if n > 0 else {}
        pw = (form.get("password") or [""])[0]
        if not pw_allowed(self.client_ip()):
            return self.send(429, password_page(i, doc.get("title"), True), "text/html; charset=utf-8")
        if not pw or not secrets.compare_digest(hash_pw(pw, doc.get("pw_salt", "00")), doc.get("pw_hash", "")):
            return self.send(403, password_page(i, doc.get("title"), True), "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        self.send(200, page(doc, i, links=False), "text/html; charset=utf-8", {"Cache-Control": "no-store"})

    def do_PUT(self):
        m = re.match(r"^/api/share/([A-Za-z0-9]{6,16})$", self.path)
        if not m:
            return self.json_out(404, {"error": "not found"})
        i = m.group(1)
        doc = load(i)
        if not doc:
            return self.json_out(404, {"error": "gone"})
        if not secrets.compare_digest(doc.get("token", ""), self.headers.get("X-Delete-Token", "")):
            return self.json_out(403, {"error": "forbidden"})
        if not allowed(self.client_ip()):
            return self.json_out(429, {"error": "too many"})
        o = self.read_json()
        if not isinstance(o, dict):
            return self.json_out(400, {"error": "bad request"})
        has_text = isinstance(o.get("text"), str) and o["text"].strip() != ""
        # 公開の設定 (公開のしかた・パスワード・期限) を変える
        vis = o.get("visibility")
        if vis is not None:
            if vis not in VISIBILITIES:
                return self.json_out(400, {"error": "bad visibility"})
            pw = str(o.get("password") or "")
            if vis == "password":
                if pw:
                    if len(pw) < 4:
                        return self.json_out(400, {"error": "password too short"})
                    salt = secrets.token_hex(16)
                    doc["pw_salt"], doc["pw_hash"] = salt, hash_pw(pw, salt)
                elif doc.get("visibility") != "password":
                    return self.json_out(400, {"error": "password too short"})
                try:   # パスワード制にしたら、だれでも取れる画面の画像は消す
                    os.remove(shot_path(i))
                except OSError:
                    pass
            else:
                doc.pop("pw_salt", None)
                doc.pop("pw_hash", None)
            doc["visibility"] = vis
        if "expiresAt" in o:
            try:
                doc["expires"] = custom_expiry(o, time.time())
            except ValueError:
                return self.json_out(400, {"error": "bad expiresAt"})
        elif "days" in o:
            try:
                days = max(0, min(int(o.get("days") or 0), 3650))
            except (TypeError, ValueError):
                days = 0
            doc["expires"] = time.time() + days * 86400 if days else None
        # 変更履歴: 残さない設定にしたら、今ある履歴も消す。clearHistory で今ある履歴だけ消す
        if "listed" in o:
            doc["listed"] = bool(o.get("listed"))
        if doc.get("visibility") != "public":
            doc["listed"] = False   # 「公開」のものだけ載せる
        if "keepHistory" in o:
            doc["keepHistory"] = o.get("keepHistory") is not False
            if not doc["keepHistory"]:
                doc["history"] = []
        if o.get("clearHistory") is True:
            doc["history"] = []
        if isinstance(o.get("title"), str) and o["title"].strip() and not has_text:
            doc["title"] = o["title"].strip()[:120]
        if has_text:
            mode = o.get("mode") if o.get("mode") in MODES else doc.get("mode", "text")
            # 前の中身は変更履歴に残す (古いものから消して HISTORY_MAX 版まで)
            prev = {k: doc.get(k) for k in ("title", "text", "mode", "layout", "theme")}
            prev["at"] = doc.get("updated") or doc.get("created")
            if doc.get("keepHistory", True):
                doc["history"] = ((doc.get("history") or []) + [prev])[-HISTORY_MAX:]
            doc["text"] = o["text"][:MAX_TEXT]
            if isinstance(o.get("title"), str) and o["title"].strip():
                doc["title"] = o["title"].strip()[:120]
            doc["mode"] = mode
            doc["layout"] = clean_layout(o.get("layout")) if mode in ("genko", "genkoH") else None
            doc["theme"] = clean_theme(o.get("theme")) if mode == "editor" else None
            doc["updated"] = time.time()
        save(i, doc)
        try:   # カード画像も作り直す
            os.remove(os.path.join(STATE_DIR, i + ".png"))
        except OSError:
            pass
        if has_text and doc.get("visibility") != "password":
            save_shot(i, o)
        self.json_out(200, {"id": i, "url": "%s/r/%s" % (BASE_URL, i), "expires": doc.get("expires"),
                            "visibility": doc.get("visibility"), "keepHistory": doc.get("keepHistory", True),
                            "listed": bool(doc.get("listed")),
                            "historyCount": len(doc.get("history") or [])})

    def do_DELETE(self):
        m = re.match(r"^/api/share/([A-Za-z0-9]{6,16})$", self.path)
        if not m:
            return self.json_out(404, {"error": "not found"})
        doc = load(m.group(1))
        if not doc:
            return self.json_out(200, {"ok": True})  # もう無い
        if not secrets.compare_digest(doc.get("token", ""), self.headers.get("X-Delete-Token", "")):
            return self.json_out(403, {"error": "forbidden"})
        remove_doc(m.group(1))
        self.json_out(200, {"ok": True})


if __name__ == "__main__":
    threading.Thread(target=cleanup, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
