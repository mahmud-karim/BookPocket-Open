import contextlib
import hashlib
import json
import sqlite3
from datetime import datetime, timezone

def now():
    return datetime.now(timezone.utc).isoformat()

def digest(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

class Store:
    def __init__(self, root):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)
        for name in ("books", "voices", "assets", "exports", "engines", "tls"):
            (root / name).mkdir(exist_ok=True)
        self.path = root / "library.sqlite3"
        with self.db() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS books(id TEXT PRIMARY KEY, data TEXT NOT NULL, source TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS voices(id TEXT PRIMARY KEY, data TEXT NOT NULL, reference TEXT, transcript TEXT);
                CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, request_id TEXT UNIQUE NOT NULL, request TEXT NOT NULL, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY, cache_key TEXT UNIQUE, data TEXT NOT NULL, path TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT, token_hash TEXT UNIQUE, created_at TEXT);
                CREATE TABLE IF NOT EXISTS tickets(id TEXT PRIMARY KEY, code_hash TEXT UNIQUE, expires REAL, used INTEGER DEFAULT 0);
                CREATE TABLE IF NOT EXISTS pairings(id TEXT PRIMARY KEY, name TEXT, poll_hash TEXT, expires REAL, status TEXT, device_id TEXT, encrypted_token TEXT);
            """)

    @contextlib.contextmanager
    def db(self):
        connection = sqlite3.connect(self.path, timeout=30)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def item(self, table, item_id):
        assert table in {"books", "voices", "jobs", "assets"}
        with self.db() as db:
            row = db.execute(f"SELECT * FROM {table} WHERE id=?", (item_id,)).fetchone()
        return dict(row) if row else None

    def all(self, table):
        assert table in {"books", "voices", "jobs", "assets"}
        with self.db() as db:
            return [json.loads(row[0]) for row in db.execute(f"SELECT data FROM {table} ORDER BY rowid DESC")]
