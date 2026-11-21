"""管理画面 (https://docs.satoru.net/admin)。公開されているものの一覧・詳細を見て、設定を変えたり公開をやめたりする。

入るには管理用のパスワード (サーバの /etc/satoru-docs.env の ADMIN_PASSWORD_HASH。pbkdf2 の「塩$印」) が要る。
入ったあとはクッキー (HttpOnly・Secure・SameSite=Strict) で 12 時間。操作のフォームには、その入場ごとの合言葉 (csrf) を付ける。
スクリプトは使わない (ページの CSP でスクリプトを止めたまま動く)。
"""
import hashlib
import html
import secrets
import threading
import time
import urllib.parse

SESSION_HOURS = 12
_sessions = {}            # 合言葉 → (期限, csrf)
_lock = threading.Lock()
esc = html.escape
VIS_NAMES = {"public": "公開", "unlisted": "リンクを知っている人だけ", "password": "パスワード"}
MODE_NAMES = {"text": "テキスト", "editor": "エディタ", "genko": "原稿用紙 (縦)", "genkoH": "原稿用紙 (横)", "a4": "A4"}


def check_password(pw, conf):
    """conf = "塩(16進)$印(16進)"。正しければ True"""
    try:
        salt, want = conf.split("$", 1)
        got = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), bytes.fromhex(salt), 300_000).hex()
        return secrets.compare_digest(got, want)
    except (ValueError, AttributeError):
        return False


def new_session():
    token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(16)
    with _lock:
        now = time.time()
        for k in [k for k, v in _sessions.items() if v[0] < now]:
            del _sessions[k]
        _sessions[token] = (now + SESSION_HOURS * 3600, csrf)
    return token


def session_of(cookie_header):
    """クッキーから入場中かを見る。入場中なら csrf、そうでなければ None"""
    for part in (cookie_header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == "sadm":
            with _lock:
                s = _sessions.get(v)
            if s and s[0] > time.time():
                return s[1]
    return None


def end_session(cookie_header):
    for part in (cookie_header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == "sadm":
            with _lock:
                _sessions.pop(v, None)


def fmt(t):
    return time.strftime("%Y/%m/%d %H:%M", time.localtime(t)) if t else "—"


CSS = """
*{box-sizing:border-box}body{margin:0;font:14px/1.6 -apple-system,"Hiragino Sans","Yu Gothic UI",sans-serif;background:#f4f5f7;color:#1c1e21}
a{color:#0b6bcb}header{background:#1d2733;color:#fff;padding:12px 20px;display:flex;align-items:center;gap:16px}
header b{font-size:16px}header a{color:#cfe3ff;text-decoration:none}header form{margin-left:auto}
main{max-width:1200px;margin:0 auto;padding:20px}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px}.card{background:#fff;border-radius:10px;padding:12px 16px;box-shadow:0 1px 3px rgba(0,0,0,.08);min-width:140px}
.card small{display:block;color:#667}.card b{font-size:20px}
form.filter{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}input,select,button{font:inherit;padding:6px 10px;border:1px solid #c9ced6;border-radius:7px;background:#fff}
button{cursor:pointer}button.primary{background:#1d9bf0;border-color:#1d9bf0;color:#fff}button.danger{background:#d93a3a;border-color:#d93a3a;color:#fff}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08)}
th,td{padding:8px 10px;border-bottom:1px solid #eceef1;text-align:left;vertical-align:top}th{background:#fafbfc;color:#556;font-weight:600;white-space:nowrap}
td.num{text-align:right;font-variant-numeric:tabular-nums}tr:hover td{background:#f8fbff}
.tag{display:inline-block;font-size:12px;border-radius:999px;padding:0 8px;border:1px solid}
.v-public{color:#1a7f37;border-color:#9bd3a8}.v-unlisted{color:#0b6bcb;border-color:#9cc4ee}.v-password{color:#9a6700;border-color:#e8c768}
.pager{margin:12px 0;display:flex;gap:10px;align-items:center}
.grid{display:grid;grid-template-columns:180px 1fr;gap:6px 16px;background:#fff;border-radius:10px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.grid dt{color:#667}.grid dd{margin:0}
.box{background:#fff;border-radius:10px;padding:16px;margin-top:16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.box h3{margin:0 0 10px;font-size:15px}.box form{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:6px 0}
pre{white-space:pre-wrap;word-break:break-all;background:#fafbfc;border:1px solid #eceef1;border-radius:8px;padding:12px;max-height:360px;overflow:auto;margin:0}
.msg{background:#e8f6ec;border:1px solid #9bd3a8;border-radius:8px;padding:8px 12px;margin-bottom:12px}
.login{max-width:360px;margin:12vh auto;background:#fff;border-radius:12px;padding:28px;box-shadow:0 4px 20px rgba(0,0,0,.12)}
.login input{width:100%;margin:10px 0}.err{color:#c0392b}
"""


def shell(title, body, csrf=None):
    logout = ('<form method="post" action="/admin/logout"><input type="hidden" name="csrf" value="%s">'
              '<button>ログアウト</button></form>' % esc(csrf)) if csrf else ""
    return ('<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta name="robots" content="noindex"><title>%s — 公開の管理</title><style>%s</style></head><body>'
            '<header><b>さとるエディタ 公開の管理</b><a href="/admin">一覧</a>%s</header><main>%s</main></body></html>'
            % (esc(title), CSS, logout, body))


def login_page(wrong=False):
    return shell("ログイン", '<form class="login" method="post" action="/admin/login"><h2>公開の管理</h2>'
                 + ('<p class="err">パスワードが違います。</p>' if wrong else '')
                 + '<input type="password" name="password" autofocus autocomplete="current-password" placeholder="管理用のパスワード">'
                 '<button class="primary">入る</button></form>')


def list_page(store, query, csrf, base_url):
    q = (query.get("q") or [""])[0][:80]
    vis = (query.get("vis") or [""])[0]
    sort = (query.get("sort") or ["new"])[0]
    try:
        page = max(1, int((query.get("p") or ["1"])[0]))
    except ValueError:
        page = 1
    per = 50
    total, rows = store.search(q, vis if vis in VIS_NAMES else "", sort, per, (page - 1) * per)
    st = store.stats()
    cards = "".join('<div class="card"><small>%s</small><b>%s</b></div>' % (esc(k), esc(str(v))) for k, v in [
        ("公開中の数", st["total"]), ("きょう増えた", st["today"]), ("閲覧数の合計", st["views"]),
        ("公開", st["by_visibility"].get("public", 0)), ("リンクだけ", st["by_visibility"].get("unlisted", 0)),
        ("パスワード", st["by_visibility"].get("password", 0)), ("文字数の合計", st["chars"])])

    def opt(value, label, cur):
        return '<option value="%s"%s>%s</option>' % (esc(value), " selected" if value == cur else "", esc(label))
    filt = ('<form class="filter" method="get" action="/admin"><input name="q" value="%s" placeholder="id・題名で探す">'
            '<select name="vis">%s</select><select name="sort">%s</select><button>絞り込む</button></form>') % (
        esc(q), opt("", "すべての公開のしかた", vis) + "".join(opt(k, v, vis) for k, v in VIS_NAMES.items()),
        "".join(opt(k, v, sort) for k, v in [("new", "公開した順"), ("updated", "更新した順"), ("views", "閲覧数の多い順"),
                                               ("expires", "期限の近い順"), ("size", "文字数の多い順")]))
    trs = []
    for r in rows:
        trs.append('<tr><td><a href="/admin/d/%s">%s</a></td><td>%s</td><td><span class="tag v-%s">%s</span></td><td>%s</td>'
                   '<td>%s</td><td>%s</td><td>%s</td><td class="num">%d</td><td class="num">%d</td><td class="num">%d</td></tr>' % (
                       esc(r["id"]), esc(r["id"]), esc(r["title"] or "（題名なし）"), esc(r["visibility"]),
                       esc(VIS_NAMES.get(r["visibility"], r["visibility"])), esc(MODE_NAMES.get(r["mode"], r["mode"])),
                       fmt(r["created"]), fmt(r["updated"]), fmt(r["expires"]) if r["expires"] else "期限なし",
                       r["views"], r["chars"], r["history_count"]))
    table = ('<table><tr><th>id</th><th>題名</th><th>公開のしかた</th><th>表示</th><th>公開</th><th>更新</th><th>期限</th>'
             '<th>閲覧</th><th>文字数</th><th>版</th></tr>%s</table>') % ("".join(trs) or '<tr><td colspan="10">ありません</td></tr>')
    pages = max(1, (total + per - 1) // per)
    link = lambda n: "/admin?" + urllib.parse.urlencode({"q": q, "vis": vis, "sort": sort, "p": n})
    pager = '<div class="pager">%d 件 ・ %d / %d ページ %s %s</div>' % (
        total, page, pages, '<a href="%s">← 前</a>' % esc(link(page - 1)) if page > 1 else "",
        '<a href="%s">次 →</a>' % esc(link(page + 1)) if page < pages else "")
    return shell("一覧", '<div class="cards">%s</div>%s%s%s' % (cards, filt, table, pager), csrf)


def detail_page(store, i, csrf, base_url, files, msg=""):
    doc = store.get(i)
    if not doc:
        return None
    url = "%s/r/%s" % (base_url, i)
    hist = doc.get("history") or []
    info = [("id", i), ("URL", '<a href="%s" target="_blank" rel="noopener">%s</a>' % (esc(url), esc(url))),
            ("題名", esc(doc.get("title") or "（題名なし）")),
            ("公開のしかた", '<span class="tag v-%s">%s</span>' % (esc(doc.get("visibility", "")), esc(VIS_NAMES.get(doc.get("visibility"), "")))),
            ("表示", esc(MODE_NAMES.get(doc.get("mode"), doc.get("mode") or ""))),
            ("公開した日時", fmt(doc.get("created"))), ("更新した日時", fmt(doc.get("updated"))),
            ("期限", fmt(doc.get("expires")) if doc.get("expires") else "期限なし"),
            ("閲覧数", "%d 回 (最後: %s)" % (doc.get("views") or 0, fmt(doc.get("last_view")))),
            ("文字数", "%d 字" % len(doc.get("text") or "")),
            ("変更履歴", "%d 版を残している ・ %s" % (len(hist), "これからも残す" if doc.get("keepHistory", True) else "残さない")),
            ("画面の画像", "あり" if files.get("shot") else "なし"), ("SNS のカード画像", "作成済み" if files.get("og") else "まだ")]
    # 値は、上で必要なものはすでに esc してある (日時・数・決まった言葉だけそのまま)
    grid = '<dl class="grid">%s</dl>' % "".join("<dt>%s</dt><dd>%s</dd>" % (esc(k), v) for k, v in info)

    def form(action, inner, cls="", confirm=""):
        return ('<form method="post" action="/admin/d/%s/%s"><input type="hidden" name="csrf" value="%s">%s'
                '<button class="%s">%s</button></form>') % (esc(i), action, esc(csrf), inner, cls, confirm)
    vis_opts = "".join('<option value="%s"%s>%s</option>' % (k, " selected" if k == doc.get("visibility") else "", esc(v)) for k, v in VIS_NAMES.items())
    actions = (
        '<div class="box"><h3>設定を変える</h3>'
        + form("title", '<input name="title" value="%s" size="40">' % esc(doc.get("title") or ""), "", "題名を変える")
        + form("visibility", '<select name="visibility">%s</select><input type="password" name="password" placeholder="パスワード制にするとき (4 文字以上)" autocomplete="new-password">' % vis_opts, "", "公開のしかたを変える")
        + form("expires", '<select name="days"><option value="">日数で</option><option value="1">1 日</option><option value="7">7 日</option>'
               '<option value="30">30 日</option><option value="365">1 年</option><option value="0">期限なし</option></select>'
               '<span>または</span><input type="datetime-local" name="at">', "", "期限を変える")
        + form("history", '<label><input type="checkbox" name="keep" value="1"%s> 変更履歴を残す</label>' % (" checked" if doc.get("keepHistory", True) else ""), "", "変更履歴の設定を変える")
        + form("clearhistory", "", "", "今ある変更履歴を消す (%d 版)" % len(hist))
        + '</div><div class="box"><h3>公開をやめる</h3><p>ページ・画像・変更履歴をすべて消します。元に戻せません。</p>'
        + form("delete", '<label><input type="checkbox" name="sure" value="1" required> 本当に消す</label>', "danger", "公開をやめる (消す)")
        + '</div>')
    preview = '<div class="box"><h3>本文 (はじめの 3000 字)</h3><pre>%s</pre></div>' % esc((doc.get("text") or "")[:3000])
    vers = ""
    if hist:
        vers = '<div class="box"><h3>変更履歴</h3><ul>%s</ul></div>' % "".join(
            '<li>第%d版 ・ %s ・ %s ・ %d 字 ・ <a href="%s?rev=%d" target="_blank" rel="noopener">見る</a></li>' % (
                k + 1, fmt(h.get("at")), esc(h.get("title") or ""), len(h.get("text") or ""), esc(url), k + 1)
            for k, h in enumerate(hist))
    note = '<div class="msg">%s</div>' % esc(msg) if msg else ""
    return shell(doc.get("title") or i, note + '<h2>%s</h2>' % esc(doc.get("title") or "（題名なし）") + grid + actions + preview + vers, csrf)
