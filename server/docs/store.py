"""公開したものの保存場所 (SQLite)。

1 件 = 1 行。よく使う項目 (題名・公開のしかた・日時・閲覧数など) は列にして、一覧・並べ替え・検索に使う。
中身すべて (本文・変更履歴・パスワードの印など) は data 列に JSON で入れる。
前の版 (1 件ずつの .json ファイル) は、はじめに読み込んで .json.migrated に名前を変える。
"""
import json
import os
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS docs (
    id            TEXT PRIMARY KEY,
    title         TEXT NOT NULL DEFAULT '',
    mode          TEXT NOT NULL DEFAULT 'text',
    visibility    TEXT NOT NULL DEFAULT 'unlisted',
    created       REAL NOT NULL,
    updated       REAL,
    expires       REAL,
    chars         INTEGER NOT NULL DEFAULT 0,
    history_count INTEGER NOT NULL DEFAULT 0,
    keep_history  INTEGER NOT NULL DEFAULT 1,
    views         INTEGER NOT NULL DEFAULT 0,
    last_view     REAL,
    data          TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS docs_created ON docs(created);
CREATE INDEX IF NOT EXISTS docs_expires ON docs(expires);
CREATE INDEX IF NOT EXISTS docs_visibility ON docs(visibility);
"""

SORTS = {
    "new": "created DESC",
    "updated": "COALESCE(updated, created) DESC",
    "views": "views DESC, created DESC",
    "expires": "CASE WHEN expires IS NULL THEN 1 ELSE 0 END, expires ASC",
    "size": "chars DESC",
}


class Store:
    def __init__(self, path, legacy_dir=None):
        self.lock = threading.Lock()
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(SCHEMA)
        if legacy_dir:
            self._migrate(legacy_dir)

    # ---------- 前の版からの引っ越し ----------

    def _migrate(self, folder):
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".json") or name.count(".") != 1:
                continue
            path = os.path.join(folder, name)
            try:
                with open(path, encoding="utf-8") as f:
                    doc = json.load(f)
                if isinstance(doc, dict) and "text" in doc:
                    if not self.exists(name[:-5]):
                        self.put(name[:-5], doc)
                    os.replace(path, path + ".migrated")
            except (OSError, ValueError):
                pass

    # ---------- 1 件 ----------

    def exists(self, i):
        with self.lock:
            return self.db.execute("SELECT 1 FROM docs WHERE id=?", (i,)).fetchone() is not None

    def get(self, i):
        with self.lock:
            row = self.db.execute("SELECT data, views, last_view FROM docs WHERE id=?", (i,)).fetchone()
        if not row:
            return None
        doc = json.loads(row["data"])
        doc["views"], doc["last_view"] = row["views"], row["last_view"]
        return doc

    def put(self, i, doc):
        data = {k: v for k, v in doc.items() if k not in ("views", "last_view")}
        cols = (data.get("title") or "", data.get("mode") or "text", data.get("visibility") or "unlisted",
                data.get("created") or time.time(), data.get("updated"), data.get("expires"),
                len(data.get("text") or ""), len(data.get("history") or []), 0 if data.get("keepHistory") is False else 1,
                json.dumps(data, ensure_ascii=False))
        with self.lock:
            self.db.execute(
                "INSERT INTO docs (id, title, mode, visibility, created, updated, expires, chars, history_count, keep_history, data) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title, mode=excluded.mode, "
                "visibility=excluded.visibility, created=excluded.created, updated=excluded.updated, expires=excluded.expires, "
                "chars=excluded.chars, history_count=excluded.history_count, keep_history=excluded.keep_history, data=excluded.data",
                (i,) + cols)

    def delete(self, i):
        with self.lock:
            return self.db.execute("DELETE FROM docs WHERE id=?", (i,)).rowcount > 0

    def count_view(self, i):
        with self.lock:
            self.db.execute("UPDATE docs SET views=views+1, last_view=? WHERE id=?", (time.time(), i))

    # ---------- 一覧・集計 (管理画面) ----------

    def expired_ids(self, now):
        with self.lock:
            return [r[0] for r in self.db.execute("SELECT id FROM docs WHERE expires IS NOT NULL AND expires < ?", (now,))]

    def search(self, q="", visibility="", sort="new", limit=50, offset=0):
        where, args = [], []
        if q:
            where.append("(id LIKE ? OR title LIKE ?)")
            args += ["%" + q + "%", "%" + q + "%"]
        if visibility:
            where.append("visibility=?")
            args.append(visibility)
        sql = ("SELECT id, title, mode, visibility, created, updated, expires, chars, history_count, keep_history, views, last_view "
               "FROM docs" + (" WHERE " + " AND ".join(where) if where else ""))
        with self.lock:
            total = self.db.execute("SELECT COUNT(*) FROM (" + sql + ")", args).fetchone()[0]
            rows = self.db.execute(sql + " ORDER BY " + SORTS.get(sort, SORTS["new"]) + " LIMIT ? OFFSET ?",
                                   args + [limit, offset]).fetchall()
        return total, [dict(r) for r in rows]

    def stats(self):
        with self.lock:
            by_vis = {r[0]: r[1] for r in self.db.execute("SELECT visibility, COUNT(*) FROM docs GROUP BY visibility")}
            total, views, chars = self.db.execute("SELECT COUNT(*), COALESCE(SUM(views),0), COALESCE(SUM(chars),0) FROM docs").fetchone()
            day = self.db.execute("SELECT COUNT(*) FROM docs WHERE created > ?", (time.time() - 86400,)).fetchone()[0]
        return {"total": total, "views": views, "chars": chars, "today": day, "by_visibility": by_vis}

    def public_list(self, limit=100):
        with self.lock:
            rows = self.db.execute("SELECT id, data FROM docs WHERE visibility='public' ORDER BY created DESC LIMIT ?", (limit,)).fetchall()
        return [(json.loads(r["data"]).get("created", 0), r["id"], json.loads(r["data"])) for r in rows]
