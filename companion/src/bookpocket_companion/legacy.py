"""Explicit legacy archive migration; unmatched recordings remain labelled legacy."""
import io
import json
from pathlib import Path, PurePosixPath
import tempfile
import uuid
import zipfile
import subprocess
from .media import normalize_reference
from .models import Pronunciation
from .publication import normalize, parse_book
from .store import canonical, digest, now
from .worker import validate_wav

def initialize(store):
    with store.db() as db:
        db.executescript("""CREATE TABLE IF NOT EXISTS legacy_recordings(id TEXT PRIMARY KEY,book_id TEXT,data TEXT);
                          CREATE TABLE IF NOT EXISTS migrations(id TEXT PRIMARY KEY,data TEXT);
                          CREATE TABLE IF NOT EXISTS preferences(key TEXT PRIMARY KEY,value TEXT);""")

def import_legacy(store, content, ffmpeg):
    identity = digest(content)
    with store.db() as db:
        previous = db.execute("SELECT data FROM migrations WHERE id=?", (identity,)).fetchone()
    if previous: return json.loads(previous[0])
    result = {"kind": "legacy", "books": [], "recordings": [], "voices": [], "pronunciation_rules": [], "positions": []}
    files = []
    rows = {"books": [], "assets": [], "voices": [], "recordings": []}
    try:
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            members = archive.infolist()
            if len(members) > 10000 or len({m.filename for m in members}) != len(members) or sum(m.file_size for m in members) > 1024**3:
                raise ValueError("Legacy archive exceeds limits or contains duplicate entries")
            for m in members:
                if m.filename.startswith(("/", "\\")) or ".." in PurePosixPath(m.filename).parts or "\\" in m.filename or ":" in m.filename or m.flag_bits & 1:
                    raise ValueError("Unsafe legacy archive path")
            if archive.getinfo("legacy.json").file_size > 10 * 1024**2: raise ValueError("Legacy manifest is too large")
            manifest = json.loads(archive.read("legacy.json"))
            if manifest.get("format_version") != 1 or manifest.get("kind") != "bookpocket_legacy": raise ValueError("Unsupported legacy archive format")
            by_legacy_id = {}
            for item in manifest.get("books", []):
                source_name = item["source"]
                if archive.getinfo(source_name).file_size > 100*1024**2: raise ValueError("Original book exceeds 100 MiB")
                source = archive.read(source_name)
                book = parse_book(source, item.get("title", "Imported book") + Path(source_name).suffix)
                by_legacy_id[item["legacy_id"]] = book
                path = store.root / "books" / (book["id"] + Path(source_name).suffix.lower())
                if not path.exists():
                    temp = path.with_suffix(path.suffix + "." + str(uuid.uuid4()) + ".tmp")
                    temp.write_bytes(source); temp.replace(path)
                rows["books"].append((book["id"], canonical(book), str(path)))
                result["books"].append(book)
                if item.get("position"):
                    result["positions"].append({"book_id": book["id"], "legacy_position": str(item["position"]), "mapping": "unmapped", "explanation": "Old display-page positions cannot be mapped reliably; the original value is preserved"})
            for item in manifest.get("recordings", []):
                book = by_legacy_id.get(item.get("book_legacy_id"))
                if not book: raise ValueError("A legacy recording references a missing original book")
                name = item["path"]
                if archive.getinfo(name).file_size > 500 * 1024**2: raise ValueError("Legacy recording exceeds 500 MiB")
                audio = archive.read(name)
                recording_id, asset_id = str(uuid.uuid4()), str(uuid.uuid4())
                original_path = store.root / "assets" / (asset_id + ".original")
                path = store.root / "assets" / (asset_id + ".wav")
                original_path.write_bytes(audio); files.append(original_path)
                files.append(path)
                subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file,pipe", "-format_whitelist", "wav,mp3,flac,ogg,mov,aac,aiff", "-i", str(original_path), "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", str(path)], check=True, capture_output=True, timeout=600)
                duration = validate_wav(path)
                matches = []
                text = normalize(str(item.get("source_text", "")))
                if text:
                    for chapter in book["chapters"]:
                        for segment in chapter["segments"]:
                            start = segment["text"].find(text)
                            if start >= 0 and segment["text"].find(text, start+1) < 0:
                                matches.append({"segment_id": segment["id"], "start_offset": start, "end_offset": start+len(text), "locator": segment["locator"]})
                asset = {"id": asset_id, "segment_id": matches[0]["segment_id"] if len(matches) == 1 else None, "media_type": "audio/wav", "duration": duration,
                         "sha256": digest(path.read_bytes()), "bytes": path.stat().st_size, "url": "/v1/assets/" + asset_id, "timings": [], "alignment": "unmapped"}
                recording = {"id": recording_id, "book_id": book["id"], "title": str(item.get("title", "Legacy recording")), "asset": asset,
                             "mapping": "text_match_without_timings" if len(matches) == 1 else "unmapped", "source_match": matches[0] if len(matches) == 1 else None,
                             "source_text": text, "legacy_metadata": item, "imported_at": now()}
                rows["assets"].append((asset_id, None, canonical(asset), str(path)))
                rows["recordings"].append((recording_id, book["id"], canonical(recording)))
                result["recordings"].append(recording)
            for item in manifest.get("voices", []):
                if item.get("engine", "qwen3") != "qwen3": raise ValueError("Legacy voice references currently import into Qwen3")
                if archive.getinfo(item["path"]).file_size > 20*1024**2: raise ValueError("Voice reference exceeds 20 MiB")
                voice_id = str(uuid.uuid4())
                path = store.root / "voices" / (voice_id + ".wav")
                files.append(path)
                normalize_reference(archive.read(item["path"]), path, ffmpeg)
                voice = {"id": voice_id, "name": str(item["name"])[:120], "engine": "qwen3", "kind": "clone", "language": item.get("language", "en"), "created_at": now()}
                rows["voices"].append((voice_id, canonical(voice), str(path), str(item.get("transcript", ""))[:10000]))
                result["voices"].append(voice)
            rules = [Pronunciation.model_validate(r).model_dump() for r in manifest.get("pronunciation_rules", [])]
            result["pronunciation_rules"] = rules
            with store.db() as db:
                db.execute("BEGIN IMMEDIATE")
                db.executemany("INSERT OR IGNORE INTO books VALUES(?,?,?)", rows["books"])
                db.executemany("INSERT INTO assets VALUES(?,?,?,?)", rows["assets"])
                db.executemany("INSERT INTO voices VALUES(?,?,?,?)", rows["voices"])
                db.executemany("INSERT INTO legacy_recordings VALUES(?,?,?)", rows["recordings"])
                existing = db.execute("SELECT value FROM preferences WHERE key='pronunciation_rules'").fetchone()
                existing_rules = json.loads(existing[0]) if existing else []
                by_term = {r["term"].casefold(): r for r in rules}
                by_term.update({r["term"].casefold(): r for r in existing_rules})
                db.execute("INSERT OR REPLACE INTO preferences VALUES('pronunciation_rules',?)", (canonical(list(by_term.values())),))
                db.execute("INSERT INTO migrations VALUES(?,?)", (identity, canonical(result)))
            files.clear()
        return result
    finally:
        for path in files: path.unlink(missing_ok=True)
