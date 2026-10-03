"""Compare critical private state before/after an authorized installed update.

Reports only preservation booleans and counts. Tokens, configuration values,
book names, voice references and certificate keys never appear in output.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3


def digest(value): return hashlib.sha256(value).hexdigest()


def snapshot(root):
    files = {}
    for name in ("config.json", "pairing.key"):
        path = root / name
        if path.is_file(): files[name] = digest(path.read_bytes())
    for directory in ("tls", "books", "voices"):
        for path in sorted((root / directory).rglob("*")):
            if path.is_file(): files[str(path.relative_to(root)).replace("\\", "/")] = digest(path.read_bytes())
    with sqlite3.connect((root / "library.sqlite3").as_uri() + "?mode=ro", uri=True) as db:
        devices = db.execute("SELECT * FROM devices ORDER BY id").fetchall()
        books = db.execute("SELECT id,data FROM books ORDER BY id").fetchall()
        jobs = db.execute("SELECT id,data FROM jobs ORDER BY id").fetchall()
    statuses = [json.loads(row[1])["status"] for row in jobs]
    if any(status in {"running", "queued"} for status in statuses):
        raise RuntimeError("Wait for active narration before upgrading the installed app")
    return {"files": files, "devices_hash": digest(json.dumps(devices).encode()),
            "books_hash": digest(json.dumps(books).encode()), "jobs_hash": digest(json.dumps(jobs).encode()),
            "device_count": len(devices), "book_count": len(books), "job_count": len(jobs)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["snapshot", "verify"])
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    args = parser.parse_args()
    current = snapshot(args.data_dir.resolve())
    if args.mode == "snapshot":
        args.baseline.parent.mkdir(parents=True, exist_ok=True)
        args.baseline.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"ready_for_upgrade": True, "private_files_checked": len(current["files"]),
                          "devices": current["device_count"], "books": current["book_count"], "jobs": current["job_count"]}))
    else:
        before = json.loads(args.baseline.read_text(encoding="utf-8"))
        results = {"private_files_preserved": before["files"] == current["files"],
                   "paired_devices_preserved": before["devices_hash"] == current["devices_hash"],
                   "library_preserved": before["books_hash"] == current["books_hash"],
                   "narration_jobs_preserved": before["jobs_hash"] == current["jobs_hash"]}
        print(json.dumps(results))
        if not all(results.values()): raise SystemExit(1)
